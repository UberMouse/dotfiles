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
# We measure PSI on the DESKTOP graphical session scope (session-<N>.scope),
# NOT system-wide. The pool's io.max deliberately concentrates build stall
# INSIDE worktrees.slice, so system-wide io PSI now sits near the old threshold
# during any build storm even when the desktop is fine — that's the cap working,
# not a stall. The desktop scope's own PSI is the only signal that the user
# actually stalled, so that is what wakes the monitor.
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
#   CGPM_THRESH               DESKTOP full-avg10 %% that counts as a stall
#                             (integer %, default 15 -- it is pre-scaled for an
#                             integer compare, see THRESH_CENTI)
#   CGPM_INTERVAL             poll seconds                          (default 5)
#   CGPM_COOLDOWN             min seconds between snapshots         (default 120)
#   CGPM_OUTDIR               output directory
#   CGPM_INVESTIGATE          set non-empty to spawn a claude diagnosis on stall
#   CGPM_CLAUDE               claude binary (default: claude on PATH)
#   CGPM_MODEL                model for the diagnosis                (default opus)
#   CGPM_INVESTIGATE_COOLDOWN min seconds between diagnoses         (default 1800)
#   KX_CGROUP_MEM_LIB         path to cgroup-mem.py (net-of-cache correction)
#   CGPM_PYTHON               python3 for the above          (default python3 on PATH)
set -u

OUTDIR="${CGPM_OUTDIR:-$HOME/.local/state/cgroup-pressure}"
THRESH="${CGPM_THRESH:-15}"
INTERVAL="${CGPM_INTERVAL:-5}"
COOLDOWN="${CGPM_COOLDOWN:-120}"
CLAUDE_BIN="${CGPM_CLAUDE:-claude}"
MODEL="${CGPM_MODEL:-opus}"
INV_COOLDOWN="${CGPM_INVESTIGATE_COOLDOWN:-1800}"
# The net-of-cache correction (see mem_net). Both are OPTIONAL on purpose: a
# snapshot missing its net column is degraded but still a snapshot, whereas a
# monitor that refused to capture because an interpreter was missing would
# destroy the only record of the stall it exists to record. mem_net returns
# non-zero when either is absent and the caller falls back to raw, saying so.
MEMLIB="${KX_CGROUP_MEM_LIB:-$(dirname "${BASH_SOURCE[0]}")/cgroup-mem.py}"
PYTHON="${CGPM_PYTHON:-$(command -v python3 2>/dev/null)}"
# Fail LOUDLY if the output directory cannot exist. Unchecked (as this was
# until 2026-08-07), a failed mkdir meant every event append and snapshot below
# went nowhere, forever, silently -- a monitor whose whole job is to leave a
# trace would leave none. Exiting lets systemd (Restart=always) retry and
# surface the flapping unit instead.
mkdir -p "$OUTDIR" || { echo "cgroup-pressure-monitor: cannot create output dir '$OUTDIR'" >&2; exit 1; }
LOG="$OUTDIR/events.log"

# Shared helpers (PSI parser, desktop resolution, cgroup paths incl. the
# KX_POOL override). CGLIB is set by the systemd unit (single-file store
# paths have no siblings); the BASH_SOURCE fallback serves local runs and
# the test suites' sourcing seam.
# shellcheck disable=SC1090  # path is env-supplied (CGLIB) in production
. "${CGLIB:-$(dirname "${BASH_SOURCE[0]}")/cgroup-lib.sh}" || {
  echo "cgroup-pressure-monitor: cannot source cgroup-lib.sh" >&2; exit 1;
}
kx_cgroup_paths
last_snap=0
last_investigate=0

# Threshold pre-scaled to the integer hundredths psi_full_avg10 returns, so the
# per-tick comparison is a shell integer test and not an awk invocation.
# ("15.00" -> 1500 >= 1500 fires; "14.99" -> 1499 does not.) This is why
# CGPM_THRESH must be an integer percent.
THRESH_CENTI=$(( THRESH * 100 ))

# psi_full_avg10 comes from cgroup-lib.sh (sourced above), which carries the
# FORK BUDGET argument for why it sets globals instead of echoing.
human() {
  # cgroup memory files can hold the literal "max"; pass non-numbers through.
  case "${1:-}" in
    '' | *[!0-9]*) echo "${1:-?}" ;;
    *) numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B" ;;
  esac
}

