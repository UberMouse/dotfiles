#!/usr/bin/env python3
# build-semaphore-controller -- the ADMISSION half of the pressure system.
#
# cgroup-governor.sh gates EXECUTION: under pressure it freezes build scopes so
# N run and the rest wait. Its own header records why it settled for that:
#
#     "True admission control gates at spawn, but the spawn point is
#      ~/code/kawaka/.claude/hooks/worktree-setup.sh -- a different repo."
#
# This service is the lever that sentence said it could not reach. It gates at
# SPAWN, from this repo, by publishing a machine-global counting semaphore that
# any heavy job -- in any worktree, any repo, any language -- takes a slot from
# before it allocates anything.
#
# WHY FREEZING WAS NEVER GOING TO CONVERGE. A frozen cgroup keeps every anon
# page resident: SIGSTOP does not return memory, it only stops the process
# asking for more. So the governor's cap can stop demand GROWING but can never
# make the current peak smaller, and the log shows exactly that -- a ~20 s
# round-robin of FREEZE/THAW "cap rotation" that never reaches a steady state
# because the signal it reacts to never responds to the action it takes.
# Refusing ADMISSION is different in kind: a job that has not started has not
# allocated, so the peak never forms in the first place.
#
# WHY A SEMAPHORE IS THE RIGHT SHAPE (measured 2026-08-03, 429 samples / 80 min
# of worktrees.slice at 10 s resolution):
#
#     pool_mem   p50=12.57G  p90=15.08G  max=16.00G  mean=11.93G
#     pool_PSI   p50= 0.0%   p90=16.6%   max=81.1%
#     pool >14G for 26% of samples; PSI >20% for 9% of samples
#
# Median memory pressure is ZERO. Mean pool utilisation is 11.93 of 16 GiB --
# 73%, which is healthy. The box is not short of RAM on average; it is short of
# RAM for the ~10% of the time when independent worktrees happen to burst at the
# same instant. That is a QUEUEING problem, and the fix for a queueing problem
# is a queue. More RAM would only raise the ceiling the same bursts slam into.
#
# WHAT ACTUALLY BURSTS. The hog is `heft typecheck` at 0.6-2.3 GB per process
# (single largest observed: 2312 MB, packages/embeds/map-viewer/core). Demand is
# roughly N_active_worktrees x 4 concurrent package builds x ~1.5 GB, and with
# 78 worktrees on disk (58 top-level + 20 nested inside other worktrees) nothing
# bounds N. RUSH_PARALLELISM is the wrong knob for this: its minimum is 1, so
# even at the floor N worktrees still give N concurrent builds, and the test
# phase's workers belong to Jest, which Rush never sees.
#
# THE CONTROL LOOP, and why it does not oscillate like the governor does.
# Capacity is varied by this process HOLDING slots itself: slots are handed out
# from the bottom, and the controller takes them from the top, so in the common
# case the two meet in the middle without fighting over the same file. (That is
# an optimisation rather than a correctness property -- reconcile() counts slots
# instead of splitting the index range at a boundary, so a contested file costs
# one retry and nothing more. See its docstring for why counting is required.)
# Consequences:
#
#   * Tightening is naturally graceful. The controller can only take a slot that
#     is free, so lowering capacity does not preempt a running job -- it just
#     stops the next one starting. Capacity falls as jobs drain, not instantly.
#   * The feedback is real. Fewer admissions genuinely means less memory soon,
#     unlike a freeze. So the loop has an honest signal to close on.
#   * But it is LAGGED: an in-flight heft holds its 2 GB for tens of seconds
#     after admission stops. A symmetric controller would therefore overshoot,
#     see pressure fall, re-open, and ring -- which is precisely the failure mode
#     the governor already demonstrates. So the loop is deliberately asymmetric:
#     TIGHTEN FAST on a short window, LOOSEN SLOWLY on a long one, and never
#     loosen twice inside DWELL seconds. Multiplicative decrease, additive
#     increase -- the same asymmetry TCP uses, for the same reason.
#
# WHY CAPACITY IS NOT THE SAME AS AVAILABILITY (added 2026-08-04). The loop
# above governs how many jobs may run. On its own that says nothing about how
# many may START AT ONCE, and the difference is the whole of the first day's
# failure. From the log:
#
#     14:10:07 LOOSEN psi60=0.0%   allowed 5 -> 6     idle box, ratcheting
#     14:11:07 LOOSEN psi60=0.0%   allowed 6 -> 7
#     14:12:07 LOOSEN psi60=0.0%   allowed 7 -> 8
#     14:13:07 LOOSEN psi60=0.0%   allowed 8 -> 9     nine slots, nothing running
#     14:13:17 TIGHTEN high=93%    allowed 9 -> 7     the burst lands
#     14:14:07 TIGHTEN high=100%   allowed 7 -> 5     pool pinned at its ceiling
#     14:14:12 TIGHTEN psi10=28.8% allowed 5 -> 3
#     14:14:17 TIGHTEN psi10=28.9% allowed 3 -> 1
#
# Sixty seconds from idle to thrashing, and every tighten arrived after the
# memory it was defending against was already resident. Two separate mistakes
# compound there, and each has its own fix:
#
#   1. NINE SLOTS WERE FREE SIMULTANEOUSLY, so nine jobs could allocate in the
#      same instant. The loop's feedback is lagged by construction -- an
#      in-flight heft holds its 2 GB for tens of seconds -- so a step input of
#      that size is over before any signal responds to it. The controller was
#      built to react at 5 s resolution and was being asked to absorb a change
#      that completed in less than one tick.
#
#      Fix: bound availability at BOTH ends, because the two ends fail
#      differently and neither bound implies the other.
#
#        * A CAP ON THE SLOTS STANDING FREE (`burst`, 2). However much
#          concurrency this box has already proved it can carry, at most two
#          jobs may start before the loop gets a tick to look at what they did.
#          This bounds the STEP SIZE of the input.
#        * A PACE ON GROWTH (the high-water mark plus `grow_step`, below). Going
#          somewhere the box has not already been costs a load test and a
#          spacing interval. This bounds the RATE.
#
#      Availability is therefore `occupied + burst` at its most generous, and
#      `occupied` while the load test fails. The step becomes a ramp, and a ramp
#      is something a lagged loop can close on. Capacity still reaches `allowed`
#      under sustained demand; it just has to climb there a couple of jobs at a
#      time, and can be stopped part-way.
#
#      BOTH BOUNDS ARE REQUIRED, and shipping only the second reproduces the
#      original bug wearing different numbers. The 2026-08-04 mark rework did
#      exactly that, and the regression was measured on 2026-08-06 against a
#      synthetic pool: a run that peaked at 8 concurrent and then drained to ONE
#      job published `occupied=1 target=8 effective=8` and sat there --
#      seven slots standing free over an all-but-idle box, takeable in the same
#      instant. A mark is a memory of the peak, and a memory of the peak is
#      precisely the wrong thing to leave holding the door open, because the
#      drain is exactly when the next burst arrives. The mark answers "how high
#      may this go"; it was never entitled to answer "how many may start now".
#
#      GROWTH IS PACED; STEADY STATE IS NOT. The lever is a HIGH-WATER MARK:
#      the highest concurrency this box has held while the load test was
#      passing. Admissions up to the mark are replacements and cost nothing;
#      going above it is growth, and growth has to pass the load test and wait
#      out the spacing. The mark falls whenever the test fails, so a level the
#      box can no longer sustain stops counting as demonstrated.
#
#      The alternative -- make EVERY admission earn its own grant, replacements
#      included -- is the stricter reading and it was measured before being
#      rejected. This workload runs 15.3 admissions a minute with a median gap
#      of 3 s between them (1138 admissions over 74 minutes, 2026-08-04); jobs
#      average about 20 s. One admission per 15 s caps the machine at 4 a
#      minute, which is not a throttle but a 4x throughput cut, and the queue it
#      builds is unbounded. kx-build-slot gives up after 600 s and runs the job
#      UNGATED -- so the strict reading's end state is no gate at all. A
#      throttle that collapses under the load it exists to manage is worse than
#      none, because it also lies about being there.
#
#      Note what the mark is NOT: it is not a second cap, and it is not a
#      licence to open the whole window at once. `allowed` still bounds it, the
#      load test still gates it, `burst` still caps how much of it may stand
#      free, and a replacement batch is still sized to the memory actually free
#      (see `absorbable`). It only settles the question of which admissions have
#      to WAIT -- and the answer is the ones that take the box somewhere it has
#      not already been. Returning to a level already demonstrated is not free
#      of charge either; it is merely free of the SPACING, and still arrives two
#      jobs per tick rather than all at once.
#
#      The two halves of the load test fail independently, so both are required:
#
#        * MEMORY: at least TWO jobs' worth of room to memory.high. Two, not
#          one, so the admitted job cannot consume the last of the headroom --
#          requiring slack beyond the incoming job stops admission one job
#          earlier than the wall, which is the difference between a queue and an
#          OOM kill.
#        * STALL: psi10 at or below the quiet threshold. A pool with 4 GB free
#          can still be thrashing on reclaim; a quiet pool can still be one
#          allocation from the ceiling. Neither number alone means "healthy".
#
#      And the spacing clock runs from the last GROWTH STEP, not from the last
#      admission. psi10 is a TEN-SECOND average, so a level raised five seconds
#      after the previous one is judged against a signal that cannot yet contain
#      any evidence of it. A ramp that outruns its own feedback is just a slower
#      step. Resetting the clock on every admission instead would be worse than
#      useless here: under steady churn the mark is touched constantly, so the
#      clock would never run out and concurrency would freeze at whatever level
#      it first reached.
#
#   2. `allowed` GREW ON AN EMPTY BOX. Every LOOSEN above fired on psi60=0.0%
#      measured while nothing was running. That is not evidence the next value
#      is safe, it is the absence of evidence -- and the ratchet banked it as
#      credit, to be spent all at once by whatever arrived next.
#
#      Fix: loosen only while SATURATED (occupied >= the target in effect). Idle
#      capacity is frozen at whatever the last real workload proved safe. This is
#      why TCP does not grow cwnd while the sender is idle: a window is a claim
#      about a path, and you cannot learn anything about the path without
#      putting something on it.
#
# The LOAD TEST is the third leg, and the only one measured in the units that
# actually run out. Slots are a proxy for memory; when the pool is near its
# ceiling the proxy is simply wrong, and no slot opens regardless of what the
# slot arithmetic says. It cannot deadlock -- with nothing running, one slot is
# always free (see FLOOR) -- so a pool held near its ceiling by tenants that
# take no slots delays the next build without ever preventing builds.
#
# FLOOR is 1, never 0: a floored semaphore must still make progress or the build
# system deadlocks. At the floor, heavy jobs run strictly one at a time, which is
# slow but always finishes. The same rule governs the burst gate: `occupied == 0`
# always leaves a slot free, because a machine where every caller waits out its
# timeout and then runs UNGATED is worse than one that admits a single job.
#
# FAILURE MODES ARE ALL FAIL-OPEN, by construction:
#   * controller not running -> no slot files -> kx-build-slot execs directly,
#     so the machine behaves exactly as it did before this service existed;
#   * controller CRASHES holding locks -> the kernel drops every flock when the
#     fd closes on process death, so capacity returns to maximum rather than
#     staying stuck at the floor. This is the single strongest reason the
#     semaphore is flock-on-a-file and not a daemon protocol with leases: the
#     holders here are build workers that genuinely do get OOM-killed, and a
#     lease-based design would need expiry logic to survive what flock gets from
#     the kernel for free.
#
# Observability:
#   ~/.local/state/cgroup-pressure/build-semaphore.log   (tag: BUILDSEM|)
#   $XDG_RUNTIME_DIR/kx-build-sem/allowed                (current capacity)
#
# Tunables are env vars, all optional; defaults are in CFG below.

