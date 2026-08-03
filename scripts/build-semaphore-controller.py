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
# from the bottom, and the controller takes them from the top, so the two meet
# in the middle without ever fighting over the same file. Consequences:
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
# FLOOR is 1, never 0: a floored semaphore must still make progress or the build
# system deadlocks. At the floor, heavy jobs run strictly one at a time, which is
# slow but always finishes.
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
STATE_DIR = Path.home() / ".local/state/cgroup-pressure"
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
    # looks. 12 matches the pool's CPUQuota=1200% -- admitting more concurrent
    # heavy jobs than there are grantable cores buys nothing but memory.
    ceil=_int("KX_SEM_CEIL", 12),
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


def read_high_frac(path):
    """memory.current / memory.high for the pool, or None if unavailable."""
    try:
        cur = int((path / "memory.current").read_text().strip())
        raw = (path / "memory.high").read_text().strip()
        if raw == "max":
            return None
        high = int(raw)
        return cur / high if high > 0 else None
    except (OSError, ValueError, ZeroDivisionError):
        return None


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

    def reconcile(self, allowed):
        """Hold slots [allowed, max) and release anything below `allowed`.

        Returns the capacity actually in effect. That can be HIGHER than
        `allowed` when running jobs still occupy slots the controller wants --
        it takes them as they are returned, which is what makes tightening
        graceful rather than preemptive.
        """
        for i in list(self.held):
            if i < allowed:
                try:
                    self.held.pop(i).close()
                except OSError:
                    self.held.pop(i, None)

        for i in range(max(allowed, 0), self.max_slots):
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

    def publish(self, allowed, effective):
        try:
            tmp = self.dir / "allowed.tmp"
            tmp.write_text(f"{allowed} {effective} {self.max_slots}\n")
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
    allowed = CFG["ceil"]
    last_up = 0.0
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
        f"dwell={CFG['dwell']}s interval={CFG['interval']}s"
    )

    prev_effective = None
    try:
        while not stop["now"]:
            psi10 = read_psi(POOL, "full", "avg10")
            psi60 = read_psi(POOL, "full", "avg60")
            high_frac = read_high_frac(POOL)

            before = allowed
            reason = None

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
                allowed = max(limit, allowed - CFG["step_down"])
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
                and allowed < CFG["ceil"]
                and (time.monotonic() - last_up) >= CFG["dwell"]
            ):
                allowed = min(CFG["ceil"], allowed + CFG["step_up"])
                last_up = time.monotonic()
                reason = f"LOOSEN psi60={psi60:.1f}%"

            effective = sem.reconcile(allowed)
            sem.publish(allowed, effective)

            if reason and allowed != before:
                log(f"{reason} allowed {before} -> {allowed} (effective {effective})")
            elif effective != prev_effective and reason is None:
                # Capacity moved without a decision: jobs returned slots the
                # controller had been waiting to take. Worth seeing, since it is
                # how a tighten actually lands.
                log(f"SETTLE allowed={allowed} effective={effective}")
            prev_effective = effective

            time.sleep(CFG["interval"])
    finally:
        sem.release_all()
        sem.publish(CFG["max_slots"], CFG["max_slots"])
        log("STOP released all slots (capacity restored to maximum)")


if __name__ == "__main__":
    main()
