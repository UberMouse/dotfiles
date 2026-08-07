#!/usr/bin/env python3
"""The semaphore MACHINERY: the real controller against a synthetic pool.

    python3 scripts/build-semaphore-controller.test.py

The control LAW is unit-tested in build-semaphore-policy.test.py (pure
decide(), injected clock, sandboxed by `nix flake check`). This file covers
what genuinely involves the kernel and a second process: flock
reconciliation, the published state file, resident marker pruning, and
SIGTERM restoring full capacity. It polls for convergence with generous
timeouts rather than asserting on dwell-scale timing, so a busy machine
slows it down without failing it.

Every check runs and all failures are reported together at the end; nothing
aborts the suite part-way.
"""

import fcntl
import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CTL = HERE / "build-semaphore-controller.py"
sys.path.insert(0, str(HERE))
from testlib import check, fails, summary, wait_for  # noqa: E402

# The controller's filename has dashes, so spell the import out. Importing it
# has no side effects beyond path computation, which is what makes this safe.
spec = importlib.util.spec_from_file_location("bsc", CTL)
bsc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bsc)

GIB = 2**30
BASE = Path(tempfile.mkdtemp(prefix="kx-sem-test."))
POOL = BASE / "pool"
SEM = BASE / "sem"
POOL.mkdir(parents=True)
SEM.mkdir(parents=True)
HIGH = 16 * GIB


def set_pool(psi10, psi60, current_gib):
    (POOL / "memory.pressure").write_text(
        "some avg10=0 avg60=0 avg300=0 total=0\n"
        f"full avg10={psi10} avg60={psi60} avg300=0 total=0\n"
    )
    (POOL / "memory.current").write_text(str(int(current_gib * GIB)))
    (POOL / "memory.high").write_text(str(HIGH))


ENV = dict(os.environ)
ENV.update(
    KX_SEM_POOL=str(POOL),
    KX_BUILD_SEM_DIR=str(SEM),
    KX_SEM_INTERVAL="0.2",
    KX_SEM_MAX_SLOTS="16",
    KX_SEM_CEIL="8",
    KX_SEM_SOFT_FLOOR="4",
    # Grants come as fast as the loop ticks, and a tighten reaches the floor
    # in one step: ramp pacing is unit-tested against decide() in the policy
    # suite, so the subprocess run only has to exercise the machinery
    # around it.
    KX_SEM_GRANT_EVERY="0.2",
    KX_SEM_STEP_DOWN="16",
    # Keep synthetic decisions out of the real build-semaphore.log.
    KX_SEM_STATE_DIR=str(BASE / "state"),
)


def free_paths():
    """Slot files a job could take right now, lowest index first.

    Read from /proc/locks (via the controller's own locked_inodes -- the
    thing under test, not a reimplementation of it) rather than probed with
    flock. Probing is not merely impolite here, it CORRUPTS THE RUN: a
    test-and-release shows up as a rise in occupancy, and the controller
    reads a rise as an admission and restarts the spacing clock.
    """
    locked = bsc.locked_inodes() or set()
    out = []
    for p in sorted(SEM.glob("slot.*")):
        st_ = p.stat()
        if (os.major(st_.st_dev), os.minor(st_.st_dev), st_.st_ino) \
                not in locked:
            out.append(p)
    return out


jobs = []


def hold():
    """Take the lowest free slot as kx-build-slot would; None if none free."""
    for p in free_paths():
        fh = open(p, "w")
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            fh.close()
            continue
        jobs.append(fh)
        return p.name
    return None


def release_all():
    while jobs:
        jobs.pop().close()


def state():
    try:
        return (SEM / "allowed").read_text().split()
    except OSError:
        return []


