# THE MEMORY PARTITION, in one place. These numbers implement one invariant
# spread across two config trees:
#
#   pool MemoryHigh  <=  MemTotal - desktop MemoryMin - user-other - margin
#
# The desktop floor (memory.min, set in nixos.nix on the user.slice chain and
# reasserted by desktop-memory-protect) guarantees the graphical session's RAM
# so global reclaim lands on the pool; the pool ceiling (memory.high/max, set
# in cgroups.nix on worktrees.slice) must leave that floor plus real margin
# beneath MemTotal or the box runs out of RAM before the pool's own throttle
# can engage.
#
# Before this file, the two halves lived in nixos.nix and home.nix connected
# only by prose comments, and changing one silently invalidated the margin
# arithmetic in the other. Change the numbers HERE; the history and reasoning
# stay with the option definitions that consume them.
let
  # GiB, as integers for the assertion arithmetic below.
  desktopMinG = 8;
  poolHighG = 16;
  poolMaxG = 18;
  # Memory under user@1000.service that is NEITHER the pool NOR the desktop
  # session scope, and which therefore no pool cap bounds: app.slice,
  # claude.slice, and above all bare `tmux-spawn-*.scope` build work started by
  # hand outside the pool (claude-agents-reattach only re-homes the fleet at
  # launch). Omitting this term is what made the earlier arithmetic wrong: it
  # balanced at exact equality (18+8+3 = 29 <= 29) while this demand -- measured
  # at 1-5G across the eleven stall snapshots of 2026-08-18/19 -- had nowhere to
  # come from but the margin, which is a third of its peak. See
  # docs/notes/2026-08-18-desktop-memory-stalls.md; the single worst offender
  # was one uncapped `node eslint.js` at 2497MB.
  #
  # 4G was the opening bid, read off the 1-5G spread of the stall snapshots --
  # which sampled only the eleven worst moments of the day and so took bursts
  # for the baseline. 438 samples at 15s on 2026-08-19 put it at p50 1.8G,
  # p90 2.1G, p95 2.2G, p99 3.5G, max 4.6G. So 2G is the RESERVATION, sized to
  # the ~p90, not the peak: 23% of samples exceed it and 1.6% exceed 3G, and
  # those excursions are absorbed by the margin below. That is the division of
  # labour intended here -- this term carries the steady state, the margin
  # carries the spikes. Sizing this to p100 instead would price a 1-in-60
  # excursion into every minute of the day, which is what cost the pool 2G of
  # ceiling and pinned the build semaphore at allowed=1.
  userOtherG = 2;
  # The margin is not decorative: the 2026-07-17..21 measurements showed a
  # ceiling that leaves <~2G under MemTotal never fires (run-out wins the
  # race), so a bare `<` assertion would admit exactly the configuration the
  # evidence condemned. It covers what no cgroup accounts for at all -- kernel
  # slab, page cache working set, and zram's own PHYSICAL footprint (swap here
  # is zram-only under load: /dev/dm-0 stayed at 0B through every stall while
  # zram0 held 0.7-4.9G, so those compressed pages are resident RAM, not disk).
  marginG = 3;
  # MemTotal as the box actually reports it (29.19 GiB → floor to be safe).
  # If the VM's RAM allocation changes, update this and re-check the margin.
  memTotalG = 29;
in
assert
  poolHighG + desktopMinG + userOtherG + marginG <= memTotalG
  || throw "memory-policy: pool MemoryHigh + desktop MemoryMin + user-other + margin must fit under MemTotal";
assert
  poolMaxG > poolHighG
  || throw "memory-policy: MemoryMax must exceed MemoryHigh or there is no throttle band";
# MemoryMax is the hard bound, so it must fit beside the desktop floor too --
# otherwise the pool is legally allowed to reach a size that starves the very
# guarantee the floor exists to provide, and the throttle band becomes a licence
# to overcommit rather than a brake.
assert
  poolMaxG + desktopMinG <= memTotalG
  || throw "memory-policy: pool MemoryMax + desktop MemoryMin must fit under MemTotal";
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
    userOtherG
    memTotalG
    ;
}
