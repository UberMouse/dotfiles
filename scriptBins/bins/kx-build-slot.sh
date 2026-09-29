# kx-build-slot -- take a slot from the machine-global build semaphore, run a
# command while holding it, and release it on exit.
#
#   kx-build-slot [--label NAME] [--timeout SECS]
#                 [--resident-probe CMD | --resident-self] [--resident]
#                 -- COMMAND [ARGS...]
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
# --resident-self is residency for a command that does NOT return: a dev server
# or storybook that runs in the foreground for its whole life (monorepo-jobs'
# spawnProcess; a `heft start` held 3.3 GB outside all admission on 2026-09-14).
# There is nothing to diff, so there is no probe -- the WRAPPER is the keeper. It
# implies --resident (same admission: load test AND resident cap), writes the
# marker naming its own pid, runs the command as a child, and removes the marker
# once the child has exited. spawnProcess kills by process GROUP, so wrapper and
# server take a signal together, and a TERM still waits out the server's own
# exit before the slot goes back. A SIGKILLed wrapper leaves a marker naming a
# dead pid, which the controller prunes like any stale keeper's.
#
# THE HEARTBEAT. A queued server prints nothing, and its caller's port-discovery
# idle timer (180 s of silence, server-spawn.tsx) would SIGTERM the group long
# before the 600 s wait fails open. So in --resident-self mode a queued wrapper
# prints a line to stderr every KX_BUILD_SLOT_HEARTBEAT seconds (default 60). It
# lands in the server's own log, which is where "why is startup slow" is asked.
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
#
# QUEUE DEPTH (waiting/). Occupancy is observable from outside -- a held slot is
# a lock in /proc/locks -- but DEMAND is not: this client polls with `flock -n`
# and sleeps, so a job waiting for a slot touches nothing and appears nowhere.
# Ten jobs queued behind a cap of one and one job queued behind it are the same
# picture from every readout on the machine, which is exactly the number worth
# seeing when the bar says 1/1.
#
# So a waiting job announces itself: it opens $SEM_DIR/waiting/<pid> and holds
# an exclusive flock on it for as long as it is waiting. THE LOCK IS THE
# CONTRACT -- a marker that is flock'd is a live waiter, and an unlocked one is
# a dead job's litter that counts for nothing. Same reasoning as the slots
# themselves: the lock lives on the open file description, so the kernel drops
# it however the job died, and no reaper is needed for a number nobody would
# notice going stale.
#
# Taken LAZILY (only once a job has actually failed a pass) and dropped the
# instant it acquires a slot or fails open, so the common case -- a free slot on
# the first scan -- pays nothing, exactly like slotlog. The drop before
# run_child and before every `exec "$@"` is load-bearing rather than tidiness:
# fds survive both fork and exec, so a marker left open would be inherited by
# the very build it was counting the wait for, and the job would report itself
# as queued for its whole runtime.
#
# PRIORITY (waiting/<pid>.priority). There is no queue ORDER: every waiter polls
# with jitter and whichever looks first after a slot frees takes it. That is
# fine between builds and wrong for a dev server, which someone is sitting in
# front of -- behind a stream of short typechecks it can lose the race for its
# whole 600 s wait. So a --resident-self waiter names its marker
# `<pid>.priority`, and every OTHER job that finds a free slot while such a
# marker is live leaves it alone for that pass (YIELD in the log). The server
# takes it on its next poll, and the builds resume.
#
# What it deliberately does NOT change: the server still waits on the load test
# like any resident (a 3 GB server admitted onto a thrashing pool is the ratchet
# the RESIDENT GATE exists to stop), and builds only yield while that test
# PASSES -- yielding a slot the server is not allowed to take would just leave
# it idle. It reorders who gets a free slot; it never admits anything new.
#
# Live means LOCKED (the queue-depth contract) AND FRESH: a priority waiter
# touches its marker every pass, and a marker older than
# KX_SEM_PRIORITY_STALE_AFTER seconds (default 5) is ignored. The lock alone
# is not enough here, because a marker that stalls BUILDS has to be able to
# die of more than process death -- a server wrapper that is frozen (cgroup
# freezer) or stopped (^Z) keeps its lock and never takes the slot, and every
# build would sit in YIELD until its own timeout. Probing a marker with flock is
# safe for the reason sem_waiting in wt-cgroup-status.sh gives: it reserves
# nothing. Every failure here -- unreadable marker, garbage threshold -- reads
# as NO priority waiter, so the worst case is the old unordered race.

