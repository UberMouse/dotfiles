# wt-cgroup-status — snapshot (or --watch) of the worktrees.slice cgroup
# budget: per-bucket CPU% / memory / tasks / CPU-pressure, plus the pool total
# against its caps, and the top processes inside each bucket.
#
# Reads the cgroup v2 files directly (works even where systemd-cgtop prints "-"
# for the CPU column of transient scopes) and un-escapes slice names back to
# readable worktree names.
#
# CPU% is cgtop-style: 100% == one core. The pool cap is not a constant of
# this script: cgroups.nix derives it as (cpuCores - 4) * 100% from
# host-facts.nix, so read the number off the POOL line, not out of a comment.
#
# Process rows are ranked by RSS, which double-counts pages shared between
# processes (every node fork maps the same binary), so they deliberately do NOT
# sum to the bucket's memory.current. They answer "who is the hog", not "where
# did the bytes go".
#
# Usage:
#   wt-cgroup-status              one-shot snapshot
#   wt-cgroup-status -w [SECS]    refresh every SECS seconds (default 2)
#   wt-cgroup-status -t N         show N processes per bucket (default 3, 0 off)
#   wt-cgroup-status -s cpu|mem   rank those processes by CPU% or RSS (default mem)
#
# The SEM line above the pool is the build semaphore's own published state,
# printed as raw fields rather than re-derived: the bar (wt-cgroup-i3status.py)
# is the place that interprets them into builds-vs-capacity, and a second
# interpretation here is a second thing to keep in step. The one field that is
# NOT published is `waiting`, which is counted live from the marker locks --
# see QUEUE DEPTH in kx-build-slot.sh. So `occupied` is up to one control
# interval old while `waiting` is now.
#
# Env: WT_CG_SAMPLE=<secs> — gap between the two CPU samples (default 1).
#      KX_BUILD_SEM_DIR — semaphore directory (default $XDG_RUNTIME_DIR/kx-build-sem).

# SIBLING FILE: wt-cgroup-i3status.py reads the same cgroup fields
# (cpu.stat usage_usec, memory.current/high, cpu.max, pids.current) AND the
# same semaphore state in Python for the bar. A cgroup-v2 layout change needs
# both, as does a change to the published FIELDS order; their humanizers
# already deliberately differ (numfmt's iec "4.2GB" here vs "4.2G" there).
U=$(id -u)
POOL="${KX_POOL:-/sys/fs/cgroup/user.slice/user-$U.slice/user@$U.service/worktrees.slice}"
SEM_DIR="${KX_BUILD_SEM_DIR:-${XDG_RUNTIME_DIR:-/run/user/$U}/kx-build-sem}"
# Same heartbeat threshold every other reader uses: the controller re-publishes
# `allowed` every tick precisely so its mtime is a liveness signal, and ~3 of
# its 5 s intervals is a dead controller rather than a slow one.
SEM_STALE_AFTER="${KX_SEM_STALE_AFTER:-15}"
SAMPLE="${WT_CG_SAMPLE:-1}"
# Whole positive seconds only. The usage line says "secs" and `sleep` would
# happily take 0.5 -- but the CPU%/delta arithmetic below divides by $SAMPLE
# in bash integer math, where 0.5 is a syntax error and 0 is a division by
# zero. Reject both up front instead of crashing mid-report.
case "$SAMPLE" in
  '' | *[!0-9]* | 0)
    echo "wt-cgroup-status: WT_CG_SAMPLE wants whole seconds >= 1, got '${SAMPLE}'" >&2
    exit 2 ;;
esac

# Both have a fallback because getconf lives in glibc.bin, which is on PATH by
# inheritance rather than by being a declared runtime input. The WT_CG_HZ /
# WT_CG_PAGE overrides are test seams (deterministic tick and page math in
# scripts/wt-cgroup-status.test.py); production never sets them, and the
# `${VAR:-$(...)}` shape means getconf is not even forked when they are set.
HZ="${WT_CG_HZ:-$(getconf CLK_TCK 2>/dev/null || echo 100)}"
PAGE="${WT_CG_PAGE:-$(getconf PAGESIZE 2>/dev/null || echo 4096)}"
# /proc root for the per-process parsers below — a test seam so the suite can
# point them at a fixture tree of hand-written stat/statm/cmdline files.
# Production never sets it.
PROC="${WT_CG_PROC:-/proc}"

watch=0; interval=2; top=3; sortkey=mem
while [ "$#" -gt 0 ]; do
  case "$1" in
    -w|--watch)
      watch=1
      # SECS is optional, so only swallow the next argv if it looks like one.
      case "${2:-}" in ''|-*) ;; *) interval="$2"; shift ;; esac ;;
    -t|--top)  top="${2:-3}"; shift ;;
    -s|--sort) sortkey="${2:-mem}"; shift ;;
    -h|--help) awk '/^# wt-cgroup-status /{f=1} f{if(!/^#/)exit; sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