logfh = open(BASE / "ctl.log", "w")
proc = None
try:
    # (a) STARTUP -> PUBLISH. The state file appears in the FIELDS format,
    # capacity starts at soft_floor (asserting nothing), and exactly one slot
    # stands free on an idle box.
    set_pool(0, 0, 1)
    proc = subprocess.Popen(
        [sys.executable, str(CTL)], env=ENV,
        stdout=logfh, stderr=subprocess.STDOUT,
    )
    ok = wait_for(lambda: len(state()) == len(bsc.Semaphore.FIELDS))
    check("controller publishes the state file", bool(ok), True)
    check("startup allowed is soft_floor, not ceil",
          state()[0] if ok else None, "4")
    check("idle box leaves one slot free",
          bool(wait_for(lambda: len(free_paths()) == 1)), True)

    # (b) FLOCK RECONCILE AGAINST BUSY SLOTS. Three jobs take real flocks;
    # a hostile pool then tightens allowed to the floor, but the controller
    # can only hold back a slot that is FREE -- so `effective` stays at the
    # jobs' count until they finish, which is what makes tightening graceful
    # rather than preemptive.
    admitted = 0
    for _ in range(3):
        if wait_for(lambda: len(free_paths()) > 0) and hold():
            admitted += 1
    check("three jobs admitted through the ramp", admitted, 3)
    check("controller sees the occupancy",
          bool(wait_for(lambda: state()[3:4] == ["3"])), True)

    set_pool(50, 50, 15)
    check("hostile pool tightens allowed to the floor",
          bool(wait_for(lambda: state()[:1] == ["1"])), True)
    check("busy slots stay with their jobs (effective=occupied)",
          bool(wait_for(lambda: state()[:2] == ["1", "3"])), True)
    check("no free slots over the cap", len(free_paths()), 0)

    release_all()
    # The controller takes the returned slots as they come back; with no
    # builds running the floor still leaves exactly one slot free, however
    # hostile the pool (the occupied - resident guard, unit-tested in the
    # policy suite).
    check("returned slots are reclaimed down to the floor",
          bool(wait_for(lambda: state()[1:2] == ["1"]
                        and len(free_paths()) == 1)), True)

    # (c) RESIDENT MARKERS. A marker whose keeper is alive counts and is
    # published; one whose keeper is gone (SIGKILL, OOM) is pruned on sight
    # rather than trusted -- the flock reserves the slot, the marker only
    # sizes the floor.
    set_pool(0, 0, 1)
    (SEM / "resident").mkdir(exist_ok=True)
    (SEM / "resident" / "slot.00").write_text(
        f"keeper={os.getpid()} label=test\n"
    )
    check("live keeper counted and published",
          bool(wait_for(lambda: state()[6:7] == ["1"])), True)
    (SEM / "resident" / "slot.00").unlink()

    # A pid that is certainly dead, and REAPED -- a zombie still has a /proc
    # entry and would read as a live keeper.
    _dead = subprocess.Popen([sys.executable, "-c", "pass"])
    _dead.wait()
    (SEM / "resident" / "slot.01").write_text(
        f"keeper={_dead.pid} label=orphan\n"
    )
    check("stale marker pruned from disk",
          bool(wait_for(
              lambda: not (SEM / "resident" / "slot.01").exists())), True)
    check("stale marker not counted",
          bool(wait_for(lambda: state()[6:7] == ["0"])), True)

    # SHUTDOWN. SIGTERM must restore capacity to maximum: the finally block
    # releases every held slot and publishes max/max, and the kernel drops
    # the flocks with the closing fds.
    proc.terminate()
    try:
        proc.wait(timeout=15)
        stopped = True
    except subprocess.TimeoutExpired:
        stopped = False
    check("controller exits on SIGTERM", stopped, True)
    check("capacity restored to maximum on stop", state()[:2], ["16", "16"])
    check("every slot free after stop",
          bool(wait_for(lambda: len(free_paths()) == 16, timeout=5)), True)
except Exception as e:  # noqa: BLE001 -- report, do not abort the summary
    fails.append(f"integration: unhandled {e!r}")
    print(f"FAIL  integration: unhandled {e!r}")
finally:
    release_all()
    if proc is not None and proc.poll() is None:
        proc.kill()
        proc.wait()
    logfh.close()


def dump_log():
    print("\n--- controller log ---")
    print((BASE / "ctl.log").read_text())


summary(cleanup_dir=BASE, extra_on_fail=dump_log)
