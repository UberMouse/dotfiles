# kx-build-slot -- take a slot from the machine-global build semaphore, run a
# command while holding it, and release it on exit.
#
#   kx-build-slot [--label NAME] [--timeout SECS]
#                 [--resident-probe CMD] [--resident] -- COMMAND [ARGS...]
#
# The semaphore is published by build-semaphore-controller.py (see that file for
# why admission control is the lever and why the loop is asymmetric). This is
# the client half: the thing every heavy job wraps itself in.
#
# WHY flock ON FILES rather than a daemon with leases. The callers here are
# build workers that genuinely get OOM-killed and frozen -- that is the entire
# problem being solved. A lease protocol would need expiry, heartbeats and a
# reaper to survive a caller dying mid-hold. flock gets all of that from the
# kernel: the lock is attached to the open file description, so it is released
# on process death no matter HOW the process died. Nothing can leak a slot.
#
# The second reason is reach. The jobs that need gating live in another repo and
# several languages -- a heft plugin, two Node shard runners, a nix shell wrapper
# -- and `flock` on a known path is implementable in about three lines of any of
# them. There is no protocol to reimplement and no version to keep in step.
#
# THREE FAIL-OPEN PATHS, all deliberate. A build that runs unthrottled is a
# nuisance; a build that never runs is a broken machine. So:
#
#   1. No semaphore directory (controller not running, or a machine that never
#      had one -- CI, a colleague's checkout) -> exec the command immediately.
#      This is what lets the kawaka side of this land unconditionally: on any
#      host without the controller it is exactly a no-op.
#   2. Already holding a slot ($KX_BUILD_SLOT_HELD set) -> exec immediately.
#      Without this, a gated job that spawns another gated job would wait on a
#      slot its own ancestor is holding, and at the floor of 1 that is a
#      guaranteed deadlock rather than a rare one.
#   3. Timed out waiting -> run anyway, and log it. A slot is a scheduling hint,
#      not a permission.
#
# Slots are scanned from the BOTTOM. The controller holds them back from the
# TOP. That is the whole coordination protocol -- the two never contend for the
# same file, so neither needs to know the other exists.
#
# RESIDENCY (--resident-probe). Some gated commands do not own their own cost:
# they spawn something DETACHED that outlives them and keeps the memory. A
# `playwright-cli open` is the motivating case -- it forks a daemon that is
# reparented to init and holds a chromium (~350 MB of server + browser +
# renderers) until someone closes the session. Gating only the launch means the
# slot is returned while the memory stays, so the semaphore counts a burst that
# has ended and misses a tenant that has not.
#
# --resident-probe CMD closes that gap. CMD is a single executable (invoked
# directly, never through a shell) that lists pids one per line, and is run
# twice: once BEFORE the command and once AFTER. Anything that appears in the
# second list and not the first was spawned by this job, and the slot is HELD
# until every such pid is gone.
#
# The hold is done by FORKING a keeper subshell, never by exec. flock lives on
# the open file description, and fork SHARES the description rather than
# reopening it -- so the keeper inherits the lock already held, with no window
# in which the slot is released and must be re-acquired. At the floor that race
# would matter: a waiting typecheck would take the slot and the browser would go
# unaccounted for the rest of its life. Exec would not do: node spawns its
# daemon with stdio ["ignore","pipe",err] and closes everything else, so the fd
# cannot be passed down to the daemon itself.
#
# --resident says this job WILL leave something resident, and gates it on the
# controller's load test rather than merely on a slot being free. Residents are
# admitted like builds -- on free bytes and PSI -- instead of on the floor slot
# that exists to keep BUILDS moving. Without it the accounting is honest and the
# admission is not: the browser is counted, and still got in on a stalling box.
#
# The keeper drops a marker in $SEM_DIR/resident/ naming itself, because the
# controller has to tell a slot held by a BUILD from one held by a BROWSER: it
# raises its floor by the latter so residents can never squeeze admission to
# zero. The marker is a hint, not a lease -- the lock is still what reserves the
# slot, and a keeper killed with SIGKILL leaves a stale marker that the
# controller prunes by checking the named pid. Nothing depends on it surviving.
#
# The fail-open paths do NOT start a keeper: with no semaphore, or on a timeout,
# there is no slot to hold, and the job was not gated in the first place.

