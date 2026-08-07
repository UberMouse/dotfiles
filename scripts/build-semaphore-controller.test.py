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
    KX_SEM_GROW_STEP="1",
    KX_SEM_BURST="2",
    KX_SEM_GRANT_EVERY="4",
    KX_SEM_GRANT_HEADROOM_JOBS="2",
    KX_SEM_GRANT_PSI="3",
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


def locked_keys():
    """(major, minor, inode) of every flock holder on the machine."""
    out = set()
    with open("/proc/locks") as fh:
        for line in fh:
            if "->" in line:
                continue
            for tok in line.split():
                parts = tok.split(":")
                if len(parts) != 3:
                    continue
                try:
                    out.add((int(parts[0], 16), int(parts[1], 16), int(parts[2])))
                except ValueError:
                    pass
                break
    return out


def free_paths():
    """Slot files a job could take right now, lowest index first.

    Read from /proc/locks rather than probed with flock. Probing is not merely
    impolite here, it CORRUPTS THE RUN: a test-and-release shows up as a rise in
    occupancy, and the controller reads a rise as an admission and restarts the
    spacing clock -- so a test that probed once a second would hold the grant
    clock permanently at zero and every timing assertion below would fail for a
    reason that has nothing to do with the code under test. The same argument is
    why the controller and the status bar both read this file instead.
    """
    locked = locked_keys()
    out = []
    for p in sorted(SEM.glob("slot.*")):
        st = p.stat()
        if (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino) not in locked:
            out.append(p)
    return out


def free_slots():
    return len(free_paths())


def hold():
    """Simulate a gated job taking the lowest free slot, as kx-build-slot does."""
    for p in free_paths():
        fh = open(p, "w")
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            fh.close()
            continue
        jobs.append(fh)
        return p.name
    raise AssertionError(f"no free slot to take (state={(SEM / 'allowed').read_text()})")


def hold_resident():
    """Simulate a browser keeper: take a slot AND claim it as resident.

    The marker names THIS process as the keeper, which is alive for the whole
    run -- so the controller counts it until the test deliberately removes it.
    """
    name = hold()
    (SEM / "resident").mkdir(exist_ok=True)
    (SEM / "resident" / name).write_text(
        f"keeper={os.getpid()} label=playwright-open daemons=1\n"
    )
    return name


def release_residents():
    """Drop the markers. A real keeper removes its own as it exits."""
    for f in (SEM / "resident").glob("slot.*"):
        try:
            f.unlink()
        except OSError:
            pass


# A pid that is certainly dead, for the stale-marker test. Reaped, so the kernel
# is not holding it as a zombie -- a zombie still has a /proc entry and would
# read as a live keeper.
_dead = subprocess.Popen([sys.executable, "-c", "pass"])
_dead.wait()
dead_pid = _dead.pid


def release_all():
    while jobs:
        jobs.pop().close()


def state():
    """(allowed, effective, max_slots, occupied, target, mark) as written."""
    return (SEM / "allowed").read_text().split()


def check(name, got, want):
    ok = got == want
    (passes if ok else fails).append(name)
    print(f"{'PASS' if ok else 'FAIL'}  {name}: got {got}, want {want}")


def settle(n=3.0):
    time.sleep(n)


# 1. Startup asserts nothing: allowed begins at soft_floor, not ceil, and
#    exactly one slot stands free however calm the box looks.
check("startup allowed", state()[0], "4")
check("idle free slot", free_slots(), 1)
check("idle occupancy", state()[3], "0")

# 2. One job takes the only free slot. Nothing else may start until the spacing
#    clock has run, even though `allowed` has room and the box is calm -- psi10
#    could not yet contain evidence of the job that just started.
hold()
time.sleep(1.5)
check("slot consumed", free_slots(), 0)
check("occupancy seen", state()[3], "1")
check("no grant before its time", state()[4], "1")

# 3. Spacing elapses on a healthy box: exactly one more slot opens.
settle(5)
check("one slot regranted", free_slots(), 1)
check("never more than one free", state()[4], "2")

