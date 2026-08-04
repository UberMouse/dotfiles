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
#      Fix: cap the number of slots standing FREE, not just the number in use.
#      Availability becomes `grant_base + burst`, replenished on its own clock,
#      so capacity is handed out at a bounded RATE rather than all at once. The
#      step becomes a ramp, and a ramp is something a lagged loop can close on.
#      Capacity still reaches `allowed` under sustained demand; it just has to
#      climb there, and can be stopped part-way.
#
#      The grant clock is separate from the control interval for a reason worth
#      keeping: psi10 is a TEN-SECOND average, so granting every 5 s tick admits
#      the second and third pair against a signal that cannot yet contain any
#      evidence of the first. A ramp that outruns its own feedback is just a
#      slower step. Granting every 15 s makes each grant fully visible before
#      the next is released.
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
# The MEMORY GATE is the third leg, and the only one measured in the unit that
# actually runs out. Slots are a proxy for memory; when the pool has less than
# one job's worth of room left to memory.high, the proxy is simply wrong, and
# the gate closes the burst window regardless of what the slot arithmetic or PSI
# says. It cannot deadlock -- with nothing running, one slot is always free (see
# FLOOR) -- so a pool held near its ceiling by tenants that take no slots delays
# the next build without ever preventing builds.
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
    # How many slots may stand FREE at once -- the burst budget. See "WHY
    # CAPACITY IS NOT THE SAME AS AVAILABILITY" in the header. 2 admits at most
    # two new heavy jobs per interval, turning an idle-to-saturated step into a
    # ~5 s-per-pair ramp that the lagged feedback can actually close on.
    burst=_int("KX_SEM_BURST", 2),
    # How often the burst window is REPLENISHED, as distinct from how often the
    # loop ticks. Decoupled deliberately: at one grant per 5 s tick the ramp
    # reaches seven concurrent jobs in under twenty seconds, but psi10 is a
    # TEN-SECOND average, so the second, third and fourth pair are all admitted
    # against a signal that cannot yet contain any evidence of the first. The
    # ramp outruns the only thing able to stop it. 15 s guarantees each grant is
    # fully visible in psi10 before the next one is released -- the loop still
    # ticks at `interval` and can still TIGHTEN at any moment, it just cannot
    # hand out more concurrency until the last handful has been accounted for.
    grant_every=_float("KX_SEM_GRANT_EVERY", 15.0),
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

    def publish(self, allowed, effective, occupied=None, target=None):
        # Field 0 stays `allowed` and field 2 stays `max_slots`: the i3status
        # block reads field 0 positionally. New fields are appended, never
        # inserted, so an older reader keeps working across a partial deploy.
        try:
            occ = "-" if occupied is None else str(occupied)
            tgt = "-" if target is None else str(target)
            tmp = self.dir / "allowed.tmp"
            tmp.write_text(f"{allowed} {effective} {self.max_slots} {occ} {tgt}\n")
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
    # The burst window: `grant_base` is occupancy as of the last replenishment,
    # so admissions between grants are bounded by burst rather than by how fast
    # jobs happen to arrive.
    grant_base = 0
    last_grant = 0.0
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
        f"burst={CFG['burst']}/{CFG['grant_every']}s "
        f"job={CFG['job_bytes'] / 2**30:.1f}G start={allowed}"
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

            # The MEMORY GATE. `allowed` counts slots; this counts bytes, and
            # bytes are what actually run out. If the pool has less than one
            # job's worth of room left to memory.high, admitting another job is
            # how the box earns an OOM kill, whatever the slot arithmetic says.
            #
            # This deliberately reaches further than the predictive tighten,
            # which the header notes may only drive to soft_floor because the
            # pool contains tenants that take no slots and will not give memory
            # back. The gate does not have that problem, for two reasons: it
            # stops only NEW admissions rather than forcing the running set down
            # to one, and it cannot deadlock, because the occupied == 0 rule
            # below always leaves a slot free when no build is running at all.
            # So a pool held near its ceiling by the agents fleet delays the next
            # build; it can never stop builds happening.
            burst = CFG["burst"]
            mem_gated = False
            if pool_mem is not None:
                room = (pool_mem[1] - pool_mem[0]) // CFG["job_bytes"]
                if room < burst:
                    burst = max(0, int(room))
                    mem_gated = True

            # Replenish the burst window on its own clock. Re-basing on CURRENT
            # occupancy rather than adding to the old base is what keeps this a
            # window and not a leaky accumulator: unused grants expire instead of
            # piling up into exactly the batch admission this exists to prevent.
            tick = time.monotonic()
            if occupied is not None and (tick - last_grant) >= CFG["grant_every"]:
                grant_base = occupied
                last_grant = tick

            def admit_target(cap, _occ=occupied, _burst=burst, _base=grant_base):
                """Slots to leave free, given a capacity ceiling of `cap`.

                Measured from `grant_base`, not from live occupancy, so that a
                job finishing frees a slot for a REPLACEMENT immediately (which
                does not raise concurrency) while additional concurrency waits
                for the next grant (which does).
                """
                if _occ is None:
                    # No occupancy signal: fail open to pre-burst-gate behaviour
                    # rather than guessing. `allowed` alone still bounds things.
                    return cap
                t = min(cap, _base + _burst)
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
            # weaker test (occupied >= target) is satisfied whenever the MEMORY
            # GATE is what is holding admission back -- allowed=8, occupied=3,
            # burst=0 gives target=3, which reads as "saturated" and grows the
            # cap to 9 on the strength of a constraint that has nothing to do
            # with slots. Requiring the cap to be genuinely full keeps the
            # ratchet answering to demand alone.
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
            sem.publish(allowed, effective, occupied, target)

            now = time.monotonic()
            if reason and allowed != before:
                log(
                    f"{reason} allowed {before} -> {allowed} "
                    f"(occupied {occupied} target {target} effective {effective})"
                )
            elif (
                target < allowed
                # Every slot on offer is taken, so the capacity being held back
                # is capacity something is waiting for. This is a DIFFERENT test
                # from the one guarding LOOSEN above, deliberately: that one asks
                # whether `allowed` is full (it never is while the gate binds),
                # this one asks whether what was actually offered is. Without the
                # distinction, `target < allowed` alone is true on every tick of
                # an idle box -- the gate working as designed, with nothing
                # waiting on it -- and logging that twice a minute forever says
                # nothing at all.
                and occupied is not None
                and occupied >= target
                and (now - last_hold_log) >= CFG["hold_log_every"]
            ):
                # The gate is biting: capacity exists but is not being handed out
                # this instant. Throttled, because on a busy stretch this is true
                # of most ticks and one line per tick would bury the decisions.
                why = "burst" if not mem_gated else f"mem free={(pool_mem[1] - pool_mem[0]) / 2**30:.1f}G"
                log(
                    f"HOLD {why} occupied={occupied} target={target} "
                    f"allowed={allowed} burst={burst}"
                )
                last_hold_log = now
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
