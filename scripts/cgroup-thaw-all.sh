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
# Both freeze-target shapes are touched: mj-<name>.scope and the `transient`
# leaves (the pair kx_freeze_targets defines). The agents `fleet` is never
# frozen by design, so it is never thawed here either -- if it is somehow
# frozen, that came from something else and silently undoing it would hide a
# real problem.
set -u

# The freeze-target shapes come from cgroup-lib.sh (kx_freeze_targets),
# SHARED with the governor's list_build_scopes, so this sweep can never
# drift from what the governor actually freezes -- a shape a hand-copied
# glob pair here missed would stay frozen FOREVER after a SIGKILL, the one
# failure this script exists to prevent. Both installed copies pin CGLIB to
# the lib's store path (the governor unit via Environment=, the on-PATH
# command via the prefix scriptBins/default.nix prepends); the sibling-path
# fallback serves manual runs from a checkout and the test suite.
#
# No inline glob fallback: it existed for a "cannot source" case neither
# installed copy can reach, and a stale copy IS the documented disaster --
# a shape it lacks stays frozen forever while the run reports success. If
# the lib is genuinely unsourceable, say exactly what to do by hand.
# shellcheck disable=SC1090  # path is env-supplied (CGLIB) in production
if ! . "${CGLIB:-$(dirname "$0")/cgroup-lib.sh}" 2>/dev/null; then
  echo "cgroup-thaw-all: FATAL cannot source cgroup-lib.sh (CGLIB='${CGLIB:-}')" >&2
  echo "cgroup-thaw-all: recover by hand: printf 0 > <scope>/cgroup.freeze for each frozen mj-*.scope / transient leaf under worktrees.slice" >&2
  exit 1
fi

uid="$(id -u)"
# KX_POOL override exists for the test suite (scripts/cgroup-thaw-all.test.py),
# same convention as the controller's KX_SEM_POOL.
pool="${KX_POOL:-/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/worktrees.slice}"
[ -d "$pool" ] || { echo "worktrees.slice pool not materialized; nothing to thaw."; exit 0; }

shopt -s nullglob
thawed=0
checked=0
failed=0
for slice in "$pool"/worktrees-*.slice; do
  # Both freeze targets: the monorepo-jobs build daemons, and the `transient`
  # leaves the governor migrates agent-spawned test/browser workers into. The
  # agents slice contributes only its transient leaf -- `fleet` is never frozen,
  # so it is deliberately not swept here either. The shape pair lives in
  # kx_freeze_targets (cgroup-lib.sh), the governor's own definition.
  kx_freeze_targets "$slice"
  for scope in "${FREEZE_TARGETS[@]}"; do
    [ -e "$scope/cgroup.freeze" ] || continue
    checked=$((checked + 1))
    if [ "$(cat "$scope/cgroup.freeze" 2>/dev/null)" = "1" ]; then
      name="$(basename "$scope")"
      if printf '0' > "$scope/cgroup.freeze" 2>/dev/null; then
        echo "thawed ${name//\\x2d/-}"
        thawed=$((thawed + 1))
      else
        # This is the thaw of LAST RESORT (ExecStopPost after even SIGKILL),
        # so a failure here means a build may be permanently frozen. It must
        # be loud: report it, and exit non-zero so systemd records the unit
        # result in the journal instead of a clean success.
        echo "cgroup-thaw-all: FAILED to thaw ${name//\\x2d/-} - scope may be stuck frozen" >&2
        failed=$((failed + 1))
      fi
    fi
  done
done

echo "cgroup-thaw-all: ${thawed} thawed, ${failed} FAILED, of ${checked} build scope(s) checked"
[ "$failed" -eq 0 ] || exit 1
