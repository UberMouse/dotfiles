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
#      GATED ON EFFECTIVENESS (2026-09-14), because that premise expires. On
#      09-14 idle spares were 0.65 GB of a 12 GB slice, three of five sampled
#      reclaims left the charge at or above where it started, and anon refaults
#      tracked steals page for page: the duty was evicting ACTIVE pages that came
#      straight back, at a core of sys time. reclaim_useful reads the slice's
#      refault ratio over the last tick and duty_a_step skips when it says the
#      reclaim would only feed the loop. The STALL path's reclaim is NOT gated --
#      it is the desktop's emergency lever, where late is the worse failure.
#      See docs/notes/2026-09-14-fleet-anon-thrash.md.
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
#   grep -E 'CGGOV\|(RECLAIM|FREEZE|THAW|CAP|STALL|STATE|START|STOP|DRYRUN|SWEEP|MIGRATE|LAG|BALLOON|CEILING)' \
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
#   CGGOV_THRASH_PCT      duty A skips at this anon-refault %% of steal (default 0 = off, log-only)
#   CGGOV_THRASH_MIN_STEAL  ...only once the tick stole this many pages (default 0)
#   CGGOV_BALLOON_STEP_MB balloon granularity: a reversal that logs a peak/trough,
#                         and the step the pool ceiling moves in       (default 512)
#   CGGOV_CEILING_DWELL   seconds a higher ceiling must hold before a raise (default 60)
#   KX_POLICY_POOL_HIGH_G / KX_POLICY_POOL_HIGH_FLOOR_G
#                         memory-policy.nix's pool ceiling and its balloon floor;
#                         without both the balloon-aware ceiling is off
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
# Duty A's effectiveness gate (see reclaim_useful). OFF by default: the refault
# ratio is measured every tick and logged on every RECLAIM line, but withholds
# nothing. Both numbers get picked from those logged ratios, not guessed.
THRASH_PCT="${CGGOV_THRASH_PCT:-0}"
THRASH_MIN_STEAL="${CGGOV_THRASH_MIN_STEAL:-0}"
# Log-only: how far the hypervisor balloon must REVERSE before its last extreme
# is logged as a peak or trough (see balloon_turn); smaller moves are jitter.
BALLOON_STEP_MB="${CGGOV_BALLOON_STEP_MB:-512}"
case "$BALLOON_STEP_MB" in '' | *[!0-9]*) BALLOON_STEP_MB=512 ;; esac
# The balloon-aware pool ceiling (see ceiling_target). Base and floor are
# memory-policy.nix's numbers, handed over by the unit in GiB; without both the
# feature is off, which is what local runs and the test suite get.
POOL_HIGH_BASE_MB=""
POOL_HIGH_FLOOR_MB=""
case "${KX_POLICY_POOL_HIGH_G:-}" in
  '' | *[!0-9]*) ;; *) POOL_HIGH_BASE_MB=$(( 10#$KX_POLICY_POOL_HIGH_G * 1024 )) ;;
esac
case "${KX_POLICY_POOL_HIGH_FLOOR_G:-}" in
  '' | *[!0-9]*) ;; *) POOL_HIGH_FLOOR_MB=$(( 10#$KX_POLICY_POOL_HIGH_FLOOR_G * 1024 )) ;;
esac
CEILING_DWELL="${CGGOV_CEILING_DWELL:-60}"
case "$CEILING_DWELL" in '' | *[!0-9]*) CEILING_DWELL=60 ;; esac
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
pool_blind=0                 # pool memory.pressure unreadable: warn once, not every tick
reclaim_pid=""               # in-flight backgrounded reclaim, if any
prev_refault=""              # agents slice counters at the previous tick, for
prev_steal=""                #   duty A's refault ratio ("" = not yet sampled)
last_thrash_log=0            # SKIPPED-THRASH rate limiter (never last_reclaim)
bal_ext=""                   # balloon zigzag: running extreme MiB ("" = no reading yet)
bal_dir=""                   #   ...its direction (up|down|"" = not yet a full step)
bal_last_turn=""             #   ...the last logged turn ("peak 4470M"), for context
ceil_raise_since=""          # pool ceiling: when a raise started waiting out its dwell
ceil_pid=""                  # in-flight backgrounded memory.high lower, if any
CEIL_DRY_LAST=""             # DRYRUN: the last would-set logged, so it logs once
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

# The hypervisor balloon (vmw_balloon on this VM): RAM the HOST has taken back.
# free(1) counts it as used, yet no cgroup is charged for it, so every partition
# here (desktop floor, pool ceiling) silently assumes RAM the guest no longer
# has. Measured 2026-09-15: 4.5G ballooned since boot, the desktop stalled at
# 48% mem_full with the pool 10G under its ceiling, and nothing logged why.
# Logged, and since 2026-09-17 given back out of the pool's ceiling (see
# ceiling_target). `Balloon:` sits near the END of meminfo, so it is not
# folded into read_meminfo's three-line pass; still one builtin loop, no fork.
# No line (no balloon driver), no file, or a non-number -> BALLOON_MB="".
BALLOON_MB=""
read_balloon() {
  local k v
  BALLOON_MB=""
  while read -r k v _; do
    [ "$k" = "Balloon:" ] || continue
    case "$v" in '' | *[!0-9]*) ;; *) BALLOON_MB=$(( 10#$v / 1024 )) ;; esac
    break
  done 2>/dev/null < "${1:-/proc/meminfo}"
  return 0
}

# The balloon's TURNING POINTS, so the log shows its envelope rather than every
# move. On 2026-09-15 the host ran a ~5-minute sawtooth: inflate to a steady
# ~4.4G, then deflate ~3.5G inside a minute. Logging each move of a fixed step
# wrote ~100 lines an hour at 512M and would at any step below the swing. A
# zigzag instead: track the running extreme in the current direction, and only
# once the reading has come back a full step from it is that extreme a turn --
# ~2 lines a cycle, with sub-step jitter swallowed. Before any direction is
# known the extreme is just the first reading. An unknown reading changes
# nothing. BT_TURN_MB is the extreme being reported (BT_EXT has moved on).
balloon_turn() {  # ext_mb dir cur_mb step_mb -> BT_EXT BT_DIR BT_TURN(peak|trough|"") BT_TURN_MB
  local e c
  BT_EXT="$1"; BT_DIR="$2"; BT_TURN=""; BT_TURN_MB=""
  [ -n "$3" ] || return 0
  if [ -z "$1" ]; then BT_EXT="$3"; return 0; fi
  e=$(( 10#$1 )); c=$(( 10#$3 ))
  case "$2" in
    up)
      if [ "$c" -gt "$e" ]; then BT_EXT="$3"
      elif [ $(( e - c )) -ge "$4" ]; then BT_TURN=peak; BT_TURN_MB="$1"; BT_DIR=down; BT_EXT="$3"
      fi ;;
    down)
      if [ "$c" -lt "$e" ]; then BT_EXT="$3"
      elif [ $(( c - e )) -ge "$4" ]; then BT_TURN=trough; BT_TURN_MB="$1"; BT_DIR=up; BT_EXT="$3"
      fi ;;
    *)
      if [ $(( c - e )) -ge "$4" ]; then BT_DIR=up; BT_EXT="$3"
      elif [ $(( e - c )) -ge "$4" ]; then BT_DIR=down; BT_EXT="$3"
      fi ;;
  esac
  return 0
}