label=""
timeout_s="${KX_BUILD_SLOT_TIMEOUT:-600}"
resident_probe=""
resident_mode=""

# need_value: a flag passed as the LAST argument must be a hard error, not a
# hang. `shift 2` with only one argument left is refused by bash, `$#` never
# decreases, and the parse loop spins forever -- `kx-build-slot --timeout`
# used to hang silently before doing any work.
need_value() {
  if [ "$#" -lt 2 ]; then
    echo "kx-build-slot: $1 needs a value" >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --label) need_value "$@"; label="$2"; shift 2 ;;
    --label=*) label="${1#--label=}"; shift ;;
    --timeout) need_value "$@"; timeout_s="$2"; shift 2 ;;
    --timeout=*) timeout_s="${1#--timeout=}"; shift ;;
    --resident-probe) need_value "$@"; resident_probe="$2"; shift 2 ;;
    --resident-probe=*) resident_probe="${1#--resident-probe=}"; shift ;;
    --resident) resident_mode=1; shift ;;
    --) shift; break ;;
    -h|--help)
      # Pure bash on purpose: --help has to work under the most restricted
      # PATH of any caller (the same design rule probe_pids documents), and
      # this was the script's only awk dependency.
      #
      # ANCHORED on the header's own first line, the way the awk extractors
      # elsewhere anchor (`/^# wt-cgroup-status /{f=1}`): the INSTALLED
      # artifact is a writeShellApplication wrapper whose shebang,
      # `set -o nounset` and PATH export sit ABOVE this header, so printing
      # from line 1 dumped that preamble as mangled help (verified live
      # 2026-08-07).
      in_header=""
      while IFS= read -r hline; do
        if [ -z "$in_header" ]; then
          case "$hline" in
            '# kx-build-slot'*) in_header=1 ;;
            *) continue ;;
          esac
        fi
        case "$hline" in
          '# '*) printf '%s\n' "${hline#'# '}" ;;
          '#'*) printf '%s\n' "${hline#'#'}" ;;
          *) break ;;
        esac
      done < "$0"
      exit 0 ;;
    *) break ;;
  esac
done

if [ "$#" -eq 0 ]; then
  echo "kx-build-slot: no command given (use -- COMMAND ARGS)" >&2
  exit 2
fi

# Validate BEFORE any waiting starts. `[ "$waited" -ge "$timeout_s" ]` with a
# non-numeric operand exits 2, which reads as FALSE in an `if` -- so a garbage
# timeout would not error, it would disable fail-open 3 and wait forever. The
# script's own header says a build that never runs is a broken machine; a
# typo'd flag must not be able to produce one.
case "$timeout_s" in
  '' | *[!0-9]*)
    echo "kx-build-slot: --timeout wants whole seconds, got '${timeout_s}'" >&2
    exit 2 ;;
esac

SEM_DIR="${KX_BUILD_SEM_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/kx-build-sem}"
LOG_DIR="$HOME/.local/state/cgroup-pressure"
LOG="$LOG_DIR/build-semaphore.log"
[ -n "$label" ] || label="$(basename "${1:-job}")"

slotlog() {
  # Only ever called on the slow paths (waited, timed out), so this costs
  # nothing in the common case of a slot being free immediately.
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s  BUILDSEM|%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >> "$LOG" 2>/dev/null || true
}

# Fail-open 1 and 2: nothing to coordinate with, or we already hold a slot.
if [ ! -d "$SEM_DIR" ] || [ -n "${KX_BUILD_SLOT_HELD:-}" ]; then
  exec "$@"
fi

