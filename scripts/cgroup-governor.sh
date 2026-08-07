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
#   CGGOV_LAG_WARN        log LAG if a tick overruns this many seconds (default 15)
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
# Warn when a tick overruns this many seconds -- the blind-spot alarm.
LAG_WARN="${CGGOV_LAG_WARN:-15}"

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
# The slice's files are guaranteed by MemoryAccounting=true in cgroups.nix.
FLEET="$POOL/worktrees-agents.slice"
DESKTOP=""

declare -A frozen_since=()   # scope path -> epoch seconds it was frozen
last_reclaim=0
rot=0
last_rotate=0
state="NORMAL"
last_state=""
last_sweep=0                 # maybe_sweep rate limiter
last_tick=0                  # loop-lag watchdog
deleg_warned=0               # ensure_delegation: warn once, not every tick
reclaim_pid=""               # in-flight backgrounded reclaim, if any
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

# Reads "full ... avg10=NN.NN ..." from a PSI file into two globals:
#   PSI_TEXT  -- the value exactly as the kernel printed it, for log lines
#   PSI_CENTI -- the same number in integer hundredths, for comparisons
# Sets globals rather than echoing precisely because `x=$(fn)` forks; this is
# called two or three times per tick on the detection path.
PSI_TEXT=0
PSI_CENTI=0
psi_full_avg10() {
  local line tok i f
  PSI_TEXT=0; PSI_CENTI=0
  while read -r line; do
    case "$line" in full\ *) ;; *) continue ;; esac
    for tok in $line; do
      case "$tok" in
        avg10=*)
          PSI_TEXT="${tok#avg10=}"
          i="${PSI_TEXT%%.*}"; [ -n "$i" ] || i=0
          f="${PSI_TEXT#*.}"; [ "$f" = "$PSI_TEXT" ] && f=00
          f="${f}00"; f="${f:0:2}"
          # 10# forces base 10: PSI prints "08" and "09", which are invalid octal.
          PSI_CENTI=$(( 10#$i * 100 + 10#$f ))
          return 0
          ;;
      esac
    done
  done < "$1" 2>/dev/null
  return 0
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
#
# One fork-free pass sets both globals. MemFree and MemAvailable are the 2nd and
# 3rd lines of /proc/meminfo, so this reads three lines and stops -- against two
# `awk` processes, each of which read the whole file, on every single tick.
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
  done < /proc/meminfo 2>/dev/null
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
  local sl child target p c cl rss_mb moved=0 base parts
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

# Rate limiter for the above. Even fork-free, the sweep walks every pid in the
# pool, and it was being called on EVERY tick while TIGHT -- the log shows sweeps
# at 14:03:20, :41, :48, :58, i.e. four scans in 38 s. Nothing it does is urgent:
# a worker that appears between sweeps is caught by the next one, and the freeze
# decisions it feeds are themselves rate-limited by ROTATE_SECS. The STALL path
# passes `force` because there the scan IS the urgent step.
maybe_sweep() {
  if [ -z "${1:-}" ] && [ $(( EPOCHSECONDS - last_sweep )) -lt "$SWEEP_COOL" ]; then
    return 0
  fi
  last_sweep=$EPOCHSECONDS
  sweep_transient
}

# Every freezable scope, "<bytes>\t<path>", largest first: the monorepo-jobs
# build daemons (mj-*.scope) AND the transient leaves holding agent-spawned test
# and browser workers. The agents slice contributes its `transient` leaf but
# never `fleet` -- live agents are reclaimed from, never paused.
list_build_scopes() {
  local sl sc m p1
  shopt -s nullglob
  for sl in "$POOL"/worktrees-*.slice; do
    for sc in "$sl"/mj-*.scope "$sl"/transient; do
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
      log "THAW|$(pretty "${sc##*/}")${why:+ ($why)}"
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
    printf '%d' "$(( mb * 1024 * 1024 ))" > "$cg/memory.reclaim" 2>/dev/null || true
    read -r after < "$cg/memory.current" 2>/dev/null || after=0
    log "RECLAIM|$(pretty "$name") asked=${mb}M $(( ${before:-0} / 1048576 ))M -> $(( ${after:-0} / 1048576 ))M ($why)"
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
  local sc=""
  [ -e "$FLEET/cgroup.subtree_control" ] || return 0
  # An EMPTY subtree_control is exactly the state being repaired, and `read`
  # returns non-zero on it (EOF before any delimiter), so its exit status must
  # NOT gate the repair -- testing it would skip the only case that matters.
  read -r sc 2>/dev/null < "$FLEET/cgroup.subtree_control"
  case " $sc " in *" memory "*) deleg_warned=0; return 0 ;; esac
  if printf '+memory +pids' 2>/dev/null > "$FLEET/cgroup.subtree_control"; then
    deleg_warned=0
    log "DELEGATE|re-enabled +memory +pids on worktrees-agents.slice (had been cleared)"
  elif [ "$deleg_warned" = 0 ]; then
    # cgroup v2 refuses this while processes sit DIRECTLY in the slice (the
    # no-internal-process rule), which is a real transient state during reattach.
    # Worth saying once -- never fail silently -- but not every five seconds.
    deleg_warned=1
    log "DELEGATE|cannot enable +memory +pids on worktrees-agents.slice (procs directly in it?) - fleet/transient stay unaccounted"
  fi
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

log "START|governor started (thresh=${STALL_THRESH}% pool_thresh=${POOL_THRESH}% low_free=${LOW_FREE_MB}M maxconc=${MAXCONC} heavy=${HEAVY_MB}M reclaim=${RECLAIM_MB}M/${RECLAIM_COOL}s sweep_cool=${SWEEP_COOL}s freeze=${FREEZE_SECS}s max_freeze=${MAX_FREEZE_SECS}s rotate=${ROTATE_SECS}s lag_warn=${LAG_WARN}s dryrun=${DRYRUN:-off})"
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
  if [ "$last_tick" -gt 0 ]; then
    lag=$(( now - last_tick ))
    if [ "$lag" -ge "$LAG_WARN" ]; then
      log "LAG|tick took ${lag}s (interval ${INTERVAL}s) - detection was BLIND for that window"
    fi
  fi
  last_tick=$now

  # --- 0. Deadline enforcement. Runs FIRST and unconditionally, so a wedged
  # pressure reading can never hold a build frozen indefinitely. ---
  for sc in "${!frozen_since[@]}"; do
    held=$(( now - ${frozen_since[$sc]} ))
    if [ "$held" -ge "$MAX_FREEZE_SECS" ]; then
      thaw_scope "$sc" "deadline ${held}s >= ${MAX_FREEZE_SECS}s"
    fi
  done

  # --- 0b. Keep the agents subtree accounted. Cheap, fork-free, every tick. ---
  ensure_delegation

  resolve_desktop || { sleep "$INTERVAL"; continue; }
  # Three fork-free reads. Previously three awk processes, every five seconds,
  # forever -- and unaffordable at exactly the moment they mattered.
  psi_full_avg10 "$DESKTOP/memory.pressure"; dm="$PSI_TEXT"; dm_c="$PSI_CENTI"
  psi_full_avg10 "$POOL/memory.pressure";    pm="$PSI_TEXT"; pm_c="$PSI_CENTI"
  read_meminfo; free_mb="$MEMFREE_MB"; avail="$MEMAVAIL_MB"

  # --- 1. Classify.
  #   STALL = the desktop is stalling right now.
  #   TIGHT = either the free page buffer is draining toward the ~370 MiB floor
  #           every recorded stall bottoms out at, OR the pool is suffocating
  #           against its own memory.high. The second clause is new on 07-29:
  #           without it the governor sat in NORMAL, correctly by its own lights,
  #           while every process in the pool stalled a quarter of the time and
  #           the user reported the machine as unusable. Free RAM was 2.9 GB and
  #           the desktop was at 0.00% -- both green, both irrelevant. ---
  if [ "$dm_c" -ge "$STALL_CENTI" ]; then
    state="STALL"
  elif [ "$free_mb" -lt "$LOW_FREE_MB" ] 2>/dev/null || [ "$pm_c" -ge "$POOL_CENTI" ]; then
    state="TIGHT"
  else
    state="NORMAL"
  fi
  [ "$state" != "$last_state" ] && \
    log "STATE|$last_state -> $state (desktop_mem_full_avg10=${dm}% pool_mem_full_avg10=${pm}% free=${free_mb}M avail=${avail}M)"
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
      # freeze. Only runs off the NORMAL path, so it costs nothing at rest, and
      # is rate-limited on top of that -- see maybe_sweep.
      maybe_sweep

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
      log "STALL|desktop mem_full_avg10=${dm}% pool=${pm}% free=${free_mb}M avail=${avail}M"
      # `force`: during an actual stall the scan IS the urgent step, so it skips
      # the rate limiter that keeps it cheap during ordinary TIGHT ticks.
      maybe_sweep force
      if [ $(( now - last_reclaim )) -ge "$RECLAIM_COOL" ]; then
        reclaim_from "$FLEET" "$(( RECLAIM_MB * 2 ))" "STALL mem_psi=${dm}%"
        last_reclaim=$now
        sleep 2
        psi_full_avg10 "$DESKTOP/memory.pressure"; dm2="$PSI_TEXT"
        if [ "$PSI_CENTI" -lt "$STALL_CENTI" ]; then
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
        # Genuinely nothing freezable: no mj-*.scope and no populated transient
        # leaf in the pool. Do NOT read this as "the builds are innocent" -- that
        # was the old wording and it was actively misleading for three days while
        # list_build_scopes was broken (see the note there). It means only that
        # the governor has no lever, so the stall must be ridden out.
        log "STALL|no freezable scope in pool (nothing to brake)"
      fi
      ;;
  esac

  sleep "$INTERVAL"
done
