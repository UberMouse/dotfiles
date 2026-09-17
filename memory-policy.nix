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
  poolHighG = 15;
  poolMaxG = 17;
  # THE BALLOON FLOOR. Every term in this file is sized against the whole of
  # MemTotal, but this is a VMware guest and the host's balloon driver takes RAM
  # back from under all of them at once -- deliberately: the VM's reservation is
  # set low so the host has RAM for other work. On 2026-09-17 the balloon held
  # ~4.5G all morning, the partition ran that far over, and the desktop stalled
  # with its own pages untouched. So cgroup-governor gives the balloon back out
  # of the pool's memory.high at runtime (lower at once, raise after a dwell;
  # MemoryMax is left alone) -- and never below this. The floor is what keeps
  # the cut from becoming a build crawl: cgroups.nix records 12G ceilings
  # throttling builds (pre-memory.min, possibly stale) and the agents fleet
  # alone runs 5-7G raw. Past it, the rest of the balloon lands on the margin.
  # Chosen by taylorl 2026-09-17 over 11G and no floor; re-judge it from
  # `CGGOV|CEILING|` lines against build throughput, not by re-copying it.
  poolHighFloorG = 12;
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
  # slab, page tables, page cache working set, and zram's own PHYSICAL
  # footprint (swap here is zram-only under load: /dev/dm-0 stayed at 0B
  # through every stall).
  #
  # ZRAM IS COUNTED COMPRESSED. The earlier note here read "zram0 held
  # 0.7-4.9G, so those compressed pages are resident RAM" off the USED column
  # of `swapon --show` -- which is the UNCOMPRESSED size, not the RAM cost.
  # The physical figure is `mem_used`, field 3 of /sys/block/zram0/mm_stat.
  # Measured 2026-09-04: 3.71G uncompressed against 1.29G physical, a 2.9x
  # ratio, so the old reading overstated zram's claim on this margin by ~3x.
  # The cgroup-pressure snapshots capture only `swapon --show` and never
  # mm_stat, so every analysis written from them inherits the same error --
  # see docs/notes/2026-09-04-desktop-memory-stalls.md.
  #
  # SIZED, 2026-09-04, and the sizing turns on the same cache correction this
  # tree applies everywhere else. What the margin must cover is measurable
  # directly -- resident memory outside every budgeted cgroup tree:
  #
  #   MemTotal - MemFree - user.slice - system.slice - init.scope
  #
  # Read RAW that came to p50 4.25G / p90 4.58G / max 4.76G against a 3G
  # budget, which would have forced poolHighG down two whole gigabytes. But
  # ~1.2G of it is KReclaimable -- the dentry/inode slab this workload
  # accumulates walking ~80 worktrees -- and the kernel drops that unasked,
  # exactly like page cache. Counting it as a hard cost is the SAME misreading
  # corrected on the pool side by cgroup-mem.py and on the fleet side by
  # d17dc8b, and getting it wrong here costs a gigabyte of build ceiling.
  # NET of KReclaimable, 61 samples at 15s with user.slice spanning 16.0-21.9G
  # (the loaded regime, which is the one that matters): p50 3.10, p90 3.43,
  # p95 3.49, MAX 3.62.
  #
  # So 4G, and the reason it is not 3G is that this term has NOTHING BEHIND
  # IT. userOtherG above may be sized to ~p90 because excursions past it land
  # on this margin; the margin is the last line, so it is sized to cover the
  # measured MAXIMUM rather than the p90 -- 3G was exceeded in 67% of those
  # samples, 4G in none of them. The cost is one gigabyte of poolHighG and
  # ZERO build slots: KX_SEM_CEIL is (poolHighG - 3) * 2 / 3, which is 8 at
  # both 16 and 15. poolMaxG follows it down to keep the throttle band 2G
  # wide, as designed.
  #
  # RE-MEASURE, do not re-copy, if the workload changes: the whole term is
  #   MemTotal - MemFree - KReclaimable - user.slice - system.slice - init.scope
  # read from /proc/meminfo and the three cgroup memory.current files.
  marginG = 4;
  # MemTotal as the box actually reports it (29.19 GiB → floor to be safe).
  # If the VM's RAM allocation changes, update this and re-check the margin.
  memTotalG = 29;
  # THE CONTROL PLANE's memory guarantee, in MiB rather than GiB because that is
  # the honest size of it: the governor is a bash loop measured at 2.5M resident
  # (5.5M peak) and the semaphore controller a Python loop at 2.8M (18M peak).
  #
  # It is carved from the MARGIN above, deliberately, and so does NOT appear in
  # the GiB partition assertion below: 64M is ~2% of that 3G and the margin's
  # whole job is to cover what no cgroup budget names. Adding a fifth GiB-scale
  # term for it would force poolHighG down a whole gigabyte to keep the
  # assertion balanced -- a build-capacity cut two orders of magnitude larger
  # than the need.
  #
  # WHY IT EXISTS. `memory.min` is only effective if the WHOLE ancestor chain
  # grants it, and user@1000.service claimed 0 -- so the governor and the
  # semaphore controller, which run under it in app.slice, had no protection at
  # all while holding MemoryHigh=256M self-caps that only ever bounded them from
  # above. Their pages were swapped to zram under exactly the pressure they
  # exist to relieve: measured 2026-08-25, 117 governor LAG events of which 87%
  # fell within 120s of a desktop stall, three of them today at 15s, 17s and 48s
  # against a 5s tick -- the watchdog blind in the window it was built to watch.
  #
  # This is added ON TOP of desktopMinG at user.slice/user-<uid>.slice (see
  # userSliceMin below) rather than shared with it, so the desktop's 8G floor is
  # not diluted to pay for it; the cost lands on the margin, where it belongs.
  controlPlaneM = 64;