# Fail-open 1b: the directory exists but holds no slot files yet. This is the
# controller's startup window, and without this check the scan below would find
# nothing to lock and spin all the way to the timeout before giving up -- a
# 600 s stall on every job unlucky enough to start during a service restart.
# An empty semaphore is indistinguishable from no semaphore, so treat it as one.
# Plain glob rather than `compgen -G`. NIXPKGS BUILDS BASH WITHOUT PROGRAMMABLE
# COMPLETION, so `compgen` does not exist as a builtin on this system at all --
# `type -a compgen` reports "not found" and `shopt progcomp` reports "invalid
# shell option name". The call therefore exited 127, `! 127` evaluated TRUE, and
# every single job took the fail-open path: a semaphore that silently gated
# nothing. Caught on first deploy 2026-08-03, and worth remembering repo-wide --
# any script here reaching for compgen is broken the same way, silently.
#
# This is the same SHAPE of bug that made the governor's duties B and C dead
# code for three days in July (a test that could never be true quietly disabling
# the actuator, while the log kept reporting healthy). A literal glob depends on
# nothing and cannot fail this way.
_have_slot=0
for _slot in "$SEM_DIR"/slot.*; do
  if [ -e "$_slot" ]; then _have_slot=1; break; fi
done
if [ "$_have_slot" = 0 ]; then
  exec "$@"
fi

export KX_BUILD_SLOT_HELD=1

sem_healthy() {
  # Field 8 ("healthy") of the published state: whether the controller's load
  # test passes AND the resident cap has room. The authoritative field order is
  # the FIELDS tuple next to publish() in scripts/build-semaphore-controller.py;
  # the fast test suite asserts this index against it. FAIL-OPEN on anything
  # unexpected -- a missing file, a short line from an older controller
  # mid-deploy, a non-numeric field -- because the alternative is a browser that
  # never launches on a machine whose semaphore is merely misconfigured. Only an
  # explicit "0" blocks.
  #
  # STALENESS (added 2026-08-07): the controller re-publishes this file every
  # tick, changed or not, precisely so its mtime is a liveness signal (the
  # heartbeat comment sits by the publish call in main()'s loop). A file older
  # than KX_SEM_STALE_AFTER seconds -- default 15, three 5 s control intervals
  # -- is a dead controller's last words, and waiting up to 600 s on a stale
  # healthy=0 is waiting on nobody. Fail OPEN instead, like every other
  # unexpected state here. The env override exists for the test suite, which
  # ages the file with utime rather than sleeping through the threshold.
  local f now mtime
  mtime=$(stat -c %Y "$SEM_DIR/allowed" 2>/dev/null) || return 0
  now=$(date +%s)
  if [ $((now - mtime)) -gt "${KX_SEM_STALE_AFTER:-15}" ]; then
    return 0
  fi
  f=$(cut -d' ' -f8 "$SEM_DIR/allowed" 2>/dev/null) || return 0
  [ "$f" = "0" ] && return 1
  return 0
}

probe_pids() {
  # STRICT: only lines that are ENTIRELY digits count. A probe that prints a
  # diagnostic, a header, or a path containing digits must not be able to
  # fabricate a pid -- a fabricated pid is one that never dies, and a keeper
  # waiting on it holds a slot forever. Filtering rather than sanitising is the
  # point: `tr -cd 0-9` would turn "error: no such file" into a plausible pid.
  #
  # Filtered in bash, not `grep -E`: grep was never in this script's
  # runtimeInputs, so under a restricted PATH the pipeline died inside
  # `|| true` and every probe read as empty -- no keeper, browser unaccounted,
  # nothing logged. A shell pattern depends on nothing and cannot fail that way
  # (same shape as the compgen bug above).
  [ -n "$resident_probe" ] || return 0
  local line
  while IFS= read -r line; do
    case "$line" in
      '' | *[!0-9]*) ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < <("$resident_probe" 2>/dev/null || true)
}

resident_new=""