label=""
timeout_s="${KX_BUILD_SLOT_TIMEOUT:-600}"
resident_probe=""
resident_mode=""
resident_self=""
heartbeat_every="${KX_BUILD_SLOT_HEARTBEAT:-60}"
case "$heartbeat_every" in '' | *[!0-9]*) heartbeat_every=60 ;; esac

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
    --resident-self) resident_self=1; resident_mode=1; shift ;;
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

# Two different answers to "what is resident": a probe diffs what the command
# LEAVES BEHIND, self means the command IS the tenant. Together they would write
# two markers for one slot and double-raise the floor.
if [ -n "$resident_self" ] && [ -n "$resident_probe" ]; then
  echo "kx-build-slot: --resident-self and --resident-probe are exclusive" >&2
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

# Queue-depth markers (see QUEUE DEPTH in the header). Readers: the ⧗ field in
# scriptBins/bins/wt-cgroup-i3status.py and the SEM line in
# scriptBins/bins/wt-cgroup-status.sh.
WAIT_DIR="$SEM_DIR/waiting"
wait_fd=""
wait_marker=""

wait_marker_take() {
  # Idempotent: called once per poll pass, and a no-op while the marker is
  # already held. Every failure path here leaves the job WAITING NORMALLY and
  # merely uncounted -- this is a readout, and nothing about it may be able to
  # stall a build (the header's whole fail-open argument applies to accounting
  # code with even less room for doubt than to the gate itself).
  if [ -n "$wait_fd" ]; then
    # The PRIORITY heartbeat: builds ignore a priority marker that stops being
    # touched (see PRIORITY in the header). Every pass calls this, so this is
    # the one place that runs on every pass of every wait path.
    [ -z "$resident_self" ] || touch -c "$wait_marker" 2>/dev/null || true
    return 0
  fi
  if ! mkdir -p "$WAIT_DIR" 2>/dev/null; then
    if [ -z "${wait_marker_warned:-}" ]; then
      wait_marker_warned=1
      slotlog "WAIT-MARKER-FAILED cannot mkdir $WAIT_DIR - this job queues uncounted"
    fi
    return 0
  fi
  # Named for the pid, which is unique among LIVE processes -- the only ones
  # that can hold a lock. A marker left behind by a SIGKILL is reopened and
  # re-locked by whichever job next gets that pid, so the directory does not
  # grow without bound, and until then it sits there unlocked and uncounted.
  wait_marker="$WAIT_DIR/$$"
  # Readers count every locked file in the directory, so the suffix changes
  # nothing for them; only priority_waiting looks at it.
  [ -z "$resident_self" ] || wait_marker="$wait_marker.priority"
  # The 2>/dev/null lives on a BRACE GROUP, never on the exec itself. `exec`
  # with no command makes EVERY redirection on its line permanent for the
  # shell, so the old `exec {wait_fd}>"$wait_marker" 2>/dev/null` sent this
  # script's stderr to /dev/null for good -- and with it the stderr of every
  # job that had ever queued, build errors included, since the command
  # inherits it (found 2026-09-14 when the --resident-self heartbeat never
  # appeared). A group's redirection is undone when the group ends; the fd
  # allocated inside it is not.
  if ! { exec {wait_fd}>"$wait_marker"; } 2>/dev/null; then
    wait_fd=""
    return 0
  fi
  if ! flock -n "$wait_fd"; then
    # Only reachable against a reader probing a stale marker in the same
    # instant (wt-cgroup-status tests markers with `flock -n`, which is safe on
    # a marker precisely because a marker reserves nothing). Drop it and let the
    # next pass retry -- wait_fd stays empty, so this self-heals within one
    # poll interval.
    exec {wait_fd}>&-
    wait_fd=""
  fi
}