# NET-OF-CACHE memory for a set of cgroups, via THE shared definition in
# cgroup-mem.py rather than a private reimplementation -- see that file's CLI
# note. Emits "<raw> (net <in-use>, <n>% cache)" per path, or the raw charge
# alone when the correction has no signal, so the snapshot never silently
# downgrades to the uncorrected number without saying so.
#
# WHY THE SNAPSHOT NEEDS THIS AT ALL. `memory.current` counts page cache, and
# every snapshot before 2026-08-25 printed only that -- while the inlined
# diagnosis prompt below orders the model to reason ONLY from the snapshot. So
# the forensic record structurally could not support the correction that
# CLAUDE.md, cgroup-mem.py and three other consumers all treat as mandatory,
# and the diagnoses followed it straight into the trap: the 15:37 analysis that
# day read a 14G pool charge as 14G in use and recommended cutting MemoryHigh
# 16G -> 11G, when 52% of that charge was reclaimable cache and the cut would
# have converted a memory stall into the cache thrash that produced the SAME
# day's two io-mode stalls. A trap the prompt cannot see past is a trap in the
# capture, not in the model.
mem_net() {
  [ -n "${MEMLIB:-}" ] && [ -x "${PYTHON:-}" ] || return 1
  "$PYTHON" "$MEMLIB" "$@" 2>/dev/null | while IFS=$(printf '\t') read -r path cur recl use; do
    # Two-step trim: pool-relative where that applies (matching the top-cgroups
    # section below), else cgroup-root-relative (matching the desktop section
    # above). The desktop scope and user@ itself are not under $USERAT, and
    # printing their absolute paths broke the column alignment for every row.
    label="${path#"$USERAT"/}"; label="${label#/sys/fs/cgroup}"
    case "$cur/$use" in
      */-|-/*) printf '  %-46s %s\n' "$label" "$(human "$cur") (net: NO SIGNAL, memory.stat unreadable)" ;;
      *) printf '  %-46s %s (net %s, %d%% cache)\n' "$label" \
           "$(human "$cur")" "$(human "$use")" "$(( cur > 0 ? recl * 100 / cur : 0 ))" ;;
    esac
  done
}

# resolve_desktop comes from cgroup-lib.sh; the monitor probes io.pressure
# (the file it reads for the desktop's stall signal), the governor
# memory.pressure.

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

  # MACHINE FACTS ARE READ LIVE, never hand-copied into the prose. A previous
  # version of this prompt hardcoded "MemoryHigh 16G / MemoryMax 18G" and
  # "memory.min=6G"; both numbers were retuned in cgroups.nix/nixos.nix and every
  # diagnosis from then on reasoned about a machine that no longer existed --
  # the exact staleness failure cgroups.nix's 07-28..07-31 note documents for the
  # governor's dead window. Forks are fine here: this is the (rare, cooled-down)
  # investigate path, not the detection loop the fork budget protects.
  local ncpu mem_gib pool_high pool_max desk_min cpu_cores
  ncpu=$(nproc 2>/dev/null || echo '?')
  mem_gib=$(awk '/^MemTotal/{printf "%.1f", $2 / 1048576}' /proc/meminfo 2>/dev/null || echo '?')
  pool_high=$(human "$(cat "$POOL/memory.high" 2>/dev/null)")
  pool_max=$(human "$(cat "$POOL/memory.max" 2>/dev/null)")
  desk_min=$(human "$(cat "$DESKTOP/memory.min" 2>/dev/null)")
  cpu_cores=$(awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {printf "%.0f", $1 / $2}' "$POOL/cpu.max" 2>/dev/null)
  [ -n "$cpu_cores" ] || cpu_cores="unlimited"

  prompt="You are diagnosing a Linux DESKTOP that just STALLED. Below is a forensic snapshot captured at the moment of the stall by a cgroup-v2 PSI monitor. Reason ONLY from the snapshot.

Machine: ${ncpu}-core / ${mem_gib} GiB NixOS host (ubermouse). Parallel git-worktree build work + an adopted Claude 'agents' fleet run inside a cgroup-v2 pool 'worktrees.slice' (subtree agents-adopted), capped: ${cpu_cores} cores CPU quota, MemoryHigh ${pool_high} / MemoryMax ${pool_max}, and io.max on the build disk (value in the snapshot). IMPORTANT: io.weight is a NO-OP on this host (the mq-deadline scheduler ignores it) -> io.max is the ONLY thing bounding pool I/O; do NOT recommend raising/lowering io.weight. The DESKTOP (Xorg/browser) runs in a session-<N>.scope OUTSIDE the pool, protected by memory.min=${desk_min} (guaranteed via the user.slice ancestor chain so the POOL, not Xorg, is the reclaim target) and io.latency target=50ms (its I/O jumps the disk queue ahead of the pool).

CRUCIAL: this monitor triggers on the DESKTOP session scope's OWN PSI (the 'desktop' section of the snapshot), NOT system-wide. The pool's io.max deliberately CONCENTRATES build stall inside the pool, so 'pool io.pressure' running HIGHER than 'system io PSI' is EXPECTED and means the cap is WORKING — that alone is NOT the problem and needs no fix. The problem is ONLY whatever pushed the DESKTOP scope's own io/memory pressure over ~15%. If desktop pressure is low despite high pool/system pressure, the protections HELD and you should say so plainly.

Known dynamics: (a) MEMORY-FREEZE — global reclaim swaps out the desktop despite memory.min; shown by DESKTOP memory.pressure high AND on-disk swap (dm-*/partition, not zram) climbing. (b) IO-CONTENTION — builds saturate the virtual disk faster than io.max throttles, or io.latency fails to prioritise the desktop; shown by DESKTOP io.pressure high. (c) CPU is essentially never the cause (cpu full ~= 0).

