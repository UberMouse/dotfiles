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
# When CGPM_INVESTIGATE is set, each stall also spawns a headless `claude -p`
# that reads the snapshot (inlined, NO tools -> no system access, also defuses
# any prompt-injection in captured cmdlines) and writes a root-cause analysis +
# notifies. Diagnose-only: it never changes anything.
#
# Snapshots, analyses + an events.log land in $CGPM_OUTDIR (default
# ~/.local/state/cgroup-pressure). Investigate later:  ls -t "$CGPM_OUTDIR"
#
# Tunables (env):
#   CGPM_THRESH               full-avg10 %% that counts as a stall  (default 20)
#   CGPM_INTERVAL             poll seconds                          (default 5)
#   CGPM_COOLDOWN             min seconds between snapshots         (default 120)
#   CGPM_OUTDIR               output directory
#   CGPM_INVESTIGATE          set non-empty to spawn a claude diagnosis on stall
#   CGPM_CLAUDE               claude binary (default: claude on PATH)
#   CGPM_MODEL                model for the diagnosis                (default opus)
#   CGPM_INVESTIGATE_COOLDOWN min seconds between diagnoses         (default 1800)
set -u

OUTDIR="${CGPM_OUTDIR:-$HOME/.local/state/cgroup-pressure}"
THRESH="${CGPM_THRESH:-20}"
INTERVAL="${CGPM_INTERVAL:-5}"
COOLDOWN="${CGPM_COOLDOWN:-120}"
CLAUDE_BIN="${CGPM_CLAUDE:-claude}"
MODEL="${CGPM_MODEL:-opus}"
INV_COOLDOWN="${CGPM_INVESTIGATE_COOLDOWN:-1800}"
mkdir -p "$OUTDIR"
LOG="$OUTDIR/events.log"

U=$(id -u)
POOL="/sys/fs/cgroup/user.slice/user-$U.slice/user@$U.service/worktrees.slice"
USERAT="/sys/fs/cgroup/user.slice/user-$U.slice/user@$U.service"
last_snap=0
last_investigate=0

full_avg10() { awk '/^full/{for(i=1;i<=NF;i++){n=split($i,a,"=");if(a[1]=="avg10")print a[2]}}' "$1" 2>/dev/null; }
human() { numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1}B"; }

# Spawn a headless, tool-less claude to diagnose the just-captured snapshot.
# Detached + nice'd + timeout'd + best-effort: any failure only costs the
# auto-diagnosis, never the monitor or the snapshot itself.
investigate() {
  local snapfile="$1"
  [ -n "${CGPM_INVESTIGATE:-}" ] || return 0
  command -v "$CLAUDE_BIN" >/dev/null 2>&1 || { echo "$(date -Iseconds)  investigate: $CLAUDE_BIN not found" >> "$LOG"; return 0; }
  local now; now=$(date +%s)
  [ $((now - last_investigate)) -ge "$INV_COOLDOWN" ] || return 0
  last_investigate=$now
  ( run_investigation "$snapfile" ) &
}

run_investigation() {
  local snapfile="$1"
  local stamp analysis snap prompt headline
  stamp=$(date +%Y%m%d-%H%M%S)
  analysis="$OUTDIR/analysis-$stamp.md"
  snap=$(cat "$snapfile" 2>/dev/null)

  prompt="You are diagnosing a Linux desktop that just STALLED/HUNG under load. Below is a forensic snapshot captured at the moment of the stall by a cgroup-v2 PSI monitor. Reason ONLY from the snapshot.

Machine: 16-core / 27 GiB NixOS host (ubermouse). Parallel git-worktree build work runs inside a cgroup-v2 pool 'worktrees.slice', capped at CPUQuota 1200%% (12 cores), MemoryHigh 16G (soft), IOWeight 50; a Claude 'agents' fleet is adopted into worktrees.slice/agents-adopted. The DESKTOP (Xorg) runs in session-2.scope OUTSIDE the pool. Known dynamics: (a) the pool at its MemoryHigh can drive GLOBAL memory reclaim that swaps out Xorg -> whole-machine freeze, shown by system 'memory full' PSI spiking; (b) too-low MemoryHigh instead causes perpetual reclaim-throttle (also slow), shown by memory.events 'high' climbing fast; (c) CPU is essentially never the cause (cpu PSI full ~= 0). The machine is memory-oversubscribed when a browser + several parallel builds run.

From the snapshot, produce a SHORT markdown report:
1. Which resource stalled the machine (memory / io / cpu) — cite the PSI 'full' avg figures.
2. The specific cgroup(s) and process(es) responsible, with their memory (RSS) and/or CPU.
3. Root cause in 1-2 sentences.
4. One concrete recommendation (e.g. set MemoryHigh to X, cut concurrency to N, add desktop memory.min).
The VERY FIRST line must be exactly:  HEADLINE: <one sentence cause>

--- SNAPSHOT ---
$snap"

  # prompt on stdin (avoids the variadic --disallowedTools swallowing it);
  # dangerous tools blocked -> pure offline reasoning, no system access.
  if printf '%s' "$prompt" | timeout 360 nice -n 15 "$CLAUDE_BIN" -p --model "$MODEL" \
       --disallowedTools Bash Edit Write NotebookEdit Task WebFetch WebSearch \
       > "$analysis" 2>>"$LOG"; then
    echo "$(date -Iseconds)  INVESTIGATED -> $analysis" >> "$LOG"
  else
    echo "$(date -Iseconds)  investigate: claude exited non-zero (see $analysis)" >> "$LOG"
  fi

  if command -v notify-send >/dev/null 2>&1; then
    headline=$(grep -m1 '^HEADLINE:' "$analysis" 2>/dev/null | sed 's/^HEADLINE:[[:space:]]*//')
    [ -n "$headline" ] || headline="diagnosis ready"
    notify-send -u critical -t 20000 "System hang — Claude diagnosis" "$headline
$analysis" 2>/dev/null || true
  fi
}

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

  investigate "$file"
}

echo "$(date -Iseconds)  cgroup-pressure-monitor started (thresh=${THRESH}% full-avg10, interval=${INTERVAL}s, cooldown=${COOLDOWN}s, investigate=${CGPM_INVESTIGATE:-off})" >> "$LOG"

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