# 4. Concurrency climbs one job per grant, never in a batch.
hold()
settle(5)
hold()
settle(5)
check("ramped one at a time", state()[3], "3")
check("still only one free", free_slots(), 1)

# 5. Growth sets a high-water mark. A job finishing then frees a slot for its
#    replacement with no new grant: returning to a level the box has already
#    held is not the thing that needs pacing.
hold()           # 4 concurrent: mark rises to 4, spacing clock restarts
time.sleep(1.5)
check("window shut after growth", free_slots(), 0)
check("mark records the level", state()[5], "4")
jobs.pop().close()   # a job finishes: occupancy 3, below the mark
time.sleep(1.5)
check("replacement is free", free_slots(), 1)
check("but only back to the mark", state()[4], "4")

# 5b. A batch of finishers is offered back only as fast as MEMORY can absorb
#     them. A phase boundary can drop occupancy by several at once, and the mark
#     alone would hand every slot back in the same instant -- which needs one
#     job's worth of memory per slot, while the load test only ever checked for
#     two. Tight pool first: 3.0G free absorbs one beyond the slack it keeps.
set_pool(0, 0, 13.0)
jobs.pop().close()   # occupancy 2, mark still 4
settle()
check("batch capped by headroom", free_slots(), 1)

# 5c. Same occupancy, same mark, roomy pool: now both slots come back at once.
#     Nothing about the slot arithmetic changed -- only the memory did.
set_pool(0, 0, 4)
settle()
check("batch opens up when roomy", free_slots(), 2)

# 5d. THE DRAIN, and the regression that made this test exist. The mark is a
#     memory of the PEAK, so on its own it keeps the window open at the peak
#     long after the jobs that earned it have gone -- measured 2026-08-06 as
#     `occupied=1 target=8`, seven slots free over an all-but-idle box, every
#     one of them takeable in the same instant. That is the original step-input
#     bug rebuilt out of the parts meant to prevent it, and it is worst exactly
#     here, because a drain is when the next burst arrives.
#
#     Availability must therefore track the RUNNING SET, not the high-water
#     mark. The mark is asserted to survive unchanged, so this can only pass
#     because the free-slot cap is doing the work -- not because the mark
#     quietly decayed, which would fix the symptom by discarding what the box
#     had genuinely demonstrated.
release_all()
settle()
check("drain does not reopen the window", free_slots(), 2)
check("offer follows occupancy down", state()[4], "2")
check("mark survives the drain", state()[5], "4")

# 5e. And the way back up is the same ramp, not a rebound to the mark: the two
#     free slots are all there is, and taking them buys two more, not four.
hold()
hold()
settle()
check("drain refills two at a time", state()[3], "2")
check("back to the mark, not past it", state()[4], "4")

# 6. Load test, memory half: room for one more job is not enough, two is the
#    bar, so admission stops one job short of the wall.
set_pool(0, 0, 14.8)   # 1.2G free: fits one job, not two
settle(5)
check("held below two jobs of headroom", free_slots(), 0)

# 7. Load test, stall half: plenty of memory, but something is stalling.
set_pool(20, 1, 4)
settle(5)
check("held while stalling", free_slots(), 0)

# 8. Both halves satisfied. The mark fell to occupancy while the test was
#    failing, so this is a growth step again, not a replacement.
set_pool(0, 0, 4)
settle(5)
check("grant resumes when healthy", free_slots(), 1)

# 9. Real stall drives allowed to the floor; running jobs are NOT preempted.
set_pool(50, 50, 14)
settle(6)
check("psi tighten to floor", state()[0], "1")
check("no free slots over cap", free_slots(), 0)
check("running jobs keep slots", state()[3], "2")

# 10. Calm returns but the box is IDLE: allowed must not ratchet up.
release_all()
set_pool(0, 0, 1)
settle(8)
check("no loosen while idle", state()[0], "1")
check("floor keeps one slot free", free_slots(), 1)

# 11. Saturated and calm: now it may grow -- but only to just past demand. With
#     one job running, allowed ratchets to 2 and stops, because at that point the
#     cap is no longer full and there is nothing left to learn from.
hold()
settle(8)
check("loosen while saturated", state()[0], "2")

