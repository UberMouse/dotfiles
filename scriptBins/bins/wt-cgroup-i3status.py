#!/usr/bin/env @python3@
# wt-cgroup-i3status -- i3bar status_command that prepends two blocks to the
# LEFT of the normal i3status output: the build semaphore, then worktrees.slice.
#
# It runs i3status forced into i3bar (coloured JSON) output via a config
# mirroring i3status's built-in defaults, passes those coloured blocks
# through untouched, and prepends our own:
#
#   ◱ 4/6    build semaphore: slots in use / slots ACQUIRABLE RIGHT NOW.
#            "idle" dimmed when nothing holds a slot; "off" dimmed when the
#            controller is not running at all. Those two are deliberately
#            DISTINCT: a dead controller and an idle one look identical from
#            occupancy alone, and this repo has been bitten repeatedly by
#            components that were silently doing nothing while looking healthy.
#            The denominator is `effective`, not the `allowed` cap -- the cap
#            says how high concurrency may go, which is not the same as how many
#            jobs could start this instant, and reading the former as the latter
#            is what hid a live regression (see sem_block). So the gap between
#            the two numbers is the burst window, and watching it stay small is
#            watching the ramp work.
#
#   ⚙ 2.4/12c 4.2G/16G 3wt   worktrees.slice: cores/cap, mem/cap, active
#            buckets, coloured by peak CPU-or-mem utilisation; "⚙ idle" dimmed
#            when the pool is absent or below the CPU floor.
#
# CPU% is the pool's usage_usec delta averaged over each i3status tick (~5s),
# so no extra sampling sleep is needed. cgtop convention: 100% == one core.
#
# Env: WT_BAR_ACTIVE_CORES=<cores> -- below this the ⚙ block reads "idle"
#      (default 0.15, i.e. 15% of one core).
#      KX_BUILD_SEM_DIR -- semaphore directory (default $XDG_RUNTIME_DIR/kx-build-sem).
#
# SIBLING FILE: wt-cgroup-status.sh reads the same cgroup fields in bash for
# the interactive report. A cgroup-v2 layout change needs both.
import functools
import sys
import os
import json
import time
import subprocess
import signal

I3STATUS = "@i3status@"

UID = os.getuid()
POOL = os.environ.get(
    "KX_POOL",
    f"/sys/fs/cgroup/user.slice/user-{UID}.slice/user@{UID}.service/worktrees.slice",
)

ACTIVE_CORES = float(os.environ.get("WT_BAR_ACTIVE_CORES", "0.15"))

# Palette lifted from the dunst catppuccin-mocha theme in home.nix.
GREEN, YELLOW, RED, DIM = "#a6e3a1", "#f9e2af", "#f38ba8", "#6c7086"

def read_int(path):
    try:
        with open(path) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None

def read_usage_usec():
    try:
        with open(POOL + "/cpu.stat") as f:
            for line in f:
                if line.startswith("usage_usec"):
                    return int(line.split()[1])
    except OSError:
        return None
    return None

def cap_cores():
    try:
        with open(POOL + "/cpu.max") as f:
            quota, period = f.read().split()[:2]
        return None if quota == "max" else int(quota) / int(period)
    except (OSError, ValueError):
        return None

def mem_high():
    try:
        with open(POOL + "/memory.high") as f:
            v = f.read().strip()
        return None if v == "max" else int(v)
    except (OSError, ValueError):
        return None

def human(nbytes):
    if nbytes is None:
        return "?"
    g = nbytes / (1024 ** 3)
    if g >= 1:
        return f"{g:.1f}G"
    m = nbytes / (1024 ** 2)
    if m >= 1:
        return f"{m:.0f}M"
    return f"{nbytes / 1024:.0f}k"

def active_buckets():
    n = 0
    try:
        for name in os.listdir(POOL):
            pids = read_int(os.path.join(POOL, name, "pids.current"))
            if pids and pids > 0:
                n += 1
    except OSError:
        pass
    return n

def block(full, color, name="worktrees"):
    return {"full_text": full, "color": color, "name": name,
            "markup": "none", "separator": True}


