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


def sh_stderr(script, body):
    """As sh(), but returns STDERR -- for asserting that a read failure on the
    detection path stays silent rather than logging once per tick."""
    env = dict(os.environ)
    env["CGGOV_OUTDIR"] = str(OUT)
    env["CGPM_OUTDIR"] = str(OUT)
    p = subprocess.run(
        [BASH, "-c", f'. "{script}" && {body}'],
        env=env, capture_output=True, text=True,
    )
    return p.stderr.strip()


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


def scope(slice_name, name, procs=None, freeze="0", memcur=None, populated=None):
    d = POOL / slice_name / name
    d.mkdir(parents=True)
    if freeze is not None:
        (d / "cgroup.freeze").write_text(freeze + "\n")
    if procs is not None:
        (d / "cgroup.procs").write_text(procs)
    if memcur is not None:
        (d / "memory.current").write_text(memcur + "\n")
    if populated is not None:
        (d / "cgroup.events").write_text(f"populated {populated}\nfrozen 0\n")
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
# The per-worktree split (2026-09-23): a `transient` PARENT holding no pids
# itself, populated through two worktree leaves. The cap counts the leaves;
# the brake ranks the parent whole.
scope("worktrees-c.slice", "transient", procs="", memcur="9000", populated="1")
scope("worktrees-c.slice", "transient/wt-one", procs=ME + "\n", memcur="5000")
scope("worktrees-c.slice", "transient/wt-two", procs=ME + "\n", memcur="4000")
# A parent whose leaves have all finished: nothing to brake.
scope("worktrees-d.slice", "transient", procs="", memcur="0", populated="0")

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
check("per-worktree transient leaves are cap candidates",
      (rows.get("wt-one"), rows.get("wt-two")), (5000, 4000))
check("a transient PARENT with no direct pids is not a cap candidate",
      any(p.endswith(("worktrees-c.slice/transient", "worktrees-d.slice/transient"))
          for p in out.split()), False)

# A leaf that has no memory.current (delegation cleared by a switch) must read
# SILENTLY: `read < f 2>/dev/null` opens f before stderr is redirected, and
# the governor journal filled with one error per candidate per tick that way
# (2026-09-23). The redirect goes BEFORE the `<`.
check("scope_mem on a cgroup without memory.current is silent",
      sh_stderr(GOV, f'scope_mem "{BASE}/no-such-cgroup"'), "")

# list_brake_targets: mj scopes plus each slice's WHOLE transient parent.
out, rc = sh(GOV, f'POOL="{POOL}"; list_brake_targets; '
                  'for (( k = 0; k < ${#BK_PATH[@]}; k++ )); do '
                  'printf "%s\\t%s\\n" "${BK_MEM[$k]}" "${BK_PATH[$k]}"; done')
check("list_brake_targets runs clean", rc, 0)
brk = {str(Path(ln.split("\t")[1]).relative_to(POOL)): int(ln.split("\t")[0])
       for ln in out.splitlines()}
check("brake: a transient parent populated via its leaves is ranked whole",
      brk.get("worktrees-c.slice/transient"), 9000)
check("brake: a pre-split transient holding pids directly still counts",
      brk.get("worktrees-a.slice/transient"), 4242)
check("brake: the worktree leaves themselves are not brake candidates",
      [k for k in brk if "/transient/" in k], [])
check("brake: an unpopulated transient parent is skipped",
      "worktrees-d.slice/transient" in brk, False)
check("brake: mj scopes still candidates, empty ones and claude-* not",
      ("worktrees-a.slice/mj-live.scope" in brk,
       "worktrees-a.slice/mj-empty.scope" in brk,
       "worktrees-a.slice/claude-x.scope" in brk), (True, False, False))

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

# A missing file keeps failing OPEN in the globals -- an absent pool cgroup has
# no tasks to brake, and every caller threshold is ">=", so 0 trips nothing.
out, _ = sh(GOV, f'psi_full_avg10 "{BASE}/no-such-file"; '
                 'printf "%s %s" "$PSI_TEXT" "$PSI_CENTI"')
check("psi parser fails open (0) on a missing file", out, "0 0")

# ...but the RETURN CODE distinguishes "could not read" from "calm", which the
# globals cannot. The governor's pool_blind warn-once is built on this.
_, rc = sh(GOV, f'psi_full_avg10 "{BASE}/no-such-file"')
check("psi parser returns 1 on a missing file", str(rc), "1")
_, rc = sh(GOV, f'psi_full_avg10 "{BASE}/psi0"')
check("psi parser returns 0 on a readable file", str(rc), "0")
# A `full`-less file is READ successfully -- 0% with rc=0, not a read failure.
_, rc = sh(GOV, f'psi_full_avg10 "{BASE}/psi{len(psi_cases) - 1}"')
check("psi parser returns 0 on a readable file with no `full` line", str(rc), "0")

