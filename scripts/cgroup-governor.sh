#!/usr/bin/env bash
# cgroup-governor -- the ACTUATOR half of the pressure system.
#
# cgroup-pressure-monitor.sh detects a desktop stall in ~5s, writes a forensic
# snapshot and asks Claude to explain it. What it never does is CHANGE anything:
# 129 snapshots and ~40 analyses accumulated in ~/.local/state/cgroup-pressure
# between 2026-07-17 and 07-28, every one of them a report ABOUT a freeze the
# user had already sat through. This service closes that loop.
#
# WHY A NEW LEVER IS NEEDED AT ALL. Every knob tuned so far -- memory.min 6->8G,
# pool MemoryHigh 20->16G, watermark_scale_factor 125->300, min_free_kbytes,
# dirty_bytes, io.max, io.latency, zram, nohang, earlyoom -- is SUPPLY-side: a
# different way to divide a fixed 27 GiB. The forensics say that seam is mined
# out. In every stall the desktop sits BELOW its 8G memory.min (so memory.min
# held, its pages were never evicted) and stalls anyway, in *direct reclaim*,
# because global free RAM has collapsed to 200-500 MiB. memory.min guarantees
# the pages you already hold; it cannot manufacture free ones. Meanwhile
# Committed_AS runs ~126% of CommitLimit (45.8 / 36.3 GiB measured 07-28): the
# box is not mis-partitioned, it is oversubscribed. Nothing anywhere bounds
# DEMAND, and that is the only side left to act on.
#
# THE THREE DUTIES, cheapest first. Each escalates only if the one before it
# failed, so the common case costs nothing and pauses nothing.
#
#   A. COLD-STANDBY RECLAIM (no pause, no throttle).
#      The agents fleet is the pool's primary tenant (9.9 GB of a 15.2 GB pool,
#      measured 07-28) and ~2.9 GB of that is 16 idle `claude bg-spare` standby
#      heaps -- pre-warmed workers holding pages nothing is reading. claude-code
#      exposes no knob to cap the spare count (checked: no CLAUDE_*SPARE* symbol
#      in the 2.1.220 binary), and home.nix records that a 4G MemoryHigh on
#      worktrees-agents.slice was tried 07-21..07-24 and REVERTED -- it pinned
#      the whole slice at its ceiling and made the ACTIVE fleet crawl.
#      memory.high is the wrong tool because it penalises every allocation
#      forever. memory.reclaim is the right one: a ONE-SHOT, targeted push of
#      the cgroup's COLDEST pages (LRU order) into zram, with no standing
#      allocation penalty. Idle spare heaps are by construction the coldest
#      pages in the fleet, so they go first; hot pages of live agents stay
#      resident. zram compresses ~3.5:1 on this box (measured), so ~2.9 GB of
#      cold spare becomes ~800 MB and re-faulting costs RAM bandwidth, not disk.
#
#   B. BUILD CONCURRENCY CAP (admission control, applied to EXECUTION).
#      True admission control gates at spawn, but the spawn point is
#      ~/code/kawaka/.claude/hooks/worktree-setup.sh -- a different repo. The
#      equivalent from here is to gate execution instead: while memory is TIGHT,
#      hold all but $MAXCONC build scopes frozen so N run at full speed and the
#      rest wait, instead of six thrashing together under one memory.high and
#      all crawling. Same total throughput, no collective stall. Victims rotate
#      every $ROTATE_SECS so no build is starved, and the cap DISENGAGES the
#      moment memory recovers -- there is no standing queue to manage and
#      starvation is bounded by the length of the storm.
#
#   C. STALL BACKSTOP (emergency brake).
#      If the desktop stalls anyway: reclaim from the fleet first, re-measure,
#      and only if it is STILL stalled freeze the single largest freezable scope
#      for a few seconds. This is the last resort, not the first move.
#
#   Duties B and C are both preceded by sweep_transient, which makes
#   agent-spawned test/browser work freezable in the first place. It runs ONLY
#   off the NORMAL path, so a healthy machine pays no scan cost and sees no
#   cgroup churn.
#
# WHAT IS FROZEN, AND WHAT IS NEVER FROZEN. Two targets, both leaves:
#   * `mj-<name>.scope`  -- the monorepo-jobs BUILD DAEMON.
#   * `<slice>/transient` -- heavy test/browser/toolchain workers that agents
#     spawned, migrated there by sweep_transient (see WORKER_RE below).
#
# Capping only mj-* was the original design and it had a real hole: work an agent
# starts (`rushx test`, Playwright) inherits the AGENT's cgroup, not the build
# daemon's, so none of it was governable. Forensics show 1.5-2.9 GB single node
# processes sitting in the fleet, plus a Playwright chromium inside a
# claude-*.scope -- all of it previously untouchable.
#
# Never frozen, under any condition: the interactive Claude session
# (claude-<name>.scope), the live agent fleet (worktrees-agents.slice/fleet), and
# the desktop session scope. The whole point of migrating workers sideways into
# `transient` is that the heavy job becomes freezable WITHOUT the agent that
# launched it being frozen with it. The fleet is reclaimed from, never paused.
#
# FREEZE SAFETY. A frozen cgroup that is never thawed is a hung build, so thaw
# is guaranteed four ways: (1) every freeze carries a deadline and is force-
# thawed after $MAX_FREEZE_SECS no matter what the pressure reading says;
# (2) an EXIT/INT/TERM trap thaws everything this process froze; (3) the loop
# thaws all on startup, recovering from a previous run that was SIGKILLed
# mid-freeze; (4) the systemd unit's ExecStopPost (cgroup-thaw-all) thaws every
# mj-* scope AND every transient leaf in the pool, covering even SIGKILL.
#
# Set CGGOV_DRYRUN=1 to log every decision without touching a single cgroup file
# -- the honest way to watch the policy for a day before letting it act.
#
# All log lines are tagged CGGOV for grepping:
#   grep -E 'CGGOV\|(RECLAIM|FREEZE|THAW|CAP|STALL|STATE|START|STOP|DRYRUN)' \
#     ~/.local/state/cgroup-pressure/governor.log
#
# Tunables (env):
#   CGGOV_INTERVAL        poll seconds                                (default 5)
#   CGGOV_STALL_THRESH    desktop mem full-avg10 %% that is a stall   (default 15)
#   CGGOV_LOW_FREE_MB     MemFREE below this = TIGHT (see mem_free_mb) (default 1536)
#   CGGOV_MAXCONC         max unfrozen heavy build scopes while TIGHT (default 3)
#   CGGOV_HEAVY_MB        a build scope counts as heavy above this    (default 256)
#   CGGOV_RECLAIM_MB      bytes-worth pushed to zram per attempt      (default 256)
#   CGGOV_RECLAIM_COOL    min seconds between reclaim attempts        (default 30)
#   CGGOV_FREEZE_SECS     emergency freeze duration                   (default 3)
#   CGGOV_MAX_FREEZE_SECS absolute ceiling on ANY freeze              (default 60)
#   CGGOV_ROTATE_SECS     rotate cap victims this often               (default 20)
#   CGGOV_WORKER_MIN_MB   min RSS for a worker to be migratable        (default 128)
#   CGGOV_OUTDIR          log directory
#   CGGOV_DRYRUN          non-empty = decide + log, never act
set -u