import fcntl
import os
import signal
import sys
import time
from pathlib import Path

RUNTIME = os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
SEM_DIR = Path(os.environ.get("KX_BUILD_SEM_DIR", f"{RUNTIME}/kx-build-sem"))
# Overridable so the test harness does not write its synthetic runs into the
# real log. Not hypothetical: the 2026-08-03 log contains a stray test START
# line interleaved with production decisions, which is exactly the kind of thing
# that costs an hour when reading back a timeline months later.
STATE_DIR = Path(
    os.environ.get("KX_SEM_STATE_DIR", Path.home() / ".local/state/cgroup-pressure")
)
LOG = STATE_DIR / "build-semaphore.log"

UID = os.getuid()
# Overridable so the control loop can be exercised against a synthetic
# memory.pressure file instead of having to reproduce real memory pressure on a
# live desktop. To exercise it, point KX_SEM_POOL at a directory containing a
# memory.pressure (plus optional memory.current / memory.high) in kernel format
# and rewrite it while the controller runs:
#
#   mkdir -p /tmp/fakepool && cd /tmp/fakepool
#   printf 'some avg10=0 avg60=0 avg300=0 total=0\n'  > memory.pressure
#   printf 'full avg10=40 avg60=40 avg300=40 total=0\n' >> memory.pressure
#   KX_SEM_POOL=/tmp/fakepool KX_BUILD_SEM_DIR=/tmp/sem \
#     KX_SEM_INTERVAL=1 python3 build-semaphore-controller.py
POOL = Path(
    os.environ.get(
        "KX_SEM_POOL",
        f"/sys/fs/cgroup/user.slice/user-{UID}.slice/user@{UID}.service/worktrees.slice",
    )
)


