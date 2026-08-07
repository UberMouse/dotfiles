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

Also covers THE TICK DECISION, extracted above the seam as pure functions
(classify_state, brake_step and friends -- the governor's analogue of the
controller's decide() split): classification boundaries, the brake's
arm -> re-measure -> escalate-or-release cycle, deadline enforcement, the
LAG watchdog, the duty-B cap window, and the wall-clock clamp.
"""
import os
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

sys.path.insert(0, str(HERE))
from testlib import check, summary  # noqa: E402


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

# Code-shape assertion, for what a real filesystem cannot simulate: a tmpdir
# cannot make the fork cost of a pipeline visible, so pin the source. (The
# `[ -s ]`-on-cgroup.procs kernfs ban moved repo-wide into
# scripts/lint-tripwires.py, alongside the pgrep -f and compgen bans.)
gov_src = GOV.read_text()
check("STALL path max-scans in bash (no sort|head|cut pipeline)",
      any("sort -rn" in ln.split("#", 1)[0] for ln in gov_src.splitlines()),
      False)

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
# 3. The ACTUATORS' failure paths. freeze_scope/thaw_scope must never fail
#    silently, and a failed thaw must be RETRIED: the old code dropped the
#    frozen_since entry unconditionally, so a refused write left the scope
#    frozen with nothing left to retry it (the deadline enforcer iterates
#    frozen_since). A read-only cgroup.freeze simulates the refusal the same
#    way the thaw-all suite does.


def gov_log():
    try:
        return (OUT / "governor.log").read_text()
    except OSError:
        return ""


def reset_log():
    (OUT / "governor.log").write_text("")


act = scope("worktrees-act.slice", "mj-act.scope", procs=ME + "\n",
            memcur="1048576")

# Happy path: freeze records frozen_since, thaw clears it, both log.
reset_log()
out, rc = sh(GOV, f'POOL="{POOL}"; freeze_scope "{act}" test; '
                  f'printf "%s/%s/" "$(cat "{act}/cgroup.freeze")" '
                  '"${#frozen_since[@]}"; '
                  f'thaw_scope "{act}" test; '
                  f'printf "%s/%s" "$(cat "{act}/cgroup.freeze")" '
                  '"${#frozen_since[@]}"')
check("freeze->thaw round trip (freeze state and frozen_since bookkeeping)",
      out, "1/1/0/0")
check("round trip logged both actions",
      "FREEZE|" in gov_log() and "THAW|" in gov_log(), True)

# Failure path: the write is refused. The scope must stay in frozen_since
# (so the next tick retries) and the log must say FAILED.
(act / "cgroup.freeze").write_text("1\n")
(act / "cgroup.freeze").chmod(0o444)
reset_log()
out, rc = sh(GOV, f'POOL="{POOL}"; frozen_since["{act}"]=123; '
                  f'thaw_scope "{act}" test; '
                  'printf "%s" "${#frozen_since[@]}"')
check("failed thaw KEEPS the frozen_since entry (retry next tick)", out, "1")
check("failed thaw is loud", "THAW|FAILED" in gov_log(), True)

# A refused freeze must not look like "cap not exceeded": it logs FAILED and
# records nothing to thaw later.
(act / "cgroup.freeze").chmod(0o644)
(act / "cgroup.freeze").write_text("0\n")
(act / "cgroup.freeze").chmod(0o444)
reset_log()
out, rc = sh(GOV, f'POOL="{POOL}"; freeze_scope "{act}" test; '
                  'printf "%s" "${#frozen_since[@]}"')
check("failed freeze records no frozen_since entry", out, "0")
check("failed freeze is loud", "FREEZE|FAILED" in gov_log(), True)
(act / "cgroup.freeze").chmod(0o644)

# A vanished scope needs no thaw and no retry: entry dropped, no FAILED noise.
reset_log()
out, rc = sh(GOV, f'POOL="{POOL}"; frozen_since["{POOL}/gone.scope"]=123; '
                  f'thaw_scope "{POOL}/gone.scope" test; '
                  'printf "%s" "${#frozen_since[@]}"')
check("vanished scope dropped from frozen_since without noise", out, "0")
check("vanished scope logs no FAILED", "FAILED" in gov_log(), False)

# ---------------------------------------------------------------------------
# 4. THE TICK DECISION -- the pure functions the loop below the seam threads
#    its state through (the governor's analogue of the controller's decide()).
#    Thresholds are pinned inside each body so the machine's CGGOV_* env can
#    never skew a boundary assertion.

# classify_state: every boundary, both TIGHT clauses, and STALL's precedence.
# Thresholds pinned: STALL_CENTI=1500, LOW_FREE_MB=1536, POOL_CENTI=2500.
cls_cases = [
    ((1500, 0, 99999), "STALL", "dm at the stall line is a STALL (>=)"),
    ((1499, 0, 99999), "NORMAL", "dm one centi under the stall line is NORMAL"),
    ((0, 0, 1535), "TIGHT", "free one MiB under the floor is TIGHT"),
    ((0, 0, 1536), "NORMAL", "free at the floor is NORMAL (strict <)"),
    ((0, 2500, 99999), "TIGHT", "pool psi at its line is TIGHT (the 07-29 clause)"),
    ((0, 2499, 99999), "NORMAL", "pool psi one centi under its line is NORMAL"),
    ((1499, 2500, 1535), "TIGHT", "either TIGHT clause suffices"),
    ((1500, 2500, 100), "STALL", "STALL outranks TIGHT when both fire"),
    ((0, 0, "junk"), "NORMAL", "non-numeric free fails open to the pool clause"),
]
for (dm_c, pm_c, free), want, why in cls_cases:
    out, rc = sh(GOV, 'STALL_CENTI=1500; LOW_FREE_MB=1536; POOL_CENTI=2500; '
                      f'classify_state "{dm_c}" "{pm_c}" "{free}"; '
                      'printf "%s" "$CLASSIFY_STATE"')
    check(f"classify_state: {why}", (out, rc), (want, 0))

# elapsed_since: the wall-clock clamp itself. EPOCHSECONDS is wall time on a
# VMware guest, so a backward jump must read as "no time passed", never as a
# negative age.
out, _ = sh(GOV, 'elapsed_since 10 25; printf "%s" "$ELAPSED"')
check("elapsed_since: forward delta", out, "15")
out, _ = sh(GOV, 'elapsed_since 5000 1000; printf "%s" "$ELAPSED"')
check("elapsed_since: backward wall jump clamps to zero", out, "0")

# brake_step: all four actions, from all four input shapes.
brake_cases = [
    (('""', 0, 1000, 0), "reclaim-arm 1",
     "cold stall reclaims and arms the re-measure"),
    (('""', 1, 1005, 1000), "escalate 0",
     "armed and still stalling escalates (and consumes the flag)"),
    (('"/x/mj-a.scope"', 0, 1000, 999), "hold 0",
     "active brake holds -- never stacks a second freeze"),
    (('""', 0, 1010, 1000), "brake 0",
     "reclaim on cooldown goes straight to the brake"),
    (('""', 0, 1000, 5000), "brake 0",
     "backward wall jump reads as cooldown-not-elapsed (clamp)"),
]
for (scope, armed, now, last_rec), want, why in brake_cases:
    out, rc = sh(GOV, 'RECLAIM_COOL=30; '
                      f'brake_step {scope} {armed} {now} {last_rec}; '
                      'printf "%s %s" "$BRAKE_ACTION" "$BRAKE_ARMED_NEXT"')
    check(f"brake_step: {why}", (out, rc), (want, 0))

# brake_recovered: the deferred re-measure's verdict.
out, _ = sh(GOV, 'STALL_CENTI=1500; '
                 'brake_recovered 1 1499 && printf recovered || printf stalled')
check("brake_recovered: armed and back under the line releases", out, "recovered")
out, _ = sh(GOV, 'STALL_CENTI=1500; '
                 'brake_recovered 1 1500 && printf recovered || printf stalled')
check("brake_recovered: armed but still at the line does not", out, "stalled")
out, _ = sh(GOV, 'STALL_CENTI=1500; '
                 'brake_recovered 0 0 && printf recovered || printf idle')
check("brake_recovered: nothing armed, nothing to release", out, "idle")

# The full cycle, state threaded tick to tick exactly as the loop does it.
out, _ = sh(GOV, 'RECLAIM_COOL=30; STALL_CENTI=1500; '
                 'brake_step "" 0 1000 0; a1=$BRAKE_ACTION; armed=$BRAKE_ARMED_NEXT; '
                 'brake_recovered "$armed" 1400 && r=released || r=stalled; '
                 'printf "%s %s" "$a1" "$r"')
check("brake cycle: arm -> next tick recovered -> release, no freeze",
      out, "reclaim-arm released")
out, _ = sh(GOV, 'RECLAIM_COOL=30; STALL_CENTI=1500; '
                 'brake_step "" 0 1000 0; a1=$BRAKE_ACTION; armed=$BRAKE_ARMED_NEXT; '
                 'brake_recovered "$armed" 1600 || true; '
                 'brake_step "" "$armed" 1005 1000; '
                 'printf "%s %s %s" "$a1" "$BRAKE_ACTION" "$BRAKE_ARMED_NEXT"')
check("brake cycle: arm -> still stalled next tick -> escalate",
      out, "reclaim-arm escalate 0")

# freeze_deadline_due: the MAX_FREEZE_SECS ceiling that no pressure reading
# can override.
out, _ = sh(GOV, 'MAX_FREEZE_SECS=60; '
                 'freeze_deadline_due 1000 1060 && v=due || v=hold; '
                 'printf "%s %s" "$v" "$DEADLINE_HELD"')
check("freeze deadline: fires exactly at the ceiling", out, "due 60")
out, _ = sh(GOV, 'MAX_FREEZE_SECS=60; '
                 'freeze_deadline_due 1000 1059 && v=due || v=hold; '
                 'printf "%s %s" "$v" "$DEADLINE_HELD"')
check("freeze deadline: holds one second before it", out, "hold 59")
out, _ = sh(GOV, 'MAX_FREEZE_SECS=60; '
                 'freeze_deadline_due 2000 1000 && v=due || v=hold; '
                 'printf "%s %s" "$v" "$DEADLINE_HELD"')
check("freeze deadline: backward jump defers (held clamps to 0), never fires negative",
      out, "hold 0")

# brake_release_due: the short brake deadline the top of the loop enforces.
out, _ = sh(GOV, 'brake_release_due "/x" 100 100 && printf due || printf hold')
check("brake release: due exactly at the deadline", out, "due")
out, _ = sh(GOV, 'brake_release_due "/x" 100 99 && printf due || printf hold')
check("brake release: holds before the deadline", out, "hold")
out, _ = sh(GOV, 'brake_release_due "" 100 5000 && printf due || printf idle')
check("brake release: no active brake, nothing due", out, "idle")

# lag_check: the blind-spot alarm.
out, _ = sh(GOV, 'LAG_WARN=15; lag_check 0 1000 && v=warn || v=quiet; '
                 'printf "%s %s" "$v" "$LAG"')
check("lag: first tick never warns (no previous tick to overrun)", out, "quiet 0")
out, _ = sh(GOV, 'LAG_WARN=15; lag_check 100 115 && v=warn || v=quiet; '
                 'printf "%s %s" "$v" "$LAG"')
check("lag: warns exactly at LAG_WARN", out, "warn 15")
out, _ = sh(GOV, 'LAG_WARN=15; lag_check 100 114 && v=warn || v=quiet; '
                 'printf "%s %s" "$v" "$LAG"')
check("lag: quiet one second under", out, "quiet 14")
out, _ = sh(GOV, 'LAG_WARN=15; lag_check 200 100 && v=warn || v=quiet; '
                 'printf "%s %s" "$v" "$LAG"')
check("lag: backward jump reads as no lag, not a huge negative", out, "quiet 0")

# heavy_filter: the duty-B candidate cut at HEAVY_MB, boundary inclusive.
out, _ = sh(GOV, 'HEAVY_MB=256; '
                 'BS_MEM=(268435456 268435455 999999999); BS_PATH=(big small huge); '
                 'heavy_filter; printf "%s" "${HEAVY[*]}"')
check("heavy_filter: >= HEAVY_MB stays, one byte under is left alone",
      out, "big huge")

# cap_plan: the rotated victim window. n=5, maxconc=3 -> 2 victims.
out, _ = sh(GOV, 'cap_plan 0 3 a b c d e; '
                 'printf "%s|%s" "${CAP_FREEZE[*]}" "${CAP_RUN[*]}"')
check("cap_plan: rot=0 freezes the head of the window", out, "a b|c d e")
out, _ = sh(GOV, 'cap_plan 1 3 a b c d e; '
                 'printf "%s|%s" "${CAP_FREEZE[*]}" "${CAP_RUN[*]}"')
check("cap_plan: rot=1 rotates the window (yesterday's victim runs)",
      out, "b c|d e a")
out, _ = sh(GOV, 'cap_plan 7 3 a b c d e; '
                 'printf "%s|%s" "${CAP_FREEZE[*]}" "${CAP_RUN[*]}"')
check("cap_plan: rot wraps modulo n", out, "c d|e a b")
out, _ = sh(GOV, 'cap_plan 0 3 a b c d; '
                 'printf "%s|%s" "${CAP_FREEZE[*]}" "${CAP_RUN[*]}"')
check("cap_plan: one over the cap freezes exactly one", out, "a|b c d")

# biggest_scope: duty C's victim pick over the BS arrays.
out, _ = sh(GOV, 'BS_MEM=(5 99 7); BS_PATH=(a b c); biggest_scope; '
                 'printf "%s" "$BIGGEST"')
check("biggest_scope: picks the max", out, "b")
out, _ = sh(GOV, 'BS_MEM=(5 5); BS_PATH=(first second); biggest_scope; '
                 'printf "%s" "$BIGGEST"')
check("biggest_scope: ties keep glob order (stable victim across ticks)",
      out, "first")
out, _ = sh(GOV, 'BS_MEM=(); BS_PATH=(); biggest_scope; '
                 'printf "[%s]" "$BIGGEST"')
check("biggest_scope: empty pool yields no victim", out, "[]")

# ---------------------------------------------------------------------------
# 5. delegate_subtree -- the ONE subtree_control writer (the two hand-rolled
#    sites had already drifted: +memory at one, +memory +pids at the other).
DELEG = BASE / "deleg"

out, _ = sh(GOV, f'mkdir -p "{DELEG}/ok" && printf "memory pids" > "{DELEG}/ok/cgroup.subtree_control"; '
                 f'delegate_subtree "{DELEG}/ok"; rc=$?; '
                 f'printf "%s %s" "$rc" "$(cat "{DELEG}/ok/cgroup.subtree_control")"')
check("delegate_subtree: already delegated -> 0, file untouched",
      out, "0 memory pids")

out, _ = sh(GOV, f'mkdir -p "{DELEG}/empty" && : > "{DELEG}/empty/cgroup.subtree_control"; '
                 f'delegate_subtree "{DELEG}/empty"; rc=$?; '
                 f'printf "%s %s" "$rc" "$(cat "{DELEG}/empty/cgroup.subtree_control")"')
check("delegate_subtree: EMPTY file (the post-rebuild state) is repaired -> 2",
      out, "2 +memory +pids")

ro = DELEG / "ro"
ro.mkdir(parents=True)
(ro / "cgroup.subtree_control").write_text("")
(ro / "cgroup.subtree_control").chmod(0o444)
out, _ = sh(GOV, f'delegate_subtree "{ro}"; printf "%s" "$?"')
check("delegate_subtree: refused write -> 1 (no-internal-process rule)",
      out, "1")
(ro / "cgroup.subtree_control").chmod(0o644)

out, _ = sh(GOV, f'delegate_subtree "{DELEG}/no-such-cgroup"; printf "%s" "$?"')
check("delegate_subtree: missing subtree_control -> 1", out, "1")

# ensure_delegation's logging contract on top of the shared writer: a repair
# is logged, a refusal is logged ONCE (not every five seconds).
reset_log()
out, _ = sh(GOV, f'mkdir -p "{DELEG}/fleet" && : > "{DELEG}/fleet/cgroup.subtree_control"; '
                 f'FLEET="{DELEG}/fleet"; ensure_delegation')
check("ensure_delegation: repair is logged", "DELEGATE|re-enabled" in gov_log(), True)
reset_log()
(ro / "cgroup.subtree_control").chmod(0o444)
out, _ = sh(GOV, f'FLEET="{ro}"; ensure_delegation; ensure_delegation; '
                 'printf "%s" "$deleg_warned"')
check("ensure_delegation: refusal warns once, then stays quiet",
      (gov_log().count("DELEGATE|cannot"), out), (1, "1"))
(ro / "cgroup.subtree_control").chmod(0o644)

summary(cleanup_dir=BASE)