wait_marker_drop() {
  [ -n "$wait_fd" ] || return 0
  rm -f "$wait_marker" 2>/dev/null || true
  exec {wait_fd}>&-
  wait_fd=""
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

sem_over_cap() {
  # TRUE (0) when the published cap says no further BUILD may start.
  #
  # WHY THE CLIENT ENFORCES THE CAP AT ALL, when the controller already
  # withholds slots. Withholding is a RACE the controller loses. It can only
  # lock a slot in the instant between one job releasing and the next taking
  # it, and it retries once per 5 s control interval while waiting clients
  # retry every 0.2-0.5 s (jitter_sleep) -- roughly 14:1 against it on every
  # handoff. With a queue of short jobs the handoffs never stop, so it
  # reclaims almost nothing and `allowed` decays into advice.
  #
  # Measured 2026-08-17: memory pressure took allowed 8 -> 1 in seventeen
  # seconds, and `effective` then sat at 8 for ELEVEN MINUTES while 87
  # typechecks were admitted and the load average reached 48. It drained only
  # when the burst ended -- i.e. the clamp took hold exactly when it was no
  # longer needed. Reading the published decision here makes it binding no
  # matter who wins the race for the file.
  #
  # THE TEST IS `occupied >= allowed`, NOT `occupied - resident >= allowed`.
  # `allowed` caps TOTAL occupancy; decide() shifts the floor, soft floor and
  # ceiling by the live resident count precisely so that `allowed - resident`
  # keeps the meaning "how many BUILDS may run" (the RESIDENT TENANTS note in
  # build-semaphore-controller.py). Builds running is `occupied - resident`,
  # so the build test is `occupied - resident >= allowed - resident` and the
  # resident terms cancel. Subtracting `resident` from one side only would
  # spend the resident quota twice and grant an extra build per open browser.
  #
  # FAIL-OPEN on everything unexpected, exactly as sem_healthy does: a missing
  # file, a stale one (dead controller), a short line from an older controller
  # mid-deploy, or a non-numeric field must never be able to stall a build.
  # Only a well-formed, fresh, in-force cap blocks. Fields are 1 ("allowed")
  # and 4 ("occupied") of the FIELDS tuple; the state-format test asserts both
  # indices against the controller's own tuple.
  local now mtime a o
  mtime=$(stat -c %Y "$SEM_DIR/allowed" 2>/dev/null) || return 1
  now=$(date +%s)
  if [ $((now - mtime)) -gt "${KX_SEM_STALE_AFTER:-15}" ]; then
    return 1
  fi
  read -r a _ _ o _ < "$SEM_DIR/allowed" 2>/dev/null || return 1
  # Checked SEPARATELY, never as one concatenated string: "$a$o" with an empty
  # `o` still reads as all-digits and the arithmetic below would then error on
  # an empty operand under `set -u`.
  case "$a" in '' | *[!0-9]*) return 1 ;; esac
  case "$o" in '' | *[!0-9]*) return 1 ;; esac
  [ "$o" -ge "$a" ] && return 0
  return 1
}

