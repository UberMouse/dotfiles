#!/usr/bin/env python3
"""Unit-test wt-cgroup-i3status's sem_block arithmetic.

The resident/build split in the bar (used = holders - resident, both
denominators shifted) previously had no defence but a comment; a wrong split
makes the bar lie in whichever direction the accounting is off. held_slots and
is_controller are monkeypatched, so no /proc/locks, no semaphore, no i3status
-- pure arithmetic, instant, sandbox-safe.
"""
import importlib.util
import os
import sys
import tempfile
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

fails = []
passes = []


def check(name, got, want):
    ok = got == want
    (passes if ok else fails).append(name)
    print(f"{'PASS' if ok else 'FAIL'}  {name}: got {got!r}, want {want!r}")


def publish(line):
    (SEM / "allowed").write_text(line)


CONTROLLER_PID = 111
mod.is_controller = lambda pid: pid == CONTROLLER_PID

# Controller absent entirely.
mod.held_slots = lambda: None
check("no semaphore -> off", mod.sem_block()["full_text"], "◱ off")

# Semaphore up, nothing held.
mod.held_slots = lambda: {}
publish("4 4 16 0 4 0 0 1\n")
check("nothing held -> idle", mod.sem_block()["full_text"], "◱ idle")

# Two job holders + the controller's own held-back slot; one is resident.
mod.held_slots = lambda: {0: 200, 1: 201, 15: CONTROLLER_PID}
publish("4 4 16 2 4 2 1 1\n")
b = mod.sem_block()
check("resident split text", b["full_text"], "◱ 1/3 ◐1")

# Same holders on a SHORT line from an older controller: resident falls back
# to 0 and both holders count as builds (survives a mid-deploy window).
publish("4 4 16 2 4 2\n")
check("short line -> resident 0", mod.sem_block()["full_text"], "◱ 2/4")

# Only residents left: idle-with-tenants, not a phantom build.
mod.held_slots = lambda: {0: 200}
publish("4 4 16 1 4 1 1 1\n")
check("resident-only -> idle ◐1", mod.sem_block()["full_text"], "◱ idle ◐1")

# Mid-tighten: used above allowed-resident must saturate RED, not error.
mod.held_slots = lambda: {0: 200, 1: 201, 2: 202}
publish("1 3 16 3 1 3 0 1\n")
b = mod.sem_block()
check("mid-tighten colour saturates", b["color"], mod.RED)
check("mid-tighten text", b["full_text"], "◱ 3/3")

if fails:
    print("\nFAILURES:", fails)
sys.exit(1 if fails else 0)