case "$sortkey" in
  mem|rss) sortfield=1 ;;
  cpu)     sortfield=2 ;;
  *) printf 'unknown sort key: %s (want cpu or mem)\n' "$sortkey" >&2; exit 2 ;;
esac
case "$top" in
  ''|*[!0-9]*) printf 'top count must be a whole number, got: %s\n' "$top" >&2; exit 2 ;;
esac
# Same contract as the WT_CG_SAMPLE guard above, for a worse failure mode:
# `sleep abc` fails instantly, so a junk interval turned the watch loop into
# a tight clear/snapshot spin instead of a refresh. Whole seconds >= 1 only,
# rejected up front like SAMPLE.
case "$interval" in
  ''|*[!0-9]*|0)
    printf 'watch interval wants whole seconds >= 1, got: %s\n' "$interval" >&2
    exit 2 ;;
esac

pool_missing() {
  echo "worktrees.slice pool is not active yet."
  echo "It materializes on the first heavy command the hook wraps (or the first"
  echo "daemon started with CLAUDE_WORKTREE_CGROUP set). Nothing to show."
}

# One-shot mode: nothing to show is an exit. Watch mode presses on and lets
# snapshot() re-check every refresh instead -- systemd REMOVES the slice's
# cgroup whenever it goes empty and re-creates it on the next heavy command,
# so a watch session legitimately straddles the pool vanishing and returning.
if [ ! -d "$POOL" ] && [ "$watch" = 0 ]; then
  pool_missing
  exit 1
fi

shopt -s globstar nullglob

unesc()   { local s="$1"; printf '%s' "${s//\\x2d/-}"; }
human()   { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }
cpuusec() { awk '/^usage_usec/{print $2}' "$1/cpu.stat" 2>/dev/null || echo 0; }
psi10()   { awk -F'[= ]' '/^some/{print $3}' "$1/cpu.pressure"    2>/dev/null || echo "-"; }
mpsi10()  { awk -F'[= ]' '/^some/{print $3}' "$1/memory.pressure" 2>/dev/null || echo "-"; }

sem_waiting() {
  # How many jobs are queued for a build slot. A waiting job holds an exclusive
  # flock on $SEM_DIR/waiting/<pid> for exactly as long as it waits (QUEUE DEPTH
  # in kx-build-slot.sh); an unlocked marker is a job that was SIGKILLed
  # mid-wait and counts for nothing.
  #
  # PROBING A MARKER WITH flock IS SAFE, and that is worth stating plainly
  # because probing a SLOT is the standing trap in this subsystem: a slot is a
  # resource, so a test-and-release can deny a job reaching for it in the same
  # instant and reads to the controller as an admission. A marker reserves
  # nothing -- it is a flag, and the only cost of touching one is that the
  # waiter which happened to be creating it right then retries a marker it
  # already knows how to retry (its take is idempotent and runs every poll).
  #
  # Nothing is deleted here. This is a REPORT; sweeping the litter would make
  # reading the machine change it, and the markers are pid-named, so the next
  # job to inherit that pid reuses the file rather than adding one.
  local n=0 f
  for f in "$SEM_DIR"/waiting/*; do
    [ -e "$f" ] || continue
    flock -n "$f" -c true 2>/dev/null || n=$((n + 1))
  done
  printf '%s' "$n"
}

sem_line() {
  # RAW published fields, deliberately not re-derived into builds-vs-capacity:
  # the bar does that, and one interpretation is enough to keep correct.
  local mtime now a e m o t k r h
  if [ ! -d "$SEM_DIR" ]; then
    printf '  SEM   %-24s  not running (no %s)\n' "build semaphore" "$SEM_DIR"
    return
  fi
  if ! mtime=$(stat -c %Y "$SEM_DIR/allowed" 2>/dev/null); then
    printf '  SEM   %-24s  no published state (controller has never run)\n' \
      "build semaphore"
    return
  fi
  now=$(date +%s)
  if [ $((now - mtime)) -gt "$SEM_STALE_AFTER" ]; then
    # The same distinction the bar draws between "off" and "idle": slot files
    # and the last state line live in tmpfs and outlive the controller, so a
    # crashed one would otherwise read as a perfectly healthy idle forever.
    printf '  SEM   %-24s  STALE (%ss old) — controller not publishing; jobs run ungated\n' \
      "build semaphore" "$((now - mtime))"
    return
  fi
  # Field order is the controller's FIELDS tuple (allowed effective max_slots
  # occupied target mark resident healthy), append-only. A short line from an
  # older controller mid-deploy leaves the tail empty rather than unset.
  read -r a e m o t k r h < "$SEM_DIR/allowed" 2>/dev/null || true
  # ALL of them, including target and mark: this is the diagnostic dump, and
  # those two are what answer "why is allowed 1" without opening the log.
  printf '  SEM   %-24s  allowed %s/%s  effective %s  occupied %s  resident %s  waiting %s  target %s  mark %s  healthy %s\n' \
    "build semaphore" "${a:--}" "${m:--}" "${e:--}" "${o:--}" "${r:--}" \
    "$(sem_waiting)" "${t:--}" "${k:--}" "${h:--}"
}

# The process helpers below all return via a global rather than by echoing into
# $(...): a bucket can hold ~100 pids and each of these runs twice per refresh,
# so a fork apiece is the difference between instant and visibly laggy.
declare -a _PIDS=()
declare -A T0=()
_TICKS=0; _RSS=0; _LABEL=""

# NOTE: every /proc read below writes `2>/dev/null` BEFORE the input redirect,
# and that order is load-bearing, not style. Bash applies redirections left to
# right, so with `< /proc/N/stat 2>/dev/null` the open is attempted while stderr
# is still the terminal and a dead pid leaks
#   ".../wt-cgroup-status: line N: /proc/N/stat: No such file or directory".
# Processes exiting between our two samples is the normal case here, not an
# error, so the `|| return 1` is the whole intended handling. Silencing stderr
# first is what actually makes that quiet; the exit status is unaffected.

# Every pid in the bucket's whole subtree — buckets nest scopes under
# themselves, and cgroup.procs only lists a node's own direct members.
collect_pids() {
  local f p
  _PIDS=()
  for f in "$1"/**/cgroup.procs; do
    [ -r "$f" ] || continue
    # A cgroup can be torn down between the glob and the read, so this needs the
    # same treatment even with the -r test above.
    while read -r p; do _PIDS+=("$p"); done 2>/dev/null < "$f"
  done
}

