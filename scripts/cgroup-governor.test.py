#!/usr/bin/env python3
"""Exercise cgroup-governor.sh's detection-path functions against fixtures.

    python3 scripts/cgroup-governor.test.py

NO GOVERNOR IS STARTED, and that is the point. The governor's loop is
wall-clock- and cgroup-bound, but the functions the loop calls are not: they
read whatever tree $POOL points at. This suite sources the script (a test seam
before the trap/loop returns early when sourced), overrides $POOL to a
synthetic tree in a tempdir, and calls the functions directly -- so every
assertion is deterministic and the whole run finishes in seconds. The monitor's
ported PSI parser is driven through the same seam.

Covers the three fork-free foundations everything else stands on:
list_build_scopes (including the 07-31 kernfs-st_size trap and the
un-delegated-leaf fallback), the pure-bash PSI parser (including the
leading-zero octal trap), and read_meminfo -- plus code-shape assertions for
the bugs that cannot be reproduced on a real filesystem.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
GOV = HERE / "cgroup-governor.sh"
MON = HERE / "cgroup-pressure-monitor.sh"
# Resolve bash at runtime rather than via `#!/usr/bin/env bash`: the nix build
# sandbox (where this could run as a flake check) has no /usr/bin/env.
BASH = shutil.which("bash")
BASE = Path(tempfile.mkdtemp(prefix="cggov-test."))
OUT = BASE / "out"
OUT.mkdir()

fails = []
passes = []


def check(name, got, want):
    ok = got == want
    (passes if ok else fails).append(name)
    print(f"{'PASS' if ok else 'FAIL'}  {name}: got {got!r}, want {want!r}")


def sh(script, body):
    """Source `script` (stops at its test seam), then run `body` in the same
    shell, so `body` can call the script's functions and read its globals."""
    env = dict(os.environ)
    env["CGGOV_OUTDIR"] = str(OUT)
    env["CGPM_OUTDIR"] = str(OUT)
    p = subprocess.run(
        [BASH, "-c", f'. "{script}" && {body}'],
        env=env, capture_output=True, text=True,
    )
    return p.stdout, p.returncode


# ---------------------------------------------------------------------------
# 1. list_build_scopes against a synthetic pool.
#
# cgroup.procs files are written NON-EMPTY with a real pid (our own), because
# the function must find scopes by READING a pid, never by stat'ing the file:
# on kernfs cgroup.procs always stats as st_size=0, which is the bug that
# silently disabled duties B and C for three days in July. A tmpdir cannot
# reproduce st_size=0 on a non-empty file, so behaviour is tested here and the
# code SHAPE (no `[ -s ]` on cgroup.procs) is asserted further down.
POOL = BASE / "pool"
ME = str(os.getpid())


def scope(slice_name, name, procs=None, freeze="0", memcur=None):
    d = POOL / slice_name / name
    d.mkdir(parents=True)
    if freeze is not None:
        (d / "cgroup.freeze").write_text(freeze + "\n")
    if procs is not None:
        (d / "cgroup.procs").write_text(procs)
    if memcur is not None:
        (d / "memory.current").write_text(memcur + "\n")
    return d


s_live = scope("worktrees-a.slice", "mj-live.scope", procs=ME + "\n",
               memcur="123456789")
scope("worktrees-a.slice", "mj-empty.scope", procs="", memcur="55")
s_frozen = scope("worktrees-a.slice", "mj-frozen.scope", procs=ME + "\n",
                 freeze="1", memcur="777")
scope("worktrees-a.slice", "transient", procs=ME + "\n", memcur="4242")
# The un-delegated leaf: cgroup.procs but NO memory.current -- the state a
# nixos-rebuild switch leaves fleet/transient in (subtree_control cleared).
# The fallback must sum /proc/<pid>/statm instead of reporting nothing.
scope("worktrees-b.slice", "mj-fallback.scope", procs=ME + "\n")
scope("worktrees-b.slice", "mj-nofreeze.scope", procs=ME + "\n", freeze=None,
      memcur="99")
# Never a target: only mj-*.scope and `transient` are freezable.
scope("worktrees-a.slice", "claude-x.scope", procs=ME + "\n", memcur="31337")

body = (
    f'POOL="{POOL}"; list_build_scopes; '
    'for (( k = 0; k < ${#BS_PATH[@]}; k++ )); do '
    'printf "%s\\t%s\\n" "${BS_MEM[$k]}" "${BS_PATH[$k]}"; done'
)
out, rc = sh(GOV, body)
check("list_build_scopes runs clean", rc, 0)
rows = {}
for line in out.splitlines():
    mem, path = line.split("\t")
    rows[Path(path).name] = int(mem)

check("live scope listed with its memory.current", rows.get("mj-live.scope"),
      123456789)
check("empty scope skipped (freezing nothing buys nothing)",
      "mj-empty.scope" in rows, False)
check("frozen scope still listed (thaw_all's orphan sweep depends on it)",
      rows.get("mj-frozen.scope"), 777)
check("transient leaf listed", rows.get("transient"), 4242)
check("un-delegated leaf falls back to summed RSS, not zero/absent",
      rows.get("mj-fallback.scope", 0) > 0, True)
check("scope without cgroup.freeze skipped (not freezable)",
      "mj-nofreeze.scope" in rows, False)
