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
import subprocess
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

# ----------------------------------------------------------------- the CLI
# The CLI is the seam the pressure monitor (bash) reads this correction
# through, so it is the ONLY thing standing between the snapshot and a fourth
# reimplementation of the arithmetic. What matters is the contract the bash
# formatter depends on: four tab-separated cells per input path, always, in
# argument order, with "-" for no-signal rather than a zero or a short row.
# A silently shortened row would leave the caller's `read` binding cells to the
# wrong variables and print a cache percentage computed from a path.
CLI = [sys.executable, str(HERE / "cgroup-mem.py")]
GOOD = TMP / "good"
GOOD.mkdir()
(GOOD / "memory.stat").write_text(stat(anon=3 * G, file=2 * G))
(GOOD / "memory.current").write_text(f"{5 * G}\n")

out = subprocess.run(CLI + [str(GOOD)], capture_output=True, text=True, check=True)
row = out.stdout.rstrip("\n").split("\t")
check("CLI emits four cells", len(row), 4)
check("CLI cell 0 is the path back", row[0], str(GOOD))
check("CLI reports the raw charge", row[1], str(5 * G))
check("CLI reports reclaimable", row[2], str(2 * G))
check("CLI reports in-use net of cache", row[3], str(3 * G))

# No memory.stat at all: the correction has no signal. The row must still be
# four cells wide so the caller can detect it positionally.
BARE = TMP / "bare"
BARE.mkdir()
(BARE / "memory.current").write_text(f"{7 * G}\n")
row = subprocess.run(CLI + [str(BARE)], capture_output=True, text=True,
                     check=True).stdout.rstrip("\n").split("\t")
check("no-signal row is still four cells", len(row), 4)
check("no-signal keeps the raw charge readable", row[1], str(7 * G))
check("no-signal reclaimable is a dash, not a zero", row[2], "-")
check("no-signal in-use is a dash, not a zero", row[3], "-")

# A path that does not exist at all must not crash the snapshot writer, and
# must not be silently dropped -- a missing row would shift every later line.
row = subprocess.run(CLI + [str(TMP / "nope")], capture_output=True, text=True,
                     check=True).stdout.rstrip("\n").split("\t")
check("absent cgroup still emits a row", len(row), 4)
check("absent cgroup charge is a dash", row[1], "-")

# Argument order is the contract: the monitor labels rows by position.
multi = subprocess.run(CLI + [str(BARE), str(GOOD)], capture_output=True,
                       text=True, check=True).stdout.strip().split("\n")
check("CLI emits one row per argument", len(multi), 2)
check("CLI preserves argument order", multi[0].split("\t")[0], str(BARE))
check("CLI exits zero even when every path fails",
      subprocess.run(CLI + [str(TMP / "a"), str(TMP / "b")],
                     capture_output=True).returncode, 0)
check("CLI with no arguments is a no-op, not an error",
      subprocess.run(CLI, capture_output=True, text=True).stdout, "")

summary(cleanup_dir=TMP)
