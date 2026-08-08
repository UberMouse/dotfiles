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
#      in the 2.1.220 binary), and cgroups.nix records that a 4G MemoryHigh on
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
#   grep -E 'CGGOV\|(RECLAIM|FREEZE|THAW|CAP|STALL|STATE|START|STOP|DRYRUN|SWEEP|MIGRATE|LAG)' \
#     ~/.local/state/cgroup-pressure/governor.log
#
# LAG is the one to watch first. It means a tick overran, i.e. the governor was
# not measuring for that long -- the failure that hid the 07-29 stalls.
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
#   CGGOV_POOL_THRESH     pool mem full-avg10 %% that is TIGHT          (default 25)
#   CGGOV_SWEEP_COOL      min seconds between transient sweeps         (default 30)
#   CGGOV_LAG_WARN        log LAG if a tick overruns this many seconds (default 3x interval)
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
# Pool-side trigger. The desktop is only one of the two things worth protecting,
# and by 07-29 it had stopped being the one that hurt: session-2.scope measured
# mem_full 0.00% and io_full 0.08% while worktrees.slice sat pinned at its 16 G
# memory.high, taking 30 throttle events per second, with everything inside it --
# every agent, build and tmux shell -- stalled 24-67% of wall-clock. MemFree was
# a healthy 2.9 GB throughout, so neither existing trigger could see any of it.
# Watching the pool's own PSI closes that blind spot: the pool suffocating
# against its own ceiling is a real emergency even when the machine has free RAM.
POOL_THRESH="${CGGOV_POOL_THRESH:-25}"
# How often sweep_transient may actually scan. See maybe_sweep.
SWEEP_COOL="${CGGOV_SWEEP_COOL:-30}"
# Warn when a tick overruns this many seconds -- the blind-spot alarm. 3x the
# interval, derived rather than fixed: the loop body no longer contains any
# sleep (the stall brake is deadline state enforced at the top of the loop,
# not an inline `sleep` -- see duty C), so a healthy tick takes INTERVAL
# seconds and anything at triple that is genuine blindness. The old fixed 15
# had to sit ABOVE the brake's in-loop sleeps (2 s re-measure + 3 s freeze
# on top of the 5 s interval), which meant an entire brake cycle of
# not-measuring passed beneath it unlogged -- during a stall, the exact moment
# measuring matters most.
LAG_WARN="${CGGOV_LAG_WARN:-$(( INTERVAL * 3 ))}"

# Fail LOUDLY if the log directory cannot exist. Unchecked (as this was until
# 2026-08-07), a failed mkdir meant every `>> "$LOG"` below silently went
# nowhere, forever -- and a governor with no log is indistinguishable from a
# healthy quiet one, exactly the silence-reads-as-calm failure the LAG watchdog
# exists to prevent. Exiting lets systemd (Restart=always) retry and surface
# the flapping unit instead.
mkdir -p "$OUTDIR" || { echo "cgroup-governor: cannot create output dir '$OUTDIR'" >&2; exit 1; }
LOG="$OUTDIR/governor.log"

# Shared helpers (PSI parser, desktop resolution, cgroup paths incl. the
# KX_POOL override). CGLIB is set by the systemd unit (single-file store
# paths have no siblings); the BASH_SOURCE fallback serves local runs and
# the test suites' sourcing seam.
# shellcheck disable=SC1090  # path is env-supplied (CGLIB) in production
. "${CGLIB:-$(dirname "${BASH_SOURCE[0]}")/cgroup-lib.sh}" || {
  echo "cgroup-governor: cannot source cgroup-lib.sh" >&2; exit 1;
}
kx_cgroup_paths
# Reclaim target is the agents SLICE, deliberately -- not the `fleet` LEAF the
# processes actually sit in. memory.reclaim on a parent reclaims across its whole
# subtree, so the slice covers the fleet either way, and only the slice is
# guaranteed to HAVE memory.* files: the leaf's exist only while the slice's
# cgroup.subtree_control contains +memory, which claude-agents-reattach writes
# once at reattach and which a home-manager restart silently clears (observed
# 2026-07-28 right after a nixos-rebuild switch: subtree_control empty, leaf with
# 46 procs and no memory.current at all, slice still reporting 4.9 G). Targeting
# the leaf would have made this whole duty a silent no-op after every rebuild.
# The slice's files are guaranteed by MemoryAccounting=true in cgroups.nix.
FLEET="$POOL/worktrees-agents.slice"

declare -A frozen_since=()   # scope path -> epoch seconds it was frozen
last_reclaim=0
rot=0
last_rotate=0
state="NORMAL"
last_state=""
last_sweep=0                 # maybe_sweep rate limiter
last_tick=0                  # loop-lag watchdog
deleg_warned=0               # ensure_delegation: warn once, not every tick
desktop_blind=0              # resolve_desktop failure: warn once, not every tick
reclaim_pid=""               # in-flight backgrounded reclaim, if any
# Duty C (stall brake) state. The brake used to sleep inline -- `sleep 2` for
# the post-reclaim re-measure, then freeze + `sleep $FREEZE_SECS` + thaw --
# which stopped measurement for up to ~5 s at the single most memory-starved
# moment the governor ever acts in, invisibly (the old LAG_WARN=15 sat above
# it). Now the brake is STATE: freeze immediately, record the deadline here,
# and let the top-of-loop enforcer thaw on schedule while ticks keep measuring.
brake_scope=""               # scope currently frozen by the stall brake
brake_until=0                # epoch second the deadline enforcer must thaw it
brake_armed=0                # duty C reclaimed last tick; this tick re-measures
brake_armed_dm=""            # the stalled reading that armed it, for the log
# CLOCK CAVEAT for every deadline and cooldown above and below: bash has no
# monotonic clock, so all of this arithmetic runs on EPOCHSECONDS -- wall
# time -- and on this VMware guest wall time JUMPS (host suspend/resume, NTP
# stepping). The semaphore controller does the same arithmetic on
# time.monotonic(), and that asymmetry is deliberate: Python has a monotonic
# clock to offer, bash does not. The affordable defence is elapsed_since:
# clamp a negative delta to zero, so a backward jump reads as "no time has
# passed" (cooldowns stretch, deadlines defer by the jump size) rather than
# a huge negative age with sign-dependent surprises.
ELAPSED=0
elapsed_since() {  # past now -> ELAPSED (clamped, never negative)
  # Sets a global rather than echoing: this runs on the detection path, and
  # $(...) forks a subshell even for a builtin (see THE FORK BUDGET below).
  ELAPSED=$(( $2 - $1 ))
  [ "$ELAPSED" -lt 0 ] && ELAPSED=0
  return 0
}
# Thresholds pre-scaled to the integer hundredths psi_full_avg10 returns, so the
# per-tick comparison is a shell integer test and not an awk invocation.
STALL_CENTI=$(( STALL_THRESH * 100 ))
POOL_CENTI=$(( POOL_THRESH * 100 ))