OUTDIR="${CGGOV_OUTDIR:-$HOME/.local/state/cgroup-pressure}"
INTERVAL="${CGGOV_INTERVAL:-5}"
STALL_THRESH="${CGGOV_STALL_THRESH:-15}"
LOW_FREE_MB="${CGGOV_LOW_FREE_MB:-1536}"
MAXCONC="${CGGOV_MAXCONC:-3}"
HEAVY_MB="${CGGOV_HEAVY_MB:-256}"
RECLAIM_MB="${CGGOV_RECLAIM_MB:-256}"
RECLAIM_COOL="${CGGOV_RECLAIM_COOL:-30}"
FREEZE_SECS="${CGGOV_FREEZE_SECS:-3}"
MAX_FREEZE_SECS="${CGGOV_MAX_FREEZE_SECS:-60}"
ROTATE_SECS="${CGGOV_ROTATE_SECS:-20}"
DRYRUN="${CGGOV_DRYRUN:-}"

mkdir -p "$OUTDIR"
LOG="$OUTDIR/governor.log"

U=$(id -u)
UNAME=$(id -un)
USERSLICE="/sys/fs/cgroup/user.slice/user-$U.slice"
USERAT="$USERSLICE/user@$U.service"
POOL="$USERAT/worktrees.slice"
# Reclaim target is the agents SLICE, deliberately -- not the `fleet` LEAF the
# processes actually sit in. memory.reclaim on a parent reclaims across its whole
# subtree, so the slice covers the fleet either way, and only the slice is
# guaranteed to HAVE memory.* files: the leaf's exist only while the slice's
# cgroup.subtree_control contains +memory, which claude-agents-reattach writes
# once at reattach and which a home-manager restart silently clears (observed
# 2026-07-28 right after a nixos-rebuild switch: subtree_control empty, leaf with
# 46 procs and no memory.current at all, slice still reporting 4.9 G). Targeting
# the leaf would have made this whole duty a silent no-op after every rebuild.
# The slice's files are guaranteed by MemoryAccounting=true in home.nix.
FLEET="$POOL/worktrees-agents.slice"
DESKTOP=""