def _int(name, default):
    try:
        return int(os.environ.get(name, default))
    except ValueError:
        return default


def _float(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


CFG = dict(
    # Total slot files created. The ceiling can never exceed this.
    max_slots=_int("KX_SEM_MAX_SLOTS", 16),
    # Never admit more than this many heavy jobs at once, however calm the box
    # looks. Originally 12, to match the pool's CPUQuota=1200% -- but cores were
    # never the binding resource here. Sizing by the one that is:
    #
    #     (16 GiB pool - ~3 GiB of tenants that take no slots) / ~1.5 GiB a heft
    #       = ~8 concurrent
    #
    # and the measurement agrees: on 2026-08-04 the box reached 100% of
    # memory.high and psi10=48% at SEVEN concurrent jobs, four short of the
    # nominal ceiling. A cap the machine cannot reach without stalling is not a
    # cap, it is decoration -- every excursion above ~8 was recovered by the
    # tighten path rather than prevented by the ceiling.
    ceil=_int("KX_SEM_CEIL", 8),
    # Never admit fewer than this. 1, not 0 -- see FLOOR note above.
    floor=_int("KX_SEM_FLOOR", 1),
    # The lowest capacity the PREDICTIVE (memory.high fraction) signal may reach
    # on its own. Only measured stalling (PSI) may go below this, down to floor.
    # See the tightening branch for why the two signals are not equivalent.
    soft_floor=_int("KX_SEM_SOFT_FLOOR", 4),
    # Control interval.
    interval=_float("KX_SEM_INTERVAL", 5.0),
    # Tighten when the pool's SHORT-window memory stall exceeds this. The
    # measured p90 is 16.6% and median is 0.0%, so 15% fires on the bursts we
    # care about and stays silent through the calm 90%.
    tighten_psi=_float("KX_SEM_TIGHTEN_PSI", 15.0),
    # Loosen only when the LONG window is this quiet. Well below tighten_psi so
    # the two thresholds cannot chatter against each other.
    loosen_psi=_float("KX_SEM_LOOSEN_PSI", 3.0),
    # Predictive tighten: also tighten when the pool is this close to its
    # memory.high, before PSI has had time to register. Reclaim latency is the
    # symptom; approaching the ceiling is the cause, and it is visible earlier.
    tighten_high_frac=_float("KX_SEM_TIGHTEN_HIGH_FRAC", 0.90),
    # Slots surrendered per tightening tick (multiplicative-ish decrease).
    step_down=_int("KX_SEM_STEP_DOWN", 2),
    # Slots regained per loosening tick (additive increase).
    step_up=_int("KX_SEM_STEP_UP", 1),
    # Minimum seconds between two increases. This is the anti-ring guard: it
    # must comfortably exceed how long an in-flight heft keeps its pages after
    # admission stops, or the loop re-opens into memory that has not drained.
    dwell=_float("KX_SEM_DWELL", 60.0),
    # How far the high-water mark may move in one step -- the GROWTH quantum.
    # One: concurrency climbs to a level it has never held one job at a time,
    # and each step has to pass the load test below.
    #
    # Renamed from KX_SEM_FREE_SLOTS, which is what this knob genuinely was
    # before the mark existed and was actively misleading afterwards -- it
    # bounds how fast the CEILING may rise, not how many slots stand free. Two
    # different quantities behind one name is how the cap below came to be
    # deleted by a commit that believed it was merely rewording it.
    grow_step=_int("KX_SEM_GROW_STEP", 1),
    # THE FREE-SLOT CAP: how many slots may stand FREE at once, no matter how
    # much headroom the mark or the memory gate would otherwise allow. This is
    # the bound on STEP SIZE, and it is the one thing here that keeps a drain
    # from re-arming the burst that the ramp exists to prevent -- see "BOTH
    # BOUNDS ARE REQUIRED" in the header.
    #
    # 2, not 1: at 1 the only way to reach any concurrency at all is one
    # admission per control interval, which turns every phase boundary (where
    # several jobs finish within one tick) into a needless queue. 2 admits at
    # most two new heavy jobs before the loop gets to look at them, which at a
    # 5 s interval is a ramp psi10's ten-second window can still resolve.
    burst=_int("KX_SEM_BURST", 2),
    # Minimum seconds between one GROWTH step and the next. Replacements are not
    # subject to this (see the high-water mark note in the header) -- only moves
    # to a concurrency level the box has not yet demonstrated. psi10 is a
    # TEN-SECOND average, so a level raised five seconds after the last one is
    # judged against a signal that cannot yet contain any evidence of it. 15 s
    # guarantees each step is fully visible before the next is considered.
    grant_every=_float("KX_SEM_GRANT_EVERY", 15.0),
    # THE LOAD TEST, part one: how many jobs' worth of memory must remain free
    # before another slot is opened. TWO, not one, and the difference is the
    # whole point -- at one, the admitted job is allowed to consume the last of
    # the headroom, which is precisely how the pool reached 100% of memory.high
    # at six concurrent on 2026-08-04. Requiring slack beyond the incoming job
    # means admission stops one job EARLIER than the wall.
    grant_headroom_jobs=_float("KX_SEM_GRANT_HEADROOM_JOBS", 2.0),
    # THE LOAD TEST, part two: nothing may be stalling. Memory headroom says
    # there is room; this says the box is not already struggling to use what it
    # has. Both must hold, because they fail independently -- a pool with 4 GB
    # free can still be thrashing on reclaim, and a quiet pool can still be one
    # allocation from the ceiling.
    grant_psi=_float("KX_SEM_GRANT_PSI", 3.0),
    # Assumed peak RSS of one gated job, for the memory gate. 1.5 GiB is the
    # middle of the measured heft typecheck range (0.6-2.3 GB); the largest
    # single observation was 2312 MB. Deliberately not the maximum: sizing the
    # gate to the worst case would hold admission shut through the pool states
    # the median job passes through comfortably.
    job_bytes=_int("KX_SEM_JOB_BYTES", 1610612736),
    # Minimum seconds between two HOLD log lines. The gate engages on most ticks
    # of a busy period and logging each one would bury the decisions.
    hold_log_every=_float("KX_SEM_HOLD_LOG_EVERY", 30.0),
)


def log(msg):
    line = f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')}  BUILDSEM|{msg}\n"
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG, "a") as fh:
            fh.write(line)
    except OSError:
        pass
    sys.stderr.write(line)
    sys.stderr.flush()


