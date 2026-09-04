#!/usr/bin/env python3
"""The semaphore MACHINERY: the real control loop against a synthetic pool.

    python3 scripts/build-semaphore-controller.test.py

The control LAW is unit-tested in build-semaphore-policy.test.py (pure
decide(), injected clock). This file covers what genuinely involves the
kernel: flock reconciliation read back through /proc/locks, the published
state file and its heartbeat, resident-marker pruning, the orphan-slot
sweep, and shutdown restoring full capacity.

SANDBOX-SAFE BY CONSTRUCTION. main() runs in a THREAD with a stepping sleep
stub: each tick() runs exactly one loop iteration and then parks, so every
assertion reads state a completed iteration just published -- no polling, no
wall-clock races (KX_SEM_GRANT_EVERY=0 removes the one time-based gate these
scenarios cross), and flock + /proc/locks both work inside the nix build
sandbox (tools needed: python3 and /proc only). SIGTERM is installed through
a shim (signal.signal is main-thread-only) and delivered by calling the
recorded handler, which exercises the same shutdown path minus the kernel's
part; the kernel's part -- a real signal interrupting a real process, flocks
dropped on process death -- is the one genuinely host-only check, and runs
only when KX_TEST_HOST_ONLY=1 is exported (a SKIP line is printed
otherwise), so the suite passes fully sandboxed and completely on a host
that opts in.

Every check runs and all failures are reported together at the end.
"""

import fcntl
import importlib.util
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

GIB = 2**30
BASE = Path(tempfile.mkdtemp(prefix="kx-sem-test."))
POOL = BASE / "pool"
SEM = BASE / "sem"
POOL.mkdir(parents=True)
SEM.mkdir(parents=True)
HIGH = 16 * GIB

# The controller reads its directories and tunables at IMPORT time, so the
# environment must be pinned before exec_module below -- that is what lets
# main() run in-process instead of via Popen.
os.environ.update(
    KX_SEM_POOL=str(POOL),
    KX_BUILD_SEM_DIR=str(SEM),
    KX_SEM_MAX_SLOTS="16",
    KX_SEM_CEIL="8",
    KX_SEM_SOFT_FLOOR="4",
    # One tighten reaches the floor in a single step, and growth needs no
    # wall-clock spacing: ramp pacing is the policy suite's business (it has
    # an injected clock); here a real grant interval would only put real
    # time between ticks and reintroduce the flake this file was known for.
    KX_SEM_STEP_DOWN="16",
    KX_SEM_GRANT_EVERY="0",
    # Keep synthetic decisions out of the real build-semaphore.log.
    KX_SEM_STATE_DIR=str(BASE / "state"),
)

HERE = Path(__file__).resolve().parent
CTL = HERE / "build-semaphore-controller.py"
sys.path.insert(0, str(HERE))
from testlib import check, fails, summary, wait_for  # noqa: E402

# The controller's filename has dashes, so spell the import out. Importing it
# has no side effects beyond path computation, which is what makes this safe.
spec = importlib.util.spec_from_file_location("bsc", CTL)
bsc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bsc)


def set_pool(psi10, psi60, current_gib):
    (POOL / "memory.pressure").write_text(
        "some avg10=0 avg60=0 avg300=0 total=0\n"
        f"full avg10={psi10} avg60={psi60} avg300=0 total=0\n"
    )
    (POOL / "memory.current").write_text(str(int(current_gib * GIB)))
    (POOL / "memory.high").write_text(str(HIGH))


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
    """Take the lowest free slot as kx-build-slot would; None if none free.

    Same-process is equivalent to a separate job here: flock is per OPEN FILE
    DESCRIPTION, so a second open of a locked file conflicts exactly as a
    stranger's would.
    """
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


class Stepper:
    """The injected sleep: parks the loop after each iteration until the test
    releases the next one. tick() therefore means 'run exactly one iteration
    and wait for it to finish' -- everything asserted after it reads state
    that iteration published. Timeouts are pure failure backstops, never
    something the logic waits out."""

    def __init__(self):
        self.go = threading.Semaphore(0)
        self.done = threading.Semaphore(0)

    def __call__(self, _interval):  # stands in for time.sleep in main()
        self.done.release()
        self.go.acquire()

    def first_iteration(self):
        """main() runs one full iteration before its first sleep."""
        return self.done.acquire(timeout=30)

    def tick(self, n=1):
        ok = True
        for _ in range(n):
            self.go.release()
            ok = self.done.acquire(timeout=30) and ok
        return ok

    def unpark(self):
        """Let a stopped loop out of its final sleep (no iteration follows)."""
        self.go.release()