run_child() {
  # The lock lives on this shell's fd, so the command runs as a CHILD rather
  # than via exec -- the parent must stay alive to keep holding it. Signals are
  # forwarded so the wrapper is transparent to Ctrl-C and to systemd stopping a
  # build scope.
  before_pids="$(probe_pids | tr '\n' ' ')"
  "$@" &
  child=$!
  trap 'kill -TERM "$child" 2>/dev/null || true' TERM INT
  wait "$child"
  rc=$?
  trap - TERM INT

  # Anything present now but absent before was spawned by this job. Comparing
  # against a snapshot rather than trusting the probe to self-filter is what
  # makes the common case exact: daemons that were already up appear in BOTH
  # lists and are ignored, so a job never claims a browser it did not open.
  #
  # The exception is a daemon that appears DURING this window, from a job
  # running alongside -- it is absent from the snapshot and so gets claimed
  # here, and two keepers then hold slots for one browser. Bounded and
  # self-correcting (both release when that daemon dies), and it errs toward
  # holding one slot too many, which throttles rather than overcommits. Not
  # worth a handshake to prevent: capacity has to be down at several before two
  # `open`s can overlap at all, and at the floor they are strictly serialised.
  # Deliberately NOT conditioned on rc. A launch that fails partway can still
  # have left a daemon running, and the invariant being defended is "a live
  # browser holds a slot", not "a successful command holds a slot" -- an
  # unaccounted browser after a failed open is exactly the hole this closes.
  # The diff only ever claims pids that the probe currently sees, so a failure
  # path cannot invent one.
  resident_new=""
  if [ -n "$resident_probe" ]; then
    after_pids="$(probe_pids | tr '\n' ' ')"
    # A probe that sees NOTHING at all after the command ran is the signature
    # of a broken probe (the daemon path moved in an upgrade), and it is
    # otherwise indistinguishable from a genuine no-spawn: no keeper forks, no
    # slot is held, and the log stays silent while browsers escape accounting.
    # Log it so a silent zero can be told apart after the fact.
    case "$after_pids" in
      *[0-9]*) ;;
      *) slotlog "RESIDENT-PROBE-EMPTY $label probe saw no daemons at all" ;;
    esac
    for p in $after_pids; do
      case " $before_pids " in
        *" $p "*) ;;
        *) resident_new="$resident_new $p" ;;
      esac
    done
  fi
  return "$rc"
}

