#!/usr/bin/env python3
"""Table-driven test for kx-proc-find's argv matching semantics.

    python3 scripts/kx-proc-find.test.py

kx-proc-find is the repo-wide mandated replacement for the banned `pgrep -f`,
enforced by lint-tripwires, and its highest-stakes consumer is
claude-agents-reattach -- a false positive there drags a whole process
subtree into the fleet cgroup. Yet its two subtle behaviours (in-order but
NOT-necessarily-consecutive field matching, and self/probe exclusion) had no
tests. Fixture processes are `sleep` children with crafted argv (argv[0]
renamed via exec -a), so every case is a real /proc entry.
"""

import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from testlib import check, summary, wait_for  # noqa: E402

KPF = HERE.parent / "scriptBins" / "bins" / "kx-proc-find.sh"
BASH = shutil.which("bash")

# Fixture argvs. Each is a `sleep 300` whose visible argv is the crafted one:
# bash -c 'exec -a "$0" sleep ...' replaces argv[0]; extra fields come from
# handing sleep ignored trailing args is not possible, so instead we exec a
# tiny `bash -c ':; sleep' -- <fields>` shape: the fields land in argv as $1..
FIXTURES = [
    # name, argv fields after argv[0]
    ("daemon-full", ["daemon", "run", "--origin", "kx-test-fixture"]),
    ("daemon-gap", ["daemon", "--verbose", "run", "extra", "--origin"]),
    ("daemon-reordered", ["run", "daemon", "--origin"]),
    ("joined-one-field", ["daemon run --origin"]),
]

procs = []
for name, fields in FIXTURES:
    # The fields become $0.. so they appear verbatim in /proc/<pid>/cmdline
    # as separate argv entries. The trailing ":" stops bash exec-optimizing
    # the LAST command of -c (which would replace the whole argv, extra
    # fields included, with plain `sleep 300`).
    p = subprocess.Popen(
        [BASH, "-c", "sleep 300; :", f"kxpf-{name}", *fields],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    procs.append(p)


def find(*patterns):
    r = subprocess.run([BASH, str(KPF), *patterns],
                       capture_output=True, text=True)
    return {int(x) for x in r.stdout.split() if x.isdigit()}, r


by_name = {name: p.pid for (name, _), p in zip(FIXTURES, procs)}

try:
    ok = wait_for(lambda: Path(f"/proc/{procs[-1].pid}/cmdline").exists(),
                  timeout=5)
    check("fixtures are live", bool(ok), True)

    # Exact fields, in order: matches the full and gapped argv, NOT the
    # reordered one and NOT the pgrep-style joined single field.
    got, _ = find("daemon", "run", "--origin")
    check("in-order match finds the exact argv",
          by_name["daemon-full"] in got, True)
    check("in-order match tolerates gaps (not necessarily consecutive)",
          by_name["daemon-gap"] in got, True)
    check("out-of-order fields never match",
          by_name["daemon-reordered"] in got, False)
    check("a joined 'daemon run --origin' single field never matches "
          "(the pgrep -f false-positive this tool exists to kill)",
          by_name["joined-one-field"] in got, False)

    # Globs match within a single field only.
    got, _ = find("*kx-test-fixture*")
    check("glob matches inside one field", by_name["daemon-full"] in got, True)
    check("glob does not span fields", by_name["daemon-gap"] in got, False)

    # Every pattern must match: an extra unmatched pattern excludes.
    got, _ = find("daemon", "run", "--origin", "nonexistent-arg")
    check("unmatched trailing pattern excludes", got & set(by_name.values()),
          set())

    # The probe never reports itself, however pattern-shaped its own argv is:
    # search for a pattern that IS on the probe's command line.
    got, r = find("kx-proc-find*", "sleep")
    mypids = {p.pid for p in procs}
    check("probe self-exclusion holds", got & mypids, set())

    # Usage error on no patterns.
    _, r = find()
    check("no patterns is a usage error", r.returncode, 2)
finally:
    for p in procs:
        p.kill()
    for p in procs:
        p.wait()

summary()