def read_psi(path, field="full", key="avg10"):
    """Return a PSI percentage, or None when the file is absent/unreadable.

    None means "no signal" and is treated as calm -- the pool cgroup simply may
    not exist yet (it materialises on the first heavy command), and a missing
    pool must not be read as a stalled one.
    """
    try:
        for line in (path / "memory.pressure").read_text().splitlines():
            parts = line.split()
            if parts and parts[0] == field:
                for p in parts[1:]:
                    k, _, v = p.partition("=")
                    if k == key:
                        return float(v)
    except (OSError, ValueError):
        return None
    return None


def read_pool_mem(path):
    """(current, high) bytes for the pool, or None when unavailable.

    Both numbers come from one pass because both signals below are derived from
    them: the FRACTION drives the predictive tighten, and the absolute HEADROOM
    drives the memory gate. Reading the pair together keeps the two decisions
    made from a single consistent sample.
    """
    try:
        cur = int((path / "memory.current").read_text().strip())
        raw = (path / "memory.high").read_text().strip()
        if raw == "max":
            return None
        high = int(raw)
        return (cur, high) if high > 0 else None
    except (OSError, ValueError):
        return None


def locked_inodes():
    """{(major, minor, inode)} for every flock HOLDER on the machine, or None.

    This is how the controller learns how many slots are actually in use without
    touching a lock itself. Probing with a non-blocking flock would be
    destructive: a test-and-release momentarily owns the slot, which can deny a
    job that was reaching for it in the same instant. /proc/locks is a pure read.

    Rows containing '->' are BLOCKED WAITERS, not holders, and must be skipped or
    a queue of waiters would inflate the occupancy count and stall admission
    exactly when demand is highest. (kx-build-slot uses `flock -n`, so it never
    creates such a row -- but nothing guarantees every future caller will.)

    The device is compared as well as the inode. Slot files live on tmpfs and
    carry very low inode numbers (58-73 as measured), which collide freely with
    inodes on any other small filesystem; matching on the inode alone would count
    unrelated locks as busy slots.
    """
    out = set()
    try:
        with open("/proc/locks") as fh:
            for line in fh:
                if "->" in line:
                    continue
                for tok in line.split():
                    parts = tok.split(":")
                    if len(parts) != 3:
                        continue
                    try:
                        # maj:min are hex in this file; the inode is decimal.
                        out.add(
                            (int(parts[0], 16), int(parts[1], 16), int(parts[2]))
                        )
                    except ValueError:
                        pass
                    break
    except OSError:
        return None
    return out


