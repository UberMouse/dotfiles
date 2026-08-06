# wt-cgroup-status — snapshot (or --watch) of the worktrees.slice cgroup
# budget: per-bucket CPU% / memory / tasks / CPU-pressure, plus the pool total
# against its caps, and the top processes inside each bucket.
#
# Reads the cgroup v2 files directly (works even where systemd-cgtop prints "-"
# for the CPU column of transient scopes) and un-escapes slice names back to
# readable worktree names.
#
# CPU% is cgtop-style: 100% == one core. The pool cap of 1200% == 12 cores.
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
# Env: WT_CG_SAMPLE=<secs> — gap between the two CPU samples (default 1).

U=$(id -u)
POOL="/sys/fs/cgroup/user.slice/user-$U.slice/user@$U.service/worktrees.slice"
SAMPLE="${WT_CG_SAMPLE:-1}"

# Both have a fallback because getconf lives in glibc.bin, which is on PATH by
# inheritance rather than by being a declared runtime input.
HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
PAGE=$(getconf PAGESIZE 2>/dev/null || echo 4096)

watch=0; interval=2; top=3; sortkey=mem
while [ "$#" -gt 0 ]; do
  case "$1" in
    -w|--watch)
      watch=1
      # SECS is optional, so only swallow the next argv if it looks like one.
      case "${2:-}" in ''|-*) ;; *) interval="$2"; shift ;; esac ;;
    -t|--top)  top="${2:-3}"; shift ;;
    -s|--sort) sortkey="${2:-mem}"; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{f=1;sub(/^# ?/,"");print;next} f{exit}' "$0"; exit 0 ;;
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

if [ ! -d "$POOL" ]; then
  echo "worktrees.slice pool is not active yet."
  echo "It materializes on the first heavy command the hook wraps (or the first"
  echo "daemon started with CLAUDE_WORKTREE_CGROUP set). Nothing to show."
  exit 1
fi

shopt -s globstar nullglob

unesc()   { local s="$1"; printf '%s' "${s//\\x2d/-}"; }
human()   { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }
cpuusec() { awk '/^usage_usec/{print $2}' "$1/cpu.stat" 2>/dev/null || echo 0; }
psi10()   { awk -F'[= ]' '/^some/{print $3}' "$1/cpu.pressure"    2>/dev/null || echo "-"; }
mpsi10()  { awk -F'[= ]' '/^some/{print $3}' "$1/memory.pressure" 2>/dev/null || echo "-"; }

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
  read -r line 2>/dev/null < "/proc/$1/stat" || return 1
  rest=${line##*') '}
  # shellcheck disable=SC2206 # deliberate splitting of a known-numeric line
  local -a f=( $rest )
  _TICKS=$(( ${f[11]:-0} + ${f[12]:-0} ))
}

# statm field 2 is resident pages.
proc_rss() {
  local line
  read -r line 2>/dev/null < "/proc/$1/statm" || return 1
  # shellcheck disable=SC2206 # ditto
  local -a f=( $line )
  _RSS=$(( ${f[1]:-0} * PAGE ))
}

proc_label() {
  local -a toks=()
  local t out=""
  mapfile -d '' -t toks 2>/dev/null < "/proc/$1/cmdline"
  if [ "${#toks[@]}" -eq 0 ] || [ -z "${toks[0]}" ]; then
    read -r out 2>/dev/null < "/proc/$1/comm" || out="pid $1"
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
  read -r quota period < "$POOL/cpu.max"
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