# THE FORK BUDGET. Everything below is written to avoid fork() on the detection
# path, and that is not micro-optimisation -- it is the central bug fix of
# 2026-07-29. This service exists to notice ~400 MiB-free conditions, and under
# exactly those conditions every fork()+execve() is itself an allocation that
# lands in direct reclaim. The old hot path spent a `date` per log line, three
# `awk`s per tick, and (via sweep_transient) three forks PER PID in the pool.
# The result is in the governor log: ticks that should be 5 s apart stretched to
# 100 s and 129 s, straddling the 14:05 and 14:55 desktop stalls -- both caught
# by cgroup-pressure-monitor and BOTH MISSED HERE. The governor was not making
# bad decisions, it was making none, because measuring had become as expensive
# as the problem being measured. A monitor that slows down in proportion to the
# thing it watches is worse than no monitor, because its silence reads as calm.
# (cgroup-pressure-monitor.sh's detection loop had the same disease -- a `date`
# plus three `awk`s per tick -- and was ported to these rules on 2026-08-07, so
# both halves of the pressure system now comply.)
#
# Rules, in order of importance:
#   1. Nothing on the detection path may fork. That means no $(...) command
#      substitution either -- it forks a subshell even for a builtin -- so these
#      helpers set GLOBALS instead of echoing.
#   2. Nothing on the detection path may block. See reclaim_from.
#   3. Comparisons are integer, in hundredths of a percent, so PSI's "18.71"
#      needs no awk to compare against a threshold.
log() {
  local t
  printf -v t '%(%Y-%m-%dT%H:%M:%S%z)T' -1
  # strftime has no %:z -- that is a GNU `date` extension -- so splice the colon
  # into the offset with parameter expansion. Keeps the timestamp byte-identical
  # to the `date -Iseconds` format the existing log and every analysis of it
  # already use, without paying a fork per line to get it.
  printf '%s  CGGOV|%s\n' "${t:0:${#t}-2}:${t: -2}" "$*" >> "$LOG"
}

# cgroup dir names escape '-' as '\x2d'; undo that for readable log lines.
pretty() { printf '%s' "${1//\\x2d/-}"; }

# psi_full_avg10 and resolve_desktop come from cgroup-lib.sh (sourced above).
# The governor probes the desktop's memory.pressure -- the file it goes on to
# read -- where the monitor probes io.pressure.

# MemFREE, deliberately -- NOT MemAvailable. Measured across every memory stall
# in ~/.local/state/cgroup-pressure, MemFree is pinned at 365-390 MiB almost
# without exception, while MemAvailable at those same moments reads anywhere from
# 750 MiB to 17 GiB. MemAvailable counts reclaimable page cache as "available",
# which is exactly the accounting fiction that hides this failure: the pages are
# reclaimable in principle, but reclaiming them is precisely the direct-reclaim
# work that stalls the allocating task. The kernel's own watermarks are about
# FREE pages, so that is what predicts the stall and that is what we watch.
#
# One fork-free pass sets both globals. MemFree and MemAvailable are the 2nd and
# 3rd lines of /proc/meminfo, so this reads three lines and stops -- against two
# `awk` processes, each of which read the whole file, on every single tick.
# Takes an optional file argument so the test suite can feed fixtures; the
# governor itself always reads the default /proc/meminfo.
MEMFREE_MB=99999
MEMAVAIL_MB=99999
read_meminfo() {
  local k v
  MEMFREE_MB=99999; MEMAVAIL_MB=99999
  while read -r k v _; do
    case "$k" in
      MemFree:)      MEMFREE_MB=$(( v / 1024 )) ;;
      MemAvailable:) MEMAVAIL_MB=$(( v / 1024 )); break ;;
    esac
  done < "${1:-/proc/meminfo}" 2>/dev/null
  return 0
}

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