# THE 2026-08-17 REGRESSION GUARD. `2>/dev/null` must sit AFTER the `< "$1"` in
# source order so bash has already redirected stderr when the input open fails;
# written the other way it printed a redirect error per tick for as long as the
# pool slice was absent (190 lines in 16 minutes). Assert on actual stderr, not
# on the source text, so any future rewrite that reintroduces the noise fails.
err = sh_stderr(GOV, f'psi_full_avg10 "{BASE}/no-such-file"')
check("psi parser is silent on a missing file", err, "")

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

# brake_step: every action, from every input shape. Args are
# brake_count armed now last_reclaim last_add; INTERVAL pinned at 5.
brake_cases = [
    ((0, 0, 1000, 0, 0), "reclaim-arm 1",
     "cold stall reclaims and arms the re-measure"),
    ((0, 1, 1005, 1000, 0), "escalate 0",
     "armed and still stalling escalates (and consumes the flag)"),
    ((1, 0, 1004, 999, 1000), "hold 0",
     "a victim added under one tick ago gets that tick before judging"),
    ((1, 0, 1005, 999, 1000), "add 0",
     "still stalled a whole tick after the last victim adds the next"),
    ((2, 0, 1000, 0, 5000), "hold 0",
     "backward wall jump on last_add reads as not-yet-a-tick (clamp)"),
    ((0, 0, 1010, 1000, 0), "brake 0",
     "reclaim on cooldown goes straight to the brake"),
    ((0, 0, 1000, 5000, 0), "brake 0",
     "backward wall jump reads as cooldown-not-elapsed (clamp)"),
]
for (count, armed, now, last_rec, last_add), want, why in brake_cases:
    out, rc = sh(GOV, 'RECLAIM_COOL=30; INTERVAL=5; '
                      f'brake_step {count} {armed} {now} {last_rec} {last_add}; '
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
                 'brake_step 0 0 1000 0 0; a1=$BRAKE_ACTION; armed=$BRAKE_ARMED_NEXT; '
                 'brake_recovered "$armed" 1400 && r=released || r=stalled; '
                 'printf "%s %s" "$a1" "$r"')
check("brake cycle: arm -> next tick recovered -> release, no freeze",
      out, "reclaim-arm released")
