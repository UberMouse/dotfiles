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
# The reattach runs DETACHED (the UI starts immediately) and only when the pool
# is actually installed on this host; everywhere else this is just `claude
# agents`.

# systemd-run/exec need an absolute executable, so resolve `claude` (prepended
# via runtimeInputs) to its store path rather than passing a bare name.
claude="$(command -v claude)"

# kx-pool-loaded: the shared unit-loaded guard (never a -d on the cgroup
# dir, which vanishes while the pool is idle -- see that bin's header).
if kx-pool-loaded \
   && command -v claude-agents-reattach >/dev/null 2>&1; then
  # Detached: wait (bounded, ~60s) for the cc-daemon to come up -- whether this
  # UI spawns it or attaches to one already running -- then pull it into the
  # pool. Runs out-of-pool itself; it only writes cgroup files.
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
  (
    n=0
    while [ "$n" -lt 120 ]; do
      # kx-proc-find, not `pgrep -f`: -f matches the joined cmdline of every
      # process, so it matches its own invocation and any shell holding the
      # string (see CLAUDE.md and kx-proc-find's header).
      if [ -n "$(kx-proc-find daemon run --origin 2>/dev/null)" ]; then
        out="$(claude-agents-reattach 2>&1)"; rc=$?
        agentlog "REATTACH rc=$rc after $((n / 2))s daemon-wait"
        while IFS= read -r line; do
          [ -n "$line" ] && agentlog "  $line"
        done <<< "$out"
        exit 0
      fi
      sleep 0.5
      n=$((n + 1))
    done
    # The wait expired with no daemon in sight. Either the UI genuinely never
    # spawned one, or claude-code renamed its daemon argv and the kx-proc-find
    # signature above now matches nothing -- which would make this whole
    # mechanism a silent no-op forever. Log the installed version so a drift
    # is attributable to the release that shipped it.
    ver="$("$claude" --version 2>/dev/null)" || ver=""
    ver="${ver%% *}"
    agentlog "DAEMON-WAIT expired: no 'daemon run --origin' argv seen in 60s (claude-code ${ver:-unknown}); the daemon argv signature may have drifted -- see claude-agents-reattach.sh"
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