in
assert
  poolHighG + desktopMinG + userOtherG + marginG <= memTotalG
  || throw "memory-policy: pool MemoryHigh + desktop MemoryMin + user-other + margin must fit under MemTotal";
assert
  poolMaxG > poolHighG
  || throw "memory-policy: MemoryMax must exceed MemoryHigh or there is no throttle band";
assert
  poolHighFloorG > 0 && poolHighFloorG <= poolHighG
  || throw "memory-policy: the balloon floor must sit at or below the pool MemoryHigh it lowers";
# MemoryMax is the hard bound, so it must fit beside the desktop floor too --
# otherwise the pool is legally allowed to reach a size that starves the very
# guarantee the floor exists to provide, and the throttle band becomes a licence
# to overcommit rather than a brake.
#
# THIS ASSERTION IS DELIBERATELY NARROWER than the steady-state one above: it
# omits userOtherG and marginG. That is not an oversight -- it is the whole
# point of a throttle band. `memory.high` is not a hard stop, so the pool may
# briefly exceed it while being throttled; requiring `max` to fit the
# steady-state budget too (17+8+2+4 = 31 > 29) would forbid the band from ever
# being used and cost another gigabyte of ceiling to defend it. What must
# survive a transient excursion is the DESKTOP FLOOR, and that is exactly what
# this asserts. Checked 2026-09-04 against every archived stall snapshot:
# memory.events `max` and `oom` were 0 in all 265 of them -- the pool has never
# reached MemoryMax, because the memory.high throttle always engages first.
# Widen this only if that stops being true.
assert
  poolMaxG + desktopMinG <= memTotalG
  || throw "memory-policy: pool MemoryMax + desktop MemoryMin must fit under MemTotal";
{
  desktopMin = "${toString desktopMinG}G";
  # What user.slice and user-<uid>.slice must grant: the desktop floor PLUS the
  # control plane's reservation. The session scope still claims only desktopMin,
  # so this extra is what app.slice's watchdogs claim through user@<uid>.service
  # without taking a byte from the desktop's guarantee. Consumed by nixos.nix.
  userSliceMin = "${toString (desktopMinG * 1024 + controlPlaneM)}M";
  # The per-service floor for the governor and the semaphore controller, and the
  # matching claim for the two ancestors they sit under (user@<uid>.service and
  # its app.slice). One number, four sites: a floor granted at the leaf but not
  # at every ancestor is silently zero, which is the bug this whole term fixes.
  controlPlaneMin = "${toString controlPlaneM}M";
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
    poolHighFloorG
    poolMaxG
    userOtherG
    memTotalG
    controlPlaneM
    ;
}