declare -A frozen_since=()   # scope path -> epoch seconds it was frozen
last_reclaim=0
rot=0
last_rotate=0
state="NORMAL"
last_state=""

log() { printf '%s  CGGOV|%s\n' "$(date -Iseconds)" "$*" >> "$LOG"; }

# cgroup dir names escape '-' as '\x2d'; undo that for readable log lines.
pretty() { printf '%s' "${1//\\x2d/-}"; }

full_avg10() {
  awk '/^full/{for(i=1;i<=NF;i++){n=split($i,a,"=");if(a[1]=="avg10")print a[2]}}' "$1" 2>/dev/null
}

# Resolve the graphical session scope -- the desktop lives OUTSIDE the pool and
# its OWN PSI is the "is the user stalling" signal. Same resolution the monitor
# uses; cached, and re-resolved if the session goes away (logout/login).
resolve_desktop() {
  [ -n "$DESKTOP" ] && [ -r "$DESKTOP/memory.pressure" ] && return 0
  DESKTOP=""
  local sid ty sc
  if command -v loginctl >/dev/null 2>&1; then
    while read -r sid; do
      [ -n "$sid" ] || continue
      ty=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
      case "$ty" in x11|wayland) ;; *) continue ;; esac
      sc="$USERSLICE/session-$sid.scope"
      [ -r "$sc/memory.pressure" ] && { DESKTOP="$sc"; return 0; }
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$UNAME" '$3==u{print $1}')
  fi
  local d n best="" bestn=0
  for d in "$USERSLICE"/session-*.scope; do
    [ -r "$d/cgroup.procs" ] || continue
    n=$(wc -l < "$d/cgroup.procs" 2>/dev/null); n=${n:-0}
    if [ "$n" -gt "$bestn" ] 2>/dev/null; then bestn=$n; best="$d"; fi
  done
  [ -n "$best" ] && { DESKTOP="$best"; return 0; }
  return 1
}

