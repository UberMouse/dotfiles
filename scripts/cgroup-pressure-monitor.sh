#!/usr/bin/env bash
# cgroup-pressure-monitor — watch system memory/IO pressure (PSI) and, when the
# machine is actually stalling, capture a forensic snapshot + desktop alert so
# the cause can be investigated AFTER the fact (freezes/slowdowns are transient;
# a point-in-time `ps` after the event shows nothing).
#
# PSI "full" = fraction of time ALL non-idle tasks were stalled on a resource =
# the freeze/crawl. We trigger on that, not on loadavg (which lags and is
# inflated by CPU throttling that is NOT the problem here).
#
# Snapshots + an events.log land in $CGPM_OUTDIR (default
# ~/.local/state/cgroup-pressure). Investigate later:  ls -t "$CGPM_OUTDIR"
#
# Tunables (env):
#   CGPM_THRESH    full-avg10 %% that counts as a stall   (default 20)
#   CGPM_INTERVAL  poll seconds                            (default 5)
#   CGPM_COOLDOWN  min seconds between snapshots           (default 120)
#   CGPM_OUTDIR    output directory
set -u

OUTDIR="${CGPM_OUTDIR:-$HOME/.local/state/cgroup-pressure}"
THRESH="${CGPM_THRESH:-20}"
INTERVAL="${CGPM_INTERVAL:-5}"
COOLDOWN="${CGPM_COOLDOWN:-120}"
mkdir -p "$OUTDIR"
LOG="$OUTDIR/events.log"

U=$(id -u)
POOL="/sys/fs/cgroup/user.slice/user-$U.slice/user@$U.service/worktrees.slice"
USERAT="/sys/fs/cgroup/user.slice/user-$U.slice/user@$U.service"
last_snap=0

# extract "full ... avg10=<x>" from a /proc/pressure/* file
full_avg10() { awk '/^full/{for(i=1;i<=NF;i++){n=split($i,a,"=");if(a[1]=="avg10")print a[2]}}' "$1" 2>/dev/null; }
human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1}B"; }

snapshot() {
  local reason="$1"
  local stamp file
  stamp=$(date +%Y%m%d-%H%M%S)
  file="$OUTDIR/snap-$stamp.txt"
  {
    echo "==================================================================="
    echo "$(date -Iseconds)   TRIGGER: $reason"
    echo "loadavg: $(cut -d' ' -f1-4 /proc/loadavg)   nproc=$(nproc)"
    echo
    echo "----- system PSI (full = whole machine stalled) -----"
    for r in memory io cpu; do echo "[$r]"; sed 's/^/  /' "/proc/pressure/$r"; done
    echo
    echo "----- memory / swap -----"
    free -h
    echo "swap:"; swapon --show 2>/dev/null | sed 's/^/  /'
    echo
    echo "----- pool (worktrees.slice) -----"
    if [ -d "$POOL" ]; then
      echo "  memory.high    : $(human "$(cat "$POOL/memory.high" 2>/dev/null)")"
      echo "  memory.current : $(human "$(cat "$POOL/memory.current" 2>/dev/null)")"
      echo "  memory.swap.cur: $(human "$(cat "$POOL/memory.swap.current" 2>/dev/null)")"
      echo "  memory.events  : $(tr '\n' ' ' < "$POOL/memory.events" 2>/dev/null)"
      echo "  memory.pressure: $(sed -n 2p "$POOL/memory.pressure" 2>/dev/null)"
      echo "  io.pressure    : $(sed -n 2p "$POOL/io.pressure" 2>/dev/null)"
      echo "  cpu.stat       : $(tr '\n' ' ' < "$POOL/cpu.stat" 2>/dev/null)"
    else
      echo "  (pool cgroup not found)"
    fi
    echo
    echo "----- top cgroups by memory.current (under user@) -----"
    find "$USERAT" -name memory.current 2>/dev/null | while read -r f; do
      v=$(cat "$f" 2>/dev/null); [ -n "$v" ] && [ "$v" -gt 0 ] 2>/dev/null && \
        printf '%s\t%s\n' "$v" "${f%/memory.current}"
    done | sort -rn | head -12 | while read -r v p; do
      printf '  %10s  %s\n' "$(human "$v")" "${p#"$USERAT"/}"
    done
    echo
    echo "----- top 20 processes by RSS -----"
    ps -eo pid,rss,pcpu,comm --sort=-rss --no-headers 2>/dev/null | head -20 | while read -r pid rss pcpu comm; do
      cg=$(cut -d: -f3- "/proc/$pid/cgroup" 2>/dev/null | sed "s#/user.slice/user-$U.slice/user@$U.service##")
      cl=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-50)
      printf '  pid=%-7s rss=%7sM cpu=%5s%%  %-14s %-38s %s\n' \
        "$pid" "$((rss/1024))" "$pcpu" "$comm" "$cg" "$cl"
    done
  } >> "$file" 2>&1

  echo "$(date -Iseconds)  $reason  -> $file" >> "$LOG"
  if command -v notify-send >/dev/null 2>&1; then
    notify-send -u critical -t 8000 "cgroup pressure stall" "$reason
snapshot: $file" 2>/dev/null || true
  fi
}

echo "$(date -Iseconds)  cgroup-pressure-monitor started (thresh=${THRESH}% full-avg10, interval=${INTERVAL}s, cooldown=${COOLDOWN}s)" >> "$LOG"

while :; do
  m=$(full_avg10 /proc/pressure/memory); m=${m:-0}
  i=$(full_avg10 /proc/pressure/io);     i=${i:-0}
  now=$(date +%s)
  if awk -v m="$m" -v i="$i" -v t="$THRESH" 'BEGIN{exit !(m>=t || i>=t)}'; then
    if [ $((now - last_snap)) -ge "$COOLDOWN" ]; then
      snapshot "mem_full_avg10=${m}%  io_full_avg10=${i}%  (>= ${THRESH}%)"
      last_snap=$now
    fi
  fi
  sleep "$INTERVAL"
done
