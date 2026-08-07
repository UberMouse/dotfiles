# claude-agents-reattach -- re-home the Claude background-agent fleet into the
# worktrees-agents.slice cgroup after it has drifted out of the pool.
#
# WHY IT DRIFTS. `claude agents` does not run the agent workers itself: it talks
# to a long-lived per-user daemon (cc-daemon-<uid> -- `claude ... daemon run
# --origin transient`, re-parented to PID 1) that forks every bg-pty-host /
# bg-spare / live-agent worker. A cgroup is inherited at fork from the PARENT's
# current cgroup, so the fleet's placement is decided ENTIRELY by where that
# daemon was first spawned. If the daemon was born outside the pool -- a bare
# `claude agents` / `claude -p` from an ordinary tmux shell, before the
# claude-agents wrapper ever ran -- the whole fleet lives in that shell's
# tmux-spawn scope and escapes the 4G worktrees-agents.slice budget. Forensics
# have caught exactly this: the escaped fleet as the single largest memory
# consumer on the box during a stall. The claude-agents wrapper only cgroups the
# throwaway TUI, never the daemon, so a wrapped relaunch does NOT rescue an
# already-misplaced daemon -- hence this repair tool.
#
# WHAT IT DOES. Finds the cc-daemon (and any stray monorepo-jobs build daemons)
# and MIGRATES its whole process subtree into a leaf cgroup under
# worktrees-agents.slice by writing cgroup.procs directly (the same
# read/write-the-cgroup-files-directly approach wt-cgroup-status and the
# nixos.nix memory.min bootstrap already use). The migration is live and
# non-destructive: nothing is killed or restarted, so the running agents -- and
# this very session, when it is itself one of them -- keep going while the budget
# is restored. Because the DAEMON itself moves too, every worker it forks from
# now on inherits the slice, so this fixes future spawns as well as the current
# set. Idempotent: a pid already in the target leaf is skipped, so it is safe to
# re-run any time the fleet drifts.
#
# Gate on the pool UNIT being loaded, never on its cgroup directory existing:
# systemd only materializes a slice's cgroup while it holds active units, so a
# -d test on the dir deadlocks once the fleet is idle. Same guard claude-agents.sh
# and .claude/hooks/worktree-setup.sh use.

uid="$(id -u)"

if ! kx-pool-loaded; then
  echo "worktrees.slice is not loaded on this host; nothing to reattach into." >&2
  exit 0
fi

# Bring the child slice active so its cgroup dir exists even when no agent TUI is
# currently running (the daemon outlives the TUI, so a repair may run TUI-less).
systemctl --user start worktrees-agents.slice 2>/dev/null || true

base="${KX_POOL:-/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/worktrees.slice}/worktrees-agents.slice"
if [ ! -d "$base" ]; then
  echo "worktrees-agents.slice cgroup did not materialize; cannot reattach." >&2
  exit 1
fi

# Make sure memory/pids are delegated to leaves so the fleet is actually
# accounted against the slice cap. systemd already enables these whenever the
# slice holds a child scope (MemoryAccounting=true), but belt-and-suspenders for
# a freshly-activated, child-less slice.
if ! grep -qw memory "$base/cgroup.subtree_control" 2>/dev/null; then
  echo "+memory +pids" > "$base/cgroup.subtree_control" 2>/dev/null || true
fi

# cgroup v2 forbids processes in an inner node that has child cgroups, and the
# slice already holds the TUI's run-*.scope, so the fleet must live in its own
# leaf. Stable name -> re-runs reuse it instead of proliferating leaves.
leaf="$base/fleet"
mkdir -p "$leaf"

# Roots to sweep: the cc-daemon, plus stray monorepo-jobs build daemons (which
# also inherit whatever cgroup they were forked in). Both are re-parented to PID
# 1, so we cannot find them by walking down from the TUI -- match argv fields
# exactly via kx-proc-find, never `pgrep -f`: a false-positive root here drags
# its WHOLE process subtree into the fleet cgroup, and -f matches any process
# whose joined cmdline merely contains the string (including this script's own
# probe -- see kx-proc-find's header).
roots=()
while read -r p; do [ -n "$p" ] && roots+=("$p"); done < <(kx-proc-find daemon run --origin 2>/dev/null)
while read -r p; do [ -n "$p" ] && roots+=("$p"); done < <(kx-proc-find '*monorepo-jobs*' --daemon-run 2>/dev/null)

if [ "${#roots[@]}" -eq 0 ]; then
  echo "No cc-daemon or build daemon running; nothing to reattach."
  exit 0
fi

# Expand each root to its whole subtree (cgroup.procs migration moves ONE process
# at a time, never descendants, so every worker must be listed explicitly).
declare -A kids
while read -r pid ppid; do kids[$ppid]+=" $pid"; done < <(ps -eo pid= -o ppid=)
queue=("${roots[@]}")
allpids=()
while [ "${#queue[@]}" -gt 0 ]; do
  pid="${queue[0]}"; queue=("${queue[@]:1}")
  allpids+=("$pid")
  read -ra children <<< "${kids[$pid]:-}"
  for c in "${children[@]}"; do queue+=("$c"); done
done
mapfile -t pids < <(printf '%s\n' "${allpids[@]}" | sort -n -u)

moved=0; already=0; gone=0
for p in "${pids[@]}"; do
  cur="$(cat "/proc/$p/cgroup" 2>/dev/null)" || { gone=$((gone + 1)); continue; }
  case "$cur" in
    */worktrees-agents.slice/fleet) already=$((already + 1)); continue ;;
  esac
  if printf '%s\n' "$p" > "$leaf/cgroup.procs" 2>/dev/null; then
    moved=$((moved + 1))
  elif [ -d "/proc/$p" ]; then
    echo "  warn: could not migrate pid $p ($cur)" >&2
  else
    gone=$((gone + 1))
  fi
done

echo "reattached fleet -> worktrees-agents.slice/fleet: ${moved} moved, ${already} already in slice, ${gone} exited mid-sweep"
mem="$(numfmt --to=iec < "$base/memory.current" 2>/dev/null)"
cap="$(numfmt --to=iec < "$base/memory.high" 2>/dev/null)"
echo "worktrees-agents.slice now: mem ${mem:-?} / ${cap:-?} high-cap, $(cat "$base/pids.current" 2>/dev/null || echo '?') tasks"
