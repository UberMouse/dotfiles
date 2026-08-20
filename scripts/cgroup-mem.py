"""THE definition of how much of a cgroup's memory charge is actually IN USE.

Loaded BY PATH rather than imported by name (KX_CGROUP_MEM_LIB for the
controller, the @memlib@ substitution for the i3 bar), for exactly the reason
cgroup-lib.sh is sourced from a store path: the consumers are separate
derivations and each ships to the store as a lone file, so there is no sibling
to import and no site-packages to install into.

WHY THIS FILE EXISTS. `memory.current` counts PAGE CACHE. `free(1)` files that
same cache under `buff/cache`, NOT under `used`. So a pool sitting at 16G of a
16G `memory.high` beside a system reporting far less in use is not a
contradiction and not a bug in either number -- the two were never measuring
the same thing. Measured 2026-08-20: the pool's `memory.current` was 15.2G, of
which 7.36G was anon and 7.27G was reclaimable cache (5.6G of it
`inactive_file`, cold), accumulated by 66.6G of pool file IO. Three separate
consumers read that raw figure and all three drew the wrong conclusion from it:
the semaphore's memory gate published `healthy=0` and logged a steady
`HOLD free=0.2G<3.0G` while `memory.pressure` avg10 was 0.00%, the predictive
tighten read `build=91%` and walked `allowed` 5 -> 1, and the i3 bar rendered a
half-idle pool as full and RED.

This is the same misreading commit d17dc8b fixed for the FLEET term
(`read_untracked_mem` reads memory.stat, not memory.current). It survived on
the pool side because the argument that retired it there -- subtracting the
same bytes from both the usage and the ceiling cancels -- is true of the fleet
and FALSE of page cache: cache appears on the usage side only. `memory.high`
has no cache term to cancel against, so the correction does not vanish, it just
never got applied.

DENYLIST, NOT ALLOWLIST. Everything below names what the kernel CAN take back
without the holder's cooperation, and subtracts it. The alternative -- adding
up the keys we consider unreclaimable -- reads better but fails unsafely: a key
a future kernel introduces would go uncounted and the pool would read EMPTIER
than it is. Here an unfamiliar key stays counted as used, so the pool reads
FULLER than it is, the tighten fires early, and the failure mode is a
conservative semaphore rather than an overcommitted one. That is the same
direction `read_untracked_mem` chose for its own no-signal fallback.
"""

# `file` is the page cache and `slab_reclaimable` is the dentry/inode cache
# behind it -- 1.77G of the 1.78G of slab in the measurement above, and pure
# a side effect of the pool's file IO. Both are dropped on demand.
#
# `shmem` is accounted under `file` in cgroup v2 but is NOT droppable (tmpfs
# needs swap, exactly like anon), so it comes back out. `unevictable` is
# subtracted for the same reason; note it can also count mlocked ANON, in
# which case this over-subtracts and undercounts what is reclaimable. That
# errs toward reading the pool as fuller, which is the safe direction, so it
# is left deliberately imprecise rather than split by page type.
CACHE_KEYS = ("file", "slab_reclaimable")
PINNED_KEYS = ("shmem", "unevictable")


def parse_stat(text):
    """memory.stat text -> {key: int}. Unparseable rows are skipped.

    Skipped rather than fatal: memory.stat grows new keys across kernel
    versions and a single odd row must not blind the whole correction. The
    callers below fail closed on the keys they actually need being ABSENT,
    which is the condition that matters.
    """
    out = {}
    for line in text.splitlines():
        key, _, val = line.partition(" ")
        try:
            out[key] = int(val)
        except ValueError:
            continue
    return out


def reclaimable(stat):
    """Bytes in `stat` the kernel can reclaim on its own, or None for no signal.

    None means "could not tell", never "zero": a memory.stat with no `file` key
    is a malformed read, and reporting 0 reclaimable would silently restore the
    exact bug this module exists to fix.
    """
    if not stat or "file" not in stat:
        return None
    cache = stat["file"] - sum(stat.get(k, 0) for k in PINNED_KEYS)
    # Clamp per-term: a live tree can be read mid-change, and `shmem` alone
    # briefly exceeding `file` must not make the whole correction negative.
    return max(0, cache) + max(0, stat.get("slab_reclaimable", 0))


def in_use(current, stat):
    """`current` minus what the kernel can take back, or None for no signal.

    Callers treat None as "fall back to the raw charge" -- see the no-signal
    direction argued in the module docstring.
    """
    r = reclaimable(stat)
    if r is None or current is None:
        return None
    return max(0, current - r)


def read_stat(path):
    """Read and parse a cgroup's memory.stat, or None if it cannot be read."""
    try:
        with open(str(path) + "/memory.stat") as f:
            return parse_stat(f.read())
    except OSError:
        return None
