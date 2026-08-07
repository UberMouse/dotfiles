#!/usr/bin/env bash
# cgroup-thaw-all -- unconditionally thaw every monorepo-jobs build scope in the
# worktrees pool.
#
# The governor guarantees thaw three ways from inside its own process (per-freeze
# deadline, EXIT trap, startup sweep), but none of those survive SIGKILL. This is
# the fourth: wired as ExecStopPost on cgroup-governor.service, so systemd runs it
# whenever the governor stops FOR ANY REASON -- clean stop, crash, OOM kill,
# `systemctl kill -s KILL`. A frozen build that is never thawed is a hung build
# and, unlike everything else this system does, it would not be self-correcting.
#
# Also safe and useful to run by hand if a build ever looks wedged:
#   cgroup-thaw-all
#
# Only mj-<name>.scope is touched. The agents fleet is never frozen by design, so
# it is never thawed here either -- if it is somehow frozen, that came from
# something else and silently undoing it would hide a real problem.
set -u

uid="$(id -u)"
# KX_POOL override exists for the test suite (scripts/cgroup-thaw-all.test.py),
# same convention as the controller's KX_SEM_POOL.
pool="${KX_POOL:-/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/worktrees.slice}"
[ -d "$pool" ] || { echo "worktrees.slice pool not materialized; nothing to thaw."; exit 0; }

shopt -s nullglob
thawed=0
checked=0
for slice in "$pool"/worktrees-*.slice; do
  # Both freeze targets: the monorepo-jobs build daemons, and the `transient`
  # leaves the governor migrates agent-spawned test/browser workers into. The
  # agents slice contributes only its transient leaf -- `fleet` is never frozen,
  # so it is deliberately not swept here either.
  for scope in "$slice"/mj-*.scope "$slice"/transient; do
    [ -e "$scope/cgroup.freeze" ] || continue
    checked=$((checked + 1))
    if [ "$(cat "$scope/cgroup.freeze" 2>/dev/null)" = "1" ]; then
      if printf '0' > "$scope/cgroup.freeze" 2>/dev/null; then
        name="$(basename "$scope")"
        echo "thawed ${name//\\x2d/-}"
        thawed=$((thawed + 1))
      fi
    fi
  done
done

echo "cgroup-thaw-all: ${thawed} thawed of ${checked} build scope(s) checked"
