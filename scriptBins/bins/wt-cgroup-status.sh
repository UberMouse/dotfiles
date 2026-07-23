# wt-cgroup-status — snapshot (or --watch) of the worktrees.slice cgroup
# budget: per-bucket CPU% / memory / tasks / CPU-pressure, plus the pool total
# against its caps.
#
# Reads the cgroup v2 files directly (works even where systemd-cgtop prints "-"
# for the CPU column of transient scopes) and un-escapes slice names back to
# readable worktree names.
#
# CPU% is cgtop-style: 100% == one core. The pool cap of 1200% == 12 cores.
#
# Usage:
#   wt-cgroup-status            one-shot snapshot
#   wt-cgroup-status -w [SECS]  refresh every SECS seconds (default 2)
#
# Env: WT_CG_SAMPLE=<secs> — gap between the two CPU samples (default 1).

U=$(id -u)
POOL="/sys/fs/cgroup/user.slice/user-$U.slice/user@$U.service/worktrees.slice"
SAMPLE="${WT_CG_SAMPLE:-1}"

watch=0; interval=2
case "${1:-}" in
  -w|--watch) watch=1; [ -n "${2:-}" ] && interval="$2" ;;
  -h|--help) awk 'NR==1{next} /^#/{f=1;sub(/^# ?/,"");print;next} f{exit}' "$0"; exit 0 ;;
esac

if [ ! -d "$POOL" ]; then
  echo "worktrees.slice pool is not active yet."
  echo "It materializes on the first heavy command the hook wraps (or the first"
  echo "daemon started with CLAUDE_WORKTREE_CGROUP set). Nothing to show."
  exit 1
fi

unesc()   { local s="$1"; printf '%s' "${s//\\x2d/-}"; }
human()   { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; }
cpuusec() { awk '/^usage_usec/{print $2}' "$1/cpu.stat" 2>/dev/null || echo 0; }
psi10()   { awk -F'[= ]' '/^some/{print $3}' "$1/cpu.pressure"    2>/dev/null || echo "-"; }
mpsi10()  { awk -F'[= ]' '/^some/{print $3}' "$1/memory.pressure" 2>/dev/null || echo "-"; }

snapshot() {
  local quota period cap mhigh mhigh_h
  read -r quota period < "$POOL/cpu.max"
  if [ "$quota" = "max" ]; then cap="unlimited"; else cap="$(( quota * 100 / period ))%"; fi
  mhigh=$(cat "$POOL/memory.high" 2>/dev/null)
  if [ "$mhigh" = "max" ]; then mhigh_h="unlimited"; else mhigh_h=$(human "$mhigh"); fi

  # First CPU sample for the pool and every bucket.
  local d
  local -A u0
  u0[__pool__]=$(cpuusec "$POOL")
  local dirs=()
  for d in "$POOL"/*/; do [ -d "$d" ] || continue; dirs+=("$d"); u0["$d"]=$(cpuusec "$d"); done
  sleep "$SAMPLE"

  # Pool line (second sample).
  local u1 pct pmem
  u1=$(cpuusec "$POOL"); pmem=$(cat "$POOL/memory.current" 2>/dev/null)
  pct=$(( (u1 - u0[__pool__]) / 10000 / SAMPLE ))
  printf '  POOL  %-24s  CPU %5s%% / %-9s  mem %9s / %-9s  psi cpu:%s mem:%s\n' \
    "worktrees.slice" "$pct" "$cap" "$(human "$pmem")" "$mhigh_h" "$(psi10 "$POOL")" "$(mpsi10 "$POOL")"
  printf '  %s\n' "-------------------------------------------------------------------------------"
  printf '  %-40s %7s %11s %6s %9s\n' "BUCKET" "CPU%" "MEM" "TASKS" "PSI(cpu)"

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