# MemFREE, deliberately -- NOT MemAvailable. Measured across every memory stall
# in ~/.local/state/cgroup-pressure, MemFree is pinned at 365-390 MiB almost
# without exception, while MemAvailable at those same moments reads anywhere from
# 750 MiB to 17 GiB. MemAvailable counts reclaimable page cache as "available",
# which is exactly the accounting fiction that hides this failure: the pages are
# reclaimable in principle, but reclaiming them is precisely the direct-reclaim
# work that stalls the allocating task. The kernel's own watermarks are about
# FREE pages, so that is what predicts the stall and that is what we watch.
mem_free_mb() { awk '/^MemFree:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null; }
mem_avail_mb() { awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null; }

# Heavy transient workers that agents spawn. Capping only mj-*.scope misses
# these entirely: a `rushx test` or Playwright run started BY an agent inherits
# the AGENT's cgroup (worktrees-agents.slice/fleet, or a worktree's
# claude-<name>.scope), never the build daemon's scope. Forensics show exactly
# that -- single node processes of 1.5-2.9 GB at 100-238% CPU sitting inside
# fleet, plus a Playwright chromium inside a claude-*.scope -- all of it
# invisible to a build-daemon-only policy.
#
# The list is grounded in nohang.conf's already-curated victim policy (jest-worker
# +300, /jest +150, --headless +300, ms-playwright +200): processes this host
# ALREADY authorises nohang to KILL under pressure, so pausing them for a few
# seconds is strictly gentler than the status quo. Extended with the heavy
# toolchain workers the forensics caught that nohang does not target (eslint at
# 3.2 GB, heft typecheck at ~2 GB). Tool patterns are anchored with a leading
# slash so they match a real executable path and not an incidental substring.
#
# .claude-wrapped is NEVER matched -- nohang protects it at -2000 and it is the
# agent itself. MCP servers simply do not appear on the allowlist, so they are
# never migrated and never frozen.
# Kept deliberately in step with nohang.conf's @BADNESS_ADJ_RE_CMDLINE "prefer as
# victim" rules -- one list, two escalation levels: the governor FREEZES this set
# under pressure, and nohang KILLS the same set if it ever gets that far.
# /bin/tsc rather than /tsc, because the short form also matches
# "/tsconfig.json", which appears in the arguments of plenty of processes that
# are not the compiler.
WORKER_RE='jest-worker|/jest|--headless|ms-playwright|/eslint|/heft|/bin/tsc|/esbuild|/vitest'

# Two guards, because a cmdline match ALONE is not evidence that a process IS the
# worker. Caught in testing: a shell invoked as `zsh -c "... rushx test ..."`
# matches WORKER_RE on the strength of its ARGUMENTS and would be migrated (and
# potentially frozen) instead of the worker it launched -- freezing an agent's
# tool-call shell rather than the heavy job.
#
#   1. Shells are never the worker, only its launcher. This also re-honours
#      nohang.conf, which already protects zsh|bash|tmux|sshd|ssh at -2000.
#   2. An RSS floor. The entire purpose here is HEAVY transient work; a 4 MB
#      wrapper is not worth migrating whatever its cmdline says. This bounds the
#      blast radius of any future imprecision in WORKER_RE: nothing small can
#      ever be touched, no matter what it claims to be.
WORKER_SKIP_COMM='.claude-wrapped|claude|zsh|bash|sh|dash|fish|tmux|tmux: server|sshd|ssh|su|sudo|env'
WORKER_MIN_MB="${CGGOV_WORKER_MIN_MB:-128}"

# Move heavy workers into a freezable `transient` leaf of the slice they are
# ALREADY in. Same parent slice => memory accounting and budgets are completely
# unchanged; the migration exists only to make them independently freezable.
#
# They cannot be frozen where they sit: claude-<name>.scope holds the agent
# process itself, and cgroup v2's no-internal-processes rule forbids nesting a
# child under a cgroup that holds procs. Moving them sideways into a sibling leaf
# is the only placement that works. Live pid migration via cgroup.procs is the
# same non-destructive technique claude-agents-reattach already relies on.
#
# Called ONLY when state != NORMAL, so there is no scan cost or cgroup churn
# while the machine is healthy.
sweep_transient() {
  local sl child target p c cl rss_mb moved=0 base
  shopt -s nullglob
  for sl in "$POOL"/worktrees-*.slice; do
    target="$sl/transient"
    for child in "$sl"/*/; do
      base="$(basename "$child")"
      # mj-* is already a freeze target; transient is where we are moving TO.
      case "$base" in mj-*.scope|transient) continue ;; esac
      [ -r "$child/cgroup.procs" ] || continue
      while read -r p; do
        [ -n "$p" ] || continue
        c=$(cat "/proc/$p/comm" 2>/dev/null) || continue
        # Guard 1: never a shell, a wrapper, or the agent itself.
        [[ "$c" =~ ^($WORKER_SKIP_COMM)$ ]] && continue
        cl=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
        [[ "$cl" =~ $WORKER_RE ]] || continue
        # Guard 2: heavy only. Reading VmRSS last keeps this off the hot path for
        # the many processes that fail the cheaper checks above.
        rss_mb=$(awk '/^VmRSS/{printf "%d", $2/1024}' "/proc/$p/status" 2>/dev/null)
        [ -n "$rss_mb" ] && [ "$rss_mb" -ge "$WORKER_MIN_MB" ] 2>/dev/null || continue
        if [ -n "$DRYRUN" ]; then
          log "DRYRUN|would MIGRATE pid=$p ($c) from $(pretty "$base") -> transient"
          continue
        fi
        if [ ! -d "$target" ]; then
          mkdir -p "$target" 2>/dev/null || continue
          # Delegate memory so the transient leaf reports memory.current (used to
          # rank freeze victims). Best-effort: freezing works without it.
          grep -qw memory "$sl/cgroup.subtree_control" 2>/dev/null || \
            printf '+memory' > "$sl/cgroup.subtree_control" 2>/dev/null || true
        fi
        printf '%s\n' "$p" > "$target/cgroup.procs" 2>/dev/null && moved=$((moved + 1))
      done < "$child/cgroup.procs"
    done
  done
  shopt -u nullglob
  [ "$moved" -gt 0 ] && log "SWEEP|migrated ${moved} heavy worker(s) into transient cgroup(s)"
  return 0
}

# Every freezable scope, "<bytes>\t<path>", largest first: the monorepo-jobs
# build daemons (mj-*.scope) AND the transient leaves holding agent-spawned test
# and browser workers. The agents slice contributes its `transient` leaf but
# never `fleet` -- live agents are reclaimed from, never paused.
list_build_scopes() {
  local sl sc m
  shopt -s nullglob
  for sl in "$POOL"/worktrees-*.slice; do
    for sc in "$sl"/mj-*.scope "$sl"/transient; do
      [ -e "$sc/cgroup.freeze" ] || continue
      # Skip an empty transient leaf: freezing nothing buys nothing.
      [ -s "$sc/cgroup.procs" ] || continue
      m=$(cat "$sc/memory.current" 2>/dev/null)
      # A leaf without +memory delegated reports nothing; fall back to summed RSS
      # so it can still be ranked rather than silently sorting as zero.
      if [ -z "$m" ]; then
        m=$(awk '{s+=$1} END{printf "%d", s*1024}' < <(
          while read -r p; do awk '/^VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null; done < "$sc/cgroup.procs"
        ) 2>/dev/null)
      fi
      [ -n "$m" ] && printf '%s\t%s\n' "$m" "$sc"
    done
  done
  shopt -u nullglob
}

is_frozen() { [ "$(cat "$1/cgroup.freeze" 2>/dev/null)" = "1" ]; }

freeze_scope() {
  local sc="$1" why="$2"
  is_frozen "$sc" && return 0
  if [ -n "$DRYRUN" ]; then
    log "DRYRUN|would FREEZE $(pretty "$(basename "$sc")") ($why)"
    return 0
  fi
  if printf '1' > "$sc/cgroup.freeze" 2>/dev/null; then
    frozen_since["$sc"]=$(date +%s)
    log "FREEZE|$(pretty "$(basename "$sc")") mem=$(numfmt --to=iec < "$sc/memory.current" 2>/dev/null) ($why)"
  fi
}

thaw_scope() {
  local sc="$1" why="${2:-}"
  if [ -n "$DRYRUN" ]; then
    unset 'frozen_since[$sc]' 2>/dev/null || true
    return 0
  fi
  # Thaw even if the dir vanished from our map -- writing 0 to a gone cgroup is
  # a harmless no-op, and never thawing is the only failure mode that matters.
  if [ -e "$sc/cgroup.freeze" ]; then
    printf '0' > "$sc/cgroup.freeze" 2>/dev/null && \
      log "THAW|$(pretty "$(basename "$sc")")${why:+ ($why)}"
  fi
  unset 'frozen_since[$sc]' 2>/dev/null || true
}

# Thaw everything we hold, plus (belt and braces) every mj-* scope in the pool --
# this is what recovers a build left frozen by a previous run that was killed
# mid-freeze, so it also runs once at startup.
thaw_all() {
  local why="${1:-}" sc m
  for sc in "${!frozen_since[@]}"; do thaw_scope "$sc" "$why"; done
  while IFS=$'\t' read -r m sc; do
    [ -n "${sc:-}" ] || continue
    is_frozen "$sc" && thaw_scope "$sc" "${why:-orphan sweep}"
  done < <(list_build_scopes)
}

# Push the cgroup's COLDEST pages into zram. Errors are expected and ignored:
# memory.reclaim returns EAGAIN when it cannot free the full amount, which is
# information, not a failure. Bounded to a modest chunk so the write returns
# quickly -- if pressure persists the next tick reclaims again.
reclaim_from() {
  local cg="$1" mb="$2" why="$3" before after
  # Never fail silently: a missing memory.reclaim means this duty is doing
  # NOTHING, which is exactly the failure that hid behind the leaf-vs-slice bug
  # above. Log it loudly so a silent no-op is visible in the governor log.
  if [ ! -e "$cg/memory.reclaim" ]; then
    log "RECLAIM|SKIPPED - no memory.reclaim at ${cg#"$USERAT"/} (memory controller not delegated here?)"
    return 0
  fi
  before=$(cat "$cg/memory.current" 2>/dev/null)
  if [ -n "$DRYRUN" ]; then
    log "DRYRUN|would RECLAIM ${mb}M from $(basename "$cg") cur=$(numfmt --to=iec <<< "${before:-0}" 2>/dev/null) ($why)"
    return 0
  fi
  printf '%d' "$((mb * 1024 * 1024))" > "$cg/memory.reclaim" 2>/dev/null || true
  after=$(cat "$cg/memory.current" 2>/dev/null)
  log "RECLAIM|$(basename "$cg") asked=${mb}M $(numfmt --to=iec <<< "${before:-0}" 2>/dev/null) -> $(numfmt --to=iec <<< "${after:-0}" 2>/dev/null) ($why)"
}

# A bash trap handler does NOT terminate the shell by itself, so the signal
# handler must exit explicitly -- otherwise SIGTERM thaws everything and then
# the loop merrily carries on, `systemctl --user stop` blocks until its timeout,
# and the service is SIGKILLed (leaving whatever it froze next still frozen).
# EXIT does the thawing; INT/TERM just ask for a clean exit.
on_exit() { thaw_all "governor exiting"; log "STOP|governor stopped"; }
on_signal() { log "STOP|signal received, shutting down"; exit 0; }
trap on_exit EXIT
trap on_signal INT TERM

log "START|governor started (thresh=${STALL_THRESH}% low_free=${LOW_FREE_MB}M maxconc=${MAXCONC} heavy=${HEAVY_MB}M reclaim=${RECLAIM_MB}M/${RECLAIM_COOL}s freeze=${FREEZE_SECS}s max_freeze=${MAX_FREEZE_SECS}s rotate=${ROTATE_SECS}s dryrun=${DRYRUN:-off})"
thaw_all "startup sweep"

while :; do
  now=$(date +%s)

  # --- 0. Deadline enforcement. Runs FIRST and unconditionally, so a wedged
  # pressure reading can never hold a build frozen indefinitely. ---
  for sc in "${!frozen_since[@]}"; do
    held=$(( now - ${frozen_since[$sc]} ))
    if [ "$held" -ge "$MAX_FREEZE_SECS" ]; then
      thaw_scope "$sc" "deadline ${held}s >= ${MAX_FREEZE_SECS}s"
    fi
  done

  resolve_desktop || { sleep "$INTERVAL"; continue; }
  dm=$(full_avg10 "$DESKTOP/memory.pressure"); dm=${dm:-0}
  free_mb=$(mem_free_mb); free_mb=${free_mb:-99999}
  avail=$(mem_avail_mb); avail=${avail:-99999}   # logged for context only

  # --- 1. Classify. STALL = the desktop is stalling right now. TIGHT = the free
  # page buffer is draining toward the ~370 MiB floor every recorded stall bottoms
  # out at, so act BEFORE the user feels it. ---
  if awk -v m="$dm" -v t="$STALL_THRESH" 'BEGIN{exit !(m>=t)}'; then
    state="STALL"
  elif [ "$free_mb" -lt "$LOW_FREE_MB" ] 2>/dev/null; then
    state="TIGHT"
  else
    state="NORMAL"
  fi
  [ "$state" != "$last_state" ] && \
    log "STATE|$last_state -> $state (desktop_mem_full_avg10=${dm}% free=${free_mb}M avail=${avail}M)"
  last_state="$state"

  case "$state" in
    NORMAL)
      # Pressure gone: release every held build immediately. The cap is a storm
      # response, not a standing policy -- nothing stays frozen at rest.
      [ "${#frozen_since[@]}" -gt 0 ] && thaw_all "pressure cleared"
      rot=0
      ;;

    TIGHT)
      # Make agent-spawned test/browser workers freezable before deciding what to
      # freeze. Only runs off the NORMAL path, so it costs nothing at rest.
      sweep_transient

      # Duty A: cheapest lever first -- push the fleet's cold spare heaps to
      # zram. No pause, no throttle, no effect on hot pages.
      if [ $(( now - last_reclaim )) -ge "$RECLAIM_COOL" ]; then
        reclaim_from "$FLEET" "$RECLAIM_MB" "TIGHT free=${free_mb}M"
        last_reclaim=$now
      fi

      # Duty B: hold all but $MAXCONC heavy build scopes, rotating victims so
      # none is starved. Light scopes are left alone -- they are not the problem
      # and freezing them buys nothing.
      mapfile -t heavy < <(list_build_scopes | awk -v h="$((HEAVY_MB * 1024 * 1024))" -F'\t' '$1>=h{print $2}')
      n=${#heavy[@]}
      if [ "$n" -gt "$MAXCONC" ]; then
        [ $(( now - last_rotate )) -ge "$ROTATE_SECS" ] && { rot=$(( rot + 1 )); last_rotate=$now; }
        # Rotate the victim window each cycle: every build gets turns running.
        want_frozen=$(( n - MAXCONC ))
        for (( k = 0; k < n; k++ )); do
          sc="${heavy[$(( (k + rot) % n ))]}"
          if [ "$k" -lt "$want_frozen" ]; then
            freeze_scope "$sc" "cap ${MAXCONC}/${n} free=${free_mb}M"
          else
            is_frozen "$sc" && thaw_scope "$sc" "cap rotation"
          fi
        done
      elif [ "${#frozen_since[@]}" -gt 0 ]; then
        thaw_all "under cap (${n} <= ${MAXCONC})"
      fi
      ;;

    STALL)
      # Duty C: the desktop is stalling NOW. Reclaim first (no pause), give the
      # kernel a beat, then re-measure -- only escalate if that did not fix it.
      log "STALL|desktop mem_full_avg10=${dm}% free=${free_mb}M avail=${avail}M"
      sweep_transient
      if [ $(( now - last_reclaim )) -ge "$RECLAIM_COOL" ]; then
        reclaim_from "$FLEET" "$(( RECLAIM_MB * 2 ))" "STALL mem_psi=${dm}%"
        last_reclaim=$now
        sleep 2
        dm2=$(full_avg10 "$DESKTOP/memory.pressure"); dm2=${dm2:-0}
        if awk -v m="$dm2" -v t="$STALL_THRESH" 'BEGIN{exit !(m<t)}'; then
          log "STALL|recovered after reclaim (${dm}% -> ${dm2}%), no freeze needed"
          sleep "$INTERVAL"; continue
        fi
        dm="$dm2"
      fi

      # Still stalling: brake the single largest build scope, briefly.
      biggest=$(list_build_scopes | sort -rn | head -1 | cut -f2)
      if [ -n "${biggest:-}" ]; then
        freeze_scope "$biggest" "stall brake mem_psi=${dm}%"
        sleep "$FREEZE_SECS"
        thaw_scope "$biggest" "brake released after ${FREEZE_SECS}s"
      else
        log "STALL|no build scope to brake (pressure is not from builds)"
      fi
      ;;
  esac

  sleep "$INTERVAL"
done