# utime+stime in clock ticks. comm can contain both spaces and parens, so the
# only safe split is "everything past the LAST ')'"; that leaves state as index
# 0, i.e. overall field N lands at index N-3 — utime is 14, stime is 15.
proc_ticks() {
  local line rest
  read -r line 2>/dev/null < "$PROC/$1/stat" || return 1
  rest=${line##*') '}
  # shellcheck disable=SC2206 # deliberate splitting of a known-numeric line
  local -a f=( $rest )
  _TICKS=$(( ${f[11]:-0} + ${f[12]:-0} ))
}

# statm field 2 is resident pages.
proc_rss() {
  local line
  read -r line 2>/dev/null < "$PROC/$1/statm" || return 1
  # shellcheck disable=SC2206 # ditto
  local -a f=( $line )
  _RSS=$(( ${f[1]:-0} * PAGE ))
}

proc_label() {
  local -a toks=()
  local t out=""
  mapfile -d '' -t toks 2>/dev/null < "$PROC/$1/cmdline"
  if [ "${#toks[@]}" -eq 0 ] || [ -z "${toks[0]}" ]; then
    read -r out 2>/dev/null < "$PROC/$1/comm" || out="pid $1"
    _LABEL="[$out]"
    return
  fi
  for t in "${toks[@]}"; do
    [ -n "$t" ] || continue
    # Basename every token: the informative tail of
    # /nix/store/<hash>-claude-code-2.1.220/bin/.claude-wrapped is the last
    # component, and one full store path would eat the whole column.
    out="$out ${t##*/}"
    if [ "${#out}" -gt 60 ]; then break; fi
  done
  _LABEL="${out# }"
}

print_top() {
  local d="$1" rows="" p cpu
  collect_pids "$d"
  [ "${#_PIDS[@]}" -gt 0 ] || return 0
  for p in "${_PIDS[@]}"; do
    proc_rss "$p"   || continue
    proc_ticks "$p" || continue
    if [ -n "${T0[$p]:-}" ]; then
      cpu=$(( (_TICKS - T0[$p]) * 100 / HZ / SAMPLE ))
      [ "$cpu" -ge 0 ] || cpu=0
    else
      # Joined the bucket mid-window: no baseline, so its lifetime total would
      # read as if it all happened in this second. Say nothing instead.
      cpu=""
    fi
    rows+="$_RSS ${cpu:-0} $p ${cpu:+$cpu%}"$'\n'
  done
  [ -n "$rows" ] || return 0
  printf '%s' "$rows" | sort -rn -k"$sortfield","$sortfield" | head -n "$top" |
    while read -r rss _ p shown; do
      proc_label "$p"
      printf '    - %-36.36s %7s %11s\n' "$_LABEL" "${shown:--}" "$(human "$rss")"
    done
}

snapshot() {
  local quota period cap mhigh mhigh_h
  # Printed BEFORE the pool check: the semaphore is a separate subsystem and is
  # worth seeing even on a tick where the pool has gone empty (systemd removes
  # the slice whenever it does), which is exactly when a queue behind a wedged
  # controller would otherwise be invisible.
  sem_line
  # Re-checked EVERY snapshot, not only at startup: in watch mode the pool
  # legitimately vanishes while idle (see the startup check's comment), and
  # the bare `read < $POOL/cpu.max` below then failed its redirect, left
  # `quota` unset, and nounset killed the whole watch loop (2026-08-07). The
  # read keeps its own fallback for the window between this test and the open.
  if [ ! -d "$POOL" ]; then
    pool_missing
    return 1
  fi
  read -r quota period 2>/dev/null < "$POOL/cpu.max" || { pool_missing; return 1; }
  if [ "$quota" = "max" ]; then cap="unlimited"; else cap="$(( quota * 100 / period ))%"; fi
  mhigh=$(cat "$POOL/memory.high" 2>/dev/null)
  if [ "$mhigh" = "max" ]; then mhigh_h="unlimited"; else mhigh_h=$(human "$mhigh"); fi

  # First CPU sample for the pool, every bucket, and (if we are showing them)
  # every process — all three deltas have to straddle the same one sleep.
  local d p
  local -A u0
  u0[__pool__]=$(cpuusec "$POOL")
  local dirs=()
  for d in "$POOL"/*/; do [ -d "$d" ] || continue; dirs+=("$d"); u0["$d"]=$(cpuusec "$d"); done
  T0=()
  if [ "$top" -gt 0 ]; then
    for d in "${dirs[@]}"; do
      collect_pids "$d"
      for p in "${_PIDS[@]}"; do
        proc_ticks "$p" && T0[$p]=$_TICKS
      done
    done
  fi
  sleep "$SAMPLE"

  # Pool line (second sample).
  local u1 pct pmem
  u1=$(cpuusec "$POOL"); pmem=$(cat "$POOL/memory.current" 2>/dev/null)
  pct=$(( (u1 - u0[__pool__]) / 10000 / SAMPLE ))
  printf '  POOL  %-24s  CPU %5s%% / %-9s  mem %9s / %-9s  psi cpu:%s mem:%s\n' \
    "worktrees.slice" "$pct" "$cap" "$(human "$pmem")" "$mhigh_h" "$(psi10 "$POOL")" "$(mpsi10 "$POOL")"
  printf '  %s\n' "-------------------------------------------------------------------------------"
  printf '  %-40s %7s %11s %6s %9s\n' "BUCKET" "CPU%" "MEM" "TASKS" "PSI(cpu)"
  if [ "$top" -gt 0 ]; then
    printf '  %s\n' "(indented: top $top procs by $sortkey — RSS, which neither sums nor matches the bucket)"
  fi

  if [ "${#dirs[@]}" -eq 0 ]; then
    printf '  (no active buckets)\n'
    return
  fi
  for d in "${dirs[@]}"; do
    local b u1b pctb mem tasks
    b=$(basename "$d"); b=${b%.slice}; b=${b#worktrees-}
    u1b=$(cpuusec "$d")
    pctb=$(( (u1b - ${u0[$d]:-0}) / 10000 / SAMPLE ))
    mem=$(cat "$d/memory.current" 2>/dev/null)
    tasks=$(cat "$d/pids.current" 2>/dev/null || echo "?")
    printf '  %-40.40s %6s%% %11s %6s %9s\n' "$(unesc "$b")" "$pctb" "$(human "$mem")" "$tasks" "$(psi10 "$d")"
    # An `&&` here would make a false test the loop's — and so the script's —
    # exit status, i.e. `-t 0` would report failure on a perfectly good run.
    if [ "$top" -gt 0 ]; then print_top "$d"; fi
  done
}

# TEST SEAM. scripts/wt-cgroup-status.test.py exercises the parsers above
# against fixture trees: it sources this file (KX_POOL and WT_CG_PROC pointed
# at a tempdir — the pool must exist, or the startup check above exits the
# sourcing shell) and calls the functions directly. `return` succeeds only in
# a sourced context, so a sourced load stops HERE — definitions and argument
# checks only, no sampling, no loop. Executed normally, the subshell's
# `return` fails and the script falls through to the dispatch below.
if (return 0 2>/dev/null); then
  return 0
fi

if [ "$watch" = 1 ]; then
  while :; do
    clear 2>/dev/null || printf '\n\n'
    printf 'worktrees.slice cgroup budget — %s (refresh %ss · ctrl-c to quit)\n\n' \
      "$(date +%T 2>/dev/null || echo now)" "$interval"
    snapshot
    sleep "$interval"
  done
else
  snapshot
fi