# The ONE writer for cgroup.subtree_control repair. Two call sites used to
# hand-roll this write -- sweep_transient delegating a fresh transient leaf's
# parent slice, and ensure_delegation re-asserting the agents slice every
# tick -- and they had ALREADY drifted (`+memory` at one, `+memory +pids` at
# the other) before being folded here. One helper, one controller set; the
# next drift is impossible.
#
# An EMPTY subtree_control is exactly the state being repaired, and `read`
# returns non-zero on it (EOF before any delimiter), so its exit status must
# NOT gate the repair -- testing it would skip the only case that matters.
#
# Returns: 0 = memory already delegated, nothing written;
#          2 = repaired, the write landed;
#          1 = no subtree_control file, or the write was refused. cgroup v2
#              refuses it while processes sit DIRECTLY in the cgroup (the
#              no-internal-process rule), a real transient state during
#              reattach -- callers decide how loud to be about it.
delegate_subtree() {
  local cg="$1" sc=""
  [ -e "$cg/cgroup.subtree_control" ] || return 1
  read -r sc 2>/dev/null < "$cg/cgroup.subtree_control"
  case " $sc " in *" memory "*) return 0 ;; esac
  if printf '+memory +pids' 2>/dev/null > "$cg/cgroup.subtree_control"; then
    return 2
  fi
  return 1
}

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
  local sl child target p c cl rss_mb moved=0 failed=0 base parts
  shopt -s nullglob
  for sl in "$POOL"/worktrees-*.slice; do
    target="$sl/transient"
    for child in "$sl"/*/; do
      base="${child%/}"; base="${base##*/}"
      # mj-* is already a freeze target; transient is where we are moving TO.
      case "$base" in mj-*.scope|transient) continue ;; esac
      [ -r "$child/cgroup.procs" ] || continue
      while read -r p; do
        [ -n "$p" ] || continue
        # Every read below is a bash builtin. This loop body runs once per pid in
        # every non-mj child of every pool slice -- ~50 pids in the fleet alone --
        # and it used to cost THREE forks per pid (cat comm, tr cmdline, awk
        # status). At the ~400 MiB free this runs at, those forks are the single
        # largest reason a tick took minutes instead of seconds.
        read -r c < "/proc/$p/comm" 2>/dev/null || continue
        # Guard 1: never a shell, a wrapper, or the agent itself.
        [[ "$c" =~ ^($WORKER_SKIP_COMM)$ ]] && continue
        # cmdline is NUL-separated; mapfile -d '' is a builtin, `tr` was a fork.
        parts=()
        mapfile -d '' -t parts < "/proc/$p/cmdline" 2>/dev/null || continue
        cl="${parts[*]}"
        [[ "$cl" =~ $WORKER_RE ]] || continue
        # Guard 2: heavy only. Reading RSS last keeps it off the hot path for the
        # many processes that fail the cheaper checks above. statm field 2 is
        # resident pages and is readable with `read`; /proc/<pid>/status needed awk.
        read -r _ rss_mb _ < "/proc/$p/statm" 2>/dev/null || continue
        [ -n "$rss_mb" ] || continue
        rss_mb=$(( rss_mb * 4096 / 1048576 ))
        [ "$rss_mb" -ge "$WORKER_MIN_MB" ] 2>/dev/null || continue
        if [ -n "$DRYRUN" ]; then
          log "DRYRUN|would MIGRATE pid=$p ($c) from $(pretty "$base") -> transient"
          continue
        fi
        if [ ! -d "$target" ]; then
          mkdir -p "$target" 2>/dev/null || continue
          # Delegate memory so the transient leaf reports memory.current (used to
          # rank freeze victims). Best-effort: freezing works without it.
          delegate_subtree "$sl" || true
        fi
        if printf '%s\n' "$p" > "$target/cgroup.procs" 2>/dev/null; then
          moved=$((moved + 1))
        else
          failed=$((failed + 1))
        fi
      done < "$child/cgroup.procs"
    done
  done
  shopt -u nullglob
  # An all-failures sweep must not be silent: with moved=0 it would log nothing
  # at all, which is indistinguishable from "no worker matched the regex" -- and
  # duty B/C then freeze nothing useful with no visible reason.
  [ "$moved" -gt 0 ] && log "SWEEP|migrated ${moved} heavy worker(s) into transient cgroup(s)"
  [ "$failed" -gt 0 ] && log "SWEEP|FAILED to migrate ${failed} worker(s) (no delegation on the slice?)"
  return 0
}

# Rate limiter for the above. Even fork-free, the sweep walks every pid in the
# pool, and it was being called on EVERY tick while TIGHT -- the log shows sweeps
# at 14:03:20, :41, :48, :58, i.e. four scans in 38 s. Nothing it does is urgent:
# a worker that appears between sweeps is caught by the next one, and the freeze
# decisions it feeds are themselves rate-limited by ROTATE_SECS. The STALL path
# passes `force` because there the scan IS the urgent step.
maybe_sweep() {
  if [ -z "${1:-}" ]; then
    elapsed_since "$last_sweep" "$EPOCHSECONDS"
    [ "$ELAPSED" -lt "$SWEEP_COOL" ] && return 0
  fi
  last_sweep=$EPOCHSECONDS
  sweep_transient
}

# Every freezable scope, into two parallel global arrays (BS_MEM[i] bytes,
# BS_PATH[i] scope path, glob order -- callers that need the largest scan for
# it): the monorepo-jobs build daemons (mj-*.scope) AND the transient leaves
# holding agent-spawned test and browser workers. The agents slice contributes
# its `transient` leaf but never `fleet` -- live agents are reclaimed from,
# never paused. The glob pair itself comes from kx_freeze_targets in
# cgroup-lib.sh, SHARED with cgroup-thaw-all's ExecStopPost sweep so the two
# can never drift (a shape thaw-all misses stays frozen forever after SIGKILL).
#
# Fills globals instead of printing, for the same reason the PSI helpers set
# globals: every caller used to consume this through a pipeline or process
# substitution, and each of those forks -- on the TIGHT and STALL paths, i.e.
# exactly when forks are unaffordable (see THE FORK BUDGET).
BS_MEM=()
BS_PATH=()
list_build_scopes() {
  local sl sc m p1 p pgs
  BS_MEM=(); BS_PATH=()
  shopt -s nullglob
  for sl in "$POOL"/worktrees-*.slice; do
    kx_freeze_targets "$sl"
    for sc in "${FREEZE_TARGETS[@]}"; do
      [ -e "$sc/cgroup.freeze" ] || continue
      # Skip an empty leaf: freezing nothing buys nothing. This MUST read a pid
      # rather than test the file's size -- cgroup.procs is a kernfs seq_file and
      # always stats as st_size=0 no matter how many pids it holds, so the
      # obvious `[ -s ]` is unconditionally false. It was, from 2026-07-28 until
      # 07-31, and it silently disabled the entire actuator: list_build_scopes
      # returned empty on every call, so duty B (the concurrency cap) and duty C
      # (the stall brake) never ran once -- `grep -c 'CGGOV|FREEZE' governor.log`
      # was 0 across the whole file while the log recorded 184 stalls in a single
      # day as "no build scope to brake (pressure is not from builds)". The
      # pressure WAS from builds; the governor just could not see any of the 21
      # live candidates. Only the two cheap duties (reclaim, sweep) ever ran.
      read -r p1 < "$sc/cgroup.procs" 2>/dev/null || continue
      [ -n "$p1" ] || continue
      read -r m < "$sc/memory.current" 2>/dev/null || m=""
      # A leaf without +memory delegated reports nothing; fall back to summed
      # RSS so it can still be ranked rather than silently sorting as zero.
      # Fork-free: statm field 2 is resident pages, readable with the `read`
      # builtin (the sweep_transient technique). The old fallback ran one awk
      # per pid inside nested process substitution -- the exact "three forks
      # PER PID" pattern THE FORK BUDGET condemns -- and it fires precisely
      # when a nixos-rebuild switch has cleared subtree_control (see
      # ensure_delegation), i.e. right after every rebuild.
      if [ -z "$m" ]; then
        m=0
        while read -r p; do
          [ -n "$p" ] || continue
          read -r _ pgs _ < "/proc/$p/statm" 2>/dev/null || continue
          case "$pgs" in '' | *[!0-9]*) continue ;; esac
          m=$(( m + pgs * 4096 ))
        done < "$sc/cgroup.procs"
      fi
      case "$m" in '' | *[!0-9]*) continue ;; esac
      BS_MEM+=("$m")
      BS_PATH+=("$sc")
    done
  done
  shopt -u nullglob
  return 0
}

