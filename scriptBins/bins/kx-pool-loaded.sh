# kx-pool-loaded -- exit 0 iff the worktrees.slice pool unit is loaded.
#
# THE guard for "does this host run the build pool", shared so the correct
# form cannot drift. It gates on the UNIT being loaded, never on the cgroup
# directory existing: systemd only materializes a slice's cgroup while it
# holds active units, so a `-d` test on the dir reads an idle pool as an
# absent one -- a guard that silently dies exactly when the fleet is quiet
# (the same shape as the compgen and dead-actuator bugs).
#
# Consumers: claude-agents, claude-agents-reattach, and (in the kawaka repo)
# .claude/hooks/worktree-setup.sh, which vendors the same one-liner because
# it cannot depend on this bin existing.
[ "$(systemctl --user show worktrees.slice -p LoadState --value 2>/dev/null)" = "loaded" ]