class SignalShim:
    """Stands in for the signal MODULE inside the controller. signal.signal
    refuses to run outside the main thread, so main() installs its handlers
    through this instead; the test 'delivers' SIGTERM by calling the recorded
    handler -- the same shutdown code path as the real thing minus kernel
    delivery, which is the host-only section's job."""

    SIGTERM = signal.SIGTERM
    SIGINT = signal.SIGINT

    def __init__(self):
        self.handlers = {}

    def signal(self, sig, handler):
        self.handlers[sig] = handler


# Count publishes without disturbing them: the heartbeat property (task of
# the staleness contract) is "publish fires EVERY tick, changed or not",
# because readers key liveness off the file's mtime.
publish_count = [0]
_real_publish = bsc.Semaphore.publish


def _counting_publish(self, *args, **kwargs):
    publish_count[0] += 1
    return _real_publish(self, *args, **kwargs)


bsc.Semaphore.publish = _counting_publish

stepper = Stepper()
shim = SignalShim()
bsc.signal = shim

ctl_error = []


def run_main():
    try:
        bsc.main(sleep=stepper)
    except BaseException as e:  # noqa: BLE001 -- surfaced as a check below
        ctl_error.append(e)
        stepper.done.release()  # unwedge any tick() waiting on this iteration


thread = threading.Thread(target=run_main, daemon=True)