# Fork-free: `read` builtin, not $(cat). Called once per candidate scope per
# tick, so on a busy pool this alone was several forks a second.
is_frozen() {
  local f
  read -r f < "$1/cgroup.freeze" 2>/dev/null || return 1
  [ "$f" = "1" ]
}

freeze_scope() {
  local sc="$1" why="$2" name m
  is_frozen "$sc" && return 0
  name="${sc##*/}"
  if [ -n "$DRYRUN" ]; then
    log "DRYRUN|would FREEZE $(pretty "$name") ($why)"
    return 0
  fi
  if printf '1' > "$sc/cgroup.freeze" 2>/dev/null; then
    frozen_since["$sc"]=$EPOCHSECONDS
    read -r m < "$sc/memory.current" 2>/dev/null || m=0
    log "FREEZE|$(pretty "$name") mem=$(( ${m:-0} / 1048576 ))M ($why)"
  else
    # Never fail silently: a freeze that did not land looks EXACTLY like "cap
    # not exceeded" in the log, which is the dead-actuator shape (duties B/C
    # were invisible no-ops for three days in July on the strength of it).
    log "FREEZE|FAILED $(pretty "$name") - write to cgroup.freeze refused ($why)"
  fi
}

thaw_scope() {
  local sc="$1" why="${2:-}"
  if [ -n "$DRYRUN" ]; then
    unset 'frozen_since[$sc]' 2>/dev/null || true
    return 0
  fi
  # A vanished cgroup needs no thaw -- drop it from the map and move on.
  if [ ! -e "$sc/cgroup.freeze" ]; then
    unset 'frozen_since[$sc]' 2>/dev/null || true
    return 0
  fi
  # Never fail silently, and never FORGET a failure: the old code dropped the
  # frozen_since entry unconditionally, so a refused write (delegation lost,
  # EACCES) left the scope frozen with nothing left to retry it -- the deadline
  # enforcer iterates frozen_since. Keep the entry on failure so the next tick
  # tries again, and say so in the log.
  if printf '0' > "$sc/cgroup.freeze" 2>/dev/null; then
    log "THAW|$(pretty "${sc##*/}")${why:+ ($why)}"
    unset 'frozen_since[$sc]' 2>/dev/null || true
  else
    log "THAW|FAILED $(pretty "${sc##*/}") - scope stays frozen, retrying next tick${why:+ ($why)}"
  fi
}

# Thaw everything we hold, plus (belt and braces) every mj-* scope in the pool --
# this is what recovers a build left frozen by a previous run that was killed
# mid-freeze, so it also runs once at startup.
thaw_all() {
  local why="${1:-}" sc k
  for sc in "${!frozen_since[@]}"; do thaw_scope "$sc" "$why"; done
  # Orphan sweep over the arrays list_build_scopes fills -- the old process
  # substitution here forked, and thaw_all runs from the NORMAL branch of the
  # detection loop.
  list_build_scopes
  for (( k = 0; k < ${#BS_PATH[@]}; k++ )); do
    sc="${BS_PATH[$k]}"
    is_frozen "$sc" && thaw_scope "$sc" "${why:-orphan sweep}"
  done
  return 0
}

# Push the cgroup's COLDEST pages into zram. Errors are expected and ignored:
# memory.reclaim returns EAGAIN when it cannot free the full amount, which is
# information, not a failure. Bounded to a modest chunk so the write returns
# quickly -- if pressure persists the next tick reclaims again.
reclaim_from() {
  local cg="$1" mb="$2" why="$3" name before after
  # Never fail silently: a missing memory.reclaim means this duty is doing
  # NOTHING, which is exactly the failure that hid behind the leaf-vs-slice bug
  # above. Log it loudly so a silent no-op is visible in the governor log.
  if [ ! -e "$cg/memory.reclaim" ]; then
    log "RECLAIM|SKIPPED - no memory.reclaim at ${cg#"$USERAT"/} (memory controller not delegated here?)"
    return 0
  fi
  name="${cg##*/}"
  read -r before < "$cg/memory.current" 2>/dev/null || before=0
  if [ -n "$DRYRUN" ]; then
    log "DRYRUN|would RECLAIM ${mb}M from $(pretty "$name") cur=$(( ${before:-0} / 1048576 ))M ($why)"
    return 0
  fi
  # Single-in-flight guard. If the previous reclaim is still blocked inside the
  # kernel there is no sense stacking another onto it: they would contend for the
  # same LRU and the second would just wait behind the first.
  if [ -n "$reclaim_pid" ] && kill -0 "$reclaim_pid" 2>/dev/null; then
    log "RECLAIM|SKIPPED - previous reclaim still in flight (pid $reclaim_pid)"
    return 0
  fi
  # BACKGROUNDED DELIBERATELY, and this is the second half of the 07-29 fix.
  # A write to memory.reclaim performs the reclaim SYNCHRONOUSLY in the calling
  # context -- measured at 0.23-1.56 s with 10 GiB free, and far worse at the
  # ~400 MiB free this actually fires at, because the reclaiming thread is itself
  # competing for pages. Doing that inline meant the detection loop stopped
  # measuring for the whole duration, which is how the governor came to be blind
  # for 129 s across the 14:05 stall it was built to catch. Actuation may take as
  # long as it takes; detection must never wait on it.
  #
  # numfmt is gone from this path too: it was three more forks per reclaim, on a
  # path that by definition only runs when memory is short.
  {
    ok=1
    printf '%d' "$(( mb * 1024 * 1024 ))" > "$cg/memory.reclaim" 2>/dev/null || ok=0
    read -r after < "$cg/memory.current" 2>/dev/null || after=0
    if [ "$ok" = 1 ]; then
      log "RECLAIM|$(pretty "$name") asked=${mb}M $(( ${before:-0} / 1048576 ))M -> $(( ${after:-0} / 1048576 ))M ($why)"
    else
      # The write's exit status cannot tell EAGAIN (partial reclaim -- normal,
      # the header's "information, not a failure") from EACCES/ENOENT
      # (delegation lost -- the duty silently doing nothing, the freeze/thaw
      # siblings' documented FAILED shape). Don't swallow both: name the
      # refusal and let before/after disambiguate -- a refused write that
      # also moved no memory is the dangerous one.
      log "RECLAIM|WRITE-REFUSED $(pretty "$name") asked=${mb}M $(( ${before:-0} / 1048576 ))M -> $(( ${after:-0} / 1048576 ))M ($why) - EAGAIN-partial is normal; unchanged usage means delegation is lost"
    fi
  } &
  reclaim_pid=$!
}

# Re-assert +memory +pids on the agents slice so its children stay ACCOUNTED.
#
# claude-agents-reattach writes this once, at reattach. systemd prunes it back to
# empty on every user-unit reload -- i.e. on every nixos-rebuild switch -- because
# it keeps in a slice's subtree_control only what some CHILD UNIT asks for, and
# `fleet`/`transient` are raw mkdir cgroups, not units, so systemd sees no reason
# to keep anything. See the FLEET comment near the top: observed 07-28 as a leaf
# holding 46 procs with no memory.current at all.
#
# The window between a rebuild and the next reattach is therefore one where
# `fleet` and `transient` report NOTHING -- which is why the per-child figures in
# the pressure monitor's stall analyses ("fleet 9.5 GB") cannot be trusted for
# those two: they are read from files that may not exist. Re-asserting every tick
# closes that window for good; the governor already runs forever and already has
# the path.
#
# ACCOUNTING ONLY. This sets no limit and changes no scheduling -- it restores
# visibility. The reclaim target above stays the SLICE, which is correct either
# way (parent reclaim covers the whole subtree) and does not depend on this.
ensure_delegation() {
  local rc
  # A fleet slice with no subtree_control at all is not materialized yet --
  # nothing to repair, nothing to warn about.
  [ -e "$FLEET/cgroup.subtree_control" ] || return 0
  delegate_subtree "$FLEET"
  rc=$?
  case "$rc" in
    0) deleg_warned=0 ;;
    2)
      deleg_warned=0
      log "DELEGATE|re-enabled +memory +pids on worktrees-agents.slice (had been cleared)"
      ;;
    *)
      # Refused (see delegate_subtree's no-internal-process note). Worth
      # saying once -- never fail silently -- but not every five seconds.
      if [ "$deleg_warned" = 0 ]; then
        deleg_warned=1
        log "DELEGATE|cannot enable +memory +pids on worktrees-agents.slice (procs directly in it?) - fleet/transient stay unaccounted"
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# THE TICK DECISION, as pure functions. Everything from here down to the test
# seam takes this tick's measurements (and the brake/cap state variables) as
# ARGUMENTS and hands verdicts back in globals or exit statuses -- no cgroup
# writes, no log lines, no clock reads. The loop below the seam keeps every
# EFFECT (freeze/thaw/reclaim/sweep and each log line) and threads the state
# variables through these. Same split as the semaphore controller's decide()
# (see build-semaphore-policy.test.py): the loop itself had zero tests because
# exercising it meant standing up wall-clock ticks against a real cgroup tree;
# the decisions need none of that.

# STALL / TIGHT / NORMAL, from this tick's three readings. Thresholds are the
# pre-scaled globals (STALL_CENTI, LOW_FREE_MB, POOL_CENTI).
#   STALL = the desktop is stalling right now.
#   TIGHT = either the free page buffer is draining toward the ~370 MiB floor
#           every recorded stall bottoms out at, OR the pool is suffocating
#           against its own memory.high. The second clause is new on 07-29:
#           without it the governor sat in NORMAL, correctly by its own lights,
#           while every process in the pool stalled a quarter of the time and
#           the user reported the machine as unusable. Free RAM was 2.9 GB and
#           the desktop was at 0.00% -- both green, both irrelevant.
# The 2>/dev/null on the free_mb test keeps a non-numeric reading from
# spraying errors; it then reads as "not low" and the pool clause still gets
# its say (fail-open, like read_meminfo's 99999 sentinel).
CLASSIFY_STATE="NORMAL"
classify_state() {  # dm_c pm_c free_mb -> CLASSIFY_STATE
  if [ "$1" -ge "$STALL_CENTI" ]; then
    CLASSIFY_STATE="STALL"
  elif [ "$3" -lt "$LOW_FREE_MB" ] 2>/dev/null || [ "$2" -ge "$POOL_CENTI" ]; then
    CLASSIFY_STATE="TIGHT"
  else
    CLASSIFY_STATE="NORMAL"
  fi
  return 0
}

# The loop-lag watchdog's verdict: 0 = warn, with the (clamped) overrun in
# $LAG. The first tick (last_tick=0) never warns -- there is no previous tick
# to have overrun.
LAG=0
lag_check() {  # last_tick now -> LAG; exit 0 = log the LAG line
  LAG=0
  [ "$1" -gt 0 ] || return 1
  elapsed_since "$1" "$2"
  LAG=$ELAPSED
  [ "$LAG" -ge "$LAG_WARN" ]
}

# Freeze-deadline verdict for one frozen_since entry: 0 = the hold has hit
# MAX_FREEZE_SECS and the scope must be thawed no matter what the pressure
# reading says. The held time (clamped) is left in $DEADLINE_HELD for the log.
DEADLINE_HELD=0
freeze_deadline_due() {  # frozen_at now -> DEADLINE_HELD; exit 0 = thaw it
  elapsed_since "$1" "$2"
  DEADLINE_HELD=$ELAPSED
  [ "$DEADLINE_HELD" -ge "$MAX_FREEZE_SECS" ]
}

# Brake-deadline verdict: 0 = a brake victim is held and its deadline has
# passed, thaw it and clear the brake state.
brake_release_due() {  # brake_scope brake_until now
  [ -n "$1" ] && [ "$3" -ge "$2" ]
}

# The deferred STALL re-measure verdict. Last tick's STALL reclaimed and
# armed the brake; this tick's fresh PSI read IS the re-measure -- one
# INTERVAL later instead of the old inline `sleep 2`, a deliberate trade of a
# slightly staler reading for a loop that never stops measuring. Back under
# the stall line (exit 0) means the reclaim worked and the brake stands down.
# (Still stalled? brake_step consumes the armed flag and escalates.)
brake_recovered() {  # brake_armed dm_c; exit 0 = disarm and log recovery
  [ "$1" = 1 ] && [ "$2" -lt "$STALL_CENTI" ]
}

# Duty C's decision, for a tick that classified STALL (only the STALL branch
# calls this): reclaim first (no pause), re-measure next tick, and only if
# that did not fix it, freeze. The caller performs whichever action comes
# back and copies BRAKE_ARMED_NEXT into brake_armed. Actions:
#   hold        -- a brake is already applied; the deadline enforcer will
#                  release it. Keep measuring rather than stacking a second
#                  freeze on top.
#   escalate    -- armed last tick, and this tick's reading still says STALL
#                  (or this function would not be running): the reclaim was
#                  not enough. Brake.
#   reclaim-arm -- reclaim from the fleet and arm the re-measure.
#   brake       -- reclaim is on cooldown: it already ran for this storm and
#                  did not clear it, so go straight to the brake, as the old
#                  shape did.
BRAKE_ACTION="hold"
BRAKE_ARMED_NEXT=0
brake_step() {  # brake_scope brake_armed now last_reclaim -> BRAKE_ACTION BRAKE_ARMED_NEXT
  BRAKE_ARMED_NEXT="$2"
  if [ -n "$1" ]; then
    BRAKE_ACTION="hold"
  elif [ "$2" = 1 ]; then
    BRAKE_ACTION="escalate"
    BRAKE_ARMED_NEXT=0
  else
    elapsed_since "$4" "$3"
    if [ "$ELAPSED" -ge "$RECLAIM_COOL" ]; then
      BRAKE_ACTION="reclaim-arm"
      BRAKE_ARMED_NEXT=1
    else
      BRAKE_ACTION="brake"
    fi
  fi
  return 0
}

# Duty B's candidate filter over the arrays list_build_scopes fills: heavy
# scopes only. Light scopes are left alone -- they are not the problem and
# freezing them buys nothing. Filtered in bash: the old
# `mapfile -t < <(... | awk ...)` forked a subshell plus an awk on every
# TIGHT tick.
HEAVY=()
heavy_filter() {  # (reads BS_MEM/BS_PATH) -> HEAVY
  local k
  HEAVY=()
  for (( k = 0; k < ${#BS_PATH[@]}; k++ )); do
    [ "${BS_MEM[$k]}" -ge $(( HEAVY_MB * 1024 * 1024 )) ] && HEAVY+=("${BS_PATH[$k]}")
  done
  return 0
}

# Duty B's victim window over the heavy candidates. Rotate the window each
# cycle (`rot` advances every ROTATE_SECS, in the loop): every build gets
# turns running. CAP_FREEZE gets the first n - maxconc scopes of the rotated
# order (the victims), CAP_RUN the rest -- the same rotated sequence, in the
# same order, that the inline loop produced.
CAP_FREEZE=()
CAP_RUN=()
cap_plan() {  # rot maxconc scope... -> CAP_FREEZE CAP_RUN
  local rot="$1" maxconc="$2" k n want
  shift 2
  local scopes=("$@")
  n=$#
  want=$(( n - maxconc ))
  CAP_FREEZE=(); CAP_RUN=()
  for (( k = 0; k < n; k++ )); do
    if [ "$k" -lt "$want" ]; then
      CAP_FREEZE+=("${scopes[$(( (k + rot) % n ))]}")
    else
      CAP_RUN+=("${scopes[$(( (k + rot) % n ))]}")
    fi
  done
  return 0
}

# Duty C's victim pick: the single largest build scope ("" if none). Ties
# keep the earlier (glob-order) scope, `-gt` not `-ge`, so the pick is
# stable across ticks. Fork-free max scan over the arrays -- this replaces
# `list_build_scopes | sort -rn | head -1 | cut -f2`, three pipeline forks at
# the most memory-starved moment the governor ever acts in.
BIGGEST=""
biggest_scope() {  # (reads BS_MEM/BS_PATH) -> BIGGEST
  local k m=-1
  BIGGEST=""
  for (( k = 0; k < ${#BS_PATH[@]}; k++ )); do
    if [ "${BS_MEM[$k]}" -gt "$m" ]; then
      m="${BS_MEM[$k]}"
      BIGGEST="${BS_PATH[$k]}"
    fi
  done
  return 0
}

# TEST SEAM. scripts/cgroup-governor.test.py exercises the functions above
# against a synthetic pool: it sources this file, overrides $POOL, and calls
# them directly. `return` succeeds only in a sourced context, so a sourced
# load stops HERE -- definitions only, no traps, no START log, no loop.
# Executed normally (systemd), the subshell's `return` fails and the service
# falls through to the loop below.
if (return 0 2>/dev/null); then
  return 0
fi

# A bash trap handler does NOT terminate the shell by itself, so the signal
# handler must exit explicitly -- otherwise SIGTERM thaws everything and then
# the loop merrily carries on, `systemctl --user stop` blocks until its timeout,
# and the service is SIGKILLed (leaving whatever it froze next still frozen).
# EXIT does the thawing; INT/TERM just ask for a clean exit.
on_exit() { thaw_all "governor exiting"; log "STOP|governor stopped"; }
on_signal() { log "STOP|signal received, shutting down"; exit 0; }
trap on_exit EXIT
trap on_signal INT TERM

log "START|governor started (thresh=${STALL_THRESH}% pool_thresh=${POOL_THRESH}% low_free=${LOW_FREE_MB}M maxconc=${MAXCONC} heavy=${HEAVY_MB}M reclaim=${RECLAIM_MB}M/${RECLAIM_COOL}s sweep_cool=${SWEEP_COOL}s freeze=${FREEZE_SECS}s max_freeze=${MAX_FREEZE_SECS}s rotate=${ROTATE_SECS}s lag_warn=${LAG_WARN}s dryrun=${DRYRUN:-off})"

# Machine-fact cross-check. memory-policy.nix hardcodes memTotalG -- the one
# hand-copied machine fact the policy allows itself -- and every margin
# calculation (pool ceiling vs desktop floor) reasons from it. If the VM's
# RAM allocation changes and that number is not updated, the whole partition
# is silently mis-sized; this is the runtime verifier the eval-time assert
# cannot be (eval is pure, /proc is not). Once at startup, ±1 GiB tolerance
# for kernel/firmware reservations.
if [ -n "${KX_POLICY_MEMTOTAL_G:-}" ]; then
  while read -r k v _; do
    [ "$k" = "MemTotal:" ] || continue
    mt_g=$(( (v + 524288) / 1048576 ))
    if [ "$mt_g" -lt $(( KX_POLICY_MEMTOTAL_G - 1 )) ] \
       || [ "$mt_g" -gt $(( KX_POLICY_MEMTOTAL_G + 1 )) ]; then
      log "MEMTOTAL-DRIFT|/proc/meminfo says ~${mt_g}G but memory-policy.nix says ${KX_POLICY_MEMTOTAL_G}G - the desktop-floor/pool-ceiling margins are computed from a machine that no longer exists; update memTotalG"
    fi
    break
  done < /proc/meminfo
fi

thaw_all "startup sweep"

while :; do
  now=$EPOCHSECONDS

  # --- Loop-lag watchdog. THE failure mode this service actually suffered was
  # not a wrong decision, it was NO decision: on 07-29 the tick stretched to 100 s
  # and 129 s under memory pressure, and both of the day's desktop stalls landed
  # inside those gaps. Nothing in the log said so -- a blind spot looks exactly
  # like a quiet machine. If detection ever goes slow again, it now says so in
  # its own log rather than leaving an absence to be noticed by someone reading
  # timestamps by hand. ---
  if lag_check "$last_tick" "$now"; then
    log "LAG|tick took ${LAG}s (interval ${INTERVAL}s) - detection was BLIND for that window"
  fi
  last_tick=$now

  # --- 0. Deadline enforcement. Runs FIRST and unconditionally, so a wedged
  # pressure reading can never hold a build frozen indefinitely. The stall
  # brake's short deadline is enforced here too: duty C freezes WITHOUT
  # sleeping (the loop must never stop measuring) and records brake_until;
  # this is where that promise is kept. With FREEZE_SECS below INTERVAL the
  # actual hold rounds up to one tick, which is the price of staying awake. ---
  for sc in "${!frozen_since[@]}"; do
    if freeze_deadline_due "${frozen_since[$sc]}" "$now"; then
      thaw_scope "$sc" "deadline ${DEADLINE_HELD}s >= ${MAX_FREEZE_SECS}s"
    fi
  done
  if brake_release_due "$brake_scope" "$brake_until" "$now"; then
    thaw_scope "$brake_scope" "brake released after $(( now - brake_until + FREEZE_SECS ))s (deadline ${FREEZE_SECS}s)"
    brake_scope=""
    brake_until=0
  fi

  # --- 0b. Keep the agents subtree accounted. Cheap, fork-free, every tick. ---
  ensure_delegation

  # A governor that cannot find the desktop measures NOTHING, and last_tick
  # was just refreshed above -- so without this warn-once its log is
  # indistinguishable from a healthy quiet machine, the exact "silence reads
  # as calm" failure the lag watchdog exists to prevent on the other axis.
  if ! resolve_desktop memory.pressure; then
    if [ "$desktop_blind" = 0 ]; then
      log "DESKTOP|UNRESOLVED - no readable session scope; detection is BLIND until one appears"
      desktop_blind=1
    fi
    sleep "$INTERVAL"; continue
  fi
  if [ "$desktop_blind" = 1 ]; then
    log "DESKTOP|resolved ${DESKTOP##*/} - detection resumed"
    desktop_blind=0
  fi
  # Three fork-free reads. Previously three awk processes, every five seconds,
  # forever -- and unaffordable at exactly the moment they mattered.
  psi_full_avg10 "$DESKTOP/memory.pressure"; dm="$PSI_TEXT"; dm_c="$PSI_CENTI"
  psi_full_avg10 "$POOL/memory.pressure";    pm="$PSI_TEXT"; pm_c="$PSI_CENTI"
  read_meminfo; free_mb="$MEMFREE_MB"; avail="$MEMAVAIL_MB"

  # --- 1. Classify. The semantics (and the 07-29 pool-clause history) live on
  # classify_state, above the test seam. ---
  classify_state "$dm_c" "$pm_c" "$free_mb"
  state="$CLASSIFY_STATE"
  [ "$state" != "$last_state" ] && \
    log "STATE|$last_state -> $state (desktop_mem_full_avg10=${dm}% pool_mem_full_avg10=${pm}% free=${free_mb}M avail=${avail}M)"
  last_state="$state"

  # Deferred STALL re-measure (semantics on brake_recovered, above the seam):
  # last tick's reclaim worked, so the brake stands down without freezing.
  if brake_recovered "$brake_armed" "$dm_c"; then
    brake_armed=0
    log "STALL|recovered after reclaim (${brake_armed_dm}% -> ${dm}%), no freeze needed"
  fi

  case "$state" in
    NORMAL)
      # Pressure gone: release every held build immediately. The cap is a storm
      # response, not a standing policy -- nothing stays frozen at rest. Any
      # active brake victim is thawed with the rest (only possible when
      # FREEZE_SECS is tuned above INTERVAL), so its state resets with it.
      [ "${#frozen_since[@]}" -gt 0 ] && thaw_all "pressure cleared"
      rot=0
      brake_scope=""
      brake_until=0
      ;;

    TIGHT)
      # Make agent-spawned test/browser workers freezable before deciding what to
      # freeze. Only runs off the NORMAL path, so it costs nothing at rest, and
      # is rate-limited on top of that -- see maybe_sweep.
      maybe_sweep

      # Duty A: cheapest lever first -- push the fleet's cold spare heaps to
      # zram. No pause, no throttle, no effect on hot pages.
      elapsed_since "$last_reclaim" "$now"
      if [ "$ELAPSED" -ge "$RECLAIM_COOL" ]; then
        reclaim_from "$FLEET" "$RECLAIM_MB" "TIGHT free=${free_mb}M"
        last_reclaim=$now
      fi

      # Duty B: hold all but $MAXCONC heavy build scopes, rotating victims so
      # none is starved. The candidate filter and the rotated victim window
      # live on heavy_filter and cap_plan, above the seam; this branch only
      # advances the rotation clock and applies the plan.
      list_build_scopes
      heavy_filter
      n=${#HEAVY[@]}
      if [ "$n" -gt "$MAXCONC" ]; then
        elapsed_since "$last_rotate" "$now"
        [ "$ELAPSED" -ge "$ROTATE_SECS" ] && { rot=$(( rot + 1 )); last_rotate=$now; }
        cap_plan "$rot" "$MAXCONC" "${HEAVY[@]}"
        for sc in "${CAP_FREEZE[@]}"; do
          freeze_scope "$sc" "cap ${MAXCONC}/${n} free=${free_mb}M"
        done
        for sc in "${CAP_RUN[@]}"; do
          is_frozen "$sc" && thaw_scope "$sc" "cap rotation"
        done
      elif [ "${#frozen_since[@]}" -gt 0 ]; then
        thaw_all "under cap (${n} <= ${MAXCONC})"
      fi
      ;;

    STALL)
      # Duty C, effects only -- the decision is brake_step, above the seam:
      # reclaim first (no pause), then re-measure on the NEXT tick, and only
      # escalate if that did not fix it.
      #
      # NO SLEEP ANYWHERE IN THIS BRANCH, and that is the point of its shape.
      # The old form slept inline (`sleep 2` before the re-measure, then
      # freeze + `sleep $FREEZE_SECS` + thaw), which stopped measurement for
      # up to ~5 s during a stall -- and invisibly, because LAG_WARN sat above
      # it. Now: reclaim arms the brake (brake_armed) and the re-measure is
      # the next tick's own PSI read; the freeze records brake_until and the
      # top-of-loop deadline enforcer does the thaw. Every guarantee is
      # unchanged -- only mj-*.scope / transient leaves are ever frozen
      # (list_build_scopes yields nothing else), victims rotate via duty B,
      # and a brake victim is still covered by the EXIT trap, the startup
      # sweep, ExecStopPost, and the MAX_FREEZE_SECS ceiling.
      log "STALL|desktop mem_full_avg10=${dm}% pool=${pm}% free=${free_mb}M avail=${avail}M"
      # `force`: during an actual stall the scan IS the urgent step, so it skips
      # the rate limiter that keeps it cheap during ordinary TIGHT ticks.
      maybe_sweep force
      brake_step "$brake_scope" "$brake_armed" "$now" "$last_reclaim"
      brake_armed="$BRAKE_ARMED_NEXT"
      do_brake=0
      case "$BRAKE_ACTION" in
        # hold: a brake is already applied; the deadline enforcer will release
        # it. Keep measuring rather than stacking a second freeze on top.
        hold) : ;;
        escalate|brake) do_brake=1 ;;
        reclaim-arm)
          reclaim_from "$FLEET" "$(( RECLAIM_MB * 2 ))" "STALL mem_psi=${dm}%"
          last_reclaim=$now
          brake_armed_dm="$dm"
          ;;
      esac

      if [ "$do_brake" = 1 ]; then
        # Still stalling: brake the single largest build scope (biggest_scope,
        # above the seam), briefly.
        list_build_scopes
        biggest_scope
        if [ -n "$BIGGEST" ]; then
          freeze_scope "$BIGGEST" "stall brake mem_psi=${dm}%"
          brake_scope="$BIGGEST"
          brake_until=$(( now + FREEZE_SECS ))
        else
          # Genuinely nothing freezable: no mj-*.scope and no populated transient
          # leaf in the pool. Do NOT read this as "the builds are innocent" -- that
          # was the old wording and it was actively misleading for three days while
          # list_build_scopes was broken (see the note there). It means only that
          # the governor has no lever, so the stall must be ridden out.
          log "STALL|no freezable scope in pool (nothing to brake)"
        fi
      fi
      ;;
  esac

  sleep "$INTERVAL"
done
