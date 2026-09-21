#!/usr/bin/env python3
"""Unit-test wt-cgroup-i3status's sem_block arithmetic.

The resident/build split in the bar (used = holders - resident, both
denominators shifted) previously had no defence but a comment; a wrong split
makes the bar lie in whichever direction the accounting is off. held_slots,
waiting_count and is_controller are monkeypatched, so no /proc/locks, no
semaphore, no i3status -- pure arithmetic, instant, sandbox-safe.

The queue field (⧗) has its own section at the bottom, plus a real-lock test
of waiting_count against actual flocks, because "the lock is the contract" is
the one part of it that arithmetic cannot check: a stale marker file from a
SIGKILLed job must count for nothing, and only a real lock can tell the two
apart.
"""
import importlib.util
import os
import sys
import tempfile
import time
from pathlib import Path

SEM = Path(tempfile.mkdtemp(prefix="wt-i3s-test."))
os.environ["KX_BUILD_SEM_DIR"] = str(SEM)

spec = importlib.util.spec_from_file_location(
    "wti3",
    Path(__file__).resolve().parent.parent
    / "scriptBins" / "bins" / "wt-cgroup-i3status.py",
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from testlib import check, summary  # noqa: E402


def publish(line):
    (SEM / "allowed").write_text(line)


# Captured BEFORE the stubs replace them: the last section runs the real
# implementations against real flocks, and an attribute assignment here would
# otherwise have left nothing to restore.
REAL_WAITING_COUNT = mod.waiting_count
REAL_HELD_SLOTS = mod.held_slots

CONTROLLER_PID = 111
mod.is_controller = lambda pid: pid == CONTROLLER_PID
# Default for the cases below: no queue, so every pre-existing expectation is
# unchanged by the ⧗ field existing at all.
mod.waiting_count = lambda *_: 0

# Controller absent entirely.
mod.held_slots = lambda *_: None
check("no semaphore -> off", mod.sem_block()["full_text"], "◱ off")

# Semaphore up, nothing held.
mod.held_slots = lambda *_: {}
publish("4 4 16 0 4 0 0 1\n")
check("nothing held -> idle", mod.sem_block()["full_text"], "◱ idle")

# Two job holders + the controller's own held-back slot; one is resident.
mod.held_slots = lambda *_: {0: 200, 1: 201, 15: CONTROLLER_PID}
publish("4 4 16 2 4 2 1 1\n")
b = mod.sem_block()
check("resident split text", b["full_text"], "◱ 1/3 ◐1")

# Same holders on a SHORT line from an older controller: resident falls back
# to 0 and both holders count as builds (survives a mid-deploy window).
publish("4 4 16 2 4 2\n")
check("short line -> resident 0", mod.sem_block()["full_text"], "◱ 2/4")

# Only residents left: idle-with-tenants, not a phantom build.
mod.held_slots = lambda *_: {0: 200}
publish("4 4 16 1 4 1 1 1\n")
check("resident-only -> idle ◐1", mod.sem_block()["full_text"], "◱ idle ◐1")

# Mid-tighten: used above allowed-resident must saturate RED, not error.
mod.held_slots = lambda *_: {0: 200, 1: 201, 2: 202}
publish("1 3 16 3 1 3 0 1\n")
b = mod.sem_block()
check("mid-tighten colour saturates", b["color"], mod.RED)
check("mid-tighten text", b["full_text"], "◱ 3/3")

# STALENESS: slot files and the last state line live in tmpfs and outlive the
# controller, so a dead controller's leftovers must read as OFF, not as a
# healthy idle -- the off/idle split exists precisely to expose the
# silently-doing-nothing state. mtime is the heartbeat (the controller
# re-publishes every tick); aged with utime, not by sleeping.
mod.held_slots = lambda *_: {}
publish("4 4 16 0 4 0 0 1\n")
_old = time.time() - 1000
os.utime(SEM / "allowed", (_old, _old))
check("stale state file -> off", mod.sem_block()["full_text"], "◱ off")

# A fresh rewrite brings it back: the AGE, not the content, is the signal.
publish("4 4 16 0 4 0 0 1\n")
check("fresh rewrite -> idle again", mod.sem_block()["full_text"], "◱ idle")

# ---------------------------------------------------------------------------
# THE QUEUE FIELD. Occupancy alone reads identically at "the cap is full" and
# "the cap is full and ten jobs are backed up behind it"; ⧗ is the difference.
# Hidden when empty (the ◐resident rule) so an idle bar is unchanged.
mod.held_slots = lambda *_: {0: 200}
publish("1 1 16 1 1 1 0 1\n")
mod.waiting_count = lambda *_: 0
check("empty queue shows no ⧗ field", mod.sem_block()["full_text"], "◱ 1/1")

mod.waiting_count = lambda *_: 3
check("queued jobs show as ⧗", mod.sem_block()["full_text"], "◱ 1/1 ⧗3")

# The queue must NOT touch the colour: at the cap a queue is the DESIGNED
# behaviour, so colouring it would pin the block at its warning shade for the
# whole of every healthy burst. Same bytes, same colour, with and without it.
mod.waiting_count = lambda *_: 0
plain = mod.sem_block()["color"]
mod.waiting_count = lambda *_: 9
check("queue leaves the colour alone", mod.sem_block()["color"], plain)

# A queue with NOTHING RUNNING is not a contradiction: a --resident job waits
# on the load test rather than on a free slot, so browsers legitimately queue
# on an unhealthy pool while every slot sits free. Capacity free and nobody
# being let in is exactly the state worth seeing.
mod.held_slots = lambda *_: {}
publish("4 4 16 0 4 0 0 0\n")
mod.waiting_count = lambda *_: 2
check("idle with a queue still shows ⧗", mod.sem_block()["full_text"],
      "◱ idle ⧗2")

# Residents and the queue coexist, in that order.
mod.held_slots = lambda *_: {0: 200}
publish("4 4 16 1 4 1 1 1\n")
check("idle-with-tenants keeps ⧗ last", mod.sem_block()["full_text"],
      "◱ idle ◐1 ⧗2")

mod.held_slots = lambda *_: {0: 200, 1: 201, 15: CONTROLLER_PID}
publish("4 4 16 2 4 2 1 1\n")
check("busy block orders ◐ then ⧗", mod.sem_block()["full_text"],
      "◱ 1/3 ◐1 ⧗2")

# A dead controller stays OFF no matter how many jobs are queued behind it --
# the staleness check runs before anything is rendered.
mod.waiting_count = lambda *_: 5
publish("4 4 16 0 4 0 0 1\n")
_old = time.time() - 1000
os.utime(SEM / "allowed", (_old, _old))
check("stale controller is off even with a queue",
      mod.sem_block()["full_text"], "◱ off")

# ---------------------------------------------------------------------------
# THE LOCK IS THE CONTRACT. Everything above stubs waiting_count; this runs the
# real one against real flocks. A marker left behind by a SIGKILLed job is
# unlocked, and counting the FILE rather than the LOCK would leave a phantom in
# the queue until some later job happened to inherit its pid.
import fcntl  # noqa: E402

mod.waiting_count = REAL_WAITING_COUNT
mod.held_slots = REAL_HELD_SLOTS

WAIT = SEM / "waiting"
check("no waiting dir at all -> zero, not a crash",
      mod.waiting_count(mod.lock_holders()), 0)
WAIT.mkdir()
check("empty waiting dir -> zero",
      mod.waiting_count(mod.lock_holders()), 0)

(WAIT / "4242").write_text("")   # a SIGKILLed job's litter: file, no lock
check("unlocked marker counts for nothing",
      mod.waiting_count(mod.lock_holders()), 0)

live = []
for name in ("111", "222"):
    fh = open(WAIT / name, "w")
    fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
    live.append(fh)
check("locked markers are the queue",
      mod.waiting_count(mod.lock_holders()), 2)

live.pop().close()  # a job got its slot and dropped the marker's lock
check("dropping the lock leaves the queue immediately",
      mod.waiting_count(mod.lock_holders()), 1)

# The waiting/ markers must not be mistaken for slots, or a queue would read as
# occupancy -- the exact over-report the '->' skip in lock_holders exists to
# prevent, arriving by a different door. Needs a REAL slot file present, or
# held_slots short-circuits to None and the assertion proves nothing.
(SEM / "slot.00").write_text("")
check("markers are not counted as held slots",
      mod.held_slots(mod.lock_holders()), {})
for fh in live:
    fh.close()

# ------------------------------------------------------ fleet escape --------
# The ⚠ block asserts an invariant the ⚙ block structurally cannot see: no
# cc-daemon outside the fleet leaf. An escaped fleet makes the POOL look calm
# (it is -- it is empty), so every check here is about processes found OUTSIDE
# it. Driven off a synthetic /proc rather than real daemons: the detector is
# pure argv-and-cgroup reading, so a live fleet would add nothing but flakiness.
import shutil  # noqa: E402

PROC = Path(tempfile.mkdtemp(prefix="wt-i3s-proc."))
mod.PROC = str(PROC)

FLEET_CG = "0::/user.slice/user-1000.slice/user@1000.service" + mod.FLEET_SUFFIX
UI_CG = ("0::/user.slice/user-1000.slice/user@1000.service"
         "/claude.slice/claude-ui.slice/run-p1-i1.scope")


def proc_entry(pid, argv, cgroup):
    d = PROC / str(pid)
    d.mkdir(exist_ok=True)
    (d / "cmdline").write_bytes(b"\0".join(a.encode() for a in argv) + b"\0")
    (d / "cgroup").write_text(cgroup + "\n")


def reset_escape_cache():
    mod._escape_cache, mod._escape_at = None, 0.0


DAEMON = ["/nix/store/x-claude-code/bin/.claude-wrapped", "daemon", "run",
          "--origin", "transient", "--spawned-by", '{"pid":4242}']

# argv matching: fields, in order, not necessarily adjacent.
check("signature matches in order, non-adjacent",
      mod.argv_matches([b"c", b"daemon", b"run", b"--origin"], mod.DAEMON_ARGV),
      True)
check("a missing field does not match",
      mod.argv_matches([b"c", b"daemon", b"--origin"], mod.DAEMON_ARGV), False)
check("out-of-order fields do not match",
      mod.argv_matches([b"c", b"run", b"daemon", b"--origin"], mod.DAEMON_ARGV),
      False)
# The trap that makes `pgrep -f` unusable here: the signature as ONE joined
# field is not three fields, and must not match.
check("the joined signature as one field does not match",
      mod.argv_matches([b"grep", b"daemon run --origin"], mod.DAEMON_ARGV),
      False)

# A daemon sitting in the fleet leaf is the healthy case: not an escape.
proc_entry(4243, DAEMON, FLEET_CG)
reset_escape_cache()
check("daemon in the fleet is not escaped", mod.escaped_daemons(), [])
check("healthy renders no block", mod.escape_block(), None)

# The same daemon in claude-ui.slice IS the incident: CPUWeight=5000, no
# cpu.max, and the whole fleet inheriting it at fork.
proc_entry(4244, DAEMON, UI_CG)
reset_escape_cache()
check("daemon outside the fleet is escaped", mod.escaped_daemons(), [4244])
b = mod.escape_block()
check("escape renders a block", b["full_text"], "⚠ fleet escaped")
check("escape is red", b["color"], mod.RED)

# Non-daemons in the same cgroup are not the signal -- the fleet's WORKERS live
# outside the pool too during an escape, and counting them would turn one
# incident into a process census.
proc_entry(4245, ["claude", "bg-spare", "--bg-spare", "/tmp/x.sock"], UI_CG)
reset_escape_cache()
check("workers are not counted, only daemons", mod.escaped_daemons(), [4244])

# The repair tool's own probe holds the signature as its argv. Counting it
# would make every reattach look like the escape it is fixing.
proc_entry(4246, ["/nix/store/y/bin/kx-proc-find", "daemon", "run", "--origin"],
           UI_CG)
reset_escape_cache()
check("the kx-proc-find probe is not an escaped daemon",
      mod.escaped_daemons(), [4244])

# Two escaped daemons pluralise rather than reading as one.
proc_entry(4247, DAEMON, UI_CG)
reset_escape_cache()
check("two escapes count", sorted(mod.escaped_daemons()), [4244, 4247])
check("plural text", mod.escape_block()["full_text"], "⚠ fleet escaped ×2")

# The verdict is cached between ticks (a full argv scan every ~5s is waste), so
# a repair must not clear the warning until the TTL lapses -- and must clear it
# then. Asserted both ways, because a cache that never expires is a warning
# that never goes away.
shutil.rmtree(PROC / "4244")
shutil.rmtree(PROC / "4247")
check("cached verdict survives within the TTL",
      mod.escape_block()["full_text"], "⚠ fleet escaped ×2")
mod._escape_at -= mod.ESCAPE_TTL + 1
check("verdict is re-read once the TTL lapses", mod.escape_block(), None)

# An unreadable /proc must not crash the bar; it reports no escape, which is
# the same no-signal reading the ⚙ block gives for an absent pool.
mod.PROC = str(PROC / "does-not-exist")
reset_escape_cache()
check("unreadable /proc is not a crash", mod.escaped_daemons(), [])

shutil.rmtree(PROC, ignore_errors=True)

summary(cleanup_dir=SEM)
