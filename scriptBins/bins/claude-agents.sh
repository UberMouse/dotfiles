# claude-agents -- launch the `claude agents` FleetView kept OUT of the
# worktrees pool (so the UI stays responsive under memory pressure) while
# pulling the fleet it drives INTO the pool (so the heavy work stays budgeted).
#
# The UI and the per-user cc-daemon are lightweight coordinators; the weight is
# in what the daemon forks -- bg-spare / bg-pty-host workers, live agents, their
# MCP servers, agent-spawned monorepo-jobs build daemons. So we run the UI in the
# ordinary user session (uncapped) and, once the daemon exists, hand it to
# claude-agents-reattach, which re-homes the daemon + its whole worker subtree
# into worktrees-agents.slice (governed by the pool's 16G high). Because a cgroup
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

if [ "$(systemctl --user show worktrees.slice -p LoadState --value 2>/dev/null)" = "loaded" ] \
   && command -v claude-agents-reattach >/dev/null 2>&1; then
  # Detached: wait (bounded, ~60s) for the cc-daemon to come up -- whether this
  # UI spawns it or attaches to one already running -- then pull it into the
  # pool. Runs out-of-pool itself; it only writes cgroup files.
  (
    n=0
    while [ "$n" -lt 120 ]; do
      if pgrep -f 'daemon run --origin' >/dev/null 2>&1; then
        claude-agents-reattach >/dev/null 2>&1 || true
        break
      fi
      sleep 0.5
      n=$((n + 1))
    done
  ) &
fi

exec "$claude" agents "$@"
