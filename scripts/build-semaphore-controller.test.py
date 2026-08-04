#!/usr/bin/env python3
"""Exercise build-semaphore-controller against a synthetic pool.

    python3 scripts/build-semaphore-controller.test.py

Runs a real controller against a fake cgroup whose memory.pressure and
memory.current this script rewrites by hand, so every branch of the control
loop is reachable without having to put a live desktop under real memory
pressure. Simulated jobs are genuine flocks on the slot files, so what is being
tested is the actual coordination protocol rather than a model of it.

Takes about a minute: several assertions have to wait out a dwell or a grant
interval, and shrinking those below the control interval would stop the test
exercising the thing it is named after.

The tunables are all env vars, which is what makes this possible at all -- the
timings here are compressed roughly 4x from production defaults.
"""
import fcntl
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BASE = Path(tempfile.mkdtemp(prefix="kx-sem-test."))
POOL = BASE / "pool"
SEM = BASE / "sem"
CTL = Path(__file__).resolve().parent / "build-semaphore-controller.py"
HIGH = 16 * 2**30

POOL.mkdir(parents=True)
SEM.mkdir(parents=True)

fails = []
passes = []


def set_pool(psi10, psi60, current_gib):
    (POOL / "memory.pressure").write_text(
        "some avg10=0 avg60=0 avg300=0 total=0\n"
        f"full avg10={psi10} avg60={psi60} avg300=0 total=0\n"
    )
    (POOL / "memory.current").write_text(str(int(current_gib * 2**30)))
    (POOL / "memory.high").write_text(str(HIGH))


set_pool(0, 0, 1)

env = dict(os.environ)
env.update(
    KX_SEM_POOL=str(POOL),
    KX_BUILD_SEM_DIR=str(SEM),
    KX_SEM_INTERVAL="1",
    KX_SEM_DWELL="2",
    KX_SEM_MAX_SLOTS="16",
    KX_SEM_CEIL="12",
    KX_SEM_SOFT_FLOOR="4",
    KX_SEM_BURST="2",
    KX_SEM_GRANT_EVERY="4",
    KX_SEM_HOLD_LOG_EVERY="1",
    # Keep synthetic decisions out of the real build-semaphore.log.
    KX_SEM_STATE_DIR=str(BASE / "state"),
)
log = open(BASE / "ctl.log", "w")
proc = subprocess.Popen(
    [sys.executable, str(CTL)], env=env, stdout=log, stderr=subprocess.STDOUT
)
time.sleep(2.5)

jobs = []


def hold(idx):
    """Simulate a gated job taking slot `idx` and keeping it."""
    fh = open(SEM / f"slot.{idx:02d}", "w")
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    jobs.append(fh)


def release_all():
    while jobs:
        jobs.pop().close()


def free_slots():
    """Count slots a job could take right now."""
    n = 0
    for p in sorted(SEM.glob("slot.*")):
        fh = open(p, "w")
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            n += 1
        except OSError:
            pass
        finally:
            fh.close()
    return n


def state():
    a, e, m, occ, tgt = (SEM / "allowed").read_text().split()
    return int(a), int(e), int(m), occ, tgt


def check(name, got, want):
    ok = got == want
    (passes if ok else fails).append(name)
    print(f"{'PASS' if ok else 'FAIL'}  {name}: got {got}, want {want}")


def settle(n=3.0):
    time.sleep(n)


# 1. Startup asserts nothing: allowed begins at soft_floor, not ceil, and only
#    `burst` slots stand free however calm the box looks.
check("startup allowed", state()[0], 4)
check("idle free slots", free_slots(), 2)
check("idle occupancy", state()[3], "0")

# 2. Two jobs take the whole window. No more may start until it is replenished,
#    even though `allowed` has room -- this is the grant clock, not the cap.
hold(0)
hold(1)
time.sleep(1.5)
check("window spent", free_slots(), 0)
check("occupancy seen", state()[3], "2")
check("no grant before its time", state()[4], "2")

# 3. Window replenishes on its own clock and re-bases on current occupancy.
settle(5)
check("grant re-bases", state()[4], "4")
check("grant reopens window", free_slots(), 2)

# 4. Saturating `allowed` itself is what earns more capacity.
hold(2)
hold(3)
settle(5)
check("loosen once cap is full", state()[0] > 4, True)
# The invariant that actually matters, and the one to assert rather than a
# hardcoded count: what stands free is exactly what was granted and not taken.
occ, tgt = int(state()[3]), int(state()[4])
check("free == granted - taken", free_slots(), tgt - occ)

# 5. Real stall drives allowed to the floor; running jobs are NOT preempted.
set_pool(50, 50, 14)
settle(6)
allowed = state()[0]
check("psi tighten to floor", allowed, 1)
check("no free slots over cap", free_slots(), 0)
check("running jobs keep slots", state()[3], "4")

# 6. Calm returns but the box is IDLE: allowed must not ratchet up.
release_all()
set_pool(0, 0, 1)
settle(8)
check("no loosen while idle", state()[0], 1)
check("floor keeps one slot free", free_slots(), 1)

# 7. Saturated and calm: now it may grow -- but only to just past demand. With
#    one job running, allowed ratchets to 2 and stops, because at that point the
#    cap is no longer full and there is nothing left to learn from.
hold(0)
settle(8)
check("loosen while saturated", state()[0], 2)

# 8. Memory gate: less than one job's worth of headroom left.
set_pool(0, 0, 15.2)
settle()
check("mem gate with job running", free_slots(), 0)

# 8b. The gate makes occupied >= target trivially true. That must NOT read as
#     demand and grow the cap -- the constraint is bytes, not slots.
before_gate = state()[0]
settle(8)
check("no loosen behind a closed mem gate", state()[0], before_gate)
release_all()
settle()
check("mem gate still admits when empty", free_slots(), 1)

# 9. Headroom returns.
set_pool(0, 0, 2)
settle()
check("gate reopens", free_slots(), 2)

proc.terminate()
proc.wait(timeout=10)
log.close()

if fails:
    print()
    print("--- controller log ---")
    print((BASE / "ctl.log").read_text())
    print("FAILURES:", fails)
else:
    shutil.rmtree(BASE, ignore_errors=True)
    print(f"\nall {len(passes)} assertions passed")
sys.exit(1 if fails else 0)
