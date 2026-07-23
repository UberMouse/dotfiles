# claude-agents -- run `claude agents` inside the worktrees.slice cgroup
# pool so the background-agent fleet shares the same 12-core / 16 GiB budget
# as worktree builds. It lands in a dedicated leaf child slice
# (worktrees-agents.slice) that takes one equal-weight share of the pool and
# shows up as the "agents" bucket in wt-cgroup-status; every process the
# agent view dispatches inherits that cgroup. cgroup v2 forbids processes in
# an inner slice that has children, hence a child slice rather than the pool
# root. No-ops gracefully to a direct run if the pool unit isn't installed.
#
# Gate on the pool UNIT being loaded, never on its cgroup directory
# existing: systemd only materializes a slice's cgroup while it holds
# active units, so once the last worktree slice exits the directory
# vanishes and a -d test deadlocks (the pool can only activate when
# something is placed in it, but the test refuses to place anything until
# it is active) — silently dropping the whole fleet outside the budget.
# systemd-run auto-starts the parent slice chain, so placement is all the
# bootstrap that is needed. Same guard .claude/hooks/worktree-setup.sh uses.

# systemd-run needs an absolute executable, so resolve `claude` (prepended via
# runtimeInputs) to its store path rather than passing a bare name.
claude="$(command -v claude)"

if [ "$(systemctl --user show worktrees.slice -p LoadState --value 2>/dev/null)" = "loaded" ]; then
  exec systemd-run --user --scope --quiet --collect \
    --slice=worktrees-agents.slice \
    --description="claude agents (worktrees pool)" \
    -- "$claude" agents "$@"
fi

exec "$claude" agents "$@"
