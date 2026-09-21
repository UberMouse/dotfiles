# claude-agents -- launch the `claude agents` FleetView kept OUT of the
# worktrees pool (so the UI stays responsive under memory pressure) while
# pulling the fleet it drives INTO the pool (so the heavy work stays budgeted).
#
# The UI and the per-user cc-daemon are lightweight coordinators; the weight is
# in what the daemon forks -- bg-spare / bg-pty-host workers, live agents, their
# MCP servers, agent-spawned monorepo-jobs build daemons. So we run the UI in the
# ordinary user session (uncapped) and, once the daemon exists, hand it to
# claude-agents-reattach, which re-homes the daemon + its whole worker subtree
# into worktrees-agents.slice (governed by the pool's MemoryHigh -- the number
# lives in memory-policy.nix, never here). Because a cgroup
# is inherited at fork, every worker the now-in-pool daemon forks from then on
# lands in the pool automatically -- so this single launch-time reattach is
# enough, with no continuous sweeper. See claude-agents-reattach.sh for the full
# reasoning on why the "UI out / workers in" split cannot simply be inherited.
#
# That one-shot design puts the whole weight of the mechanism on reattaching
# the RIGHT daemon at the right moment, which is subtler than it looks: a
# cc-daemon outlives its TUI, so "a daemon is running" can be true because of
# YESTERDAY's session. Firing on that reading reattaches an already-correct
# daemon and exits before this TUI forks its own -- see the waiter below for
# the incident and the two-step identification that replaced it.
#
# The reattach runs DETACHED (the UI starts immediately) and only when the pool
# is actually installed on this host; everywhere else this is just `claude
# agents`.

# systemd-run/exec need an absolute executable, so resolve `claude` (prepended
# via runtimeInputs) to its store path rather than passing a bare name.
claude="$(command -v claude)"

# The pid the TUI will eventually run as. Both launch paths below (`exec
# systemd-run --scope` and the bare `exec claude` fallback) replace THIS shell
# in place, so $$ is already that pid -- and it is the pid claude-code stamps
# into its daemon's `--spawned-by {...,"pid":N}` argv field, which is what lets
# the waiter tell this TUI's daemon from someone else's. Captured out here
# rather than inside the subshell: a subshell's $$ is still the parent's today,
# but that is a shell-portability detail to depend on by accident.
tui_pid="$$"

