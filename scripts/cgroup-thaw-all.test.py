#!/usr/bin/env python3
"""End-to-end test for cgroup-thaw-all against a synthetic pool.

The script is the governor's ExecStopPost — the thaw of last resort. A frozen
build it fails to thaw is a hung build, so its sweep logic (which scopes are
touched, which are deliberately left alone) gets a real behavioural test.
Fast, deterministic, sandbox-safe: KX_POOL points at a tempdir.
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "cgroup-thaw-all.sh"
BASH = shutil.which("bash")
POOL = Path(tempfile.mkdtemp(prefix="thaw-test."))

fails = []
passes = []


def check(name, got, want):
    ok = got == want
    (passes if ok else fails).append(name)
    print(f"{'PASS' if ok else 'FAIL'}  {name}: got {got!r}, want {want!r}")


def scope(path, frozen):
    d = POOL / path
    d.mkdir(parents=True, exist_ok=True)
    (d / "cgroup.freeze").write_text("1\n" if frozen else "0\n")
    return d


frozen_mj = scope("worktrees-alpha.slice/mj-alpha.scope", frozen=True)
thawed_mj = scope("worktrees-beta.slice/mj-beta.scope", frozen=False)
frozen_transient = scope("worktrees-agents.slice/transient", frozen=True)
# The fleet is NEVER swept: a frozen fleet came from something else, and
# silently undoing it would hide a real problem (per the script header).
frozen_fleet = scope("worktrees-agents.slice/fleet", frozen=True)

r = subprocess.run(
    [BASH, str(SCRIPT)],
    env={"KX_POOL": str(POOL), "PATH": "/run/current-system/sw/bin:/usr/bin:/bin"},
    capture_output=True,
    text=True,
)
check("exits 0", r.returncode, 0)
check("frozen mj scope thawed",
      (frozen_mj / "cgroup.freeze").read_text().strip(), "0")
check("already-thawed scope untouched",
      (thawed_mj / "cgroup.freeze").read_text().strip(), "0")
check("frozen transient leaf thawed",
      (frozen_transient / "cgroup.freeze").read_text().strip(), "0")
check("fleet deliberately NOT thawed",
      (frozen_fleet / "cgroup.freeze").read_text().strip(), "1")
check("summary line counts", "2 thawed, 0 FAILED, of 3" in r.stdout, True)

# The failure path: a cgroup.freeze the script cannot write must be REPORTED
# and must fail the run (this is ExecStopPost -- the thaw of last resort; a
# silent failure here is a permanently hung build). Simulated with a
# read-only file, which makes bash's redirection fail the same way a
# delegation loss would.
POOL2 = Path(tempfile.mkdtemp(prefix="thaw-test-fail."))
stuck = POOL2 / "worktrees-gamma.slice/mj-gamma.scope"
stuck.mkdir(parents=True)
(stuck / "cgroup.freeze").write_text("1\n")
(stuck / "cgroup.freeze").chmod(0o444)
r2 = subprocess.run(
    [BASH, str(SCRIPT)],
    env={"KX_POOL": str(POOL2), "PATH": "/run/current-system/sw/bin:/usr/bin:/bin"},
    capture_output=True,
    text=True,
)
check("failed thaw exits non-zero", r2.returncode, 1)
check("failed thaw is named on stderr", "FAILED to thaw mj-gamma" in r2.stderr, True)
check("failed thaw counted in summary", "0 thawed, 1 FAILED, of 1" in r2.stdout, True)
(stuck / "cgroup.freeze").chmod(0o644)
shutil.rmtree(POOL2, ignore_errors=True)

if fails:
    print("\nFAILURES:", fails)
    print("stdout:", r.stdout)
    print("stderr:", r.stderr)
else:
    shutil.rmtree(POOL, ignore_errors=True)
sys.exit(1 if fails else 0)
