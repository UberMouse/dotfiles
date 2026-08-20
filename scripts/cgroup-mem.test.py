#!/usr/bin/env python3
"""Unit-test cgroup-mem's page-cache correction.

THE PROPERTY UNDER TEST is a direction, not a formula: when the module cannot
tell how much of a charge is reclaimable it must say so (None), and every
caller then falls back to the raw charge -- reading the pool as FULLER than it
is. The opposite mistake is the expensive one. Reporting "0 reclaimable" from a
malformed read would look like a working correction while restoring exactly the
bug the module exists to fix: a semaphore that refuses builds at 0.00% memory
pressure because it counted cold page cache as memory in use.

Pure arithmetic over literal memory.stat text -- no cgroups, no root, instant
and sandbox-safe.
"""
import importlib.util
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("cgmem", HERE / "cgroup-mem.py")
cgmem = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cgmem)

sys.path.insert(0, str(HERE))
from testlib import check, summary  # noqa: E402

G = 1024 ** 3


def stat(**kw):
    return "\n".join(f"{k} {v}" for k, v in kw.items()) + "\n"


# ---------------------------------------------------------------- parse_stat
check("parses key/value rows",
      cgmem.parse_stat("anon 10\nfile 20\n"), {"anon": 10, "file": 20})
# memory.stat grows keys across kernel versions and some carry non-integer
# values in other cgroup files; one odd row must not blind the correction.
check("skips unparseable rows rather than failing the read",
      cgmem.parse_stat("anon 10\ngarbage\nfile notanumber\nshmem 5\n"),
      {"anon": 10, "shmem": 5})
check("empty text parses to empty mapping", cgmem.parse_stat(""), {})

# --------------------------------------------------------------- reclaimable
# The measurement that prompted the module (pool, 2026-08-20).
real = cgmem.parse_stat(stat(
    anon=7887302656, file=6027902976, shmem=4096, unevictable=0,
    slab_reclaimable=1773536400, slab_unreclaimable=10509504,
))
check("reclaimable = page cache + reclaimable slab",
      cgmem.reclaimable(real), 6027902976 - 4096 + 1773536400)
check("in_use strips the cache from the charge",
      cgmem.in_use(15_200_000_000, real),
      15_200_000_000 - (6027902976 - 4096 + 1773536400))

# tmpfs is accounted under `file` but needs swap exactly like anon, so it must
# NOT read as reclaimable -- otherwise a big tmpfs makes the pool look empty.
check("shmem is not reclaimable even though it lands in `file`",
      cgmem.reclaimable(cgmem.parse_stat(stat(file=10 * G, shmem=4 * G))),
      6 * G)
check("unevictable is not reclaimable",
      cgmem.reclaimable(cgmem.parse_stat(stat(file=10 * G, unevictable=2 * G))),
      8 * G)
check("slab_unreclaimable is not subtracted",
      cgmem.reclaimable(cgmem.parse_stat(stat(file=1 * G, slab_unreclaimable=9 * G))),
      1 * G)

# A live tree can be read mid-change; a per-term clamp keeps a transient
# shmem > file from making the WHOLE correction negative (which would inflate
# in_use above the real charge).
check("cache term clamps at zero, keeping slab intact",
      cgmem.reclaimable(cgmem.parse_stat(stat(file=1 * G, shmem=5 * G,
                                              slab_reclaimable=2 * G))),
      2 * G)

# ------------------------------------------------------- the no-signal rules
check("no `file` key is NO SIGNAL, not zero reclaimable",
      cgmem.reclaimable(cgmem.parse_stat(stat(anon=5 * G))), None)
check("empty stat is no signal", cgmem.reclaimable({}), None)
check("None stat is no signal", cgmem.reclaimable(None), None)
check("in_use propagates no signal", cgmem.in_use(10 * G, {}), None)
check("in_use with no current is no signal",
      cgmem.in_use(None, real), None)
# A cache larger than the charge is only reachable from two reads of a live
# tree; usage must not go negative.
check("in_use clamps at zero",
      cgmem.in_use(1 * G, cgmem.parse_stat(stat(file=5 * G))), 0)

# ------------------------------------------------------------------ read_stat
TMP = Path(tempfile.mkdtemp(prefix="cgmem-test."))
(TMP / "memory.stat").write_text(stat(anon=1 * G, file=2 * G))
check("read_stat reads a real tree", cgmem.read_stat(TMP)["file"], 2 * G)
check("read_stat accepts a str path", cgmem.read_stat(str(TMP))["anon"], 1 * G)
check("missing memory.stat is no signal", cgmem.read_stat(TMP / "nope"), None)
check("unreadable tree is no signal, end to end",
      cgmem.in_use(9 * G, cgmem.read_stat(TMP / "nope")), None)

summary(cleanup_dir=TMP)