# kx-pool-loaded: the shared unit-loaded guard (never a -d on the cgroup
# dir, which vanishes while the pool is idle -- see that bin's header).
if kx-pool-loaded \
   && command -v claude-agents-reattach >/dev/null 2>&1; then
  # Detached: wait (bounded, ~60s) for THIS UI's cc-daemon to come up, then
  # pull it into the pool. Runs out-of-pool itself; it only writes cgroup files.
  #
  # Both terminal outcomes go to the state log (same location + line format as
  # build-semaphore.log; see kx-build-slot.sh's slotlog). They used to be
  # silent: the 60s wait expiring looked identical to success, and the
  # reattach's entire output -- including its "warn: could not migrate pid"
  # lines -- went to /dev/null. stdout stays untouched so the interactive TUI
  # launch is not polluted; the log is the only witness.
  log_dir="$HOME/.local/state/cgroup-pressure"
  agentlog() {
    mkdir -p "$log_dir" 2>/dev/null || true
    printf '%s  CLAUDE-AGENTS|%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" \
      >> "$log_dir/claude-agents.log" 2>/dev/null || true
  }

  # Every cc-daemon that already exists, snapshotted BEFORE the TUI launches.
  # A daemon outlives the TUI that spawned it, so "is a daemon running" is a
  # question about yesterday as much as today -- see the waiter for why that
  # distinction is the whole bug.
  daemons_before=" $(kx-proc-find daemon run --origin 2>/dev/null | tr '\n' ' ') "

  # Log the reattach's outcome and its whole output, one line per line.
  reattach_and_log() {
    local out rc
    out="$(claude-agents-reattach 2>&1)"; rc=$?
    agentlog "REATTACH rc=$rc $1"
    while IFS= read -r line; do
      [ -n "$line" ] && agentlog "  $line"
    done <<< "$out"
  }

  (
    n=0
    while [ "$n" -lt 120 ]; do
      # WAIT FOR *THIS* TUI'S DAEMON, NOT FOR ANY DAEMON. A cc-daemon outlives
      # the TUI that spawned it, so on a box where yesterday's fleet is still up
      # the old "is a daemon running" test was satisfied INSTANTLY: the reattach
      # fired against the already-in-pool old daemon, reported "0 moved, N
      # already in slice", rc=0 -- and exited one second BEFORE this TUI forked
      # its own daemon. That daemon then inherited claude-ui.slice, and so did
      # every bg-spare, rg and typecheck it went on to fork. Measured
      # 2026-09-22: 71 escaped processes, load 73 on 16 cores, claude-ui at 55%
      # cpu.pressure and pinned against its 2G MemoryHigh, while the pool's
      # 12-core cap governed almost nothing. The log line for that failure is
      # character-for-character a success.
      #
      # Two ways to recognise the right daemon, in order:
      #   1. EXACT -- claude-code stamps the spawning TUI's pid into the
      #      daemon's `--spawned-by {...,"pid":N}` argv field. kx-proc-find
      #      globs per argv FIELD, so that JSON needs no parsing: one more
      #      pattern on the same call.
      #   2. FALLBACK -- a daemon that was not in daemons_before. Covers a
      #      release dropping or reshaping --spawned-by, and is the only reason
      #      the snapshot is taken at all.
      # kx-proc-find, not `pgrep -f`: -f matches the joined cmdline of every
      # process, so it matches its own invocation and any shell holding the
      # string (see CLAUDE.md and kx-proc-find's header).
      target="$(kx-proc-find daemon run --origin "*\"pid\":${tui_pid}[,}]*" 2>/dev/null | head -1)"
      if [ -z "$target" ]; then
        while read -r p; do
          [ -n "$p" ] || continue
          case "$daemons_before" in *" $p "*) continue ;; esac
          target="$p"
          break
        done < <(kx-proc-find daemon run --origin 2>/dev/null)
      fi
      if [ -n "$target" ]; then
        reattach_and_log "after $((n / 2))s daemon-wait (daemon $target)"
        exit 0
      fi
      sleep 0.5
      n=$((n + 1))
    done
    # The wait expired with no daemon that is demonstrably OURS. Three ways to
    # get here: this UI attached to a daemon that was already running (normal --
    # and that daemon may itself be misplaced), it genuinely never spawned one,
    # or claude-code reshaped the argv matched above. Reattach ANYWAY. The
    # repair is idempotent and on an already-correct fleet costs one process
    # scan, whereas the old behaviour -- log the suspicion, fix nothing -- is
    # what let a misplaced daemon run unbudgeted for as long as the session
    # lasted. Log the installed version so an argv drift is attributable to the
    # release that shipped it.
    ver="$("$claude" --version 2>/dev/null)" || ver=""
    ver="${ver%% *}"
    agentlog "DAEMON-WAIT expired: no daemon carrying \"pid\":$tui_pid, and none new since launch (claude-code ${ver:-unknown}); reattaching unconditionally -- if agents are running, the daemon argv signature may have drifted, see claude-agents-reattach.sh"
    reattach_and_log "after 60s daemon-wait timeout"
  ) &
fi

# Run the TUI in claude-ui.slice, which carries CPUWeight=5000 + memory.min so
# it actually OUTRANKS the fleet for CPU rather than merely escaping the pool's
# memory cap. Exemption is not priority: measured 2026-07-31, this TUI stalled on
# cpu.pressure full avg10 6% with memory and io pressure both flat 0.00, because
# a bare tmux-spawn scope gives cpu.weight=100 -- par with the whole build pool.
# See the slice definition in cgroups.nix for the full reasoning.
#
# --scope (not --service) is required: it runs the command in the CALLER's
# context, inheriting the terminal, so the TUI keeps its tty. A --service would
# be detached from the pty and useless here. --collect reaps the transient unit
# on exit so repeated launches do not leave failed scope units behind.
#
# Gate on the slice UNIT being loaded, same as the pool guard above -- on a host
# without this config the fallback is a plain unwrapped launch.
if [ "$(systemctl --user show claude-ui.slice -p LoadState --value 2>/dev/null)" = "loaded" ] \
   && command -v systemd-run >/dev/null 2>&1; then
  exec systemd-run --user --quiet --collect --scope --slice=claude-ui.slice \
       -- "$claude" agents "$@"
fi

exec "$claude" agents "$@"