start_keeper() {
  # $1 = slot path; $2... = pids to outlive.
  #
  # FORKED, NEVER EXEC'D. The subshell inherits this shell's open file
  # description for the slot, and with it the flock already held -- see the
  # RESIDENCY note in the header for why the re-acquire race that exec would
  # introduce is not acceptable at the floor.
  keeper_slot="$1"; shift
  keeper_pids="$*"
  mkdir -p "$SEM_DIR/resident" 2>/dev/null \
    || slotlog "RESIDENT-MARKER-FAILED cannot mkdir $SEM_DIR/resident - controller will count this slot as a build"
  (
    marker="$SEM_DIR/resident/$(basename "$keeper_slot")"
    # BASHPID, not $$: inside a subshell $$ is still the PARENT's pid, which
    # exits moments from now. The controller prunes markers whose keeper is
    # dead, so naming the parent here would make every marker look stale and
    # the floor would never rise at all.
    #
    # MARKER FORMAT: exactly `keeper=<pid>`. The parser is
    # Semaphore.resident() in scripts/build-semaphore-controller.py -- it is
    # the contract; anything added here that it does not read is drift waiting
    # to happen (label= and daemons= fields once lived here, written by this
    # line and read by nothing).
    # The marker is a hint for SLOT RESERVATION, but capacity math depends on
    # it: an unwritten marker means the controller counts this browser as a
    # build, the resident floor never rises, and the self-feeding open door
    # (twelve browsers onto a saturated pool, 2026-08-07) is back. Every
    # other path here got a breadcrumb in the silent-failure sweep; this one
    # must not be the exception.
    printf 'keeper=%s\n' "$BASHPID" > "$marker" 2>/dev/null \
      || slotlog "RESIDENT-MARKER-FAILED $marker unwritable - floor will not rise for this slot"
    trap 'rm -f "$marker" 2>/dev/null || true; exit 0' TERM INT
    while :; do
      alive=0
      for p in $keeper_pids; do
        if kill -0 "$p" 2>/dev/null; then alive=1; break; fi
      done
      [ "$alive" = 1 ] || break
      # Injectable so the test suite can poll at 0.2s instead of padding
      # every keeper-death assertion with multi-second sleeps. Production
      # never sets it.
      sleep "${KX_KEEPER_POLL:-5}"
    done
    rm -f "$marker" 2>/dev/null || true
    # Falling off the end closes the fd, which releases the slot. Nothing else
    # needs to happen, and nothing can leak it if this process is killed.
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

jitter_sleep() {
  # 0.2-0.5s. Jitter matters: without it a burst of jobs that arrived together
  # stays in lockstep and they all retry on the same tick forever, which is the
  # thundering herd this whole service exists to prevent. (String-built on
  # purpose; the range must stay single-digit tenths.)
  sleep "0.$(((RANDOM % 4) + 2))"
}

start=$(date +%s)
waited=0

while :; do
  # A RESIDENT JOB MAY NOT TAKE THE PROGRESS-FLOOR SLOT. The floor guarantees a
  # free slot whenever no BUILD is running, so that a floored semaphore still
  # makes progress. That slot is free by construction, regardless of memory --
  # which means a browser could take it, become resident, raise the floor by one
  # and open the next one, indefinitely. Measured 2026-08-07 on a synthetic pool
  # at 15.5G of 16G with psi10=40%: twelve admitted in a row, `allowed` pinned at
  # 1 the entire time. The ratchet fed itself and pressure never entered it.
  #
  # Waiting on the load test binds residents to the same evidence as builds --
  # free bytes and PSI -- rather than to a separate number that would have to be
  # kept in step with job_bytes. It also cannot reintroduce the deadlock: this
  # only ever makes a resident job WAIT, and builds are what the floor slot is
  # being kept for.
  if [ -n "$resident_mode" ] && ! sem_healthy; then
    # An explicit flag, not `[ "$waited" = 0 ]`: the poll is sub-second, so
    # `waited` stays 0 for the first few passes and the same line lands three
    # times before the clock ticks over.
    if [ -z "${resident_wait_logged:-}" ]; then
      resident_wait_logged=1
      slotlog "RESIDENT-WAIT $label load test shut, not taking the floor slot"
    fi
    now=$(date +%s)
    waited=$((now - start))
    if [ "$waited" -ge "$timeout_s" ]; then
      slotlog "TIMEOUT $label waited ${waited}s unhealthy, running UNGATED"
      exec "$@"
    fi
    jitter_sleep
    continue
  fi

  for slot in "$SEM_DIR"/slot.*; do
    [ -e "$slot" ] || continue
    exec {fd}>"$slot" || continue
    if flock -n "$fd"; then
      [ "$waited" -gt 0 ] && slotlog "ACQUIRED $label after ${waited}s ($(basename "$slot"))"
      run_child "$@"
      rc=$?
      if [ -n "$resident_new" ]; then
        # Unquoted on purpose: start_keeper takes ONE ARGUMENT PER PID, so the
        # list has to split. Quoting it happens to survive today -- `$*` rejoins
        # the single argument and the keeper's `for` splits it again -- but that
        # is a coincidence of the current implementation, not the interface, and
        # the next person to touch either end should not have to rediscover it.
        # shellcheck disable=SC2086
        start_keeper "$slot" $resident_new
        slotlog "RESIDENT $label keeps $(basename "$slot") for pid(s)$resident_new"
      fi
      # Closing our copy does NOT release the lock when a keeper was forked --
      # the keeper holds the same open file description and the kernel only
      # drops the flock when the LAST reference to it closes.
      exec {fd}>&-
      exit "$rc"
    fi
    exec {fd}>&-
  done

  now=$(date +%s)
  waited=$((now - start))
  if [ "$waited" -ge "$timeout_s" ]; then
    # Fail-open 3.
    slotlog "TIMEOUT $label waited ${waited}s, running UNGATED"
    exec "$@"
  fi

  jitter_sleep
done