out, _ = sh(GOV, 'RECLAIM_COOL=30; STALL_CENTI=1500; '
                 'brake_step 0 0 1000 0 0; a1=$BRAKE_ACTION; armed=$BRAKE_ARMED_NEXT; '
                 'brake_recovered "$armed" 1600 || true; '
                 'brake_step 0 "$armed" 1005 1000 0; '
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

# brake_release_due: HOLD TILL CLEAR (2026-09-23). The brake set releases when
# the desktop is back under the stall line AND the first victim has been held
# FREEZE_SECS -- never on a timer while the desktop is still stalled (the 09-23
# freeze/thaw/re-stall loop). Args: brake_count dm_c now brake_since.
for args, want, why in [
    ("1 1499 1003 1000", "due", "under the line after the minimum hold releases"),
    ("1 1500 1003 1000", "hold", "still AT the stall line keeps holding"),
    ("3 1500 1900 1000", "hold", "no timer: still stalled 900 s later still holds"),
    ("1 1499 1002 1000", "hold", "clear, but inside the minimum hold, waits"),
    ("1 junk 1003 1000", "hold", "a non-numeric reading never releases"),
    ("1 1499 1000 2000", "hold", "backward wall jump reads as not-yet-held (clamp)"),
    ("0 0 5000 0", "idle", "no brake held, nothing to release"),
]:
    out, _ = sh(GOV, 'STALL_CENTI=1500; FREEZE_SECS=3; '
                     f'brake_release_due {args} && printf due || '
                     f'{{ [ "{args.split()[0]}" = 0 ] && printf idle || printf hold; }}')
    check(f"brake release: {why}", out, want)

# brake_prune: the ONE reconciliation of brake_set against frozen_since.
out, _ = sh(GOV, 'frozen_since=([/a]=100); brake_set=([/a]=1 [/b]=1); '
                 'brake_since=100; brake_last_add=105; brake_prune; '
                 'printf "%s|%s|%s" "${!brake_set[*]}" "$brake_since" "$brake_last_add"')
check("brake_prune: drops a victim thawed elsewhere, keeps the storm clocks",
      out, "/a|100|105")
out, _ = sh(GOV, 'frozen_since=(); brake_set=([/a]=1); '
                 'brake_since=100; brake_last_add=105; brake_prune; '
                 'printf "%s|%s|%s" "${#brake_set[@]}" "$brake_since" "$brake_last_add"')
check("brake_prune: an emptied set resets the storm clocks", out, "0|0|0")

# cap_release_due: NORMAL must HOLD before the cap lets go (09-23's 5-20 s flap).
for args, want, why in [
    ("1000 1019", "hold", "one second short of CLEAR_SECS holds"),
    ("1000 1020", "due", "releases exactly at CLEAR_SECS"),
    ("2000 1000", "hold", "backward wall jump reads as not-yet-clear (clamp)"),
]:
    out, _ = sh(GOV, f'CLEAR_SECS=20; cap_release_due {args} && printf due || printf hold')
    check(f"cap release: {why}", out, want)
out, _ = sh(GOV, 'printf "%s" "$CLEAR_SECS"')
check("cap release: CLEAR_SECS defaults to ROTATE_SECS",
      out, os.environ.get("CGGOV_CLEAR_SECS", os.environ.get("CGGOV_ROTATE_SECS", "20")))

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

# next_victim: duty C's escalating pick over the BK arrays -- the biggest
# candidate not already held.
out, _ = sh(GOV, 'BK_MEM=(5 99 7); BK_PATH=(a b c); next_victim; '
                 'printf "%s" "$NEXT_VICTIM"')
check("next_victim: picks the max", out, "b")
out, _ = sh(GOV, 'BK_MEM=(5 99 7); BK_PATH=(a b c); next_victim b; '
                 'printf "%s" "$NEXT_VICTIM"')
check("next_victim: escalation skips what is already held", out, "c")
out, _ = sh(GOV, 'BK_MEM=(5 99 7); BK_PATH=(a b c); next_victim a b c; '
                 'printf "[%s]" "$NEXT_VICTIM"')
check("next_victim: everything held yields no victim", out, "[]")
out, _ = sh(GOV, 'BK_MEM=(5 5); BK_PATH=(first second); next_victim; '
                 'printf "%s" "$NEXT_VICTIM"')
check("next_victim: ties keep glob order (stable victim across ticks)",
      out, "first")
out, _ = sh(GOV, 'BK_MEM=(); BK_PATH=(); next_victim; '
                 'printf "[%s]" "$NEXT_VICTIM"')
check("next_victim: empty pool yields no victim", out, "[]")

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

# ---------------------------------------------------------------------------
# 6. DUTY A's EFFECTIVENESS GATE (2026-09-14). Reclaiming the agents slice is
#    only worth its sys time while the pages it evicts STAY evicted; on 09-14
#    anon refaults tracked steals page for page. Every unreadable shape must
#    read as "useful", so a blind gate keeps the pre-gate behaviour.

# read_reclaim_counters: fork-free, stops at pgsteal (which follows the refault
# counter in the kernel's key order).
stat = BASE / "agents-memory.stat"
stat.write_text(
    "anon 3374104576\nfile 1001103360\n"
    "workingset_refault_anon 16749231\nworkingset_refault_file 14659485\n"
    "pgscan 75628334\npgsteal 57387177\npgsteal_kswapd 3641964\n"
)
out, _ = sh(GOV, f'read_reclaim_counters "{stat}"; '
                 'printf "%s %s" "$RC_REFAULT" "$RC_STEAL"')
check("read_reclaim_counters: refault_anon and pgsteal", out, "16749231 57387177")
out, _ = sh(GOV, f'read_reclaim_counters "{BASE}/no-such-stat"; '
                 'printf "[%s|%s]" "$RC_REFAULT" "$RC_STEAL"')
check("read_reclaim_counters: missing memory.stat leaves both empty",
      out, "[|]")
err = sh_stderr(GOV, f'read_reclaim_counters "{BASE}/no-such-stat"')
check("read_reclaim_counters: silent on a missing file (runs every tick)",
      err, "")
junk = BASE / "junk-memory.stat"
junk.write_text("workingset_refault_anon 12x\npgsteal 5\n")
out, _ = sh(GOV, f'read_reclaim_counters "{junk}"; '
                 'printf "[%s|%s]" "$RC_REFAULT" "$RC_STEAL"')
check("read_reclaim_counters: non-numeric value reads as not read",
      out, "[|5]")

# reclaim_useful: THRASH_PCT=90, THRASH_MIN_STEAL=1000 pinned in every body.
useful_cases = [
    (("0", "0", "9500", "10000"), "0 95", "refaults at 95% of steal: thrash, skip"),
    (("0", "0", "1000", "10000"), "1 10", "cold reclaim (10%) proceeds"),
    (("0", "0", "9000", "10000"), "0 90", "exactly at the bar is thrash (>=)"),
    (("0", "0", "8999", "10000"), "1 89", "one page under the bar proceeds"),
    (("100", "100", "50", "10000"), "1 -", "refault counter went backwards: proceed"),
    (("0", "20000", "9500", "10000"), "1 -", "steal counter went backwards: proceed"),
    (("5", "7", "5", "7"), "1 -", "zero steal proceeds (no ratio at all)"),
    (("0", "0", "999", "999"), "1 100", "steal under the floor proceeds, ratio still logged"),
    (("", "", "9500", "10000"), "1 -", "first tick (no previous sample) proceeds"),
    (("0", "0", "", ""), "1 -", "missing memory.stat proceeds"),
]
for (pr, ps, cr, cs), want, why in useful_cases:
    out, rc = sh(GOV, 'THRASH_PCT=90; THRASH_MIN_STEAL=1000; '
                      f'reclaim_useful "{pr}" "{ps}" "{cr}" "{cs}"; '
                      'printf "%s %s" "$RECLAIM_USEFUL" "$REFAULT_PCT"')
    check(f"reclaim_useful: {why}", (out, rc), (want, 0))
out, _ = sh(GOV, 'THRASH_PCT=0; THRASH_MIN_STEAL=0; '
                 'reclaim_useful 0 0 9500 10000; '
                 'printf "%s %s %s %s" "$RECLAIM_USEFUL" "$REFAULT_PCT" '
                 '"$REFAULT_DELTA" "$STEAL_DELTA"')
check("reclaim_useful: gate OFF (log-only) never skips, still measures",
      out, "1 95 9500 10000")
out, _ = sh(GOV, 'printf "%s %s" "$THRASH_PCT" "$THRASH_MIN_STEAL"')
check("thrash gate ships OFF by default (log-only until calibrated)",
      out, f'{os.environ.get("CGGOV_THRASH_PCT", "0")} '
           f'{os.environ.get("CGGOV_THRASH_MIN_STEAL", "0")}')

# duty_a_step: cooldown outranks the gate; a skip logs at most once per cooldown.
duty_cases = [
    (("0", "0", "1000", "1"), "reclaim", "due and useful reclaims"),
    (("990", "0", "1000", "1"), "cooldown", "inside RECLAIM_COOL waits"),
    (("990", "0", "1000", "0"), "cooldown", "cooldown outranks the thrash verdict"),
    (("0", "0", "1000", "0"), "skip-log", "due but thrashing skips, loudly"),
    (("0", "990", "1000", "0"), "skip", "a repeat skip inside the log cooldown is quiet"),
    (("5000", "0", "1000", "1"), "cooldown", "backward wall jump reads as cooldown"),
]
for (lr, ll, now, useful), want, why in duty_cases:
    out, rc = sh(GOV, 'RECLAIM_COOL=30; '
                      f'duty_a_step {lr} {ll} {now} {useful}; '
                      'printf "%s" "$DUTY_A_ACTION"')
    check(f"duty_a_step: {why}", (out, rc), (want, 0))

# THE STALL PATH IS UNAFFECTED. A skipped Duty A must not advance last_reclaim,
# or brake_step would read "reclaim on cooldown" and brake straight away instead
# of reclaim-arming -- the gate would have reached the ungated emergency path
# through the shared clock. Threaded as the loop does it: skip at 1000 with
# last_reclaim still 0, then a STALL tick at 1005.
out, _ = sh(GOV, 'RECLAIM_COOL=30; last_reclaim=0; '
                 'duty_a_step "$last_reclaim" 0 1000 0; a=$DUTY_A_ACTION; '
                 'brake_step "" 0 1005 "$last_reclaim"; '
                 'printf "%s %s" "$a" "$BRAKE_ACTION"')
check("a thrash skip leaves the STALL path free to reclaim-arm",
      out, "skip-log reclaim-arm")


def code(block):
    """Source lines of `block` with comments stripped, for shape assertions."""
    return "\n".join(ln.split("#", 1)[0] for ln in block.splitlines())


tight = gov_src[gov_src.index("\n    TIGHT)\n"):gov_src.index("\n    STALL)\n")]
stall = gov_src[gov_src.index("\n    STALL)\n"):gov_src.rindex('\n  sleep "$INTERVAL"')]
skip_arm = tight[tight.index("skip-log)"):]
skip_arm = skip_arm[:skip_arm.index(";;")]
check("shape: the TIGHT skip arm never assigns last_reclaim",
      "last_reclaim" in code(skip_arm), False)
check("shape: the STALL branch never consults the thrash gate",
      any(t in code(stall) for t in ("RECLAIM_USEFUL", "duty_a_step")), False)
check("shape: the brake reclaims the victim it just froze (a freeze frees nothing)",
      'reclaim_from "$NEXT_VICTIM"' in code(stall), True)
check("shape: the brake picks from list_brake_targets, not the cap's leaves",
      ("list_brake_targets" in code(stall), "list_build_scopes" in code(stall)),
      (True, False))
check("shape: both reclaim call sites carry the logged ratio",
      min(code(tight).count("$gate"), code(stall).count("$gate")) >= 1, True)

# ---------------------------------------------------------------------------
# 7. FREEZABLE IS NOT KILLABLE (2026-09-14). nohang's kill set must be a SUBSET
#    of the governor's freeze set -- nothing is killed that could not first be
#    paused -- and FREEZE_ONLY_RE widens the freeze set without ever reaching
#    the kill list. The two lists used to be "kept in step" by comment and had
#    drifted: nohang carried bare `playwright`, WORKER_RE only ms-playwright.
from testlib import wait_for  # noqa: E402

NOHANG = HERE.parent / "nohang" / "nohang.conf"


def top_level_alts(regex):
    """Split an ERE on its TOP-LEVEL `|` only, so `/(rush|pnpm) install`
    stays one alternative."""
    out, depth, cur, prev = [], 0, "", ""
    for ch in regex:
        if prev != "\\" and ch == "(":
            depth += 1
        elif prev != "\\" and ch == ")":
            depth -= 1
        if ch == "|" and depth == 0 and prev != "\\":
            out.append(cur)
            cur = ""
        else:
            cur += ch
        prev = ch
    out.append(cur)
    return out


# nohang's own parse: a rule is a line STARTING with the key (indented ones are
# examples inside comments), split on `///`, stripped.
kill = []
for ln in NOHANG.read_text().splitlines():
    if not ln.startswith("@BADNESS_ADJ_RE_CMDLINE"):
        continue
    adj, _, pat = ln.partition("@BADNESS_ADJ_RE_CMDLINE")[2].partition("///")
    if int(adj.strip()) > 0:
        kill.append(pat.strip())
out, _ = sh(GOV, 'printf "%s\\n%s" "$WORKER_RE" "$FREEZE_ONLY_RE"')
worker_re, freeze_only_re = out.split("\n")
worker = top_level_alts(worker_re)
freeze_only = top_level_alts(freeze_only_re)
check("nohang.conf yields a real kill list (the parse found its rules)",
      len(kill) >= 8, True)
check("every nohang kill pattern is in WORKER_RE (kill set <= freeze set)",
      [p for p in kill if p not in worker], [])
check("no FREEZE_ONLY_RE pattern is in nohang's kill list",
      [p for p in freeze_only if p in kill], [])
check("the split keeps the grouped install alternative whole",
      "/(rush|pnpm) install( |$)" in freeze_only, True)

# wt_key: which worktree leaf a worker lands in. `cd /` pins the probing shell's
# own cwd (it IS the pid probed, $$) so the argv fallback is what is tested.
WT = BASE / "wt-home" / ".claude" / "worktrees" / "from-cwd" / "packages" / "x"
WT.mkdir(parents=True)
for body, want, why in [
    ('cd / && wt_key $$ "node /k/.claude/worktrees/outer/.claude/worktrees/inner/node_modules/jest"',
     "inner", "argv: the innermost nested worktree wins"),
    ('cd / && wt_key $$ "node /nix/store/x-tsc/bin/tsc -p ."',
     "misc", "argv naming no worktree keys misc"),
    ('cd / && wt_key $$ "node /k/.claude/worktrees/.hidden/x"',
     "misc", "a dot-leading name can never spell a control file"),
    (f'cd "{WT}" && wt_key $$ "node /k/.claude/worktrees/from-argv/x"',
     "from-cwd", "the cwd outranks the argv"),
    (f'cd "{WT}" && wt_key 999999999 "node /k/.claude/worktrees/from-argv/x"',
     "from-argv", "an unreadable cwd (exited pid) falls back to the argv"),
]:
    out, _ = sh(GOV, f'{body}; printf "%s" "$WT_KEY"')
    check(f"wt_key: {why}", out, want)
out, _ = sh(GOV, f'cd "{WT}" && wt_key $$ x; printf "%s" "$PWD"')
check("wt_key: the governor's own cwd is restored after probing", out, str(WT))

# sweep_transient against REAL processes whose argv carry each shape. A
# fixture file of pids would only assert a belief about /proc; these are read
# through the same comm/cmdline/statm builtins the governor uses.
SWEEP = BASE / "sweep-pool"
fleet = SWEEP / "worktrees-agents.slice" / "fleet"
fleet.mkdir(parents=True)
HOLD = "import time; time.sleep(120)"
fixtures = {
    "pnpm install": [sys.executable, "-c", HOLD,
                     "/k/common/temp/pnpm-local/node_modules/.bin/pnpm",
                     "install", "--frozen-lockfile"],
    "rush install": [sys.executable, "-c", HOLD,
                     "/nix/store/x-rush/lib/node_modules/@microsoft/rush/bin/rush",
                     "install"],
    "cliDaemon": [sys.executable, "-c", HOLD,
                  "/x/playwright-core/lib/entry/cliDaemon.js", "session-1"],
    "playwright runner": [sys.executable, "-c", HOLD,
                          "/k/node_modules/playwright/cli.js", "test"],
    # Guard 1 must still win: a SHELL whose arguments name an install is the
    # launcher, not the worker (`zsh -c "... rush install ..."`).
    "shell naming an install": [BASH, "-c", "sleep 120; :", "_",
                                "/x/bin/rush", "install"],
    "rush install-autoinstaller": [sys.executable, "-c", HOLD,
                                   "/x/bin/rush", "install-autoinstaller"],
    "http-server (deliberately excluded)": [sys.executable, "-c", HOLD,
                                            "/x/node_modules/.bin/http-server",
                                            "storybook-static"],
}
want_migrated = {"pnpm install", "rush install", "cliDaemon", "playwright runner"}
# Own session + /dev/null stdio, killed by GROUP: killing the bash fixture alone
# orphans its `sleep`, which holds an inherited stdout open -- and whatever is
# reading this suite's output (run-tests.sh, the flake sandbox) then waits out
# the sleep. Measured: 1.3 s unpiped, >120 s through a pipe.
procs = {
    k: subprocess.Popen(v, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL, start_new_session=True,
                        cwd="/")
    for k, v in fixtures.items()
}
try:
    def argv_ready():
        for k, p in procs.items():
            with open(f"/proc/{p.pid}/cmdline", "rb") as fh:
                if fixtures[k][-1].encode() not in fh.read():
                    return False
        return True

    check("sweep fixtures exec'd with their argv", bool(wait_for(argv_ready)), True)
    (fleet / "cgroup.procs").write_text(
        "".join(f"{p.pid}\n" for p in procs.values()))
    reset_log()
    sh(GOV, f'POOL="{SWEEP}"; WORKER_MIN_MB=1; DRYRUN=1; sweep_transient')
    log_text = gov_log()
    pid_of = {str(p.pid): k for k, p in procs.items()}
    migrated = {pid_of[ln.split("pid=", 1)[1].split()[0]]
                for ln in log_text.splitlines() if "would MIGRATE pid=" in ln}
    for k in fixtures:
        check(f"sweep_transient: {k} {'migrates' if k in want_migrated else 'stays put'}",
              k in migrated, k in want_migrated)

    # And a REAL (non-dry) sweep lands the install in its worktree's leaf.
    # The fixture's cwd is / and its argv names no worktree, so it keys `misc`.
    one = SWEEP / "worktrees-one.slice" / "claude-x.scope"
    one.mkdir(parents=True)
    (one / "cgroup.procs").write_text(f"{procs['pnpm install'].pid}\n")
    (fleet / "cgroup.procs").write_text("")
    reset_log()
    sh(GOV, f'POOL="{SWEEP}"; WORKER_MIN_MB=1; sweep_transient')
    landed = (one.parent / "transient" / "misc" / "cgroup.procs").read_text().split()
    check("a real sweep writes the install's pid into transient/<worktree>",
          (landed, "SWEEP|migrated 1" in gov_log()),
          ([str(procs["pnpm install"].pid)], True))

    # RE-HOME: a pid sitting directly in the transient PARENT (the pre-split
    # layout) moves into its worktree leaf WITHOUT re-running the guards --
    # http-server fails WORKER_RE and would never be migrated from the fleet,
    # but one already in transient was vetted when it arrived.
    two = SWEEP / "worktrees-two.slice" / "transient"
    two.mkdir(parents=True)
    hs = str(procs["http-server (deliberately excluded)"].pid)
    (two / "cgroup.procs").write_text(hs + "\n")
    (one / "cgroup.procs").write_text("")
    reset_log()
    sh(GOV, f'POOL="{SWEEP}"; WORKER_MIN_MB=1; sweep_transient')
    check("a pid left directly in the transient parent is re-homed to its leaf",
          (two / "misc" / "cgroup.procs").read_text().split(), [hs])
finally:
    import signal  # noqa: E402

    for p in procs.values():
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        p.wait()

# ---------------------------------------------------------------------------
# 8. THE HYPERVISOR BALLOON (2026-09-15). Guest RAM the host took back is in
#    free(1)'s "used" and in no cgroup, so it is logged: a BALLOON timeline
#    line when it moves a step, and a balloon= field on STATE/STALL. Every
#    no-signal read is "" (logged as ?), never a number.
mib = BASE / "meminfo-balloon"
mib.write_text(
    "MemTotal:       30606080 kB\n"
    "MemFree:         7039460 kB\n"
    "MemAvailable:    9114560 kB\n"
    "Percpu:            94720 kB\n"
    "Balloon:         4701876 kB\n"
    "HugePages_Total:       0\n"
)
out, _ = sh(GOV, f'read_balloon "{mib}"; printf "[%s]" "$BALLOON_MB"')
check("read_balloon parses Balloon: to MiB", out, "[4591]")
out, _ = sh(GOV, f'read_balloon "{mi}"; printf "[%s]" "$BALLOON_MB"')
check("read_balloon: no Balloon: line (no driver) is unknown, not zero", out, "[]")
junk = BASE / "meminfo-balloon-junk"
junk.write_text("Balloon:         lots kB\n")
out, _ = sh(GOV, f'read_balloon "{junk}"; printf "[%s]" "$BALLOON_MB"')
check("read_balloon: a non-number is unknown", out, "[]")
out, _ = sh(GOV, f'{{ read_balloon "{BASE}/no-such-meminfo"; }} 2>&1; printf "[%s]" "$BALLOON_MB"')
check("read_balloon: a missing file is unknown AND silent", out, "[]")

#    balloon_turn is a zigzag: ext dir cur step -> BT_EXT BT_DIR BT_TURN BT_TURN_MB.
for (ext, d, cur, want, why) in [
    ("", "", "", "||:", "unknown with no history changes nothing"),
    ("", "", "4000", "4000||:", "the first reading seeds the extreme"),
    ("4000", "up", "", "4000|up|:", "an unknown reading changes nothing"),
    ("4000", "", "4300", "4000||:", "undecided: a sub-step move sets no direction"),
    ("4000", "", "4600", "4600|up|:", "undecided: a full step sets the direction, no turn"),
    ("4400", "up", "4470", "4470|up|:", "rising extends the running peak"),
    ("4470", "up", "4100", "4470|up|:", "a sub-step pullback is jitter"),
    ("4470", "up", "3877", "3877|down|peak:4470", "a full-step reversal reports the PEAK"),
    ("821", "down", "1500", "1500|up|trough:821", "a full-step rebound reports the TROUGH"),
]:
    out, _ = sh(GOV, f'balloon_turn "{ext}" "{d}" "{cur}" 512; '
                     'printf "%s|%s|%s:%s" "$BT_EXT" "$BT_DIR" "$BT_TURN" "$BT_TURN_MB"')
    check(f"balloon_turn: {why}", out, want)

# The real 2026-09-15 sawtooth (13:44-13:59 BALLOON lines), with an unknown
# reading spliced in: 14 readings become four turns.
out, _ = sh(GOV, 'e=""; d=""; for c in 4357 3684 3139 2623 3357 "" 3953 3018 2404 1700 '
                 '2533 3203 3754 4358 3704; do '
                 'balloon_turn "$e" "$d" "$c" 512; e="$BT_EXT"; d="$BT_DIR"; '
                 '[ -n "$BT_TURN" ] && printf "%s:%s " "$BT_TURN" "$BT_TURN_MB"; done')
check("balloon_turn: a real sawtooth logs only its turning points",
      out, "trough:2623 peak:3953 trough:1700 peak:4358 ")
out, _ = sh(GOV, 'printf "%s" "$BALLOON_STEP_MB"')
check("balloon step defaults to 512 MiB", out, "512")

state_log = next(ln for ln in gov_src.splitlines() if 'log "STATE|$last_state' in ln)
stall_log = next(ln for ln in gov_src.splitlines() if 'log "STALL|desktop' in ln)
check("shape: STATE and STALL lines carry balloon=",
      ("balloon=${balloon}" in state_log, "balloon=${balloon}" in stall_log),
      (True, True))

# ---------------------------------------------------------------------------
# 9. THE BALLOON-AWARE POOL CEILING (2026-09-17). The partition in
#    memory-policy.nix is sized against the whole of MemTotal; a held balloon
#    removes RAM from under it. The pool's memory.high gives the balloon back,
#    rounded DOWN to a step so jitter writes nothing, never below the policy
#    floor and never above the configured ceiling. Lowering is immediate; a
#    raise waits for the target to have stayed higher for the whole dwell.
#    ceiling_target base floor balloon step -> CT_MB ("" = feature off).
for (base, floor, bal, want, why) in [
    ("15360", "12288", "", "15360", "no balloon reading keeps the configured ceiling"),
    ("15360", "12288", "0", "15360", "an empty balloon keeps the configured ceiling"),
    ("15360", "12288", "300", "15360", "a sub-step balloon is jitter, not a cut"),
    ("15360", "12288", "1300", "14336", "the balloon comes off in whole steps, rounded down"),
    ("15360", "12288", "2600", "12800", "a larger balloon, still above the floor"),
    ("15360", "12288", "4570", "12288", "the floor holds (2026-09-17's 4570M balloon)"),
    ("15360", "16384", "4570", "15360", "a floor above the base never raises the ceiling"),
    ("", "12288", "4570", "", "no configured base: the feature is off"),
    ("15360", "", "4570", "", "no configured floor: the feature is off"),
    ("15G", "12288", "4570", "", "a non-number base: the feature is off"),
]:
    out, _ = sh(GOV, f'ceiling_target "{base}" "{floor}" "{bal}" 512; printf "[%s]" "$CT_MB"')
    check(f"ceiling_target: {why}", out, f"[{want}]")

#    ceiling_step live target now raise_since dwell -> CS_SET CS_SINCE CS_WHY.
for (live, target, now, since, want, why) in [
    ("", "12288", "1000", "", "||", "an unreadable live ceiling is left alone"),
    ("15360", "", "1000", "", "||", "feature off: nothing is written"),
    ("15360", "12288", "1000", "", "12288||lower", "a higher live ceiling is lowered at once"),
    ("max", "15360", "1000", "", "15360||lower", "an unset (max) ceiling is lowered at once"),
    ("15360", "12288", "1000", "990", "12288||lower", "lowering also cancels a pending raise"),
    ("12288", "12288", "1000", "", "||", "on target: nothing to do"),
    ("12288", "12288", "1000", "990", "||", "back on target cancels a pending raise"),
    ("12288", "14336", "1000", "", "|1000|wait", "a raise starts the dwell clock, writes nothing"),
    ("12288", "14336", "1030", "1000", "|1000|wait", "mid-dwell: still waiting"),
    ("12288", "14336", "1060", "1000", "14336||raise", "the dwell served: raise"),
    ("12288", "14336", "900", "1000", "|1000|wait", "a backward clock jump reads as no time passed"),
]:
    out, _ = sh(GOV, f'ceiling_step "{live}" "{target}" "{now}" "{since}" 60; '
                     'printf "%s|%s|%s" "$CS_SET" "$CS_SINCE" "$CS_WHY"')
    check(f"ceiling_step: {why}", out, want)

#    read_pool_high: bytes -> MiB, `max` passes through, anything else is "".
ph = BASE / "memory.high-bytes"
ph.write_text("16106127360\n")
out, _ = sh(GOV, f'read_pool_high "{ph}"; printf "[%s]" "$POOL_HIGH_MB"')
check("read_pool_high parses bytes to MiB", out, "[15360]")
ph.write_text("max\n")
out, _ = sh(GOV, f'read_pool_high "{ph}"; printf "[%s]" "$POOL_HIGH_MB"')
check("read_pool_high: an unset ceiling reads as max", out, "[max]")
out, _ = sh(GOV, f'{{ read_pool_high "{BASE}/no-such-high"; }} 2>&1; printf "[%s]" "$POOL_HIGH_MB"')
check("read_pool_high: a missing file is unknown AND silent", out, "[]")

#    set_pool_high against a synthetic pool: real writes land, dry runs do not,
#    a missing file says so, and a lower is backgrounded (the kernel reclaims
#    synchronously in the writer) but still lands once waited for.
CEIL = BASE / "ceilpool"
CEIL.mkdir()
(CEIL / "memory.high").write_text("16106127360\n")
reset_log()
sh(GOV, f'POOL="{CEIL}"; set_pool_high 15360 12288 "lower: test"; wait')
check("set_pool_high: a lower lands in memory.high (after its background write)",
      ((CEIL / "memory.high").read_text().strip(),
       "CEILING|memory.high 15360M -> 12288M (lower: test)" in gov_log()),
      (str(12288 * 1048576), True))
reset_log()
sh(GOV, f'POOL="{CEIL}"; set_pool_high 12288 14336 "raise: test"')
check("set_pool_high: a raise is written inline (no wait needed)",
      ((CEIL / "memory.high").read_text().strip(),
       "CEILING|memory.high 12288M -> 14336M (raise: test)" in gov_log()),
      (str(14336 * 1048576), True))
reset_log()
sh(GOV, f'POOL="{CEIL}"; DRYRUN=1; set_pool_high 14336 12288 "lower: dry"; '
        'set_pool_high 14336 12288 "lower: dry"; wait')
check("set_pool_high: DRYRUN writes nothing and logs the decision once",
      ((CEIL / "memory.high").read_text().strip(),
       gov_log().count("DRYRUN|would set CEILING memory.high 14336M -> 12288M")),
      (str(14336 * 1048576), 1))
reset_log()
sh(GOV, f'POOL="{BASE}/no-such-pool"; set_pool_high 15360 12288 "lower: gone"; wait')
check("set_pool_high: a missing memory.high is logged, not silent",
      "CEILING|SKIPPED - no memory.high" in gov_log(), True)

out, _ = sh(GOV, 'printf "%s" "$CEILING_DWELL"')
check("ceiling dwell defaults to 60s", out, "60")
loop = gov_src[gov_src.index("\nwhile :; do\n"):]
check("shape: the loop derives the ceiling from the balloon and steps it",
      all(t in code(loop) for t in ('ceiling_target "$POOL_HIGH_BASE_MB"',
                                    '"$BALLOON_MB"', "ceiling_step", "set_pool_high")),
      True)
on_exit = next(ln for ln in gov_src.splitlines() if ln.startswith("on_exit()"))
check("shape: exit restores the configured ceiling", "restore_pool_high" in on_exit, True)

#    The monitor's diagnosis prompt: it must see the kernel's live reclaim
#    tuning (two 09-17 diagnoses recommended a watermark_scale_factor the box
#    already exceeded) and must know a lowered memory.high is the governor.
out, _ = sh(MON, "vm_tuning")
check("monitor vm_tuning names the three reclaim knobs, in order",
      [kv.split("=", 1)[0] for kv in out.split()],
      ["vm.watermark_scale_factor", "vm.swappiness", "vm.min_free_kbytes"])
mon_src = MON.read_text()
machine = next(ln for ln in mon_src.splitlines() if ln.startswith("Machine:"))
check("shape: the prompt's Machine line carries live vm tuning and the ceiling note",
      ("$(vm_tuning)" in machine, "${ceiling_note}" in machine), (True, True))
check("shape: the snapshot records the live vm tuning",
      'echo "kernel reclaim tuning: $(vm_tuning)"' in mon_src, True)
check("shape: the prompt no longer forbids what the governor now does",
      "Never recommend a cgroup retune to compensate for a balloon" in mon_src, False)

summary(cleanup_dir=BASE)