class Semaphore:
    """Slot files plus the subset this controller is holding back.

    Held slots are counted from the TOP so that jobs (which scan from the
    bottom) and the controller never contend for the same file.
    """

    def __init__(self, directory, max_slots):
        self.dir = directory
        self.max_slots = max_slots
        self.held = {}  # index -> open file object
        self.dir.mkdir(parents=True, exist_ok=True)
        for i in range(max_slots):
            self.dir.joinpath(f"slot.{i:02d}").touch(exist_ok=True)

    def _path(self, i):
        return self.dir / f"slot.{i:02d}"

    def occupancy(self):
        """How many slots JOBS are holding, or None when /proc/locks is unreadable.

        Slots this controller holds are excluded by INDEX rather than by
        inspecting holder pids: the controller knows exactly which files its own
        fds are on, and flock is exclusive, so a locked slot that is not in
        self.held is by definition a job's. That is both cheaper and more exact
        than reading /proc/<pid>/cmdline for every holder.

        None is fail-open, not zero: an unreadable /proc/locks disables the burst
        gate entirely rather than reporting an idle machine and opening the
        floodgates on a busy one.
        """
        locked = locked_inodes()
        if locked is None:
            return None
        n = 0
        for i in range(self.max_slots):
            if i in self.held:
                continue
            try:
                st = self._path(i).stat()
            except OSError:
                continue
            if (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino) in locked:
                n += 1
        return n

    def reconcile(self, target):
        """Hold back slots until exactly `target` remain available, and report it.

        `target` is a COUNT, not an index boundary, and that distinction is
        load-bearing. The previous form held the fixed range [target, max) and
        released everything below it, which silently leaked capacity whenever a
        job held a slot ABOVE the boundary: the controller could not take that
        slot, so one extra slot stayed free for every such job. Harmless when
        capacity only moved on the minute-scale AIMD; not harmless now that
        `target` tracks occupancy tick by tick, because a job that acquired a
        high slot during a burst would widen the burst window it was admitted by.
        Counting cannot drift this way -- it keeps descending until it has enough.

        The controller still prefers the TOP of the index space and jobs still
        scan from the BOTTOM, so in the common case the two never contend. That
        is now only an optimisation, though, rather than something correctness
        rests on.

        Returns the capacity actually in effect, which can be HIGHER than
        `target` when running jobs still occupy slots the controller wants -- it
        takes them as they are returned, which is what makes tightening graceful
        rather than preemptive.
        """
        want_held = max(0, min(self.max_slots, self.max_slots - target))

        # Give back from the BOTTOM of our holdings, so what we keep stays a
        # suffix and jobs scanning upward keep meeting free files first.
        for i in sorted(self.held):
            if len(self.held) <= want_held:
                break
            try:
                self.held.pop(i).close()
            except OSError:
                self.held.pop(i, None)

        for i in range(self.max_slots - 1, -1, -1):
            if len(self.held) >= want_held:
                break
            if i in self.held:
                continue
            try:
                fh = open(self._path(i), "w")
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.held[i] = fh
            except OSError:
                # Slot busy: a job holds it. Try again next tick.
                try:
                    fh.close()
                except (OSError, UnboundLocalError, NameError):
                    pass

        return self.max_slots - len(self.held)

    def publish(self, allowed, effective, occupied=None, target=None, mark=None):
        # Field 0 stays `allowed` and field 2 stays `max_slots`: the i3status
        # block reads field 0 positionally. New fields are appended, never
        # inserted, so an older reader keeps working across a partial deploy.
        try:
            occ = "-" if occupied is None else str(occupied)
            tgt = "-" if target is None else str(target)
            mk = "-" if mark is None else str(mark)
            tmp = self.dir / "allowed.tmp"
            tmp.write_text(
                f"{allowed} {effective} {self.max_slots} {occ} {tgt} {mk}\n"
            )
            tmp.replace(self.dir / "allowed")
        except OSError:
            pass

    def release_all(self):
        for i in list(self.held):
            try:
                self.held.pop(i).close()
            except OSError:
                self.held.pop(i, None)