priority_waiting() {
  # TRUE (0) when a live, fresh priority marker exists (PRIORITY in the
  # header). The glob matches nothing in the common case, so this costs no
  # fork until a dev server is actually queued.
  local f fd mtime now=""
  for f in "$WAIT_DIR"/*.priority; do
    [ -e "$f" ] || continue
    [ -n "$now" ] || now=$(date +%s)
    mtime=$(stat -c %Y "$f" 2>/dev/null) || continue
    # A garbage threshold makes the test error, which reads as stale: the
    # fail-open direction.
    [ $((now - mtime)) -le "${KX_SEM_PRIORITY_STALE_AFTER:-5}" ] 2>/dev/null \
      || continue
    # Opened READ-only: flock(2) does not need write access, and `>` would
    # truncate a marker this job does not own.
    { exec {fd}<"$f"; } 2>/dev/null || continue
    if flock -n "$fd"; then
      # Unlocked: a SIGKILLed waiter's litter. Released at once.
      exec {fd}<&-
      continue
    fi
    exec {fd}<&-
    return 0
  done
  return 1
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
  # A trapped signal makes `wait` return AT ONCE (rc > 128) while the child may
  # still be shutting down. A build's slot going back a moment early is
  # harmless; a SERVER's is not -- a dev server's SIGTERM grace can hold
  # gigabytes for seconds -- so --resident-self waits out the child's real exit
  # and reports its real status. (Builds keep the old shape, unchanged.)
  if [ -n "$resident_self" ] && kill -0 "$child" 2>/dev/null; then
    wait "$child"
    rc=$?
  fi
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

last_beat=""
heartbeat() {
  # $1 = why the job is waiting. --resident-self only (see THE HEARTBEAT in the
  # header): plain builds and browser launchers own their stderr, and a server
  # is the one caller that kills on silence. stderr, never the log -- the point
  # is to be OUTPUT the caller's idle timer sees.
  [ -n "$resident_self" ] || return 0
  local now
  now=$(date +%s)
  [ -n "$last_beat" ] || last_beat="$start"
  [ $((now - last_beat)) -ge "$heartbeat_every" ] || return 0
  last_beat="$now"
  printf 'kx-build-slot: %s waiting for a build slot (%ss, %s)\n' \
    "$label" "$((now - start))" "$1" >&2
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
    wait_marker_take
    heartbeat "load test shut"
    now=$(date +%s)
    waited=$((now - start))
    if [ "$waited" -ge "$timeout_s" ]; then
      slotlog "TIMEOUT $label waited ${waited}s unhealthy, running UNGATED"
      wait_marker_drop
      exec "$@"
    fi
    jitter_sleep
    continue
  fi

  # THE PUBLISHED CAP IS BINDING FOR BUILDS. Checked once per pass rather than
  # per slot: it is a property of the semaphore as a whole, not of any one
  # file, and one short read per 0.2-0.5 s poll costs nothing next to the work
  # being gated.
  #
  # RESIDENTS ARE EXEMPT, and that is not an oversight. A job about to become
  # resident is not yet counted in `resident`, so the bounds have not shifted
  # for it yet -- holding it to the BUILD cap would make browsers queue behind
  # builds whenever the cap is saturated, which is a throughput change well
  # beyond this fix. Residents are already gated, by the load test above and
  # by the resident cap folded into the same `healthy` bit; that is the
  # designed mechanism and it stays the only one.
  #
  # RESIDUAL RACE, stated rather than hidden: `occupied` is a published value
  # up to one control interval old, so a burst of clients can read the same
  # pre-admission count and overshoot the cap by up to that interval's worth
  # of starts. The flock still bounds them by `effective`, and the next
  # publish shuts the gate, so the overshoot is bounded and self-correcting
  # rather than the sustained 8-wide run this replaces. Making it exact needs
  # the controller to win its reclaim race (a blocking acquire on withheld
  # slots), which is a change to the controller, not to this client.
  if [ -z "$resident_mode" ] && sem_over_cap; then
    # An explicit flag for the same reason the resident wait uses one: the
    # poll is sub-second, so `waited` stays 0 for the first few passes and an
    # unguarded line would land three times before the clock ticks over.
    if [ -z "${cap_wait_logged:-}" ]; then
      cap_wait_logged=1
      slotlog "CAP-WAIT $label at published cap, waiting"
    fi
    wait_marker_take
    now=$(date +%s)
    waited=$((now - start))
    if [ "$waited" -ge "$timeout_s" ]; then
      slotlog "TIMEOUT $label waited ${waited}s at cap, running UNGATED"
      wait_marker_drop
      exec "$@"
    fi
    jitter_sleep
    continue
  fi

  # YIELD TO A WAITING DEV SERVER (PRIORITY in the header). After the cap, so a
  # capped build keeps logging CAP-WAIT, and gated on the load test, because a
  # server cannot take a slot while it is shut and yielding would idle one.
  # Browsers (--resident) yield too: they are agent-driven, not someone waiting.
  if [ -z "$resident_self" ] && sem_healthy && priority_waiting; then
    if [ -z "${yield_logged:-}" ]; then
      yield_logged=1
      slotlog "YIELD $label an interactive job is waiting, leaving it the free slot"
    fi
    wait_marker_take
    now=$(date +%s)
    waited=$((now - start))
    if [ "$waited" -ge "$timeout_s" ]; then
      slotlog "TIMEOUT $label waited ${waited}s yielding, running UNGATED"
      wait_marker_drop
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
      # Before run_child, not after: the child inherits every open fd, so a
      # marker still held here would count this job as queued for as long as
      # the build it is no longer queued for takes to run.
      wait_marker_drop
      # --resident-self: THIS process is the keeper, for exactly as long as the
      # command runs. $$ is right here (the main shell, not a subshell -- contrast
      # start_keeper's BASHPID), and the format is the one Semaphore.resident()
      # parses, so the controller needs no second reader.
      self_marker=""
      if [ -n "$resident_self" ]; then
        self_marker="$SEM_DIR/resident/$(basename "$slot")"
        if mkdir -p "$SEM_DIR/resident" 2>/dev/null \
           && printf 'keeper=%s\n' "$$" > "$self_marker" 2>/dev/null; then
          slotlog "RESIDENT-SELF $label holds $(basename "$slot") for its lifetime (keeper=$$)"
        else
          slotlog "RESIDENT-MARKER-FAILED $self_marker unwritable - controller will count this server as a build"
          self_marker=""
        fi
      fi
      run_child "$@"
      rc=$?
      [ -z "$self_marker" ] || rm -f "$self_marker" 2>/dev/null
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

  # Every slot was busy: this job is now genuinely queued, so say so.
  wait_marker_take
  heartbeat "all slots busy"
  now=$(date +%s)
  waited=$((now - start))
  if [ "$waited" -ge "$timeout_s" ]; then
    # Fail-open 3.
    slotlog "TIMEOUT $label waited ${waited}s, running UNGATED"
    wait_marker_drop
    exec "$@"
  fi

  jitter_sleep
done