# ---------------------------------------------------------------- semaphore --
SEM_DIR = os.environ.get(
    "KX_BUILD_SEM_DIR",
    os.path.join(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{UID}"), "kx-build-sem"),
)

# An `allowed` file older than this many seconds is a DEAD controller's
# leftovers: the controller re-publishes every tick, changed or not, precisely
# so the file's mtime is a heartbeat (see the publish call in its main loop).
# 15 s is ~3 of its 5 s control intervals. Overridable so the test suite can
# age the file with utime instead of sleeping; garbage degrades to the default
# (this runs unattended in the bar, same rule as the controller's from_env).
try:
    SEM_STALE_AFTER = float(os.environ.get("KX_SEM_STALE_AFTER", "15"))
except ValueError:
    SEM_STALE_AFTER = 15.0


def held_slots():
    """{slot_index: holder_pid} for every flock'd slot, read from /proc/locks.

    Deliberately NOT probed with flock. Taking even a momentary LOCK_NB on a
    free slot would make a real job's acquire fail spuriously -- the status bar
    would be competing with the builds it is reporting on. /proc/locks is
    read-only, cannot interfere, and is one small read (~112 lines here) plus a
    stat per slot.

    The key is the full (major, minor, inode), not the inode alone. Slot files
    sit on tmpfs and carry very low inode numbers -- 58-73 as measured -- which
    collide freely with inodes on any other small filesystem, and an inode-only
    match would report an unrelated lock elsewhere on the machine as a busy build
    slot. Silently, and only sometimes, which is the worst way for a status
    readout to be wrong.
    """
    inodes = {}
    try:
        for name in os.listdir(SEM_DIR):
            if not name.startswith("slot."):
                continue
            try:
                st = os.stat(os.path.join(SEM_DIR, name))
                key = (os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)
                inodes[key] = int(name.split(".")[-1])
            except (OSError, ValueError):
                continue
    except OSError:
        return None  # no semaphore directory at all
    if not inodes:
        return None  # directory exists but holds no slots
    held = {}
    try:
        with open("/proc/locks") as f:
            for line in f:
                if "FLOCK" not in line:
                    continue
                # Rows containing '->' are blocked WAITERS, not holders, and
                # counting them would over-report occupancy exactly when the
                # semaphore is contended.
                if "->" in line:
                    continue
                fields = line.split()
                for idx, field in enumerate(fields):
                    parts = field.split(":")
                    if len(parts) != 3:
                        continue
                    try:
                        # maj:min are hex in this file; the inode is decimal.
                        key = (int(parts[0], 16), int(parts[1], 16), int(parts[2]))
                    except ValueError:
                        continue
                    if key in inodes:
                        # The pid column sits immediately before the
                        # major:minor:inode column in every /proc/locks row.
                        try:
                            held[inodes[key]] = int(fields[idx - 1])
                        except (ValueError, IndexError):
                            held[inodes[key]] = -1
                    break
    except OSError:
        return None
    return held


@functools.lru_cache(maxsize=64)
def is_controller(pid):
    """True if pid is the semaphore controller rather than a gated job.

    Classifying by SLOT INDEX instead (index < allowed == a job) is wrong, and
    wrong exactly when it matters most: tightening is non-preemptive, so during
    a tighten jobs legitimately keep slots ABOVE `allowed` until they drain.
    Observed live at 16:35 as allowed=1 with effective=3 -- three jobs running,
    which an index rule would have reported as one. The holder pid is exact.

    lru_cache bounds the memo the same way the old hand-rolled dict did; pid
    reuse can serve one stale answer per recycled pid, which the previous
    cache also accepted -- a wrong colour for one tick is not worth a TTL.
    """
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return b"build-semaphore-controller" in f.read()
    except OSError:
        return False


def sem_block():
    held = held_slots()
    if held is None:
        # Controller not running. Distinct from "idle" on purpose: an absent
        # semaphore means nothing is being gated at all, which is exactly the
        # silent-no-op state worth being able to see at a glance.
        return block("◱ off", DIM, name="buildsem")

    try:
        # DEAD-CONTROLLER CHECK FIRST: slot files and the last-published state
        # line live in tmpfs and outlive the controller, so a crashed (or
        # failed-to-start-after-a-deploy) controller would otherwise render as
        # a healthy "idle" forever -- exactly the silently-doing-nothing state
        # the off/idle split in the header exists to expose. mtime is the
        # heartbeat; a stale file means nobody is publishing.
        allowed_path = os.path.join(SEM_DIR, "allowed")
        if time.time() - os.stat(allowed_path).st_mtime > SEM_STALE_AFTER:
            return block("◱ off", DIM, name="buildsem")
        # Field 0 is `allowed` (the cap the loop is aiming at), field 1 is
        # `effective` (what the controller is not holding back, i.e. what a job
        # could actually take right now). Field 1 is written by every publish,
        # including the two-field one on STOP, so this cannot IndexError against
        # a controller mid-shutdown.
        with open(allowed_path) as f:
            fields = f.read().split()
        allowed = int(fields[0])
        effective = int(fields[1])
        # Field 6 is `resident`: slots held for the LIFETIME of a browser rather
        # than for the duration of a build. Appended last and read defensively,
        # because a controller from before residency existed writes six fields
        # and this block has to survive the window between switch and restart.
        resident = int(fields[6]) if len(fields) > 6 else 0
    except (OSError, ValueError, IndexError):
        return block("◱ off", DIM, name="buildsem")

    # SPLIT THE HOLDERS. A resident browser is a slot holder but not a build,
    # and lumping the two together makes the bar lie in whichever direction the
    # accounting happens to be wrong: before residency it read 1/1 with four
    # browsers up (the tenants were invisible), and counting them as builds
    # would now read 4/5 on an idle box with no build running at all. Neither is
    # what someone glancing at a bar wants to know, which is how much BUILD
    # capacity is left.
    holders = sum(1 for pid in held.values() if not is_controller(pid))
    used = max(0, holders - resident)
    build_effective = max(0, effective - resident)
    if used == 0 and resident == 0:
        return block("◱ idle", DIM, name="buildsem")
    if used == 0:
        # Nothing building, but the browsers are still costing capacity and are
        # the reason `allowed` is not what it would otherwise be. Worth seeing.
        return block(f"◱ idle ◐{resident}", DIM, name="buildsem")

    # THE NUMBER IS AVAILABILITY, THE COLOUR IS THROTTLING, and they are drawn
    # from different denominators on purpose.
    #
    # Showing used/`allowed` made the bar read as though the whole cap were
    # takeable: an 8-wide `allowed` with one job running looked like "seven
    # free" when the controller may be offering two. `effective` is the honest
    # count, so used/effective at saturation means "nothing free right now".
    #
    # But that saturation is the ORDINARY state of a healthy ramp -- the free
    # cap deliberately keeps availability a couple of jobs ahead of occupancy,
    # so the bar would sit at its warning colour permanently. Being at
    # `allowed`, on the other hand, is the real throttle: it means demand has
    # reached the cap and the next job queues on the control loop rather than on
    # the ramp. So the colour keeps `allowed` as its denominator. used > allowed
    # is legitimate mid-tighten (jobs drain rather than being preempted) and
    # correctly shows as saturated red.
    # Residents come out of BOTH denominators, for the same reason they come out
    # of the numerator: the controller raises every bound by the resident count,
    # so `allowed - resident` is the build cap in the sense `allowed` had before
    # residency existed, and the colour keeps meaning what it always meant.
    build_allowed = allowed - resident
    u = used / build_allowed if build_allowed > 0 else 1.0
    color = GREEN if u < 0.5 else (YELLOW if u < 1.0 else RED)
    tail = f" ◐{resident}" if resident else ""
    return block(f"◱ {used}/{build_effective}{tail}", color, name="buildsem")

prev_usage = None
prev_t = None

def worktree_block():
    global prev_usage, prev_t
    if not os.path.isdir(POOL):
        prev_usage, prev_t = None, None
        return block("⚙ idle", DIM)

    usage = read_usage_usec()
    now = time.monotonic()
    cores = 0.0
    if usage is not None and prev_usage is not None and now > prev_t:
        cores = max(0.0, (usage - prev_usage) / 1e6 / (now - prev_t))
    prev_usage, prev_t = usage, now

    if cores < ACTIVE_CORES:
        return block("⚙ idle", DIM)

    cap = cap_cores()
    mem = read_int(POOL + "/memory.current")
    memhigh = mem_high()
    nwt = active_buckets()

    cpu_txt = f"{cores:.1f}/{cap:.0f}c" if cap else f"{cores:.1f}c"
    mem_txt = f"{human(mem)}/{human(memhigh)}" if memhigh else human(mem)
    full = f"⚙ {cpu_txt} {mem_txt} {nwt}wt"

    cpu_u = (cores / cap) if cap else 0.0
    mem_u = (mem / memhigh) if (mem and memhigh) else 0.0
    u = max(cpu_u, mem_u)
    color = GREEN if u < 0.5 else (YELLOW if u < 0.8 else RED)
    return block(full, color)

def main():
    proc = subprocess.Popen(
        [I3STATUS, "-c", "@i3statusConf@"],
        stdout=subprocess.PIPE, stdin=subprocess.DEVNULL, text=True, bufsize=1)

    def term(*_):
        try:
            proc.terminate()
        except Exception:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, term)
    signal.signal(signal.SIGINT, term)

    sys.stdout.write('{"version":1}\n[\n')
    sys.stdout.flush()

    first = True
    for raw in proc.stdout:
        s = raw.strip()
        if s.startswith(","):        # i3bar continuation lines: ",[ ... ]"
            s = s[1:].strip()
        # Skip the protocol header and the opening "[".
        if not s or s == "[" or (s.startswith("{") and "version" in s):
            continue
        # i3status is configured for i3bar JSON, so pass its coloured blocks
        # through. Fall back to wrapping a plain-text line as one block.
        if s.startswith("["):
            try:
                status_blocks = json.loads(s)
            except json.JSONDecodeError:
                status_blocks = [{"full_text": s, "markup": "none"}]
        else:
            status_blocks = [{"full_text": raw.rstrip("\n"),
                              "markup": "none", "separator": True}]

        # Semaphore first: it sits to the LEFT of the worktrees block, which in
        # turn sits left of i3status's own blocks.
        line = json.dumps([sem_block(), worktree_block()] + status_blocks)
        sys.stdout.write(("" if first else ",") + line + "\n")
        sys.stdout.flush()
        first = False

    term()


# Guarded so the pure block-building functions (sem_block arithmetic above all)
# are importable by scripts/wt-cgroup-i3status.test.py without spawning i3status.
if __name__ == "__main__":
    main()