def main():
    sem = Semaphore(SEM_DIR, CFG["max_slots"])
    # START CONSERVATIVE AND EARN THE REST. Initialising to `ceil` asserts that
    # maximum concurrency is safe having measured precisely nothing -- the same
    # unearned credit the idle ratchet was accruing, just banked at startup
    # instead. It is not a hypothetical: this service restarts on every
    # `nixos-rebuild switch`, and the run at 14:33 on 2026-08-04 restarted into
    # allowed=12 and was pinned at 100% of memory.high seventy seconds later.
    # soft_floor is the same value the predictive signal is trusted to reach on
    # its own, which makes it the natural "no evidence either way" position.
    allowed = max(CFG["floor"], min(CFG["soft_floor"], CFG["ceil"]))
    last_up = 0.0
    # THE HIGH-WATER MARK: the highest concurrency this box has held while the
    # load test was passing. Admissions up to it are replacements and cost
    # nothing; going above it is growth and has to be earned. Starts at zero, so
    # a fresh controller has demonstrated nothing and climbs from the floor.
    mark = 0
    last_growth = 0.0
    stop = {"now": False}

    def _term(_sig, _frm):
        stop["now"] = True

    signal.signal(signal.SIGTERM, _term)
    signal.signal(signal.SIGINT, _term)

    # Every tunable that shapes a decision is logged at START, so any later
    # TIGHTEN/LOOSEN line in this file can be interpreted without having to know
    # which build of the script produced it.
    log(
        f"START dir={SEM_DIR} pool={POOL} max={CFG['max_slots']} "
        f"ceil={CFG['ceil']} floor={CFG['floor']} soft_floor={CFG['soft_floor']} "
        f"tighten>{CFG['tighten_psi']}% high>{CFG['tighten_high_frac'] * 100:.0f}% "
        f"loosen<{CFG['loosen_psi']}% step-{CFG['step_down']}/+{CFG['step_up']} "
        f"dwell={CFG['dwell']}s interval={CFG['interval']}s "
        f"grow+{CFG['grow_step']} every>={CFG['grant_every']}s free<={CFG['burst']} "
        f"needs {CFG['grant_headroom_jobs']}x{CFG['job_bytes'] / 2**30:.1f}G free "
        f"and psi10<={CFG['grant_psi']}% start={allowed}"
    )

    prev_effective = None
    last_hold_log = 0.0
    try:
        while not stop["now"]:
            psi10 = read_psi(POOL, "full", "avg10")
            psi60 = read_psi(POOL, "full", "avg60")
            pool_mem = read_pool_mem(POOL)
            high_frac = None if pool_mem is None else pool_mem[0] / pool_mem[1]

            before = allowed
            reason = None

            occupied = sem.occupancy()

            tick = time.monotonic()

            # THE LOAD TEST. `allowed` counts slots; this counts bytes and
            # stalls, which are what actually run out. Both halves must hold,
            # and both are about the box's ability to absorb ONE MORE heavy job:
            # memory says there is room for it with slack to spare, PSI says
            # nothing is already struggling with what is resident.
            #
            # This deliberately reaches further than the predictive tighten,
            # which the header notes may only drive to soft_floor because the
            # pool contains tenants that take no slots and will not give memory
            # back. The test does not have that problem, for two reasons: it
            # withholds only NEW admissions rather than forcing the running set
            # down, and it cannot deadlock, because the occupied == 0 rule below
            # always leaves a slot free when no build is running at all. A pool
            # held near its ceiling by the agents fleet delays the next build; it
            # can never stop builds happening.
            need = CFG["grant_headroom_jobs"] * CFG["job_bytes"]
            headroom = None if pool_mem is None else pool_mem[1] - pool_mem[0]
            # Unreadable memory is NO SIGNAL, not a refusal: a pool with
            # memory.high unset would otherwise serialise every build forever.
            mem_ok = headroom is None or headroom >= need
            psi_ok = psi10 is None or psi10 <= CFG["grant_psi"]
            healthy = mem_ok and psi_ok

            # Move the mark. Upward only on evidence -- occupancy that was
            # actually reached while the load test passed -- and downward
            # whenever the test fails, so a level the box can no longer sustain
            # stops being treated as demonstrated. Growth restarts the spacing
            # clock; replacements do not touch it, which is the entire point:
            # under steady churn the mark is hit constantly, and a clock reset on
            # every admission would freeze concurrency at whatever level
            # happened to be reached first.
            if occupied is not None:
                if not healthy:
                    mark = min(mark, occupied)
                elif occupied > mark:
                    mark = occupied
                    last_growth = tick

            grow = (
                healthy
                and occupied is not None
                and occupied >= mark
                and (tick - last_growth) >= CFG["grant_every"]
            )

            # How many jobs the CURRENT headroom can absorb, keeping one job's
            # worth of slack in hand. This is what bounds a replacement batch:
            # when a build phase ends, five jobs can finish within one interval
            # and the mark alone would offer all five slots back at once. Five
            # simultaneous admissions need five jobs' worth of memory, but the
            # load test above only ever checked for two -- so the batch, not the
            # test, would decide how far the pool overshot. Sizing the offer to
            # the headroom keeps admission honest at any batch size: roomy pool,
            # several may restart together; tight pool, strictly one at a time.
            absorbable = (
                None
                if headroom is None
                else max(0, int(headroom // CFG["job_bytes"]) - 1)
            )

            def admit_target(cap, _occ=occupied, _mark=mark, _grow=grow):
                """Slots to offer, given a capacity ceiling of `cap`."""
                if _occ is None:
                    # No occupancy signal: fail open to pre-gate behaviour rather
                    # than guessing. `allowed` alone still bounds things.
                    return cap
                if not healthy:
                    # Offer nothing new; the running set drains and the mark
                    # follows it down.
                    t = min(cap, _occ)
                else:
                    t = min(cap, _mark + (CFG["grow_step"] if _grow else 0))
                # THE FREE-SLOT CAP, and the reason it is a separate term from
                # everything above it. Each clause so far answers "how high may
                # concurrency go" -- the cap, the mark, the load test. None of
                # them answers "how many may start in the same instant", and on
                # a DRAINING box the two diverge completely: occupancy falls to
                # 1 while the mark still remembers 8, so the window the mark
                # leaves open is seven wide at precisely the moment the loop has
                # the least evidence about what is coming next.
                #
                # Clamping to `occupied + burst` makes availability track the
                # running set instead of the peak. It costs nothing in steady
                # state -- a finished job drops occupancy and the target with
                # it, so the free pool stays pinned at `burst` rather than
                # growing, and a waiting job still starts immediately.
                t = min(t, _occ + CFG["burst"])
                if absorbable is not None:
                    t = min(t, _occ + absorbable)
                # Never gate the machine to a standstill. With nothing running,
                # at least one job must be able to start or the build system
                # makes no progress at all -- and every caller would then sit out
                # its timeout and run UNGATED, which is strictly worse than
                # admitting one job. Same reasoning as floor being 1, not 0.
                if _occ == 0:
                    t = max(t, CFG["floor"])
                return t

            # Is `allowed` ITSELF the binding constraint? That is the only
            # question a loosen has any business answering, and the test must be
            # against `allowed` rather than against the target in effect. The
            # weaker test (occupied >= target) is satisfied on EVERY tick that
            # withholds a grant -- target is `occupied` exactly then, so it reads
            # as "saturated" and would grow the cap on the strength of the load
            # test refusing, or merely of the spacing clock running. Requiring
            # the cap to be genuinely full keeps the ratchet answering to demand
            # alone.
            cap_saturated = occupied is None or occupied >= allowed

            hot_psi = psi10 is not None and psi10 > CFG["tighten_psi"]
            hot_high = (
                high_frac is not None and high_frac > CFG["tighten_high_frac"]
            )

            if hot_psi or hot_high:
                # The predictive signal alone may not drive to the absolute
                # floor. WHY: memory.current is the WHOLE pool, but this
                # controller only governs the part that takes slots. The agents
                # fleet, its MCP servers and any resident browser sit in the
                # same pool and ask for nothing -- measured at 2-3 GB of a
                # 9-16 GB pool. If those tenants alone hold the pool above
                # tighten_high_frac (and the baseline says the pool exceeds 14G,
                # 87.5% of high, 28% of the time) then a high-frac-only rule
                # would floor the semaphore permanently, serialising every build
                # to reclaim memory that was never the builds' to give back.
                #
                # So high-frac is treated as what it is -- an EARLY WARNING that
                # buys a head start on a burst -- and is allowed to take capacity
                # down only to soft_floor. Reaching the true floor requires
                # psi10, i.e. evidence that something is actually stalling. That
                # keeps the aggressive state reserved for demonstrated harm
                # rather than for a threshold this box crosses routinely.
                limit = CFG["floor"] if hot_psi else max(CFG["floor"], CFG["soft_floor"])
                # The outer min() is load-bearing: a tighten must NEVER raise
                # capacity. Without it, `max(limit, allowed - step_down)` reads
                # max(4, -1) = 4 once PSI has already driven allowed to 1, so a
                # subsequent predictive-only tick RAISES 1 -> 4 -- a loosen
                # wearing a TIGHTEN label, and one that skips the dwell guard
                # entirely. Observed live 2026-08-03 14:23 as a 1->4->2->1 ring,
                # which is precisely the oscillation the fast-tighten/slow-loosen
                # asymmetry exists to prevent. Loosening has exactly one route
                # out of this function: the LOOSEN branch below, gated on the
                # long PSI window and on dwell.
                allowed = min(allowed, max(limit, allowed - CFG["step_down"]))
                bits = []
                if hot_psi:
                    bits.append(f"psi10={psi10:.1f}%")
                if hot_high:
                    bits.append(f"high={high_frac * 100:.0f}%")
                if not hot_psi:
                    bits.append(f"[predictive, soft floor {limit}]")
                reason = "TIGHTEN " + " ".join(bits)
            elif (
                psi60 is not None
                and psi60 < CFG["loosen_psi"]
                # Only grow capacity that is actually being USED. A quiet PSI on
                # an idle box is not evidence that a larger `allowed` is safe --
                # it is the absence of evidence, measured on a machine doing
                # nothing. Without this the ratchet accrues capacity it never
                # earned: observed 2026-08-04 as four consecutive LOOSEN lines on
                # psi60=0.0% taking allowed 5 -> 9 across an idle four minutes,
                # followed 10 s later by the burst that walked it back 9 -> 1 and
                # pinned the pool at 100% of memory.high. Same reason TCP does
                # not grow cwnd while the sender is idle.
                and cap_saturated
                and allowed < CFG["ceil"]
                and (time.monotonic() - last_up) >= CFG["dwell"]
            ):
                allowed = min(CFG["ceil"], allowed + CFG["step_up"])
                last_up = time.monotonic()
                reason = f"LOOSEN psi60={psi60:.1f}%"

            target = admit_target(allowed)
            effective = sem.reconcile(target)
            sem.publish(allowed, effective, occupied, target, mark)

            if reason and allowed != before:
                log(
                    f"{reason} allowed {before} -> {allowed} "
                    f"(occupied {occupied} mark {mark} target {target} "
                    f"effective {effective})"
                )
            elif (
                # Only a grant withheld on LOAD is worth a line. Withholding on
                # spacing is the ordinary rhythm of the thing -- true of most
                # ticks between admissions -- and logging it would bury the
                # decisions under its own metronome. `target < allowed` keeps
                # quiet when the cap is the real constraint, since the TIGHTEN
                # lines already tell that story.
                not healthy
                and target < allowed
                and occupied is not None
                and (tick - last_hold_log) >= CFG["hold_log_every"]
            ):
                bits = []
                if not mem_ok:
                    bits.append(
                        f"free={headroom / 2**30:.1f}G<{need / 2**30:.1f}G"
                    )
                if not psi_ok:
                    bits.append(f"psi10={psi10:.1f}%")
                log(
                    f"HOLD {' '.join(bits)} occupied={occupied} allowed={allowed}"
                )
                last_hold_log = tick
            elif effective != prev_effective and reason is None and target >= allowed:
                # Capacity moved without a decision: jobs returned slots the
                # controller had been waiting to take. Worth seeing, since it is
                # how a tighten actually lands. Suppressed while the burst gate
                # is what is moving `effective`, since that tracks occupancy by
                # design and would otherwise log on every admission.
                log(f"SETTLE allowed={allowed} effective={effective}")
            prev_effective = effective

            time.sleep(CFG["interval"])
    finally:
        sem.release_all()
        sem.publish(CFG["max_slots"], CFG["max_slots"])
        log("STOP released all slots (capacity restored to maximum)")


if __name__ == "__main__":
    main()