# 12. A closed load test makes occupied >= target trivially true. That must NOT
#     read as demand and grow the cap -- the constraint is bytes, not slots.
set_pool(0, 0, 15.2)
settle()
check("no slot while gated", free_slots(), 0)
before_gate = state()[0]
settle(8)
check("no loosen behind a closed gate", state()[0], before_gate)

# 13. Non-deadlock: with nothing running at all, a job may always start, however
#     hostile the pool looks. Otherwise every caller waits out its timeout and
#     runs UNGATED, which is strictly worse.
release_all()
settle()
check("floor admits one when empty", free_slots(), 1)

# 14. RESIDENCY. A browser keeper holds a slot for the lifetime of the browser,
#     which means slots can be occupied indefinitely by something that is not a
#     build. The floor has to rise with them or the machine deadlocks: the pool
#     here is still hostile from test 12, so the load test is shut and the ONLY
#     thing that can open a slot is the floor.
#
#     This is the discriminating test for the guard in admit_target. Written the
#     obvious way -- `if occupied == 0` -- the guard silently stops firing the
#     moment a browser is open, because occupancy is then never zero. Builds
#     would wait out the full timeout and run ungated, and nothing in the log
#     would look wrong. Two residents, so a stuck guard cannot pass by luck.
#     Note the settle BETWEEN the two: a browser is admitted like any other job,
#     through the one slot the floor leaves open, and the floor only rises once
#     the controller has seen its marker. Residents arrive one per tick, which
#     is the point -- two browsers opening at once still queue.
res_a = hold_resident()
settle(4)
res_b = hold_resident()
settle(4)
check("residents counted", state()[6], "2")
check("resident floor still admits one", free_slots(), 1)

# 15. That free slot is real: a build takes it, and only then is the box full.
hold()
settle()
check("build takes the resident-floored slot", free_slots(), 0)
check("occupancy counts residents and builds", state()[3], "3")

# 16. A keeper killed outright (SIGKILL, OOM) cannot remove its own marker. The
#     stale marker must not keep buying floor forever -- the lock is what
#     reserves the slot, the marker only sizes the floor, so an orphan is pruned
#     on sight rather than trusted.
release_all()
release_residents()
(SEM / "resident").mkdir(exist_ok=True)
(SEM / "resident" / "slot.00").write_text(f"keeper={dead_pid} label=orphan\n")
settle(4)
check("stale marker not counted", state()[6], "0")
check("stale marker pruned", (SEM / "resident" / "slot.00").exists(), False)

# 17. Capacity a browser bought does not outlive the browser. `allowed` only
#     ever moves on a tighten or a loosen, so a ceiling raised by residents
#     would keep sanctioning builds after the last browser closed.
#
#     This needs a RESTART on a low ceiling to be testable at all. The clamp
#     only fires once `allowed` exceeds the bare ceiling, and at the 12 this
#     run has been using that would mean ratcheting to 13 -- nine grant
#     intervals and thirteen concurrent holds, to exercise one comparison. A
#     ceiling of 2 puts the same state three admissions away. It is reachable in
#     production (ceil 8, 16 slots, four browsers), which is why it is tested
#     rather than reasoned about.
release_all()
release_residents()
set_pool(0, 0, 1)
proc.terminate()
proc.wait(timeout=10)

env["KX_SEM_CEIL"] = "2"
env["KX_SEM_SOFT_FLOOR"] = "2"
proc = subprocess.Popen(
    [sys.executable, str(CTL)], env=env, stdout=log, stderr=subprocess.STDOUT
)
settle(3)
check("restarted on a low ceiling", state()[0], "2")

hold_resident()
settle(4)
hold_resident()
settle(4)
# Saturate, so the ratchet has demand to answer to and climbs to the raised
# ceiling of ceil + resident.
hold()
settle(6)
hold()
settle(10)
check("residents raise the ceiling", state()[0], "4")

# Every browser closes. The ceiling falls back to 2 and `allowed` must follow it
# down without waiting for a tighten that may never come on a calm box.
release_all()
release_residents()
settle(4)
check("cap reclaimed when residents leave", state()[0], "2")
check("no residents left", state()[6], "0")

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