# THE BALLOON-AWARE POOL CEILING. memory-policy.nix partitions MemTotal --
# pool MemoryHigh + desktop floor + user-other + margin -- and a held balloon
# takes RAM out from under all four terms at once. On 2026-09-17 it sat at
# ~4.5G all morning: the partition ran that far over, free RAM fell to ~1G
# every minute or two, and the desktop stalled with its own pages untouched.
# Of the four terms only the pool is a CEILING the governor can move and only
# the pool can stand to shrink, so the balloon comes off it: the target is the
# configured ceiling less the balloon, rounded DOWN to whole steps (a sub-step
# balloon writes nothing), never below the policy floor, never above the
# configured ceiling. A cut costs builds, not the desktop: the semaphore
# controller reads memory.high live, so it tightens admission to match.
#
# The floor exists because the cut is not free. cgroups.nix records a 12G
# ceiling crawling builds under reclaim throttle (pre-memory.min, possibly
# stale), and the fleet alone runs 5-7G raw; past the floor the rest of the
# balloon is left to the margin. Unknown balloon -> the configured ceiling.
ceiling_target() {  # base_mb floor_mb balloon_mb step_mb -> CT_MB ("" = off)
  local b f s
  CT_MB=""
  case "$1" in '' | *[!0-9]*) return 0 ;; esac
  case "$2" in '' | *[!0-9]*) return 0 ;; esac
  b=$(( 10#$1 )); f=$(( 10#$2 ))
  CT_MB="$b"
  case "$3" in '' | *[!0-9]*) return 0 ;; esac
  [ "$f" -lt "$b" ] || return 0
  s=$(( ${4:-0} > 0 ? $4 : 1 ))
  CT_MB=$(( b - 10#$3 / s * s ))
  [ "$CT_MB" -ge "$f" ] || CT_MB="$f"
  return 0
}

# Moves the live ceiling toward the target, ASYMMETRICALLY. Inflation is when
# global reclaim bites, so a lower lands on the tick it is seen. A raise waits
# until the target has stayed higher for the whole dwell: on 2026-09-15 the
# balloon deflated ~3.5G inside a minute and re-inflated within five, and
# following that both ways would hand the pool gigabytes it must give straight
# back, under reclaim, on the next inflate. Stepped against the LIVE value, so
# a systemd reload that reasserts the configured MemoryHigh is just lowered
# again next tick. `max` (no ceiling at all) is above any target.
ceiling_step() {  # live_mb|max target_mb now raise_since dwell -> CS_SET CS_SINCE CS_WHY
  local l t
  CS_SET=""; CS_SINCE="$4"; CS_WHY=""
  if [ -z "$1" ] || [ -z "$2" ]; then CS_SINCE=""; return 0; fi
  t=$(( 10#$2 ))
  if [ "$1" = max ]; then l=$(( t + 1 )); else l=$(( 10#$1 )); fi
  if [ "$l" -gt "$t" ]; then
    CS_SET="$t"; CS_SINCE=""; CS_WHY=lower
  elif [ "$l" -eq "$t" ]; then
    CS_SINCE=""
  else
    CS_WHY="wait"
    if [ -z "$4" ]; then
      CS_SINCE="$3"
    else
      elapsed_since "$4" "$3"
      if [ "$ELAPSED" -ge "$5" ]; then CS_SET="$t"; CS_SINCE=""; CS_WHY=raise; fi
    fi
  fi
  return 0
}

# The pool's live memory.high in MiB, `max` when unset, "" when unreadable (the
# slice is gone while no pool unit runs -- nothing to set). One builtin read.
POOL_HIGH_MB=""
read_pool_high() {  # [file] -> POOL_HIGH_MB
  local v=""
  POOL_HIGH_MB=""
  read -r v 2>/dev/null < "${1:-$POOL/memory.high}"
  case "$v" in
    max) POOL_HIGH_MB=max ;;
    '' | *[!0-9]*) ;;
    *) POOL_HIGH_MB=$(( 10#$v / 1048576 )) ;;
  esac
  return 0
}

# A LOWER is backgrounded for the same reason reclaim_from is: the kernel
# reclaims the charge down to the new memory.high synchronously in the writer
# (memory_high_write), gigabytes of it on an inflate, and detection must never
# wait on actuation. The kernel publishes the new value before it starts
# reclaiming, so the next tick already reads the lowered ceiling and does not
# write again. A RAISE cannot reclaim, so it is written inline -- and first
# signals any lower still reclaiming, whose loop would otherwise keep driving
# the charge toward the ceiling just given back.
set_pool_high() {  # live_mb|max new_mb why
  local f="$POOL/memory.high" from="$1"
  [ "$from" = max ] || from="${from}M"
  if [ ! -e "$f" ]; then
    log "CEILING|SKIPPED - no memory.high at ${POOL#"$USERAT"/} ($3)"
    return 0
  fi
  if [ -n "$DRYRUN" ]; then
    [ "$CEIL_DRY_LAST" = "$1>$2" ] || log "DRYRUN|would set CEILING memory.high ${from} -> ${2}M ($3)"
    CEIL_DRY_LAST="$1>$2"
    return 0
  fi
  if [ "$1" != max ] && [ "$2" -ge "$1" ]; then
    if [ -n "$ceil_pid" ] && kill -0 "$ceil_pid" 2>/dev/null; then
      kill "$ceil_pid" 2>/dev/null
    fi
    log "CEILING|memory.high ${from} -> ${2}M ($3)"
    printf '%d' "$(( $2 * 1048576 ))" 2>/dev/null > "$f" \
      || log "CEILING|WRITE-REFUSED memory.high ${from} -> ${2}M ($3) - the ceiling stays where it was"
    return 0
  fi
  if [ -n "$ceil_pid" ] && kill -0 "$ceil_pid" 2>/dev/null; then
    log "CEILING|SKIPPED - previous lower still reclaiming (pid $ceil_pid)"
    return 0
  fi
  log "CEILING|memory.high ${from} -> ${2}M ($3)"
  {
    printf '%d' "$(( $2 * 1048576 ))" 2>/dev/null > "$f" \
      || log "CEILING|WRITE-REFUSED memory.high ${from} -> ${2}M ($3) - the ceiling stays where it was"
  } &
  ceil_pid=$!
  return 0
}

# On the way out, hand back the configured ceiling: a governor that is not
# running cannot raise it again when the balloon deflates.
restore_pool_high() {  # why
  [ -n "$POOL_HIGH_BASE_MB" ] || return 0
  read_pool_high
  if [ -n "$POOL_HIGH_MB" ] && [ "$POOL_HIGH_MB" != "$POOL_HIGH_BASE_MB" ]; then
    set_pool_high "$POOL_HIGH_MB" "$POOL_HIGH_BASE_MB" "restore: $1"
  fi
  return 0
}

# The agents slice's reclaim counters, for duty A's effectiveness gate. Read on
# EVERY tick, so the same fork-free shape as read_meminfo: the kernel lists
# workingset_refault_anon before pgsteal, so the loop stops at pgsteal instead
# of reading the ~30 lines after it. Anything not read cleanly -- missing file,
# absent key, non-numeric value, a future kernel reordering the keys -- is left
# EMPTY, which reclaim_useful reads as "reclaim is useful".
#
# pgsteal, not pgsteal_anon: the memcg file has no per-type steal counter
# (checked on 6.18; /proc/vmstat has one, the cgroup does not). File steals
# therefore dilute the ratio, and that dilution errs toward "useful" -- cache
# that is evicted and stays evicted is reclaim doing its job.
RC_REFAULT=""
RC_STEAL=""
read_reclaim_counters() {  # memory.stat path -> RC_REFAULT RC_STEAL
  local k v
  RC_REFAULT=""; RC_STEAL=""
  # Silence exactly as psi_full_avg10 does it: a builtin `[ -r ]` for the common
  # missing-slice case, and 2>/dev/null BEFORE the `<` (redirections apply left
  # to right) for a file that vanishes between the test and the open.
  [ -r "$1" ] || return 0
  while read -r k v _; do
    case "$k" in
      workingset_refault_anon) RC_REFAULT="$v" ;;
      pgsteal) RC_STEAL="$v"; break ;;
    esac
  done 2>/dev/null < "$1"
  case "$RC_REFAULT" in '' | *[!0-9]*) RC_REFAULT="" ;; esac
  case "$RC_STEAL" in '' | *[!0-9]*) RC_STEAL="" ;; esac
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
# THE CONTRACT WITH nohang.conf: every positive @BADNESS_ADJ_RE_CMDLINE pattern
# there appears VERBATIM here -- the kill set is a subset of the freeze set, so
# nothing is ever killed under pressure that the governor could not first have
# paused. Asserted by cgroup-governor.test.py, not kept in step by comment: the
# comment version had already drifted (nohang had bare `playwright`, this list
# only ms-playwright) when it was replaced on 2026-09-14.
# /bin/tsc rather than /tsc, because the short form also matches
# "/tsconfig.json", which appears in the arguments of plenty of processes that
# are not the compiler. /playwright/cli\.js is the `playwright test` runner's
# entry script, not bare `playwright`, which matches any argv naming it.
WORKER_RE='jest-worker|/jest|--headless|ms-playwright|/eslint|/heft|/bin/tsc|/esbuild|/vitest|/playwright/cli\.js'

# FREEZABLE BUT NOT KILLABLE -- matched IN ADDITION to WORKER_RE by
# sweep_transient, and never added to nohang.conf (the test asserts that too).
# Pausing these for a few seconds costs nothing; killing one costs real work.
#
#   * rush/pnpm INSTALL, anchored on the script path followed by an `install`
#     field -- never a bare substring, and not `install-autoinstaller`.
#     Measured 2026-09-14: the pnpm worker peaked at 2449 MB, its launcher at
#     685 MB and `rush install` at 238 MB, all over WORKER_MIN_MB. The note's
#     worktree-setup install ran ungated at 127% sys in the fleet. Killing one
#     leaves a half-written node_modules; freezing one briefly holds that
#     worktree's rush lock, which MAX_FREEZE_SECS bounds.
#   * playwright-cli's /entry/cliDaemon.js: an agent's OPEN browser session,
#     and the parent of the headless chromium WORKER_RE already freezes.
#     Killing it destroys the session; pausing it is just latency.
#
# Deliberately NOT here: http-server (the storybook servers). Measured at 51 MB
# RSS with most of it swapped -- under the migration floor, and a freeze
# pauses CPU and allocation, it does not reclaim, so freezing a swapped-out
# server frees nothing.
FREEZE_ONLY_RE='/(rush|pnpm) install( |$)|/entry/cliDaemon\.js'

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
        [[ "$cl" =~ $WORKER_RE ]] || [[ "$cl" =~ $FREEZE_ONLY_RE ]] || continue
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

# Duty A's EFFECTIVENESS verdict (see the duty's header note). Over the last
# tick, what share of the pages stolen from the agents slice came back as anon
# refaults? When most of them did, evicting more anon only feeds the loop.
# Not useful = steal cleared THRASH_MIN_STEAL AND refaults reached THRASH_PCT
# of it. EVERY other shape is useful -- a missing or non-numeric sample (first
# tick, no memory.stat), a counter that went backwards (slice recreated), zero
# steal, the gate switched off -- so a blind gate keeps the pre-gate behaviour.
# The deltas and ratio are left for the log whenever computable; REFAULT_PCT
# is "-" when not. 10# because a leading zero must never read as octal.
RECLAIM_USEFUL=1
REFAULT_DELTA=""
STEAL_DELTA=""
REFAULT_PCT="-"
reclaim_useful() {  # prev_refault prev_steal cur_refault cur_steal -> RECLAIM_USEFUL REFAULT_{DELTA,PCT} STEAL_DELTA
  local a
  RECLAIM_USEFUL=1; REFAULT_DELTA=""; STEAL_DELTA=""; REFAULT_PCT="-"
  for a in "$1" "$2" "$3" "$4"; do
    case "$a" in '' | *[!0-9]*) return 0 ;; esac
  done
  if [ "$3" -lt "$1" ] || [ "$4" -lt "$2" ]; then
    return 0
  fi
  REFAULT_DELTA=$(( 10#$3 - 10#$1 ))
  STEAL_DELTA=$(( 10#$4 - 10#$2 ))
  if [ "$STEAL_DELTA" -le 0 ]; then
    REFAULT_DELTA=""; STEAL_DELTA=""
    return 0
  fi
  REFAULT_PCT=$(( REFAULT_DELTA * 100 / STEAL_DELTA ))
  [ "$THRASH_PCT" -gt 0 ] 2>/dev/null || return 0
  [ "$STEAL_DELTA" -ge "$THRASH_MIN_STEAL" ] 2>/dev/null || return 0
  if [ $(( REFAULT_DELTA * 100 )) -ge $(( STEAL_DELTA * THRASH_PCT )) ]; then
    RECLAIM_USEFUL=0
  fi
  return 0
}

# Duty A's decision, for a TIGHT tick. Actions:
#   cooldown -- reclaimed inside RECLAIM_COOL; nothing to do.
#   reclaim  -- due, and reclaim_useful says so.
#   skip-log -- due, but it would feed thrash: log SKIPPED-THRASH.
#   skip     -- as skip-log, inside the log line's own cooldown (quiet).
# A SKIP NEVER ADVANCES last_reclaim. brake_step reads that same clock to
# choose between reclaim-arm and braking straight away, and the STALL path's
# reclaim is deliberately ungated -- a skipped duty A has to leave the
# emergency path exactly as it found it, or the gate reaches it through the
# shared clock.
DUTY_A_ACTION="cooldown"
duty_a_step() {  # last_reclaim last_thrash_log now useful -> DUTY_A_ACTION
  elapsed_since "$1" "$3"
  if [ "$ELAPSED" -lt "$RECLAIM_COOL" ]; then
    DUTY_A_ACTION="cooldown"
  elif [ "$4" = 1 ]; then
    DUTY_A_ACTION="reclaim"
  else
    elapsed_since "$2" "$3"
    if [ "$ELAPSED" -ge "$RECLAIM_COOL" ]; then
      DUTY_A_ACTION="skip-log"
    else
      DUTY_A_ACTION="skip"
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
on_exit() { thaw_all "governor exiting"; restore_pool_high "governor exiting"; log "STOP|governor stopped"; }
on_signal() { log "STOP|signal received, shutting down"; exit 0; }
trap on_exit EXIT
trap on_signal INT TERM

ceiling="off"
[ -n "$POOL_HIGH_BASE_MB" ] && [ -n "$POOL_HIGH_FLOOR_MB" ] \
  && ceiling="${POOL_HIGH_BASE_MB}M-balloon>=${POOL_HIGH_FLOOR_MB}M/raise-after-${CEILING_DWELL}s"
log "START|governor started (thresh=${STALL_THRESH}% pool_thresh=${POOL_THRESH}% low_free=${LOW_FREE_MB}M maxconc=${MAXCONC} heavy=${HEAVY_MB}M reclaim=${RECLAIM_MB}M/${RECLAIM_COOL}s thrash_gate=${THRASH_PCT}%@${THRASH_MIN_STEAL}pg(0%=log-only) ceiling=${ceiling} sweep_cool=${SWEEP_COOL}s freeze=${FREEZE_SECS}s max_freeze=${MAX_FREEZE_SECS}s rotate=${ROTATE_SECS}s lag_warn=${LAG_WARN}s dryrun=${DRYRUN:-off})"

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
    # Held time vs what this loop can actually deliver. A brake armed with
    # FREEZE_SECS below INTERVAL ALWAYS rounds up to the next tick (see the
    # note above) -- so a 3 s deadline releasing at 5-6 s is the design working,
    # not a fault, and saying only "deadline 3s" invited every reader to score
    # it as an overshoot. Anything beyond one whole tick past the deadline is a
    # different animal: the tick itself overran, the loop was blind for that
    # window (its own LAG line says so), and a live build scope stayed frozen
    # for it. Tag that case so it greps apart from the benign rounding instead
    # of hiding among it -- measured 2026-08-25: eight releases, six of them
    # ordinary rounding at 5-6 s and two genuine overruns at 15 s and 17 s.
    brake_held=$(( now - brake_until + FREEZE_SECS ))
    if [ "$brake_held" -gt "$(( FREEZE_SECS + INTERVAL ))" ]; then
      thaw_scope "$brake_scope" "OVERRUN brake held ${brake_held}s (deadline ${FREEZE_SECS}s, tick overran ${INTERVAL}s interval)"
    else
      thaw_scope "$brake_scope" "brake released after ${brake_held}s (deadline ${FREEZE_SECS}s, rounded up to one ${INTERVAL}s tick)"
    fi
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
  # The pool read is allowed to fail: systemd removes the slice's cgroup while
  # no worktree job is running, and an absent pool has nothing in it to brake,
  # so 0% is the right reading. Say it ONCE though -- until 2026-08-17 this
  # logged a shell redirect error every tick for as long as the pool was empty,
  # which is the "silence reads as calm" failure inverted: noise reading as
  # breakage. Not a blind-and-skip like the desktop: there is genuinely nothing
  # to measure, so the tick proceeds on the desktop signal alone.
  if psi_full_avg10 "$POOL/memory.pressure"; then
    if [ "$pool_blind" = 1 ]; then
      log "POOL|memory.pressure readable again - pool pressure back in the tick"
      pool_blind=0
    fi
  elif [ "$pool_blind" = 0 ]; then
    log "POOL|no readable memory.pressure at $POOL - treating pool as idle (empty slice?)"
    pool_blind=1
  fi
  pm="$PSI_TEXT"; pm_c="$PSI_CENTI"
  read_meminfo; free_mb="$MEMFREE_MB"; avail="$MEMAVAIL_MB"
  # The hypervisor balloon: its turning points as a timeline, a field on STATE/STALL.
  read_balloon
  balloon="${BALLOON_MB:+${BALLOON_MB}M}"; balloon="${balloon:-?}"
  if [ -z "$bal_ext" ] && [ -n "$BALLOON_MB" ]; then
    log "BALLOON|${BALLOON_MB}M held by the hypervisor (first reading, avail=${avail}M)"
  fi
  balloon_turn "$bal_ext" "$bal_dir" "$BALLOON_MB" "$BALLOON_STEP_MB"
  bal_ext="$BT_EXT"; bal_dir="$BT_DIR"
  if [ -n "$BT_TURN" ]; then
    log "BALLOON|${BT_TURN} ${BT_TURN_MB}M held by the hypervisor (${bal_last_turn:+after ${bal_last_turn}, }now ${BALLOON_MB}M, avail=${avail}M)"
    bal_last_turn="${BT_TURN} ${BT_TURN_MB}M"
  fi
  # ...and given back out of the pool's ceiling (semantics on ceiling_target
  # and ceiling_step, above the seam).
  ceiling_target "$POOL_HIGH_BASE_MB" "$POOL_HIGH_FLOOR_MB" "$BALLOON_MB" "$BALLOON_STEP_MB"
  if [ -n "$CT_MB" ]; then
    read_pool_high
    ceiling_step "$POOL_HIGH_MB" "$CT_MB" "$now" "$ceil_raise_since" "$CEILING_DWELL"
    ceil_raise_since="$CS_SINCE"
    case "$CS_WHY" in
      lower) set_pool_high "$POOL_HIGH_MB" "$CS_SET" "lower: balloon=${balloon} floor=${POOL_HIGH_FLOOR_MB}M" ;;
      raise) set_pool_high "$POOL_HIGH_MB" "$CS_SET" "raise: balloon=${balloon} held lower ${CEILING_DWELL}s" ;;
    esac
  fi
  # Duty A's refault ratio, sampled EVERY tick whatever the state, so the ratio
  # a TIGHT tick acts on spans one interval -- the first tick of an episode
  # included. One builtin read loop. `gate` rides on both RECLAIM call sites.
  read_reclaim_counters "$FLEET/memory.stat"
  reclaim_useful "$prev_refault" "$prev_steal" "$RC_REFAULT" "$RC_STEAL"
  prev_refault="$RC_REFAULT"; prev_steal="$RC_STEAL"
  if [ "$REFAULT_PCT" = "-" ]; then
    gate="ratio=-"
  else
    gate="ratio=${REFAULT_PCT}% refault=${REFAULT_DELTA} steal=${STEAL_DELTA}"
  fi

  # --- 1. Classify. The semantics (and the 07-29 pool-clause history) live on
  # classify_state, above the test seam. ---
  classify_state "$dm_c" "$pm_c" "$free_mb"
  state="$CLASSIFY_STATE"
  [ "$state" != "$last_state" ] && \
    log "STATE|$last_state -> $state (desktop_mem_full_avg10=${dm}% pool_mem_full_avg10=${pm}% free=${free_mb}M avail=${avail}M balloon=${balloon})"
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

      # Duty A: cheapest lever first -- push the fleet's cold pages to zram. No
      # pause, no throttle -- unless the refault ratio says the pages it would
      # evict are not cold (duty_a_step, above the seam).
      duty_a_step "$last_reclaim" "$last_thrash_log" "$now" "$RECLAIM_USEFUL"
      case "$DUTY_A_ACTION" in
        reclaim)
          reclaim_from "$FLEET" "$RECLAIM_MB" "TIGHT free=${free_mb}M $gate"
          last_reclaim=$now
          ;;
        skip-log)
          log "RECLAIM|SKIPPED-THRASH refault=${REFAULT_DELTA} steal=${STEAL_DELTA} (${REFAULT_PCT}%, thrash>=${THRASH_PCT}%) - evicted fleet anon is coming straight back"
          last_thrash_log=$now
          ;;
      esac

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
      log "STALL|desktop mem_full_avg10=${dm}% pool=${pm}% free=${free_mb}M avail=${avail}M balloon=${balloon}"
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
          # Ungated on purpose (see duty A's header note); logs the ratio anyway.
          reclaim_from "$FLEET" "$(( RECLAIM_MB * 2 ))" "STALL mem_psi=${dm}% $gate"
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