try:
    # (a) ORPHAN SWEEP, first against a bare __init__ (no loop involved). A
    # max_slots decrease leaves the previous run's higher-indexed slot files
    # behind, and kx-build-slot scans ALL slot.*, so an orphan is lockable,
    # uncounted, ungated capacity.
    orphan_dir = BASE / "sem-orphan"
    orphan_dir.mkdir()
    (orphan_dir / "slot.20").touch()
    bsc.Semaphore(orphan_dir, 16)
    check("orphan slot above max_slots is unlinked",
          (orphan_dir / "slot.20").exists(), False)
    check("in-range slots created alongside the sweep",
          (orphan_dir / "slot.15").exists(), True)
    # And plant one in the LIVE directory: the startup sweep in (b) is the
    # same code reached through main().
    (SEM / "slot.20").touch()

    # (b) STARTUP -> PUBLISH. main()'s own Semaphore(SEM, 16) must sweep the
    # orphan planted above, publish the FIELDS-format state file, start at
    # soft_floor (asserting nothing), and leave exactly one slot free.
    set_pool(0, 0, 1)
    thread.start()
    check("first iteration completes", stepper.first_iteration(), True)
    check("startup swept the orphan slot", (SEM / "slot.20").exists(), False)
    check("controller publishes the state file",
          len(state()), len(bsc.Semaphore.FIELDS))
    check("startup allowed is soft_floor, not ceil", state()[0:1], ["4"])
    check("idle box leaves one slot free", len(free_paths()), 1)

    # (c) THE HEARTBEAT. Nothing changes across these ticks, and the file
    # must be re-published anyway: readers (kx-build-slot's stale fail-open,
    # the bar's "off") key liveness off its mtime, so a publish-on-change
    # optimisation would make a healthy quiet controller look dead.
    before = publish_count[0]
    check("stepper ran three quiet ticks", stepper.tick(3), True)
    check("unchanged state still re-published every tick",
          publish_count[0] - before, 3)
    # And the heartbeat restores FRESHNESS: age the file the way the client
    # suites do, run one tick, and the mtime is current again. This is the
    # property the readers' ~3-interval staleness threshold stands on.
    _old = time.time() - 1000
    os.utime(SEM / "allowed", (_old, _old))
    stepper.tick()
    check("one tick refreshes the state file's mtime",
          time.time() - (SEM / "allowed").stat().st_mtime < 60, True)

    # (d) FLOCK RECONCILE AGAINST BUSY SLOTS. Jobs take real flocks, which
    # the controller sees via /proc/locks (locked_inodes, the thing under
    # test). With GRANT_EVERY=0 the mark may grow by one each tick, so three
    # holds land in three hold-then-tick rounds.
    admitted = 0
    for _ in range(3):
        if hold():
            admitted += 1
        stepper.tick()
    check("three jobs admitted through the ramp", admitted, 3)
    check("controller sees the occupancy", state()[3:4], ["3"])

    # A hostile pool tightens allowed to the floor, but the controller can
    # only hold back a slot that is FREE -- `effective` stays at the jobs'
    # count until they finish, which is what makes tightening graceful
    # rather than preemptive.
    set_pool(50, 50, 15)
    stepper.tick()
    check("hostile pool tightens allowed to the floor", state()[0:1], ["1"])
    check("busy slots stay with their jobs (effective=occupied)",
          state()[0:2], ["1", "3"])
    check("no free slots over the cap", len(free_paths()), 0)

    release_all()
    stepper.tick()
    # The controller takes the returned slots in the same tick; with no
    # builds running the floor still leaves exactly one slot free, however
    # hostile the pool (the occupied - resident guard, unit-tested in the
    # policy suite).
    check("returned slots reclaimed down to the floor", state()[1:2], ["1"])
    check("floor still leaves exactly one slot free", len(free_paths()), 1)

    # (e) RESIDENT MARKERS, in the format the real keeper writes --
    # `keeper=<pid>`, nothing else (kx-build-slot.test.py binds the producer
    # side of the same contract). A marker whose keeper is alive counts and
    # is published; one whose keeper is gone (SIGKILL, OOM) is pruned on
    # sight rather than trusted -- the flock reserves the slot, the marker
    # only sizes the floor.
    set_pool(0, 0, 1)
    (SEM / "resident").mkdir(exist_ok=True)
    (SEM / "resident" / "slot.00").write_text(f"keeper={os.getpid()}\n")
    stepper.tick()
    check("live keeper counted and published", state()[6:7], ["1"])
    (SEM / "resident" / "slot.00").unlink()

    # A pid that is certainly dead, and REAPED -- a zombie still has a /proc
    # entry and would read as a live keeper.
    _dead = subprocess.Popen([sys.executable, "-c", "pass"])
    _dead.wait()
    (SEM / "resident" / "slot.01").write_text(f"keeper={_dead.pid}\n")
    stepper.tick()
    check("stale marker pruned from disk",
          (SEM / "resident" / "slot.01").exists(), False)
    check("stale marker not counted", state()[6:7], ["0"])

    # (f) SHUTDOWN restores full capacity: deliver TERM through the recorded
    # handler, release the parked loop, and the finally block must give
    # every slot back and publish max/max.
    shim.handlers[signal.SIGTERM](signal.SIGTERM, None)
    stepper.unpark()
    thread.join(timeout=30)
    check("controller loop exits on TERM", thread.is_alive(), False)
    check("capacity restored to maximum on stop", state()[:2], ["16", "16"])
    check("every slot free after stop", len(free_paths()), 16)
    check("controller thread raised nothing", ctl_error, [])
except Exception as e:  # noqa: BLE001 -- report, do not abort the summary
    fails.append(f"integration: unhandled {e!r}")
    print(f"FAIL  integration: unhandled {e!r}")
finally:
    release_all()
    if thread.is_alive():
        # Backstop only: stop the loop so summary() is not written by a
        # half-dead process. The thread is a daemon, so even a wedged loop
        # cannot keep the suite alive.
        handler = shim.handlers.get(signal.SIGTERM)
        if handler is not None:
            handler(signal.SIGTERM, None)
        stepper.unpark()
        thread.join(timeout=5)