check("claude-*.scope never a candidate (agents are never frozen)",
      "claude-x.scope" in rows, False)

out, _ = sh(GOV, f'POOL="{POOL}"; '
                 f'if is_frozen "{s_frozen}"; then echo frozen; else echo thawed; fi; '
                 f'if is_frozen "{s_live}"; then echo frozen; else echo thawed; fi')
check("is_frozen reports the frozen scope frozen, the live one not",
      out.split(), ["frozen", "thawed"])

# Code-shape assertions, for what a real filesystem cannot simulate. On kernfs
# cgroup.procs stats as size 0 however many pids it holds, so any `[ -s ]`
# guard on it is unconditionally false -- the exact 07-28..07-31 dead-actuator
# bug. A tmpdir CANNOT make a non-empty file stat as 0 bytes, so the behaviour
# tests above would keep passing if someone reintroduced it; pin the source
# instead.
gov_src = GOV.read_text()
mon_src = MON.read_text()
check("governor never tests -s on cgroup.procs (kernfs st_size is always 0)",
      re.search(r"\[ -s [^]]*cgroup\.procs", gov_src) is None, True)
check("STALL path max-scans in bash (no sort|head|cut pipeline)",
      any("sort -rn" in ln.split("#", 1)[0] for ln in gov_src.splitlines()),
      False)
# (pgrep -f and compgen bans moved to scripts/lint-tripwires.py, which covers
# every script and bin rather than just these two files.)

# ---------------------------------------------------------------------------
# 2. The pure-bash PSI parser -- both copies, governor and monitor, driven
#    through the same fixtures so the port cannot drift. The "08"/"09" cases
#    are the octal trap the 10# in the parser exists for: without it,
#    $(( 08 * 100 )) is a bash syntax error ("value too great for base") and
#    the parser dies exactly when pressure reads eight-point-something.
psi_cases = [
    # (file content, want PSI_TEXT, want PSI_CENTI)
    ("some avg10=1.23 avg60=0.50 avg300=0.10 total=1\n"
     "full avg10=18.71 avg60=5.55 avg300=1.00 total=2\n", "18.71", 1871),
    ("full avg10=0.08 avg60=0 avg300=0 total=0\n", "0.08", 8),
    ("full avg10=1.09 avg60=0 avg300=0 total=0\n", "1.09", 109),
    ("full avg10=08.09 avg60=0 avg300=0 total=0\n", "08.09", 809),
    ("full avg10=0.00 avg60=0 avg300=0 total=0\n", "0.00", 0),
    ("full avg10=15.00 avg60=0 avg300=0 total=0\n", "15.00", 1500),
    ("full avg10=14.99 avg60=0 avg300=0 total=0\n", "14.99", 1499),
    ("some avg10=1.23 avg60=0 avg300=0 total=1\n", "0", 0),  # no `full` line
]
for idx, (content, want_text, want_centi) in enumerate(psi_cases):
    f = BASE / f"psi{idx}"
    f.write_text(content)
    for label, script in (("governor", GOV), ("monitor", MON)):
        out, _ = sh(script,
                    f'psi_full_avg10 "{f}"; printf "%s %s" "$PSI_TEXT" "$PSI_CENTI"')
        check(f"{label} psi[{idx}] avg10={want_text}", out,
              f"{want_text} {want_centi}")

out, _ = sh(GOV, f'psi_full_avg10 "{BASE}/no-such-file"; '
                 'printf "%s %s" "$PSI_TEXT" "$PSI_CENTI"')
check("psi parser fails open (0) on a missing file", out, "0 0")

# The threshold the parser's centi values are compared against: "15.00" >= 15
# must fire and "14.99" >= 15 must not, which the pre-scaled THRESH_CENTI
# guarantees (1500 >= 1500, 1499 < 1500 -- see cases 5 and 6 above).
out, _ = sh(MON, 'printf "%s" "$THRESH_CENTI"')
check("monitor pre-scales its integer threshold to centi", out,
      str(int(os.environ.get("CGPM_THRESH", "15")) * 100))

# ---------------------------------------------------------------------------
# 3. read_meminfo against a fixture (the optional-path argument exists for
#    exactly this; the governor itself passes nothing and reads /proc/meminfo).
mi = BASE / "meminfo"
mi.write_text(
    "MemTotal:       30604128 kB\n"
    "MemFree:         1837056 kB\n"
    "MemAvailable:   10904128 kB\n"
    "Buffers:          123456 kB\n"
)
out, _ = sh(GOV, f'read_meminfo "{mi}"; printf "%s %s" "$MEMFREE_MB" "$MEMAVAIL_MB"')
check("read_meminfo parses MemFree/MemAvailable to MiB", out, "1794 10648")

trunc = BASE / "meminfo-short"
trunc.write_text("MemTotal:       30604128 kB\n")
out, _ = sh(GOV, f'read_meminfo "{trunc}"; printf "%s %s" "$MEMFREE_MB" "$MEMAVAIL_MB"')
check("read_meminfo fails open (99999 = never TIGHT) on a truncated file",
      out, "99999 99999")

# ---------------------------------------------------------------------------
if fails:
    print("\nFAILURES:", fails)
else:
    shutil.rmtree(BASE, ignore_errors=True)
    print(f"\nall {len(passes)} assertions passed")
sys.exit(1 if fails else 0)
