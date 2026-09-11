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

import collections
import dataclasses
import errno
import fcntl
import importlib.util
import os
import signal
import sys
import time
from pathlib import Path


def _load_cgroup_mem():
    """Load THE page-cache correction (scripts/cgroup-mem.py).

    By path, not by name: this script ships to the store as a lone file, so
    there is no importable sibling. The unit passes KX_CGROUP_MEM_LIB; the
    default is the repo checkout, which is what the test suite loads.

    A missing lib is FATAL rather than a silent fallback to the raw charge.
    Falling back would restore the very misreading the module exists to fix --
    a semaphore refusing builds at 0.00% pressure -- while every log line kept
    claiming health, which is the failure shape this repo keeps getting bitten
    by. Better to not start.
    """
    path = os.environ.get(
        "KX_CGROUP_MEM_LIB", str(Path(__file__).resolve().parent / "cgroup-mem.py")
    )
    spec = importlib.util.spec_from_file_location("kx_cgroup_mem", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"build-semaphore-controller: cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


cgmem = _load_cgroup_mem()

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

# The graphical session scope, for the DESKTOP term of the self-inflicted test.
# Overridable exactly like POOL so the policy can be exercised against a
# synthetic memory.pressure; when the override is set it is used verbatim,
# with no resolution.
DESKTOP_OVERRIDE = os.environ.get("KX_SEM_DESKTOP")
USER_SLICE = Path(f"/sys/fs/cgroup/user.slice/user-{UID}.slice")

# Resolution is deliberately PURE FILESYSTEM -- no loginctl subprocess in a 5 s
# control loop. cgroup-lib.sh's resolve_desktop() prefers loginctl and falls
# back to "the session-*.scope with the most PIDs is the graphical one";
# this keeps only the fallback, because the cost of getting it wrong here is
# bounded in the safe direction. An unresolved or misresolved desktop yields
# no PSI signal, and no signal means NOT self-inflicted (see decide()), which
# leaves the full floor available -- tighten early, never late, the same
# direction every other fallback in this file takes.
_desktop_cache = None


def resolve_desktop():
    """Path to the graphical session scope, or None when it cannot be found.

    Re-resolves whenever the cached path stops being readable, so a session
    that dies and comes back (a display-manager restart takes the scope with
    it) is picked up without restarting the controller.
    """
    global _desktop_cache
    if DESKTOP_OVERRIDE:
        return Path(DESKTOP_OVERRIDE)
    if _desktop_cache is not None and (_desktop_cache / "memory.pressure").is_file():
        return _desktop_cache
    _desktop_cache = None
    best, best_n = None, 0
    try:
        candidates = sorted(USER_SLICE.glob("session-*.scope"))
    except OSError:
        return None
    for d in candidates:
        if not (d / "memory.pressure").is_file():
            continue
        try:
            n = len((d / "cgroup.procs").read_text().split())
        except OSError:
            continue
        if n > best_n:
            best, best_n = d, n
    _desktop_cache = best
    return best


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


# The tunables, as a FROZEN DATACLASS rather than a dict: a typo'd key is an
# eval-time AttributeError with a name in it, not a runtime KeyError inside
# the control loop of a service that restarts every 10 s -- and the test
# suite constructs Config() with only the overrides it cares about instead of
# hand-maintaining a parallel dict that breaks on every new knob.
@dataclasses.dataclass(frozen=True)
class Config:
    # Total slot files created. The ceiling can never exceed this.
    max_slots: int = 16
    # Never admit more than this many heavy jobs at once, however calm the box
    # looks. Originally 12, to match the pool's CPUQuota=1200% -- but cores were
    # never the binding resource here. Sizing by the one that is:
    #
    #     (pool memory.high - untracked tenants) / job_bytes
    #
    # (memory.high itself is read live each tick -- see read_pool_mem -- so the
    # numbers here are the sizing rationale, not runtime inputs). Sized 8 on
    # 2026-08-04 against the then-16G high with ~3G of slot-less tenants and
    # ~1.5G per heft, and the measurement agreed: the box reached 100% of
    # memory.high and psi10=48% at SEVEN concurrent, four short of the nominal
    # ceiling. A cap the machine cannot reach without stalling is not a cap, it
    # is decoration.
    #
    # IN PRODUCTION THIS IS DERIVED, NOT THIS DEFAULT: cgroups.nix computes
    # KX_SEM_CEIL from memory-policy.nix's poolHighG with the formula above,
    # so a pool re-size moves the ceiling automatically (the hand-set 8 was
    # still sized for 16G two days after the pool moved to 18G). This default
    # only covers runs outside the systemd unit.
    ceil: int = 8
    # Never admit fewer than this. 1, not 0 -- see FLOOR note above.
    floor: int = 1
    # The lowest capacity the PREDICTIVE (memory.high fraction) signal may reach
    # on its own. Only measured stalling (PSI) may go below this, down to floor.
    # See the tightening branch for why the two signals are not equivalent.
    soft_floor: int = 4
    # Control interval.
    interval: float = 5.0
    # Tighten when the pool's SHORT-window memory stall exceeds this. The
    # measured p90 is 16.6% and median is 0.0%, so 15% fires on the bursts we
    # care about and stays silent through the calm 90%.
    tighten_psi: float = 15.0
    # Loosen only when the LONG window is this quiet. Well below tighten_psi so
    # the two thresholds cannot chatter against each other.
    loosen_psi: float = 3.0
    # Predictive tighten: also tighten when the pool is this close to its
    # memory.high, before PSI has had time to register. Reclaim latency is the
    # symptom; approaching the ceiling is the cause, and it is visible earlier.
    tighten_high_frac: float = 0.90
    # SELF-INFLICTED STALL DETECTION, part one: how many jobs' worth of NET
    # headroom the pool must hold before a PSI spike is read as its own cache
    # reclaim rather than as scarcity. Deliberately well above
    # grant_headroom_jobs, which asks "is there room for one more"; this asks
    # the stronger question "is there so much room that a stall cannot
    # plausibly be about builds at all". See the self-inflicted note in
    # decide().
    self_inflicted_headroom_jobs: float = 4.0
    # Part one, ALTERNATE ROUTE (2026-09-11): the share of the THROTTLED CHARGE
    # that builds hold. The headroom bar above is a proxy, and it decays as the
    # fleet grows -- at a 7.17G fleet in a 15G pool, net headroom clears 6G only
    # while the pool is under 60% net-full, so the exemption was least available
    # exactly when the fleet was largest. Measured 2026-09-11: three consecutive
    # tightens took allowed 6 -> 4 -> 2 -> 1 UNTAGGED on headroom of 4.02G,
    # while the raw charge sat at 99.2% of high pinned there by 3.90G of the
    # pool's own cache, and BUILDS held 3.81G of that 14.88G charge -- 25.6%.
    # Tightening cannot remove the other three quarters, so the stall was not
    # the builds' to relieve.
    #
    # 0.35 is the minority bar. Unlike an absolute byte count it is
    # fleet-size-adaptive -- "a minority tenant cannot be blamed for the
    # ceiling" stays true at any fleet size -- and it needs BOTH the fleet and
    # cache reads, so a missing either leaves the old headroom-only behaviour.
    self_inflicted_build_share: float = 0.35
    # Part two: the MACHINE's own slack. Both halves must hold -- the
    # pool-local term alone would ignore genuine scarcity on a globally
    # starved box, where global reclaim lands on the pool and the resulting
    # PSI is emphatically not ours to dismiss. 4 GiB is the point below which
    # there is no room outside the pool for its cache to have lived anyway.
    self_inflicted_avail: int = 4 * 1024**3
    # Part three: the DESKTOP must actually be quiet. The 2026-08-27 evidence
    # that justified this whole test cited "desktop session at 0.00% pressure"
    # as one of its conditions, but that observation was never encoded -- so
    # the exemption went on firing once the premise expired. Measured
    # 2026-09-04, with the pool at 17% cache (August: 40-52%) and the stalls
    # therefore GENUINE: the LOOSEN exemption fired on 42 of 112 loosens at
    # psi60 up to 44.3% against a 3.0% gate (9 of 61 tightens were softened to
    # soft_floor), while session-2.scope stalled at 33-48% and the pressure
    # monitor logged TWELVE desktop stalls -- the most since the pre-tuning era.
    # The loosen half is the one with teeth: a softened tighten still tightens,
    # an exempted loosen re-opens admission. Caught live at 15:43 -- tighten to
    # allowed=1 at psi10=45.2%, then fifteen seconds later an exempted loosen
    # back to 2 at psi60=26.1%, with a 32.39% desktop stall logged between them.
    #
    # 5% sits well above idle noise and well below the pressure monitor's own
    # 15% stall threshold, so the exemption withdraws BEFORE the desktop
    # crosses into what that monitor is willing to call a stall.
    #
    # This is the term the MemAvailable one cannot supply. MemAvailable counts
    # reclaimable page cache, and reclaiming that cache IS the desktop's stall:
    # at 12:04 today the desktop sat at 47.96% memory PSI with 6.5 GiB
    # "available", comfortably past the 4 GiB gate. Only the desktop's own PSI
    # distinguishes "our ceiling is squeezing our own cache" from "the squeeze
    # has reached the thing all of this exists to protect".
    desktop_quiet_psi: float = 5.0
    # THE FUTILITY BRAKE. `allowed` is a CAP, so cutting it removes nothing until
    # the running set drains -- which makes psi10 holding STEADY after a tighten
    # the lever's LATENCY, and emphatically not grounds for a brake. psi10
    # CLIMBING across consecutive tightens is the other thing: measured
    # 2026-09-11, psi10 went 37.0 -> 47.3 -> 51.6 while allowed was cut
    # 6 -> 4 -> 2 -> 1, three steps each making the measurement worse, ending in
    # a serialised pool that relieved nothing. So require a RISE of at least
    # futile_psi_rise ABOVE WHERE THE RUN OF TIGHTENS BEGAN to count a tighten
    # against the lever, and clamp at soft_floor once futile_tightens of them
    # run consecutively. Measuring against the run's origin rather than the
    # previous tick is load-bearing -- see the note at the brake itself.
    #
    # This is the backstop that needs no threshold to be RIGHT: where the
    # self-inflicted test reasons about whether a stall is the builds' to
    # relieve, this one observes whether tightening is in fact relieving it. It
    # CLAMPS at the soft floor rather than lifting the floor, so a misfire still
    # tightens; and since a genuine episode relieves as builds drain, psi falls,
    # the streak resets, and the true floor stays reachable.
    futile_psi_rise: float = 5.0
    futile_tightens: int = 2
    # Slots surrendered per tightening tick (multiplicative-ish decrease).
    step_down: int = 2
    # Slots regained per loosening tick (additive increase).
    step_up: int = 1
    # Minimum seconds between two increases. This is the anti-ring guard: it
    # must comfortably exceed how long an in-flight heft keeps its pages after
    # admission stops, or the loop re-opens into memory that has not drained.
    dwell: float = 60.0
    # How far the high-water mark may move in one step -- the GROWTH quantum.
    # One: concurrency climbs to a level it has never held one job at a time,
    # and each step has to pass the load test below.
    #
    # Renamed from KX_SEM_FREE_SLOTS, which is what this knob genuinely was
    # before the mark existed and was actively misleading afterwards -- it
    # bounds how fast the CEILING may rise, not how many slots stand free. Two
    # different quantities behind one name is how the cap below came to be
    # deleted by a commit that believed it was merely rewording it.
    grow_step: int = 1
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
    burst: int = 2
    # Minimum seconds between one GROWTH step and the next. Replacements are not
    # subject to this (see the high-water mark note in the header) -- only moves
    # to a concurrency level the box has not yet demonstrated. psi10 is a
    # TEN-SECOND average, so a level raised five seconds after the last one is
    # judged against a signal that cannot yet contain any evidence of it. 15 s
    # guarantees each step is fully visible before the next is considered.
    grant_every: float = 15.0
    # THE LOAD TEST, part one: how many jobs' worth of memory must remain free
    # before another slot is opened. TWO, not one, and the difference is the
    # whole point -- at one, the admitted job is allowed to consume the last of
    # the headroom, which is precisely how the pool reached 100% of memory.high
    # at six concurrent on 2026-08-04. Requiring slack beyond the incoming job
    # means admission stops one job EARLIER than the wall.
    grant_headroom_jobs: float = 2.0
    # THE LOAD TEST, part two: nothing may be stalling. Memory headroom says
    # there is room; this says the box is not already struggling to use what it
    # has. Both must hold, because they fail independently -- a pool with 4 GB
    # free can still be thrashing on reclaim, and a quiet pool can still be one
    # allocation from the ceiling.
    grant_psi: float = 3.0
    # Assumed peak RSS of one gated job, for the memory gate. 1.5 GiB is the
    # middle of the measured heft typecheck range (0.6-2.3 GB); the largest
    # single observation was 2312 MB. Deliberately not the maximum: sizing the
    # gate to the worst case would hold admission shut through the pool states
    # the median job passes through comfortably.
    job_bytes: int = 1610612736
    # Minimum seconds between two HOLD log lines. The gate engages on most ticks
    # of a busy period and logging each one would bury the decisions.
    hold_log_every: float = 30.0
    # THE RESIDENT CAP: how many slots resident-browser keepers may hold
    # before NEW resident admissions are refused. Nothing else bounds
    # residency -- each admitted browser raises the floor by one, so without
    # a cap 16 browsers make every slot keeper-held, every build waits out
    # its full timeout and then runs UNGATED: the gate disabled by the very
    # tenants it exists to account for, on a box that looked healthy at each
    # individual admission. The cap only gates NEW admissions (via the
    # published health bit that resident jobs wait on); accounting for
    # residents already past it stays honest, so the floor still reflects
    # reality. None (the default) derives to what the build ceiling leaves
    # over, so browsers can never squeeze builds below their full ceiling.
    max_resident: int | None = None

    def __post_init__(self):
        # KX_SEM_CEIL arrives DERIVED from Nix (cgroups.nix computes it from
        # memory-policy.nix's poolHighG), and nothing on that side can see
        # max_slots -- so ceil <= max_slots is enforceable only here. Left
        # unclamped, a poolHighG >= 27 derivation would send every consumer
        # of ceil (max_resident below, decide()'s dynamic bounds) reasoning
        # past the last slot file that actually exists. Clamp, and remember
        # the raw value so main() can log the mismatch at START.
        if self.ceil > self.max_slots:
            object.__setattr__(self, "ceil_clamped_from", self.ceil)
            object.__setattr__(self, "ceil", self.max_slots)
        if self.max_resident is None:
            object.__setattr__(
                self, "max_resident", max(1, self.max_slots - self.ceil)
            )

    @classmethod
    def from_env(cls):
        """Every field overridable via KX_SEM_<UPPER_NAME>; unset or garbage
        falls back to the field default (garbage-tolerant on purpose: this is
        a systemd service, and a typo'd Environment= line must degrade to
        defaults, not crash-loop)."""
        kwargs = {}
        for f in dataclasses.fields(cls):
            env = f"KX_SEM_{f.name.upper()}"
            if env not in os.environ:
                continue
            # f.type is the evaluated annotation OBJECT here (this module has
            # no `from __future__ import annotations`), so it must be compared
            # against the class, not the string "float" -- the string form
            # silently routed every float tunable through _int, which treats
            # any fractional value ("0.2", "90.5") as garbage and returns the
            # default. Both forms accepted so a future annotations-import
            # cannot quietly reintroduce the inverse bug.
            conv = _float if f.type in (float, "float") else _int
            kwargs[f.name] = conv(env, f.default)
        return cls(**kwargs)


CFG = Config.from_env()


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


def read_psi(path, field="full"):
    """(avg10, avg60) PSI percentages, or (None, None) when unreadable.

    None means "no signal" and is treated as calm -- the pool cgroup simply may
    not exist yet (it materialises on the first heavy command), and a missing
    pool must not be read as a stalled one.

    Both windows come from ONE pass over one read, for the same reason
    read_pool_mem reads its pair together: the two decisions made from them
    should see a single consistent sample (and the old shape parsed the whole
    file twice per tick for no reason).
    """
    avg10 = avg60 = None
    try:
        for line in (path / "memory.pressure").read_text().splitlines():
            parts = line.split()
            if parts and parts[0] == field:
                for p in parts[1:]:
                    k, _, v = p.partition("=")
                    if k == "avg10":
                        avg10 = float(v)
                    elif k == "avg60":
                        avg60 = float(v)
                break
    except (OSError, ValueError):
        return (None, None)
    return (avg10, avg60)


def read_pool_mem(path):
    """(current, high, cache) bytes for the pool, or None when unavailable.

    THE THIRD ELEMENT NEVER REACHES decide(). main() splits it off and passes
    (current, high) as `pool_mem`, because decide() UNPACKS that value --
    `pool_cur, pool_high = pool_mem` -- and the policy suite constructs it as a
    plain 2-tuple. Widening it in place raises ValueError inside the control
    loop, which kills the tick thread while the published state file goes on
    looking plausible; caught here only because the machinery suite asserts on
    startup capacity. Keep `pool_mem` two-wide.

    `cur` is the pool's charge MINUS what the kernel can reclaim on its own --
    see cgroup-mem.py for why the raw `memory.current` is the wrong number for
    every decision below. Briefly: it counts page cache, so a pool half full of
    cold `inactive_file` reads as full, and both signals derived here then fire
    on memory nobody has to give back.

    Both numbers still come from one pass because both signals are derived from
    them: the FRACTION drives the predictive tighten, and the absolute HEADROOM
    drives the memory gate. Reading the pair together keeps the two decisions
    made from a single consistent sample -- and memory.stat is now read in the
    same pass, for the same reason.

    A memory.stat that yields no correction is NO SIGNAL, and falls back to the
    raw charge: that reads the pool as fuller than it is, so the gate tightens
    early rather than late.
    """
    try:
        raw_cur = int((path / "memory.current").read_text().strip())
        raw = (path / "memory.high").read_text().strip()
        if raw == "max":
            return None
        high = int(raw)
        if high <= 0:
            return None
    except (OSError, ValueError):
        return None
    cache = cgmem.reclaimable(cgmem.read_stat(path))
    cur = raw_cur if cache is None else max(0, raw_cur - cache)
    return (cur, high, cache)


# The pool subpath holding tenants that take no slots. Overridable for the
# same reason every other path here is (KX_SEM_POOL points the tests at a
# synthetic tree); an empty value disables the correction entirely.
UNTRACKED_SUBPATH = os.environ.get("KX_SEM_UNTRACKED", "worktrees-agents.slice")


# The memory.stat keys that are genuinely UNRECLAIMABLE without the holder's
# cooperation: anonymous pages (need swap or exit) and tmpfs pages (shmem is
# accounted under `file` in cgroup v2 but is NOT droppable -- it also needs
# swap). Everything else under `file` is page cache the kernel reclaims on its
# own, so it must not be charged against the build budget.
UNTRACKED_KEYS = ("anon", "shmem")


def read_mem_available(path="/proc/meminfo"):
    """MemAvailable bytes for the WHOLE MACHINE, or None for no signal.

    The second half of the self-inflicted-stall test in decide(); the first
    half is pool-local headroom. MemAvailable rather than MemFree because
    reclaimable cache is precisely what is in question here -- MemFree would
    report a box doing healthy file IO as though it were full, which is the
    same misreading of cache this controller already corrects on the pool
    side (see cgroup-mem.py).
    """
    try:
        text = Path(path).read_text()
    except OSError:
        return None
    for line in text.splitlines():
        if line.startswith("MemAvailable:"):
            try:
                return int(line.split()[1]) * 1024
            except (IndexError, ValueError):
                return None
    return None


def read_untracked_mem(path):
    """UNRECLAIMABLE bytes held inside the pool by tenants that TAKE NO SLOTS.

    Today that is the Claude agents fleet: the cc-daemon, its workers, their
    MCP servers and the pty hosts, all re-homed into worktrees-agents.slice by
    claude-agents-reattach. They live in the pool by design -- so their memory
    is budgeted -- but they never call kx-build-slot, so no amount of tightening
    `allowed` persuades them to give a byte back.

    That last sentence is true of ANON, and false of PAGE CACHE, which is why
    this reads memory.stat and not memory.current. Measured 2026-08-19: the
    fleet's memory.current was 12.2G, of which only 4.7G was anon -- 6.7G was
    file cache (5.7G of it inactive). Charging the cache to the fleet made the
    build budget read 1.8G of a 14G pool when the unreclaimable figure left
    9.3G, and the semaphore sat at allowed=1 refusing builds while the desktop
    was at 0.00% pressure. The kernel reclaims that cache without asking the
    fleet for anything, so it is not the fleet's to hold against builds.

    None means "no signal", which restores the pre-2026-08-17 behaviour of
    measuring against the whole pool. That is the safe direction: it reads the
    pool as FULLER than it is, so the predictive tighten fires earlier, never
    later.
    """
    if not UNTRACKED_SUBPATH:
        return None
    try:
        text = (path / UNTRACKED_SUBPATH / "memory.stat").read_text()
    except OSError:
        return None
    total = None
    for line in text.splitlines():
        key, _, val = line.partition(" ")
        if key in UNTRACKED_KEYS:
            try:
                total = int(val) + (total or 0)
            except ValueError:
                return None
    # A memory.stat with no anon key at all is a malformed read, not a fleet
    # using zero bytes -- fall back to "no signal" rather than reporting the
    # pool as emptier than it is.
    return total


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
        # Warn-once sets for the two paths that must never fail silently
        # (reconcile's unlockable-slot case and publish's unwritable state
        # file): membership means "already reported, still broken".
        self._reconcile_warned = set()
        self._publish_warned = False
        self.dir.mkdir(parents=True, exist_ok=True)
        for i in range(max_slots):
            self.dir.joinpath(f"slot.{i:02d}").touch(exist_ok=True)
        # ORPHAN SWEEP (added 2026-08-07): a max_slots decrease leaves the
        # previous run's higher-indexed slot files standing in tmpfs, and
        # kx-build-slot scans ALL slot.* -- an orphan is lockable, uncounted
        # (occupancy() iterates range(max_slots)), ungated capacity. Unlink
        # them, INCLUDING one something is holding right now: flock lives on
        # the open file description, so the holder keeps its lock until it
        # exits, while the file vanishes from every future scan. That is
        # graceful wind-down, not preemption -- the same take-them-as-they-
        # return rule reconcile() applies to tightening.
        for p in self.dir.glob("slot.*"):
            idx = p.name.rpartition(".")[2]
            if idx.isdigit() and int(idx) >= max_slots:
                try:
                    p.unlink()
                except OSError:
                    pass

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

    def resident(self):
        """How many slots are held by resident-browser keepers, not by builds.

        A slot held for a resident browser (see the RESIDENCY note in
        kx-build-slot) is indistinguishable from a build's by looking at the
        lock -- both are just an exclusive flock by something that is not this
        controller. The keeper therefore drops a marker naming itself, and this
        counts the ones whose keeper is still alive.

        THE MARKER IS A HINT, NOT A LEASE. The flock is what actually reserves
        the slot; this only decides how far the FLOOR rises. So every failure
        mode here is a mis-sized floor and never a double-admitted job, which is
        why a stale marker can be pruned inline without any locking protocol: a
        keeper killed with SIGKILL cannot clean up after itself, and a marker
        left behind would otherwise inflate the floor permanently.

        Zero is the safe answer on error, and that direction is deliberate: it
        under-states the floor, which throttles harder than intended. The
        opposite mistake -- an over-stated floor built on markers for keepers
        that are gone -- would grant capacity backed by nothing.
        """
        d = self.dir / "resident"
        n = 0
        try:
            entries = list(d.iterdir())
        except OSError:
            return 0
        for f in entries:
            pid = None
            try:
                for tok in f.read_text().split():
                    if tok.startswith("keeper="):
                        pid = tok.split("=", 1)[1]
            except OSError:
                continue
            if pid and pid.isdigit() and Path(f"/proc/{pid}").exists():
                n += 1
                continue
            try:
                f.unlink()
            except OSError:
                pass
        # A marker per slot is the invariant, so this can never exceed the pool
        # even if something outside this system writes into the directory.
        return min(n, self.max_slots)

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
            fh = None
            try:
                fh = open(self._path(i), "w")
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.held[i] = fh
            except OSError as e:
                # EWOULDBLOCK/EAGAIN is the EXPECTED case: a job holds the
                # slot, try again next tick. Anything else (EACCES, EMFILE,
                # ENOSPC from open()) means the controller can NEVER withhold
                # this slot -- the semaphore has silently degraded toward "no
                # throttling" while the state file keeps publishing whatever
                # `effective` happens to reach. That must not be silent; the
                # log is rate-limited by the warned-set so a persistent
                # condition says so once per slot, not once per tick.
                if e.errno not in (errno.EWOULDBLOCK, errno.EAGAIN):
                    if i not in self._reconcile_warned:
                        self._reconcile_warned.add(i)
                        log(f"RECONCILE|slot {i} unlockable ({e}) - cannot withhold it")
                else:
                    self._reconcile_warned.discard(i)
                # `fh` is None when open() itself failed: nothing to close.
                if fh is not None:
                    try:
                        fh.close()
                    except OSError:
                        pass
            else:
                self._reconcile_warned.discard(i)

        return self.max_slots - len(self.held)

    # THE PUBLISHED STATE FORMAT -- one space-separated line, fields in exactly
    # this order. This tuple is the contract for every reader: kx-build-slot.sh
    # reads "healthy" as field 8 (1-based cut), wt-cgroup-i3status.py reads
    # allowed/effective/resident by 0-based index, and the fast test suite
    # asserts its hand-written state lines against this tuple. New fields are
    # APPENDED, never inserted, so an older reader keeps working across a
    # partial deploy -- which is why `resident` sits at the end despite
    # belonging next to `occupied`.
    FIELDS = (
        "allowed", "effective", "max_slots", "occupied",
        "target", "mark", "resident", "healthy",
    )

    @staticmethod
    def _fmt(v):
        """One published field: None -> the '-' readers fail open on, bools ->
        the 0/1 the shell gate compares against."""
        if v is None:
            return "-"
        if v is True:
            return "1"
        if v is False:
            return "0"
        return str(v)

    def publish(
        self, allowed, effective, occupied=None, target=None, mark=None,
        resident=None, healthy=None,
    ):
        # See FIELDS above for the format contract; the line is BUILT from
        # that tuple, so appending a field is one FIELDS entry + one value
        # here, not a hand-count of f-string positions. Readers wanting BUILD
        # occupancy want occupied - resident.
        #
        # `healthy` is THE LOAD TEST'S VERDICT, published so that jobs which
        # will become RESIDENT can wait for it. A build takes a slot and
        # gives it back; a resident browser takes one and never does, so the
        # floor rises to accommodate it -- which means admitting one opens
        # the door for the next. Measured 2026-08-07: twelve browsers
        # admitted in a row onto a pool at 15.5G of 16G with psi10=40%,
        # because the progress-floor slot is free by construction and nothing
        # marked it build-only. `allowed` had correctly fallen to 1 the whole
        # time; residents were simply not answering to it.
        #
        # Publishing the verdict rather than a resident cap keeps one policy
        # in one place: browsers queue on exactly the memory and PSI evidence
        # that gates builds, and there is no second number to keep in step.
        try:
            values = dict(
                allowed=allowed, effective=effective,
                max_slots=self.max_slots, occupied=occupied, target=target,
                mark=mark, resident=resident, healthy=healthy,
            )
            tmp = self.dir / "allowed.tmp"
            tmp.write_text(
                " ".join(self._fmt(values[f]) for f in self.FIELDS) + "\n"
            )
            tmp.replace(self.dir / "allowed")
            self._publish_warned = False
        except OSError as e:
            # The `allowed` file IS the external contract: every client fails
            # OPEN on a missing/unreadable one. A controller that can no
            # longer publish keeps throttling internally while every job
            # behaves as if the semaphore does not exist -- silently, forever.
            # Warn once per outage rather than once per tick.
            if not self._publish_warned:
                self._publish_warned = True
                log(f"PUBLISH|FAILED to write state file ({e}) - clients now fail open")

    def release_all(self):
        for i in list(self.held):
            try:
                self.held.pop(i).close()
            except OSError:
                self.held.pop(i, None)


# ---------------------------------------------------------------------------
# THE POLICY, separated from the machinery.
#
# decide() below is the entire control law as a PURE function: no I/O, no
# clock of its own (the caller injects `now`), no reads of module globals (the
# caller passes the config dict). main() is thereby reduced to read signals ->
# decide() -> reconcile/publish/log -> sleep, and the fast test suite can
# drive every policy branch with hand-written inputs instead of sleeping a
# real subprocess through real dwell and grant intervals.

# What the policy remembers between ticks. `allowed` is the AIMD capacity;
# `mark` and `last_growth` are the high-water mark and its spacing clock;
# `last_up` is the loosen dwell clock; `was_resident_full` is the edge
# detector behind the RESIDENT-CAP log line.
# `tighten_ref` / `tighten_streak` are the FUTILITY BRAKE's trail: the psi10 the
# last consecutive psi-driven tighten acted on, and how many such tightens have
# run with psi10 RISING. Both are cleared by any tick that does not psi-tighten,
# so the brake only ever reads a consecutive run. Appended with defaults: the
# policy suite constructs State positionally.
State = collections.namedtuple(
    "State",
    "allowed mark last_up last_growth was_resident_full "
    "tighten_ref tighten_streak",
    defaults=(0, 0.0, 0.0, False, None, 0),
)

# One tick's worth of signals, all read by the caller. `now` is a monotonic
# timestamp; `psi10`/`psi60` are PSI percentages or None for "no signal";
# `pool_mem` is (current, high) bytes or None; `occupied` is how many slots
# jobs hold in total (residents included) or None when /proc/locks is
# unreadable; `resident` is the live-keeper count; `untracked` is bytes held
# inside the pool by tenants that take no slots (the agents fleet), or None
# for no signal -- see the BUILD BUDGET note on high_frac in decide().
# `mem_available` is the MACHINE's MemAvailable in bytes (or None), the
# second term of the self-inflicted-stall test in decide(); `desktop_psi10`
# is the graphical session scope's full-avg10 memory PSI (or None), its third.
# Both read no-signal as NOT self-inflicted, so an unreadable input keeps the
# full floor.
# `pool_cache` feeds the BUILD SHARE term of the self-inflicted test (it used to
# be diagnostic only), and separately lets the
# HOLD line say how much reclaimable memory the gate is (correctly) refusing to
# count. It carries a default so the policy suite keeps constructing Inputs
# without it, and so a new field can never silently become load-bearing: any
# branch that started reading it would be reading None in every unit test.
Inputs = collections.namedtuple(
    "Inputs",
    "now psi10 psi60 pool_mem occupied resident untracked pool_cache "
    "mem_available desktop_psi10",
    defaults=(None, None, None),
)

# One capacity transition. `tag` is the branch that fired (TIGHTEN / LOOSEN /
# RECLAIM) as its own FIELD -- it used to be the first token of a free-text
# string, which meant every consumer (the log formatter, the test suite's
# tags()) re-derived the type with .split()[0]. `detail` is the human half of
# the line; `before`/`after` are the allowed-capacity span.
Reason = collections.namedtuple("Reason", "tag detail before after")

# The verdict. `state` is the successor State; `target` feeds reconcile();
# `healthy` is the raw load-test verdict the policy itself acts on, while
# `published_healthy` additionally folds in the resident cap and is what goes
# into the state file. `reasons` is a list of Reason transitions -- a list,
# not a single variable, because a RECLAIM clamp and a TIGHTEN can fire on
# the same tick and each deserves its own log line (the old single `reason`
# let the later branch overwrite the earlier one, so the reclaim never
# reached the log). `notes` are complete log lines (RESIDENT-CAP edges) to
# emit verbatim; `hold` is a ready-made HOLD line or None, which the caller
# rate-limits before logging.
Decision = collections.namedtuple(
    "Decision", "state target healthy published_healthy reasons notes hold"
)


def decide(state, inputs, cfg):
    """One control tick of pure policy: (State, Inputs, cfg) -> Decision.

    Everything here is arithmetic on the arguments -- no file, clock, or
    global is consulted -- so a test can assert any branch instantly by
    constructing the situation it is about.
    """
    allowed = state.allowed
    mark = state.mark
    last_up = state.last_up
    last_growth = state.last_growth
    was_resident_full = state.was_resident_full
    # Cleared by default: only the psi-tighten branch below re-arms them, so any
    # other outcome this tick (a loosen, a settle, a predictive-only tighten)
    # ends the run -- which is what makes the streak CONSECUTIVE.
    tighten_ref = None
    tighten_streak = 0

    now = inputs.now
    psi10 = inputs.psi10
    psi60 = inputs.psi60
    pool_mem = inputs.pool_mem
    occupied = inputs.occupied
    resident = inputs.resident
    untracked = inputs.untracked
    pool_cache = inputs.pool_cache
    mem_available = inputs.mem_available
    desktop_psi10 = inputs.desktop_psi10

    reasons = []
    notes = []

    # THE BUILD BUDGET. high_frac drives the PREDICTIVE tighten, and a control
    # signal is only worth acting on if the actuator can move it. `allowed`
    # moves builds and nothing else, so the fraction is measured over the part
    # of the pool builds actually own: subtract the untracked tenants from BOTH
    # the usage and the ceiling, and what remains is "how much of the memory
    # available to builds are builds using".
    #
    # Measured 2026-08-17: worktrees-agents.slice/fleet ran 103 processes at
    # 4.4-11.8G of an 18G pool -- 9 `claude bg-spare` at 2.85G, 11
    # `bg-pty-host` at 0.95G, 2 FleetView at 0.45G, plus MCP servers and a
    # postgres. Against the whole pool that reads as 65-90% full and tightens
    # on every tick; against the build budget it reads as whatever the BUILDS
    # are doing, which is the only thing tightening can change. The comment on
    # the tighten branch below has described this limitation since the fleet was
    # 2-3G and worked around it with soft_floor; the fleet has since grown past
    # the point where a workaround suffices.
    #
    # And it is NOT reclaimable slack, which is the reason a workaround is not
    # enough. Of those 9 spares exactly ONE (95 MB) was unclaimed standby; the
    # other 8 had been claimed and were live agent sessions sitting in worktrees
    # with 233-1298 s of CPU each. A `bg-spare` in the argv says how the process
    # STARTED, not that it is idle -- the claim socket is unlinked once a
    # session takes it. Counting spares by argv reads ~3.5G of the user's actual
    # work as free memory waiting to be reclaimed; there is no such memory.
    #
    # The LOAD TEST is deliberately NOT rewritten this way: its `headroom` is
    # (high - current), and subtracting the same untracked bytes from both terms
    # cancels exactly. Free bytes are free bytes no matter who is not using
    # them, so that gate was already right ABOUT THE FLEET.
    #
    # It was not right about PAGE CACHE, and the cancellation argument above is
    # exactly why the distinction matters: the fleet's bytes appear on both
    # sides and cancel, while cache appears on the usage side ONLY -- memory.high
    # has no cache term to cancel against. So that correction does not vanish
    # here, it just belongs upstream: `current` arrives from read_pool_mem
    # already net of reclaimable cache, which fixes the fraction and the
    # headroom together and leaves this arithmetic untouched.
    high_frac = None
    if pool_mem is not None:
        pool_cur, pool_high = pool_mem
        if untracked is None:
            high_frac = pool_cur / pool_high
        else:
            budget = pool_high - untracked
            # The fleet alone at or over memory.high leaves builds no budget at
            # all. That is maximally hot, not a divide-by-zero and not (via a
            # negative denominator) a soothing small number.
            if budget <= 0:
                high_frac = 1.0
            else:
                # current and untracked are two reads of a live tree, so a
                # shrinking fleet can make this negative by a hair. Clamp.
                high_frac = max(0.0, (pool_cur - untracked) / budget)

    # RESIDENT TENANTS SHIFT EVERY BOUND, so that `allowed - resident`
    # keeps exactly the meaning `allowed` had before residency existed:
    # how many BUILDS may run. A resident browser occupies a slot but is
    # not a build and must not consume a build's quota.
    #
    # The floor is the reason this is not optional. floor=1 exists so a
    # floored semaphore still makes progress; with two browsers resident
    # and a static floor, every build would wait out its full timeout and
    # then run UNGATED -- strictly worse than admitting one. Shifting the
    # floor keeps the "at least one build may always start" guarantee
    # true no matter how many browsers are open.
    #
    # The ceiling shifts for the same reason and is then clamped to the
    # pool: residents may not buy capacity that does not exist. Note the
    # bounds move but the LOAD TEST does not -- browser memory still has
    # to pass the same free-bytes and PSI checks as anything else, so
    # this widens the bookkeeping, never the machine's real budget.
    floor_dyn = min(cfg.max_slots, cfg.floor + resident)
    soft_floor_dyn = min(cfg.max_slots, cfg.soft_floor + resident)
    ceil_dyn = min(cfg.max_slots, cfg.ceil + resident)
    # Growth must never be blocked by a ceiling that has slipped BELOW
    # the floor, which max_slots clamping can do once residents are many.
    ceil_dyn = max(ceil_dyn, floor_dyn)

    # A CLOSING BROWSER MUST TAKE ITS CAPACITY WITH IT. `allowed` only
    # ever moves on a TIGHTEN or a LOOSEN, so a ceiling that was raised
    # to 12 by four residents would keep sanctioning 12 builds after the
    # last one closed and the real ceiling fell back to 8 -- capacity
    # granted on the strength of tenants that have gone. Lowering it here
    # is a clamp, not a tighten: it can only ever reduce `allowed`.
    if allowed > ceil_dyn:
        reasons.append(
            Reason("RECLAIM", f"resident={resident} ceiling {ceil_dyn}",
                   allowed, ceil_dyn)
        )
        allowed = ceil_dyn

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
    # down, and it cannot deadlock, because the no-builds-running rule
    # below always leaves a slot free when no build is running at all. A pool
    # held near its ceiling by the agents fleet delays the next build; it
    # can never stop builds happening.
    need = cfg.grant_headroom_jobs * cfg.job_bytes
    headroom = None if pool_mem is None else pool_mem[1] - pool_mem[0]
    # Unreadable memory is NO SIGNAL, not a refusal: a pool with
    # memory.high unset would otherwise serialise every build forever.
    mem_ok = headroom is None or headroom >= need
    psi_ok = psi10 is None or psi10 <= cfg.grant_psi
    healthy = mem_ok and psi_ok

    # The RESIDENT CAP folds into the PUBLISHED health bit only: that
    # field is read solely by jobs about to become resident (builds
    # ignore it), so refusing it when residents are at cap gates
    # exactly the admissions the cap is about -- while `healthy` keeps
    # its own meaning for every decision this function makes about builds.
    resident_full = resident >= cfg.max_resident
    if resident_full != was_resident_full:
        notes.append(
            f"RESIDENT-CAP {'engaged' if resident_full else 'released'} "
            f"resident={resident} cap={cfg.max_resident}"
        )
        was_resident_full = resident_full

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
            last_growth = now

    grow = (
        healthy
        and occupied is not None
        and occupied >= mark
        and (now - last_growth) >= cfg.grant_every
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
        else max(0, int(headroom // cfg.job_bytes) - 1)
    )

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

    # IS THE STALL SELF-INFLICTED? `memory.high` is enforced by the KERNEL
    # against the RAW charge, which counts page cache. Every signal in this
    # controller reads that charge NET of what the kernel reclaims unasked
    # (see read_pool_mem and cgroup-mem.py). Those two facts pull apart
    # exactly when the pool does heavy file IO: the raw charge rides the
    # ceiling, the kernel throttles allocations to hold it there, and the net
    # figure -- the memory builds would actually give back -- sits far below.
    #
    # That throttling IS memory PSI. So psi10 reports a stall no amount of
    # tightening can relieve: the bytes at the ceiling are cache the builds do
    # not hold and the kernel drops without being asked.
    #
    # This is the one signal the 2026-08-19 cache correction could not reach.
    # The FRACTIONS were fixed at the source by subtracting reclaimable bytes;
    # PSI is a MEASURED STALL, so there is nothing to subtract -- the stall
    # genuinely happened. It can only be cross-checked against the conditions
    # that would make it meaningful.
    #
    # Measured 2026-08-27: net in-use 4.9G of a 16G high (31%), build-budget
    # fraction 14%, desktop session at 0.00% pressure and 12.6G MemAvailable --
    # while memory.events:high climbed in hundreds per tick and psi10 spiked to
    # 39%. Every one of 28 tightens in two hours was psi10; the predictive
    # signal never fired once. `allowed` averaged 3.25 and spent 29% of its
    # time at 1-2, throttling builds to relieve pressure the ceiling was
    # manufacturing against their own cache.
    #
    # ALL THREE terms are required, and each is "no signal -> not
    # self-inflicted" so that an unreadable input leaves the full floor
    # available: tighten early, never late, the same direction every other
    # fallback here takes.
    # The headroom term says the POOL has room measured in the units this
    # controller governs. The MemAvailable term says the MACHINE has room,
    # which is what separates "our own ceiling is squeezing our own cache"
    # from "global reclaim is landing on us because the box is full". Drop
    # the second term and a genuinely starved box with a cache-heavy pool
    # would dismiss real scarcity as its own doing.
    # The DESKTOP term (added 2026-09-04) says the squeeze has not reached
    # what all of this exists to protect. It is not redundant with the other
    # two: the pool can hold headroom against its own 16G ceiling while the
    # box is out of RAM, because the partition in memory-policy.nix balances
    # at exact equality -- "room under the ceiling" and "no room on the
    # machine" are simultaneously true there, and MemAvailable does not
    # separate them because the cache it counts is the cache whose reclaim is
    # the stall. See docs/notes/2026-09-04-desktop-memory-stalls.md.
    #
    # PART ONE HAS TWO ROUTES, OR'd. `roomy` is the original headroom proxy.
    # `minority_builds` asks the actuator's own question directly: of the charge
    # the kernel is throttling against -- the RAW one, net + reclaimable cache,
    # because memory.high is enforced on that and not on the corrected figure --
    # what share do BUILDS hold? `allowed` moves builds and nothing else, so a
    # charge that is mostly fleet and cache is not a charge tightening can move,
    # however little net headroom happens to be left. It needs BOTH reads: with
    # either missing the share is unknowable, which reads as NOT self-inflicted
    # like every other no-signal here.
    build_share = None
    if pool_mem is not None and untracked is not None and pool_cache is not None:
        raw = pool_mem[0] + pool_cache
        if raw > 0:
            # Two reads of a live tree: a fleet that grew between them can put
            # the numerator below zero. Clamp -- a negative share is a minority
            # by any reading, never a wrap.
            build_share = max(0.0, (pool_mem[0] - untracked) / raw)
    roomy = (
        headroom is not None
        and headroom >= cfg.self_inflicted_headroom_jobs * cfg.job_bytes
    )
    minority_builds = (
        build_share is not None
        and build_share < cfg.self_inflicted_build_share
    )
    self_inflicted = (
        (roomy or minority_builds)
        and mem_available is not None
        and mem_available >= cfg.self_inflicted_avail
        and desktop_psi10 is not None
        and desktop_psi10 < cfg.desktop_quiet_psi
    )

    hot_psi = psi10 is not None and psi10 > cfg.tighten_psi
    hot_high = (
        high_frac is not None and high_frac > cfg.tighten_high_frac
    )

    if hot_psi or hot_high:
        # The predictive signal alone may not drive to the absolute
        # floor. WHY: memory.current is the WHOLE pool, but this
        # controller only governs the part that takes slots. The agents
        # fleet and its MCP servers sit in the same pool and ask for
        # nothing -- 2-3 GB of a 9-16 GB pool when this was written, 4.4-11.8
        # GB of an 18 GB pool by 2026-08-17. (Resident browsers WERE in that
        # list until 2026-08-07; they now hold a slot for their lifetime and
        # are counted, which is what `resident` above is for.) If those tenants
        # alone hold the pool above
        # tighten_high_frac (and the baseline says the pool exceeds 14G,
        # 87.5% of high, 28% of the time) then a high-frac-only rule
        # would floor the semaphore permanently, serialising every build
        # to reclaim memory that was never the builds' to give back.
        #
        # high_frac is now measured against the BUILD BUDGET (see its
        # computation above), which removes most of that error at the source --
        # the fleet's bytes no longer masquerade as build pressure. This soft
        # floor STAYS anyway, as the belt to that braces: the correction needs
        # worktrees-agents.slice to be readable, and read_untracked_mem returns
        # None (i.e. the old whole-pool fraction) whenever it is not.
        #
        # So high-frac is treated as what it is -- an EARLY WARNING that
        # buys a head start on a burst -- and is allowed to take capacity
        # down only to soft_floor. Reaching the true floor requires
        # psi10, i.e. evidence that something is actually stalling. That
        # keeps the aggressive state reserved for demonstrated harm
        # rather than for a threshold this box crosses routinely.
        # A SELF-INFLICTED stall is demoted to the predictive signal's
        # authority. It still tightens -- cache thrash is real (7397 file
        # refaults/s when this was measured), and more concurrent builds make
        # more of it -- but it may not drive to the absolute floor, because
        # the evidence it rests on is not evidence that BUILDS are holding the
        # memory. Reaching floor still requires a stall the pool cannot
        # explain away as reclaim of its own cache, which is exactly the
        # "demonstrated harm" bar the soft floor was introduced to protect.
        #
        # Deliberately NOT a suppression of hot_psi. Suppressing it entirely
        # would leave the LOOSEN branch free to ratchet to ceil through an
        # episode of thrash, since the memory gate reads the same roomy net
        # headroom that makes the stall self-inflicted in the first place --
        # the runaway that PSI is the only signal positioned to catch.
        # THE FUTILITY BRAKE (see its config note). Only a psi tighten can be
        # futile -- the predictive one is already bounded by the soft floor, and
        # it acts on a fraction rather than on a stall, so there is no "did it
        # help" to measure.
        #
        # THE REFERENCE IS THE RUN'S ORIGIN, not the previous tick. Comparing
        # tick-to-tick lets a decelerating but still-rising stall walk straight
        # out of the brake: replaying the real 2026-09-11 descent, psi10 went
        # 37.0 -> 47.3 -> 51.6 and that last step is a rise of 4.3, under the
        # bar -- so a per-tick reference reset the streak and released the clamp
        # at exactly the third step, with psi10 14 points WORSE than where the
        # descent began. Pinning the origin asks the question that matters --
        # "since we started cutting, has this got better?" -- and is why a run
        # only resets when psi actually comes back toward where it started.
        futile = False
        if hot_psi:
            origin = state.tighten_ref
            if origin is not None and psi10 > origin + cfg.futile_psi_rise:
                tighten_ref = origin
                tighten_streak = state.tighten_streak + 1
            else:
                # First tighten of a run, or psi has come back to/below the
                # level the run started at -- either way, a fresh baseline.
                tighten_ref = psi10
                tighten_streak = 1
            futile = tighten_streak >= cfg.futile_tightens
        limit = (
            floor_dyn
            if (hot_psi and not self_inflicted and not futile)
            else max(floor_dyn, soft_floor_dyn)
        )
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
        before = allowed
        allowed = min(allowed, max(limit, allowed - cfg.step_down))
        bits = []
        if hot_psi:
            bits.append(f"psi10={psi10:.1f}%")
        if hot_high:
            # Label it "build=" when the figure is a build-budget fraction, so
            # a log line can never be mistaken for the whole-pool number the
            # older logs (and every analysis of them) recorded under "high=".
            if untracked is None:
                bits.append(f"high={high_frac * 100:.0f}%")
            else:
                bits.append(
                    f"build={high_frac * 100:.0f}% "
                    f"(fleet {untracked / 2**30:.1f}G)"
                )
        if hot_psi and self_inflicted:
            # Named in the log because the number that explains it is one the
            # line does NOT carry: psi10 is high while the net charge is low,
            # and without this tag the pair reads as a contradiction.
            bits.append(f"[self-inflicted, soft floor {limit}]")
        if hot_psi and futile and not self_inflicted:
            # Distinct from the self-inflicted tag: that one says the stall was
            # never the builds' to relieve, this one says tightening has been
            # tried and psi10 rose anyway.
            bits.append(
                f"[futile x{tighten_streak}, soft floor {limit}]"
            )
        if not hot_psi:
            bits.append(f"[predictive, soft floor {limit}]")
        # Appended even when the clamp did not move `allowed` (before ==
        # after): the caller logs only real transitions, but a non-empty
        # `reasons` also records that a decision branch fired at all,
        # which is what suppresses a SETTLE line on the same tick.
        reasons.append(Reason("TIGHTEN", " ".join(bits), before, allowed))
    elif (
        psi60 is not None
        # THE RECOVERY SIDE OF THE SAME CORRECTION. psi60 is the raw stall
        # average, so the cache-reclaim throttling described at
        # `self_inflicted` above keeps it elevated for exactly as long as the
        # pool does file IO -- and every recovery step is gated on it. Bounding
        # the DESCENT while leaving the ASCENT blocked by the same uncorrected
        # signal fixes half a sawtooth: measured 2026-08-27, minutes at
        # allowed=2 with psi10 at 0.00% and 18 jobs queued, because psi60 sat
        # at 4.4% against a 3.0% gate while the pool was 40% full with 9.6G of
        # headroom and the machine had 9.9G available.
        #
        # Safe because `allowed` is a CAP, not an admission: every actual
        # start is still gated tick-by-tick by the load test (mem_ok AND
        # psi10 <= grant_psi), which is untouched here. Raising the cap during
        # thrash therefore admits nothing by itself -- it only stops the cap
        # from being the reason a calm box refuses work it has room for.
        #
        # And it is self-limiting: self_inflicted requires several jobs' worth
        # of net headroom, so as builds actually fill the pool the exemption
        # withdraws itself and psi60 becomes binding again. The idle-ratchet
        # guard below (cap_saturated) is what keeps this from growing capacity
        # nobody asked for.
        and (psi60 < cfg.loosen_psi or self_inflicted)
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
        and allowed < ceil_dyn
        and (now - last_up) >= cfg.dwell
    ):
        before = allowed
        allowed = min(ceil_dyn, allowed + cfg.step_up)
        last_up = now
        # Tagged when the gate was passed on the exemption rather than on a
        # quiet window, so a LOOSEN at psi60=4.4% against a 3.0% threshold
        # cannot read as a broken comparison.
        detail = f"psi60={psi60:.1f}%"
        if psi60 >= cfg.loosen_psi:
            detail += " [self-inflicted]"
        reasons.append(Reason("LOOSEN", detail, before, allowed))

    # HOW MANY SLOTS TO OFFER, given the capacity just settled on. This was
    # a closure (admit_target) that mixed default-argument capture with
    # lexical capture; every dependency is now an explicit local.
    if occupied is None:
        # No occupancy signal: fail open to pre-gate behaviour rather
        # than guessing. `allowed` alone still bounds things.
        target = allowed
    else:
        if not healthy:
            # Offer nothing new; the running set drains and the mark
            # follows it down.
            target = min(allowed, occupied)
        else:
            target = min(allowed, mark + (cfg.grow_step if grow else 0))
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
        target = min(target, occupied + cfg.burst)
        if absorbable is not None:
            target = min(target, occupied + absorbable)
        # Never gate the machine to a standstill. With nothing running,
        # at least one job must be able to start or the build system
        # makes no progress at all -- and every caller would then sit out
        # its timeout and run UNGATED, which is strictly worse than
        # admitting one job. Same reasoning as floor being 1, not 0.
        # The test is "no BUILDS running", not "no slots occupied".
        # Resident browsers occupy slots permanently, so `occupied == 0`
        # is false for as long as any session is open -- this guard would
        # simply stop firing, and an idle box with one browser on it
        # would admit nothing at all. That is the exact deadlock the
        # floor exists to prevent, reintroduced through the back door.
        if occupied - resident <= 0:
            target = max(target, floor_dyn)

    # Only a grant withheld on LOAD is worth a line. Withholding on
    # spacing is the ordinary rhythm of the thing -- true of most
    # ticks between admissions -- and logging it would bury the
    # decisions under its own metronome. `target < allowed` keeps
    # quiet when the cap is the real constraint, since the TIGHTEN
    # lines already tell that story. (The caller additionally
    # rate-limits this line with hold_log_every.)
    hold = None
    if not healthy and target < allowed and occupied is not None:
        bits = []
        if not mem_ok:
            bits.append(
                f"free={headroom / 2**30:.1f}G<{need / 2**30:.1f}G"
            )
            # The reclaimable cache this gate is (correctly) NOT counting.
            # Logged because its absence is what made the old HOLD lines
            # unreadable: `free=0.2G` beside a systemctl showing 15.4G/16G and
            # a pool at 0.00% pressure looked like a contradiction for as long
            # as the cache term was invisible. It defaults to None (the
            # policy suite never sets it), and is simply absent from the line
            # then rather than printing a fabricated zero.
            if inputs.pool_cache:
                bits.append(f"(cache {inputs.pool_cache / 2**30:.1f}G excl)")
        if not psi_ok:
            bits.append(f"psi10={psi10:.1f}%")
        hold = f"HOLD {' '.join(bits)} occupied={occupied} allowed={allowed}"

    return Decision(
        state=State(
            allowed=allowed,
            mark=mark,
            last_up=last_up,
            last_growth=last_growth,
            was_resident_full=was_resident_full,
            tighten_ref=tighten_ref,
            tighten_streak=tighten_streak,
        ),
        target=target,
        healthy=healthy,
        published_healthy=healthy and not resident_full,
        reasons=reasons,
        notes=notes,
        hold=hold,
    )


def main(sleep=time.sleep):
    sem = Semaphore(SEM_DIR, CFG.max_slots)
    # START CONSERVATIVE AND EARN THE REST. Initialising to `ceil` asserts that
    # maximum concurrency is safe having measured precisely nothing -- the same
    # unearned credit the idle ratchet was accruing, just banked at startup
    # instead. It is not a hypothetical: this service restarts on every
    # `nixos-rebuild switch`, and the run at 14:33 on 2026-08-04 restarted into
    # allowed=12 and was pinned at 100% of memory.high seventy seconds later.
    # soft_floor is the same value the predictive signal is trusted to reach on
    # its own, which makes it the natural "no evidence either way" position.
    # Residents are counted BEFORE the first tick because keepers outlive this
    # process: they are independent shells holding flocks, so a `nixos-rebuild
    # switch` restarts the controller straight into a machine that already has
    # browsers on it. Starting at the unshifted soft_floor would spend the whole
    # first interval with the residents' slots subtracted from build capacity.
    state = State(
        allowed=min(
            CFG.max_slots,
            sem.resident()
            + max(CFG.floor, min(CFG.soft_floor, CFG.ceil)),
        ),
        # THE HIGH-WATER MARK: the highest concurrency this box has held while
        # the load test was passing. Admissions up to it are replacements and
        # cost nothing; going above it is growth and has to be earned. Starts
        # at zero, so a fresh controller has demonstrated nothing and climbs
        # from the floor.
        mark=0,
    )
    stop = {"now": False}

    def _term(_sig, _frm):
        stop["now"] = True

    signal.signal(signal.SIGTERM, _term)
    signal.signal(signal.SIGINT, _term)

    # Every tunable that shapes a decision is logged at START, so any later
    # TIGHTEN/LOOSEN line in this file can be interpreted without having to know
    # which build of the script produced it.
    log(
        f"START dir={SEM_DIR} pool={POOL} max={CFG.max_slots} "
        f"ceil={CFG.ceil} floor={CFG.floor} soft_floor={CFG.soft_floor} "
        f"tighten>{CFG.tighten_psi}% high>{CFG.tighten_high_frac * 100:.0f}% "
        f"untracked={UNTRACKED_SUBPATH or '(off)'} "
        f"loosen<{CFG.loosen_psi}% step-{CFG.step_down}/+{CFG.step_up} "
        f"dwell={CFG.dwell}s interval={CFG.interval}s "
        f"grow+{CFG.grow_step} every>={CFG.grant_every}s free<={CFG.burst} "
        f"needs {CFG.grant_headroom_jobs}x{CFG.job_bytes / 2**30:.1f}G free "
        f"and psi10<={CFG.grant_psi}% max_resident={CFG.max_resident} "
        # The self-inflicted predicate, in the shape decide() evaluates it:
        # (headroom OR build-share) AND avail AND desktop-quiet. Only the
        # desktop term used to appear here, which made a [self-inflicted] tag
        # unreadable without the source -- two of the three bars were invisible.
        f"self_inflicted=("
        f"headroom>={CFG.self_inflicted_headroom_jobs}jobs "
        f"or builds<{CFG.self_inflicted_build_share * 100:.0f}%) "
        f"and avail>={CFG.self_inflicted_avail / 2**30:.0f}G "
        f"and desktop_quiet<{CFG.desktop_quiet_psi}% "
        f"futile=x{CFG.futile_tightens}@psi+{CFG.futile_psi_rise}% "
        f"start={state.allowed}"
    )
    # Set by __post_init__ when the Nix-derived KX_SEM_CEIL outgrew the slot
    # pool (not a declared field -- absent means no clamp happened).
    clamped_from = getattr(CFG, "ceil_clamped_from", None)
    if clamped_from is not None:
        log(
            f"CEIL-CLAMPED|KX_SEM_CEIL={clamped_from} exceeds max_slots="
            f"{CFG.max_slots}; running with ceil={CFG.ceil} - the pool has "
            f"outgrown the slot files, raise max_slots with it"
        )

    prev_effective = None
    last_hold_log = 0.0
    try:
        while not stop["now"]:
            psi10, psi60 = read_psi(POOL, "full")
            pool_raw = read_pool_mem(POOL)
            # Split here, not in decide(): see read_pool_mem's docstring for
            # why `pool_mem` has to stay exactly two elements wide.
            pool_mem = None if pool_raw is None else (pool_raw[0], pool_raw[1])
            pool_cache = None if pool_raw is None else pool_raw[2]
            untracked = read_untracked_mem(POOL)
            mem_available = read_mem_available()
            desktop = resolve_desktop()
            desktop_psi10 = (
                None if desktop is None else read_psi(desktop, "full")[0]
            )
            occupied = sem.occupancy()
            resident = sem.resident()
            now = time.monotonic()

            d = decide(
                state,
                Inputs(
                    now=now, psi10=psi10, psi60=psi60, pool_mem=pool_mem,
                    occupied=occupied, resident=resident, untracked=untracked,
                    pool_cache=pool_cache, mem_available=mem_available,
                    desktop_psi10=desktop_psi10,
                ),
                CFG,
            )
            state = d.state

            effective = sem.reconcile(d.target)
            # Published EVERY tick, changed or not: the file's mtime is the
            # HEARTBEAT readers key liveness off (kx-build-slot fails open on
            # a state file older than ~3 intervals, the i3 bar renders it as
            # "off"). Making this conditional on change would make a healthy
            # quiet controller indistinguishable from a dead one.
            sem.publish(
                state.allowed, effective, occupied, d.target, state.mark,
                resident, d.published_healthy,
            )

            # RESIDENT-CAP engage/release edges, already formatted by decide().
            for line in d.notes:
                log(line)

            # Every decision that MOVED `allowed` gets its own line with its
            # own before/after: a RECLAIM clamp and a TIGHTEN can fire on the
            # same tick, and each transition is worth a line of its own.
            moved = [r for r in d.reasons if r.after != r.before]
            if moved:
                for r in moved:
                    log(
                        f"{r.tag} {r.detail} allowed {r.before} -> {r.after} "
                        f"(occupied {occupied} mark {state.mark} "
                        f"target {d.target} effective {effective})"
                    )
            elif d.hold is not None and (
                (now - last_hold_log) >= CFG.hold_log_every
            ):
                # decide() already vetted this as a withheld-on-load line; the
                # throttle here only keeps a long busy period from logging one
                # every tick.
                log(d.hold)
                last_hold_log = now
            elif (
                effective != prev_effective
                and not d.reasons
                and d.target >= state.allowed
            ):
                # Capacity moved without a decision: jobs returned slots the
                # controller had been waiting to take. Worth seeing, since it is
                # how a tighten actually lands. Suppressed while the burst gate
                # is what is moving `effective`, since that tracks occupancy by
                # design and would otherwise log on every admission.
                log(f"SETTLE allowed={state.allowed} effective={effective}")
            prev_effective = effective

            sleep(CFG.interval)
    finally:
        sem.release_all()
        sem.publish(CFG.max_slots, CFG.max_slots)
        log("STOP released all slots (capacity restored to maximum)")


if __name__ == "__main__":
    main()