# HOST-ONLY: a REAL process and a REAL SIGTERM. Everything above delivers
# TERM by calling the handler; the kernel's half -- delivery interrupting a
# real sleep, flocks dropped when the process dies -- needs a live
# subprocess, which the nix sandbox is not for. Opt-in by explicit env var
# (the host runner can export it); anything else prints a SKIP so the gap is
# visible in the output rather than silent.
if os.environ.get("KX_TEST_HOST_ONLY"):
    sem2 = BASE / "sem-host"
    env = dict(os.environ)
    env.update(KX_BUILD_SEM_DIR=str(sem2), KX_SEM_INTERVAL="0.2")
    logfh = open(BASE / "ctl-host.log", "w")
    proc = subprocess.Popen(
        [sys.executable, str(CTL)], env=env,
        stdout=logfh, stderr=subprocess.STDOUT,
    )

    def host_state():
        try:
            return (sem2 / "allowed").read_text().split()
        except OSError:
            return []

    ok = wait_for(lambda: len(host_state()) == len(bsc.Semaphore.FIELDS))
    check("host controller publishes", bool(ok), True)
    proc.terminate()
    try:
        proc.wait(timeout=15)
        stopped = True
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        stopped = False
    check("host controller exits on SIGTERM", stopped, True)
    check("host capacity restored to maximum", host_state()[:2], ["16", "16"])
    logfh.close()
else:
    print("SKIP  host-only SIGTERM/process-death check "
          "(export KX_TEST_HOST_ONLY=1 to run it)")


# --- resolve_desktop: the third term's input has to survive a session ------
# The DESKTOP term of the self-inflicted test (2026-09-04) is only as good as
# its resolution, and a graphical session is not a fixture: a display-manager
# restart takes the scope with it and a new one appears under a new number.
# Resolution is pure filesystem (cgroup-lib.sh's most-PIDs fallback, no
# loginctl subprocess in a 5s control loop), and every failure mode here must
# end at None -- which decide() reads as NOT self-inflicted, keeping the full
# floor.
DESK = BASE / "userslice"
for _name, _pids, _psi in (("session-2.scope", 5, 33.8),
                           ("session-9.scope", 1, 0.0)):
    _d = DESK / _name
    _d.mkdir(parents=True)
    (_d / "memory.pressure").write_text(
        f"some avg10=0 avg60=0 avg300=0 total=0\n"
        f"full avg10={_psi} avg60=0 avg300=0 total=0\n"
    )
    (_d / "cgroup.procs").write_text("".join(f"{i}\n" for i in range(_pids)))

bsc.USER_SLICE = DESK
bsc._desktop_cache = None
check("the graphical session is the one with the most PIDs",
      bsc.resolve_desktop().name, "session-2.scope")
check("...and its PSI is what the third term reads",
      bsc.read_psi(bsc.resolve_desktop(), "full")[0], 33.8)

# A cached path that stops being readable must not be served forever: the
# session died and a different scope is now the desktop.
shutil.rmtree(DESK / "session-2.scope")
check("a vanished session is re-resolved, not cached",
      bsc.resolve_desktop().name, "session-9.scope")

# No graphical session at all (headless boot, or mid-restart) is NO SIGNAL.
shutil.rmtree(DESK / "session-9.scope")
check("no session scope at all reads as no signal", bsc.resolve_desktop(), None)

# A scope with no memory.pressure is not a candidate -- picking it would make
# the term silently unreadable while looking resolved.
(DESK / "session-3.scope").mkdir(parents=True)
(DESK / "session-3.scope" / "cgroup.procs").write_text("1\n2\n3\n")
bsc._desktop_cache = None
check("a scope without memory.pressure is not the desktop",
      bsc.resolve_desktop(), None)

# --- read_untracked_mem: only UNRECLAIMABLE bytes count ---------------------
# The fleet's memory.current is mostly page cache, which the kernel reclaims
# without the fleet's cooperation. Charging it to the build budget pinned the
# real semaphore at allowed=1 with the desktop at 0.00% pressure (2026-08-19),
# so this asserts the split rather than the total.
UNT = BASE / "untracked-pool"
(UNT / bsc.UNTRACKED_SUBPATH).mkdir(parents=True)
(UNT / bsc.UNTRACKED_SUBPATH / "memory.stat").write_text(
    f"anon {4 * GIB}\n"
    f"file {6 * GIB}\n"
    f"inactive_file {5 * GIB}\n"
    f"active_file {1 * GIB}\n"
    f"shmem {1 * GIB}\n"
    f"slab {512 * 2**20}\n"
)
# memory.current would read 11G+; only anon + shmem are the fleet's to hold.
check("untracked counts anon + shmem, not page cache",
      bsc.read_untracked_mem(UNT), 5 * GIB)

