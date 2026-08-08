#!/usr/bin/env python3
"""Exercise wt-cgroup-status.sh's /proc and cgroup parsers against fixtures.

    python3 scripts/wt-cgroup-status.test.py

NO REAL CGROUP OR /proc IS READ, and that is the point. The script is 260
lines of pure file parsing that had zero coverage; everything it reads comes
from whatever KX_POOL and WT_CG_PROC point at, so a tempdir of hand-written
stat/statm/cmdline/cpu.stat files makes every assertion deterministic and
sandbox-safe (this runs under `nix flake check`). Function-level checks
source the script through its test seam (the cgroup-governor pattern); CLI
and lifecycle checks run it end-to-end under `bash -o nounset`, matching the
writeShellApplication wrapper's bashOptions.

Covers the spots the audit flagged as silently load-bearing:
  - the /proc/N/stat "everything past the LAST ') '" split, against comms
    containing spaces, parens, and a ') ' inside the comm itself — the
    arithmetic that puts utime/stime at rest-indices 11/12;
  - the statm resident-pages * PAGE math, and that PAGE actually flows in;
  - the HZ/PAGE getconf fallbacks (and that the WT_CG_* seams are no-ops
    when unset);
  - the WT_CG_SAMPLE integer-division guard, and the new -w interval guard
    that mirrors it (a junk interval used to turn the watch loop into a
    tight clear/snapshot spin);
  - the `-t 0` exit-status regression (an `&&` would have made a good run
    report failure) and the nounset watch-loop regression: the pool
    legitimately vanishes and returns mid-watch, and the loop must survive
    both without an unbound-variable death or a leaked /proc error.

Deliberately NOT covered: real getconf values (environment-dependent), TTY
rendering (`clear`), and a live nonzero CPU delta through a full snapshot —
the two samples straddle a real sleep over static fixtures, so the delta
arithmetic is pinned at the print_top level with hand-seeded T0 baselines
instead.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "scriptBins" / "bins" / "wt-cgroup-status.sh"
# Resolve bash at runtime rather than via `#!/usr/bin/env bash`: the nix build
# sandbox (where this runs as a flake check) has no /usr/bin/env.
BASH = shutil.which("bash")
BASE = Path(tempfile.mkdtemp(prefix="wt-cgs-test."))
POOL = BASE / "pool"
PROC = BASE / "proc"

sys.path.insert(0, str(HERE))
from testlib import check, summary, wait_for  # noqa: E402

# The bucket name carries a LITERAL backslash-x2d, the way systemd escapes
# '-' in unit names on the filesystem; unesc() must render it back.
BUCKET_A = "worktrees-foo\\x2dbar.slice"


def base_env(extra=None):
    env = dict(os.environ)
    for k in list(env):
        if k.startswith("WT_CG_"):
            del env[k]
    env.update(KX_POOL=str(POOL), WT_CG_PROC=str(PROC),
               WT_CG_HZ="100", WT_CG_PAGE="4096")
    if extra:
        env.update(extra)
    return env


def sh(body, extra=None):
    """Source the script (stops at its test seam), then run `body` in the
    same shell, so `body` can call the functions and read/set the globals.
    nounset matches production; the pool must exist or sourcing exits."""
    return subprocess.run(
        [BASH, "-o", "nounset", "-c", f'. "{SCRIPT}" && {body}'],
        env=base_env(extra), capture_output=True, text=True,
    )


def run(*args, extra=None, timeout=30):
    """Run the script end-to-end. WT_CG_SAMPLE=1 keeps each snapshot's
    sample sleep at its floor (the guard rejects anything under a second)."""
    env = base_env({"WT_CG_SAMPLE": "1"})
    if extra:
        env.update(extra)
    try:
        return subprocess.run([BASH, "-o", "nounset", str(SCRIPT), *args],
                              env=env, capture_output=True, text=True,
                              timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, returncode=124,
                                           stdout="", stderr="TIMEOUT")


def proc_entry(pid, comm="x", utime=0, stime=0, pages=1, cmdline=(),
               comm_file=None):
    """A synthetic /proc/<pid>: stat in the kernel's real shape (comm in
    parens, 2nd field), statm, nul-separated cmdline, comm."""
    d = PROC / str(pid)
    d.mkdir(parents=True, exist_ok=True)
    # After the comm the fields are: state ppid pgrp session tty tpgid flags
    # minflt cminflt majflt cmajflt utime stime ... — utime/stime land at
    # indices 11/12 of the post-')' split, which is what the parser banks on.
    (d / "stat").write_text(
        f"{pid} ({comm}) S 1 {pid} {pid} 0 -1 4194560 100 0 0 0 "
        f"{utime} {stime} 10 5 20 0 1 0 0 0\n")
    (d / "statm").write_text(f"10000 {pages} 300 50 0 4000 0\n")
    data = b"\0".join(t.encode() for t in cmdline)
    (d / "cmdline").write_bytes(data + b"\0" if cmdline else b"")
    (d / "comm").write_text((comm_file or comm) + "\n")


def make_bucket(name, pids, nested=None):
    d = POOL / name
    d.mkdir(parents=True)
    (d / "cpu.stat").write_text("usage_usec 700000\n")
    (d / "memory.current").write_text("268435456\n")
    (d / "pids.current").write_text("7\n")
    (d / "cpu.pressure").write_text(
        "some avg10=2.50 avg60=1.00 avg300=0.10 total=99\n")
    (d / "cgroup.procs").write_text("".join(f"{p}\n" for p in pids))
    if nested:
        n = d / "nested.scope"
        n.mkdir()
        (n / "cgroup.procs").write_text("".join(f"{p}\n" for p in nested))
    return d


def make_pool(cpu_max="1600000 100000", mem_high="12884901888"):
    shutil.rmtree(POOL, ignore_errors=True)
    POOL.mkdir(parents=True)
    (POOL / "cpu.max").write_text(cpu_max + "\n")
    (POOL / "cpu.stat").write_text("usage_usec 5000000\n")
    (POOL / "memory.current").write_text("1073741824\n")
    (POOL / "memory.high").write_text(mem_high + "\n")
    (POOL / "cpu.pressure").write_text(
        "some avg10=1.50 avg60=0.80 avg300=0.20 total=1\n")
    (POOL / "memory.pressure").write_text(
        "some avg10=0.30 avg60=0.10 avg300=0.00 total=2\n")


make_pool()
A = str(make_bucket(BUCKET_A, [101, 103], nested=[102]))
IDLE = str(make_bucket("worktrees-idle.slice", []))

# 101: comm with a space and a colon; a fat RSS; a store-path cmdline whose
# only informative part is the last component.
proc_entry(101, comm="tmux: server", utime=400, stime=200, pages=2560,
           cmdline=("/nix/store/abc-claude-code-2.1.220/bin/.claude-wrapped",
                    "--flag"))
# 102: parens INSIDE the comm — the case a first-')' split mis-fields.
proc_entry(102, comm="(a) (b)", utime=7, stime=5, pages=100,
           cmdline=("/usr/bin/deno", "run"))
# 103: kernel-thread shape: empty cmdline, label comes bracketed from comm.
proc_entry(103, comm="kthreadd", utime=1, stime=1, pages=5)
# 105: a ') ' inside the comm itself — only a LAST-')' split survives this.
proc_entry(105, comm="evil) 123 456", utime=3, stime=4)
# 107: a cmdline long enough to hit the 60-char label cut.
proc_entry(107, comm="longboi", cmdline=("x" * 40, "y" * 40, "z" * 10))

# ---------------------------------------------------------------------------
# 1. THE GUARDS. WT_CG_SAMPLE feeds bash integer division (0 divides by zero,
#    0.5 is a syntax error), so it is rejected up front; the -w interval is
#    the same contract for a worse failure (a failing `sleep` every iteration
#    is a tight spin, not a watch). Both must exit 2 BEFORE any sampling.
for bad in ("0", "0.5", "abc"):
    p = run(extra={"WT_CG_SAMPLE": bad})
    check(f"WT_CG_SAMPLE={bad!r} rejected up front", p.returncode, 2)
    check(f"WT_CG_SAMPLE={bad!r} names the contract",
          "whole seconds" in p.stderr, True)

for bad in ("abc", "0", "1.5"):
    p = run("-w", bad)
    check(f"-w {bad!r} rejected (no spin)", p.returncode, 2)
    check(f"-w {bad!r} names the contract",
          "whole seconds" in p.stderr, True)

p = run("-t", "abc")
check("-t abc rejected", p.returncode, 2)
p = run("-s", "junk")
check("-s junk rejected", p.returncode, 2)
p = run("--bogus")
check("unknown option rejected", p.returncode, 2)

p = run("--help")
check("--help exits 0", p.returncode, 0)
check("--help starts at the header",
      p.stdout.startswith("wt-cgroup-status"), True)
check("--help documents -w", "-w [SECS]" in p.stdout, True)

# ---------------------------------------------------------------------------
# 2. SMALL PARSERS through the seam: unesc, cpuusec, psi10 (+ fallbacks).
p = sh(r'printf "%s" "$(unesc "foo\x2dbar")"')
check("unesc renders \\x2d back to a dash", p.stdout, "foo-bar")
p = sh('printf "%s" "$(cpuusec "$POOL")"')
check("cpuusec reads usage_usec", p.stdout, "5000000")
p = sh('printf "%s %s" "$(cpuusec /nonexistent)" "$(psi10 /nonexistent)"')
check("cpuusec/psi10 fail open on a missing dir", p.stdout, "0 -")
p = sh('printf "%s %s" "$(psi10 "$POOL")" "$(mpsi10 "$POOL")"')
check("psi10/mpsi10 pick avg10 off the some line", p.stdout, "1.50 0.30")

# ---------------------------------------------------------------------------
# 3. THE STAT SPLIT. comm can contain spaces and parens, so the parser splits
#    on the LAST ') ' and indexes from there; each fixture is a comm shape
#    that breaks a naive whitespace or first-paren split.
p = sh('proc_ticks 101; printf "%s" "$_TICKS"')
check("stat: comm with space+colon (tmux: server) -> utime+stime",
      p.stdout, "600")
p = sh('proc_ticks 102; printf "%s" "$_TICKS"')
check("stat: parens inside comm ((a) (b))", p.stdout, "12")
p = sh('proc_ticks 105; printf "%s" "$_TICKS"')
check("stat: comm containing ') ' itself (evil) 123 456)", p.stdout, "7")
p = sh('proc_ticks 999999 && printf yes || printf no')
check("stat: dead pid is a quiet return 1", p.stdout, "no")
check("stat: dead pid leaks nothing to stderr (redirect order)",
      p.stderr, "")

# ---------------------------------------------------------------------------
# 4. THE STATM PAGE MATH. Field 2 is resident pages; the byte count must be
#    pages * PAGE, with PAGE actually flowing in (asserted by changing it).
p = sh('proc_rss 101; printf "%s" "$_RSS"')
check("statm: 2560 pages * 4096", p.stdout, str(2560 * 4096))
p = sh('proc_rss 103; printf "%s" "$_RSS"', extra={"WT_CG_PAGE": "16384"})
check("statm: PAGE is load-bearing (5 pages * 16384)", p.stdout, "81920")
p = sh('proc_rss 999999 && printf yes || printf no')
check("statm: dead pid is a quiet return 1", (p.stdout, p.stderr),
      ("no", ""))

# ---------------------------------------------------------------------------
# 5. LABELS. Tokens are basenamed (store paths would eat the column), empty
#    cmdlines fall back to a bracketed comm, and a missing pid still labels.
p = sh('proc_label 101; printf "%s" "$_LABEL"')
check("label: store path basenamed", p.stdout, ".claude-wrapped --flag")
p = sh('proc_label 103; printf "%s" "$_LABEL"')
check("label: empty cmdline -> bracketed comm", p.stdout, "[kthreadd]")
p = sh('proc_label 999999; printf "%s" "$_LABEL"')
check("label: vanished pid still labels", p.stdout, "[pid 999999]")
p = sh('proc_label 107; printf "%s" "$_LABEL"')
check("label: stops growing past 60 chars",
      ("y" * 40 in p.stdout, "z" * 10 in p.stdout), (True, False))

# ---------------------------------------------------------------------------
# 6. collect_pids WALKS THE SUBTREE: buckets nest scopes, and cgroup.procs
#    only lists a node's own members, so the nested scope's pid must appear.
p = sh('collect_pids "' + A + '"; printf "%s\\n" "${_PIDS[@]}"')
check("collect_pids sweeps nested scopes too",
      sorted(p.stdout.split()), ["101", "102", "103"])

# ---------------------------------------------------------------------------
# 7. print_top's CPU% ARITHMETIC, with hand-seeded T0 baselines (the fixtures
#    are static, so a full run's delta is always zero; the seeding IS the
#    "first sample" and print_top is the second).
p = sh('proc_ticks 101; T0[101]=$(( _TICKS - 150 )); '
       'proc_ticks 103; T0[103]=$(( _TICKS - 50 )); '
       'proc_ticks 102; T0[102]=$_TICKS; '
       'print_top "' + A + '"')
check("cpu%%: 150-tick delta at HZ=100 SAMPLE=1 -> 150%",
      "150%" in p.stdout, True)
check("cpu%%: 50-tick delta -> 50%", "50%" in p.stdout, True)

p = sh('SAMPLE=2; proc_ticks 101; T0[101]=$(( _TICKS - 300 )); '
       'print_top "' + A + '"')
check("cpu%%: SAMPLE divides the delta (300 ticks / 2s -> 150%)",
      ("150%" in p.stdout, "300%" in p.stdout), (True, False))

p = sh('proc_ticks 101; T0[101]=$(( _TICKS + 500 )); print_top "' + A + '"')
check("cpu%%: negative delta clamps to 0%", "0%" in p.stdout, True)

# No baseline at all = joined mid-window: the column must say "-", never a
# lifetime total dressed up as one second's worth.
p = sh('print_top "' + A + '"')
check("cpu%%: no baseline shows no percentage", "%" in p.stdout, False)


def row_order(out):
    rows = [ln for ln in out.splitlines() if ln.startswith("    - ")]
    order = []
    for ln in rows:
        for tag in (".claude-wrapped", "deno run", "[kthreadd]"):
            if tag in ln:
                order.append(tag)
    return order


check("sort: default is RSS descending", row_order(p.stdout),
      [".claude-wrapped", "deno run", "[kthreadd]"])
p = sh('sortfield=2; '
       'proc_ticks 103; T0[103]=$(( _TICKS - 200 )); '
       'proc_ticks 101; T0[101]=$(( _TICKS - 100 )); '
       'proc_ticks 102; T0[102]=$_TICKS; '
       'print_top "' + A + '"')
check("sort: -s cpu reranks by the delta", row_order(p.stdout),
      ["[kthreadd]", ".claude-wrapped", "deno run"])
p = sh('top=1; print_top "' + A + '"')
check("top=1 caps the rows", len(row_order(p.stdout)), 1)
p = sh('print_top "' + IDLE + '" && printf ok')
check("empty bucket prints nothing and succeeds", p.stdout, "ok")

# ---------------------------------------------------------------------------
# 8. HZ/PAGE FALLBACKS. getconf is on PATH by inheritance, not declaration,
#    so a stripped PATH must yield 100/4096 (and human() must fall back past
#    a missing numfmt) — quietly, not with a command-not-found spray.
emptybin = BASE / "emptybin"
emptybin.mkdir()
env = base_env()
for k in ("WT_CG_HZ", "WT_CG_PAGE"):
    del env[k]
p = subprocess.run(
    [BASH, "-o", "nounset", "-c",
     f'PATH="{emptybin}"; . "{SCRIPT}" && printf "%s %s " "$HZ" "$PAGE"; '
     'human 5'],
    env=env, capture_output=True, text=True)
check("no getconf/numfmt on PATH -> HZ 100, PAGE 4096, human falls back",
      p.stdout, "100 4096 5B")

# And the seams must be NO-OPS when unset: HZ/PAGE come from getconf (or its
# fallback) and PROC is the real /proc — production sets none of them.


def getconf(name, fallback):
    gc = shutil.which("getconf")
    if not gc:
        return fallback
    r = subprocess.run([gc, name], capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else fallback


env = base_env()
for k in ("WT_CG_HZ", "WT_CG_PAGE", "WT_CG_PROC"):
    del env[k]
p = subprocess.run(
    [BASH, "-o", "nounset", "-c",
     f'. "{SCRIPT}" && printf "%s %s %s" "$HZ" "$PAGE" "$PROC"'],
    env=env, capture_output=True, text=True)
check("seams unset -> getconf values and the real /proc (production no-op)",
      p.stdout,
      f'{getconf("CLK_TCK", "100")} {getconf("PAGESIZE", "4096")} /proc')

# ---------------------------------------------------------------------------
# 9. snapshot()'s VANISHED-POOL PATHS, under nounset. The 2026-08-07 bug:
#    the bare `read < $POOL/cpu.max` failed its redirect, left `quota` unset,
#    and nounset killed the whole watch loop. Both the re-check and the
#    read's own fallback must return 1 quietly instead.
p = sh(f'POOL="{BASE}/nope"; snapshot; printf ":%s" "$?"')
check("snapshot: missing pool -> message + return 1",
      ("not active yet" in p.stdout, p.stdout.endswith(":1")), (True, True))
check("snapshot: missing pool dies on nothing (nounset survived)",
      p.stderr, "")
race = BASE / "race"
race.mkdir()
p = sh(f'POOL="{race}"; snapshot; printf ":%s" "$?"')
check("snapshot: pool torn down between -d test and cpu.max read -> return 1",
      ("not active yet" in p.stdout, p.stdout.endswith(":1")), (True, True))
check("snapshot: the race path is quiet too", p.stderr, "")

# ---------------------------------------------------------------------------
# 10. END-TO-END SNAPSHOTS (each pays one real 1s sample sleep).
p = run()
check("snapshot run exits 0", p.returncode, 0)
check("pool cap derived from cpu.max (1600000/100000)",
      "1600%" in p.stdout, True)
check("memory.high humanized", "12GB" in p.stdout, True)
check("pool psi columns", "psi cpu:1.50 mem:0.30" in p.stdout, True)
check("bucket name un-escaped", "foo-bar" in p.stdout, True)
check("bucket memory humanized", "256MB" in p.stdout, True)
check("nested scope's process surfaced end-to-end",
      "deno run" in p.stdout, True)
check("proc rows ranked with RSS shown",
      ".claude-wrapped --flag" in p.stdout and "10MB" in p.stdout, True)
check("static fixtures read as an idle 0% (T0 seeded, delta zero)",
      "0%" in p.stdout, True)
check("clean run leaks nothing to stderr", p.stderr, "")

# The -t 0 regression: an `&&` on the print_top call would have made a false
# test the loop's — and so the script's — exit status.
p = run("-t", "0")
check("-t 0 still exits 0", p.returncode, 0)
check("-t 0 shows no proc rows",
      ("    - " in p.stdout, "(indented" in p.stdout), (False, False))

(POOL / "cpu.max").write_text("max 100000\n")
(POOL / "memory.high").write_text("max\n")
p = run()
check("cpu.max/memory.high 'max' both render unlimited",
      p.stdout.count("unlimited"), 2)
check("unlimited caps still exit 0", p.returncode, 0)

make_pool()  # no buckets
p = run()
check("bucketless pool reports itself, exit 0",
      ("(no active buckets)" in p.stdout, p.returncode), (True, 0))

p = run(extra={"KX_POOL": str(BASE / "never")})
check("one-shot with no pool at all exits 1",
      ("not active yet" in p.stdout, p.returncode), (True, 1))

# ---------------------------------------------------------------------------
# 11. THE WATCH LOOP STRADDLES THE POOL VANISHING AND RETURNING. systemd
#    removes the slice's cgroup when it empties and re-creates it on the next
#    heavy command; the loop must report the gap and recover, not die (the
#    nounset regression) and not leak redirect errors. Polled via wait_for,
#    never timed.
make_pool()
make_bucket(BUCKET_A, [101, 103], nested=[102])
watch_out = BASE / "watch.out"
watch_err = BASE / "watch.err"
with open(watch_out, "w") as out_f, open(watch_err, "w") as err_f:
    watcher = subprocess.Popen(
        [BASH, "-o", "nounset", str(SCRIPT), "-w", "1"],
        env=base_env({"WT_CG_SAMPLE": "1"}), stdout=out_f, stderr=err_f)


def out_text():
    return watch_out.read_text()


check("watch: first refresh rendered",
      bool(wait_for(lambda: "BUCKET" in out_text())), True)
shutil.rmtree(POOL)
check("watch: vanished pool reported, loop pressed on",
      bool(wait_for(lambda: "not active yet" in out_text())), True)
check("watch: process survived the gap", watcher.poll(), None)
make_pool()
make_bucket(BUCKET_A, [101, 103])
check("watch: pool's return picked up on a later refresh",
      bool(wait_for(
          lambda: out_text().rfind("BUCKET") >
          out_text().rfind("not active yet"))), True)
watcher.terminate()
watcher.wait(timeout=10)
err = watch_err.read_text()
check("watch: no nounset death across the whole session",
      "unbound variable" in err, False)
check("watch: no /proc or cpu.max redirect errors leaked",
      "No such file" in err, False)

summary(cleanup_dir=BASE)