TRAP — memory.current IS NOT MEMORY IN USE. It counts PAGE CACHE, which the kernel takes back unasked and which free(1) files under buff/cache rather than used. A pool reading 16G against a 16G memory.high beside a machine reporting far less in use is NOT a contradiction and NOT a bug: the two numbers never measured the same thing. This pool does tens of GB of file IO, so the gap is routinely HALF the charge (measured 2026-08-25: 52% of the pool charge and 47% of the fleet's was reclaimable cache; 2026-08-20: 15.2G charged, 7.36G anon). The snapshot's 'memory IN USE, net of reclaimable page cache' section is the number to reason from — every 'memory.current' line elsewhere in it is RAW and overstates real usage. You MUST NOT compute a shortfall, a percentage-of-ceiling, or a MemoryHigh recommendation from a raw charge when the net column is present. Doing exactly that on 2026-08-25 produced a recommendation to cut the pool from 16G to 11G on the strength of a 14G charge that was mostly cache — a cut that would have starved the pool of page cache and converted a memory stall into an IO stall, which is the OTHER failure mode seen the same day. If the net section says NO SIGNAL or is unavailable, say so explicitly and treat every memory figure as an upper bound rather than quietly reasoning from it. NOTE the asymmetry: memory.high is a limit on the RAW charge, so do not 'correct' the ceiling to match the net usage — the correction applies to the usage side only.

TRAP — do NOT recommend reclaiming the agents fleet on argv alone. A process whose command line contains 'bg-spare' is NOT necessarily idle: that string records how it STARTED, and once a session claims the spare it becomes a live agent doing real work while the argv is unchanged. The only way to tell them apart is the process cwd (a genuine idle spare is still inside the cc-daemon spare directory; a claimed one has moved into the worktree it is working in), and the snapshot does NOT contain cwd. Measured 2026-08-19: of 14 bg-spare processes only 7 were truly idle (~571MB); the rest were claimed sessions holding ~2.3GB of real work. So you MUST NOT present the fleet's total RSS as reclaimable slack. If the fleet looks large, say only that its idle fraction is unknown from this snapshot and must be checked with cwd before any reaping.

From the snapshot, produce a SHORT markdown report:
1. Which resource stalled the DESKTOP (memory / io / cpu) — cite the DESKTOP-section 'full' avg figures, plus pool + system figures for context.
2. Did the protections hold? Compare desktop vs pool vs system pressure and state whether io.max / io.latency / memory.min did their job (or say the desktop was collateral and which one failed).
3. The specific cgroup(s) and process(es) driving it, with RSS and/or CPU.
4. One concrete recommendation to protect the DESKTOP (e.g. lower pool io.max to X, sharpen desktop io.latency target to Y ms, raise desktop memory.min, or cut build concurrency to N). Do NOT touch io.weight.
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

# Forks are fine in here: snapshot runs only on the (rare, COOLDOWN-limited)
# stall path, where forensic completeness is worth any number of forks -- by
# the time this fires, detection has already done its job.
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
      echo "  io.max         : $(cat "$POOL/io.max" 2>/dev/null)"
      echo "  io.weight      : $(cat "$POOL/io.weight" 2>/dev/null)  (NO-OP on mq-deadline; io.max is the real bound)"
      echo "  io.stat        : $(tr '\n' ' ' < "$POOL/io.stat" 2>/dev/null)"
      echo "  cpu.stat       : $(tr '\n' ' ' < "$POOL/cpu.stat" 2>/dev/null)"
    else
      echo "  (pool cgroup not found)"
    fi
    echo
    echo "----- desktop (graphical session scope, OUTSIDE the pool) -----"
    if [ -n "$DESKTOP" ] && [ -d "$DESKTOP" ]; then
      echo "  scope          : ${DESKTOP#/sys/fs/cgroup}"
      echo "  memory.pressure: $(sed -n 2p "$DESKTOP/memory.pressure" 2>/dev/null)  <- desktop mem stall (the trigger)"
      echo "  io.pressure    : $(sed -n 2p "$DESKTOP/io.pressure" 2>/dev/null)  <- desktop io stall (the trigger)"
      echo "  memory.current : $(human "$(cat "$DESKTOP/memory.current" 2>/dev/null)")"
      echo "  memory.min     : $(human "$(cat "$DESKTOP/memory.min" 2>/dev/null)")  (desktop RAM guarantee)"
      echo "  io.latency     : $(cat "$DESKTOP/io.latency" 2>/dev/null)  (desktop io priority target, usec)"
    else
      echo "  (desktop session scope not resolved)"
    fi
    echo
    echo "----- memory IN USE, net of reclaimable page cache -----"
    echo "  (memory.current counts page cache; free(1) files that same cache under"
    echo "   buff/cache, NOT used. These two never measured the same thing. Read the"
    echo "   NET column as 'in use'; the raw charge overstates it, routinely by half.)"
    if mem_net "$POOL" ${DESKTOP:+"$DESKTOP"} "$USERAT"; then :; else
      echo "  (unavailable: no python3 or cgroup-mem.py -- every memory.current"
      echo "   printed in this snapshot is therefore RAW and includes page cache)"
    fi
    echo
    echo "----- top cgroups by memory.current (RAW -- includes page cache) -----"
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

# TEST SEAM. scripts/cgroup-governor.test.py sources this file to drive the
# PSI parser above against fixtures. `return` succeeds only in a sourced
# context, so a sourced load stops HERE -- definitions only, no startup line,
# no loop. Executed normally (systemd), the subshell's `return` fails and the
# monitor falls through to the loop below.
if (return 0 2>/dev/null); then
  return 0
fi

echo "$(date -Iseconds)  cgroup-pressure-monitor started (DESKTOP-scoped, thresh=${THRESH}% full-avg10, interval=${INTERVAL}s, cooldown=${COOLDOWN}s, investigate=${CGPM_INVESTIGATE:-off})" >> "$LOG"

# THE DETECTION LOOP -- fork-free, under the same FORK BUDGET as
# cgroup-governor.sh (its header carries the full 2026-07-29 story: under the
# ~400 MiB-free conditions this loop exists to notice, every fork()+execve()
# is itself an allocation that lands in direct reclaim, so a monitor that
# forks per tick slows down in proportion to the thing it watches -- and its
# silence reads as calm). This loop used to fork five times per 5 s tick,
# forever: `date +%s`, two awk PSI parses, and an awk float compare, plus the
# interval sleep. Only the `sleep` remains (bash has no sleep builtin; the
# governor's loop carries the same one). The rare paths behind the trigger --
# snapshot and investigate -- fork freely, as they should: they are
# COOLDOWN-limited and by the time they run, detection has already fired.
desktop_blind=0
while :; do
  now=$EPOCHSECONDS
  if resolve_desktop io.pressure; then
    if [ "$desktop_blind" = 1 ]; then
      echo "$(date -Iseconds)   DESKTOP resolved (${DESKTOP##*/}); stall detection resumed" >> "$LOG"
      desktop_blind=0
    fi
    psi_full_avg10 "$DESKTOP/memory.pressure"; dm="$PSI_TEXT"; dm_c="$PSI_CENTI"
    psi_full_avg10 "$DESKTOP/io.pressure";     di="$PSI_TEXT"; di_c="$PSI_CENTI"
    if [ "$dm_c" -ge "$THRESH_CENTI" ] || [ "$di_c" -ge "$THRESH_CENTI" ]; then
      if [ $((now - last_snap)) -ge "$COOLDOWN" ]; then
        snapshot "DESKTOP stall (${DESKTOP##*/}): mem_full_avg10=${dm}%  io_full_avg10=${di}%  (>= ${THRESH}%)"
        last_snap=$now
      fi
    fi
  else
    # Warn once per blind stretch, in the events log this monitor exists to
    # keep: an unresolvable desktop used to fall through this branch in total
    # silence, forever -- a watcher whose silence read as calm. Forks (date)
    # only on the transition, so the per-tick budget is untouched.
    if [ "$desktop_blind" = 0 ]; then
      echo "$(date -Iseconds)   DESKTOP UNRESOLVED; stall detection is BLIND until a session scope appears" >> "$LOG"
      desktop_blind=1
    fi
  fi
  sleep "$INTERVAL"
done