# An unreadable subtree is NO SIGNAL, which makes the caller measure against
# the whole pool -- the direction that tightens early rather than late.
check("missing memory.stat reads as no signal",
      bsc.read_untracked_mem(BASE / "nonexistent-pool"), None)

# A memory.stat with neither key is malformed, not a fleet using zero bytes;
# returning 0 would report the pool as emptier than it is.
(UNT / "empty").mkdir()
(UNT / "empty" / bsc.UNTRACKED_SUBPATH).mkdir(parents=True)
(UNT / "empty" / bsc.UNTRACKED_SUBPATH / "memory.stat").write_text("slab 123\n")
check("memory.stat without anon/shmem reads as no signal",
      bsc.read_untracked_mem(UNT / "empty"), None)

# The correction is disableable, and disabling it must not fall back to a
# partial read.
_saved_subpath = bsc.UNTRACKED_SUBPATH
bsc.UNTRACKED_SUBPATH = ""
check("empty KX_SEM_UNTRACKED disables the correction",
      bsc.read_untracked_mem(UNT), None)
bsc.UNTRACKED_SUBPATH = _saved_subpath


def dump_log():
    print("\n--- controller log ---")
    try:
        print((BASE / "state" / "build-semaphore.log").read_text())
    except OSError:
        pass


# --- read_pool_mem: the POOL's own page cache is not memory in use ----------
# Same misreading as read_untracked_mem above, one level up. It survived the
# 2026-08-19 fix because the argument that retired it there (the fleet's bytes
# cancel between usage and ceiling) is FALSE of cache: memory.high has no cache
# term to cancel against. Left uncorrected it published healthy=0 and logged
# HOLD free=0.2G<3.0G against a pool at 0.00% pressure.
PM = BASE / "poolmem"
PM.mkdir()
(PM / "memory.current").write_text(str(12 * GIB))
(PM / "memory.high").write_text(str(16 * GIB))
(PM / "memory.stat").write_text(
    f"anon {5 * GIB}\n"
    f"file {6 * GIB}\n"
    f"shmem {1 * GIB}\n"
    f"slab_reclaimable {1 * GIB}\n"
    f"slab_unreclaimable {64 * 2**20}\n"
)
# cache = (6G file - 1G shmem) + 1G reclaimable slab = 6G, so 12G - 6G = 6G.
_pm = bsc.read_pool_mem(PM)
check("pool current is net of reclaimable cache", _pm[0], 6 * GIB)
check("pool high is untouched by the correction", _pm[1], 16 * GIB)
check("the cache term is reported for the log", _pm[2], 6 * GIB)

# THE SHAPE CONTRACT. decide() unpacks `pool_mem` (pool_cur, pool_high =
# pool_mem) and the policy suite builds it as a plain 2-tuple, so main() must
# split the third element off. Widening the value that reaches decide() raises
# ValueError inside the tick thread -- the control loop dies while the state
# file keeps publishing its last plausible value, which is precisely the
# silent-death shape this repo keeps getting caught by. Asserted, not trusted.
_cur, _high = (_pm[0], _pm[1])
check("pool_mem as decide() consumes it is exactly two wide",
      len((_cur, _high)), 2)

# No memory.stat is NO SIGNAL: fall back to the RAW charge, which reads the
# pool as fuller than it is and tightens early rather than late.
PMR = BASE / "poolmem-raw"
PMR.mkdir()
(PMR / "memory.current").write_text(str(12 * GIB))
(PMR / "memory.high").write_text(str(16 * GIB))
check("no memory.stat falls back to the raw charge",
      bsc.read_pool_mem(PMR)[0], 12 * GIB)
check("no memory.stat reports no cache term",
      bsc.read_pool_mem(PMR)[2], None)

# memory.high unset still disables both signals outright.
PMU = BASE / "poolmem-unset"
PMU.mkdir()
(PMU / "memory.current").write_text(str(12 * GIB))
(PMU / "memory.high").write_text("max")
check("memory.high=max is still no pool signal at all",
      bsc.read_pool_mem(PMU), None)


summary(cleanup_dir=BASE, extra_on_fail=dump_log)
