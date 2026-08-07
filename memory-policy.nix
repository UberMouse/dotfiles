# THE MEMORY PARTITION, in one place. These numbers implement one invariant
# spread across two config trees:
#
#   pool MemoryHigh  <=  MemTotal - desktop MemoryMin - margin
#
# The desktop floor (memory.min, set in nixos.nix on the user.slice chain and
# reasserted by desktop-memory-protect) guarantees the graphical session's RAM
# so global reclaim lands on the pool; the pool ceiling (memory.high/max, set
# in cgroups.nix on worktrees.slice) must leave that floor plus real margin
# beneath MemTotal or the box runs out of RAM before the pool's own throttle
# can engage — measured 2026-07-17..21: a 20G ceiling on this box NEVER fired
# (memory.events high = 0 in every snapshot) because run-out came first.
#
# Before this file, the two halves lived in nixos.nix and home.nix connected
# only by prose comments, and changing one silently invalidated the margin
# arithmetic in the other. Change the numbers HERE; the history and reasoning
# stay with the option definitions that consume them.
let
  # GiB, as integers for the assertion arithmetic below.
  desktopMinG = 8;
  poolHighG = 18;
  poolMaxG = 20;
  # The margin is not decorative: the 2026-07-17..21 measurements showed a
  # ceiling that leaves <~2G under MemTotal never fires (run-out wins the
  # race), so a bare `<` assertion would admit exactly the configuration the
  # evidence condemned. 3G is what the current 18G ceiling holds on this box
  # (run-out ~21.2G); shrink it only with new memory.events data.
  marginG = 3;
  # MemTotal as the box actually reports it (29.19 GiB → floor to be safe).
  # If the VM's RAM allocation changes, update this and re-check the margin.
  memTotalG = 29;
in
assert
  poolHighG + desktopMinG + marginG <= memTotalG
  || throw "memory-policy: pool MemoryHigh + desktop MemoryMin + margin must fit under MemTotal";
assert
  poolMaxG > poolHighG
  || throw "memory-policy: MemoryMax must exceed MemoryHigh or there is no throttle band";
{
  desktopMin = "${toString desktopMinG}G";
  poolHigh = "${toString poolHighG}G";
  poolMax = "${toString poolMaxG}G";
  # Raw integers, for consumers that DERIVE from the policy instead of
  # restating it: cgroups.nix computes the semaphore's KX_SEM_CEIL from
  # poolHighG, and hands memTotalG to the governor to cross-check against
  # the machine's real /proc/meminfo at startup (the one number here that
  # is a hand-copied machine fact, so it gets a runtime verifier).
  inherit
    desktopMinG
    poolHighG
    poolMaxG
    memTotalG
    ;
}
