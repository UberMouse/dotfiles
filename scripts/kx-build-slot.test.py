#!/usr/bin/env python3
"""Exercise kx-build-slot against a hand-written semaphore.

    python3 scripts/kx-build-slot.test.py

NO CONTROLLER IS STARTED, and that is the point. kx-build-slot only ever READS
the published state -- it never negotiates -- so the state file can be written by
hand, which makes every assertion here deterministic and the whole run finish in
seconds. Behaviour that can be tested without the clock should be.

Blocking is asserted from the log (RESIDENT-WAIT / TIMEOUT lines), not from
elapsed time: a `waited >= 5s` proxy both slowed the suite by its own timeout
and bet against the scheduler. The keeper's poll interval is driven down via
KX_KEEPER_POLL so its lifetime tests converge in tenths of a second, polled by
wait_for rather than padded with sleeps.

Covers the client half: the resident gate, the keeper's lifetime, and the three
fail-open paths. The controller half has its own suites (policy + machinery).
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from testlib import check, summary, wait_for  # noqa: E402

SLOT = HERE.parent / "scriptBins" / "bins" / "kx-build-slot.sh"
# Resolve bash at runtime rather than via `#!/usr/bin/env bash`: the nix build
# sandbox (where this runs as a flake check) has no /usr/bin/env.
BASH = shutil.which("bash")
BASE = Path(tempfile.mkdtemp(prefix="kx-slot-test."))
SEM = BASE / "sem"
HOME = BASE / "home"
SEM.mkdir(parents=True)
HOME.mkdir(parents=True)
LOG = HOME / ".local/state/cgroup-pressure/build-semaphore.log"

# A fake "daemon": a sleep with a distinctive argv we can match exactly. Stands
# in for the playwright cliDaemon -- the point under test is the handoff, not
# what is on the other end of it.
MARK = "987654321"
PROBE = BASE / "probe.sh"
PROBE.write_text(
    f"#!{BASH}\n"
    "for c in /proc/[0-9]*/cmdline; do\n"
    '  a=$( { tr \'\\0\' \'\\n\' < "$c" | sed -n 2p; } 2>/dev/null ) || continue\n'
    f'  [ "$a" = "{MARK}" ] || continue\n'
    '  p=${c#/proc/}; printf \'%s\\n\' "${p%/cmdline}"\n'
    "done\n"
)
PROBE.chmod(0o755)

# A command that leaves something DETACHED behind, the way `playwright-cli open`
# forks a daemon that outlives it.
SPAWN = BASE / "spawn.sh"
SPAWN.write_text(
    f"#!{BASH}\n"
    f"setsid sleep {MARK} </dev/null >/dev/null 2>&1 &\n"
    "sleep 0.3\n"
    'exit "${1:-0}"\n'
)
SPAWN.chmod(0o755)


def slots(n=4):
    for p in SEM.glob("slot.*"):
        p.unlink()
    for i in range(n):
        (SEM / f"slot.{i:02d}").touch()


def publish(allowed=4, effective=4, occupied=0, target=4, mark=0, resident=0,
            healthy=1):
    (SEM / "allowed").write_text(
        f"{allowed} {effective} 16 {occupied} {target} {mark} {resident} "
        f"{healthy}\n"
    )


def log_text():
    """The semaphore log so far, then reset -- each check reads only what its
    own run wrote."""
    try:
        text = LOG.read_text()
    except OSError:
        text = ""
    LOG.parent.mkdir(parents=True, exist_ok=True)
    LOG.write_text("")
    return text


def run(*args, timeout="2"):
    env = dict(os.environ)
    env.update(KX_BUILD_SEM_DIR=str(SEM), HOME=str(HOME),
               KX_KEEPER_POLL="0.2")
    env.pop("KX_BUILD_SLOT_HELD", None)
    t = time.time()
    # -o nounset matches the built writeShellApplication wrapper's bashOptions
    # (scriptBins/default.nix) -- without it the test exercises the script
    # under DIFFERENT shell options than production, and an unset-variable slip
    # on a rarely-taken branch would only ever surface live.
    p = subprocess.run(
        ["bash", "-o", "nounset", str(SLOT), "--timeout", timeout, *args],
        env=env, capture_output=True, text=True,
    )
    return p, time.time() - t


def held(slot="slot.00"):
    """True if anything holds an exclusive flock on the slot."""
    r = subprocess.run(["flock", "-n", str(SEM / slot), "-c", "true"],
                       capture_output=True)
    return r.returncode != 0


def probe_pids():
    r = subprocess.run([str(PROBE)], capture_output=True, text=True)
    return [int(x) for x in r.stdout.split() if x.isdigit()]


def reap():
    """Kill exactly the pids the probe sees (its match is argv-field exact),
    never a machine-global pkill pattern."""
    for pid in probe_pids():
        try:
            os.kill(pid, 9)
        except (ProcessLookupError, PermissionError):
            pass
    wait_for(lambda: not probe_pids(), timeout=5)


def markers():
    d = SEM / "resident"
    return sorted(p.name for p in d.iterdir()) if d.is_dir() else []


# 1. THE RESIDENT GATE. A build takes the slot the floor keeps free however
#    hostile the box looks; a resident job must wait for the load test, because
#    that free slot exists to keep BUILDS moving and a browser that took it would
#    raise the floor and open the next one. Asserted from the log: a gated run
#    writes RESIDENT-WAIT and then a TIMEOUT ... UNGATED line; an ungated one
#    writes neither.
slots()
publish(healthy=0)
log_text()
p, _ = run("--label", "build", "--", "true")
check("build ignores the health gate", p.returncode, 0)
check("build never waited on the gate", "RESIDENT-WAIT" in log_text(), False)

p, _ = run("--label", "browser", "--resident", "--", "true")
blocked_log = log_text()
check("resident blocked while unhealthy", "RESIDENT-WAIT" in blocked_log, True)
check("blocked resident fails open at timeout",
      "TIMEOUT" in blocked_log and "UNGATED" in blocked_log, True)
check("fail-open still ran the command", p.returncode, 0)

publish(healthy=1)
p, _ = run("--label", "browser", "--resident", "--", "true")
check("resident admitted when healthy", "RESIDENT-WAIT" in log_text(), False)

# An older controller publishes seven fields. Reading a missing field as
# "unhealthy" would wedge every browser on the machine for a whole deploy, so
# the gate fails OPEN on anything it cannot read.
(SEM / "allowed").write_text("4 4 16 0 4 0 0\n")
p, _ = run("--label", "browser", "--resident", "--", "true")
check("gate fails open on a short state line",
      "RESIDENT-WAIT" in log_text(), False)

# 2. THE KEEPER. A command that leaves a daemon behind keeps its slot after
#    kx-build-slot itself has exited, and releases it when the daemon dies.
reap()
slots()
publish(healthy=1)
p, _ = run("--label", "pw", "--resident", "--resident-probe", str(PROBE),
           "--", str(SPAWN))
check("wrapped command's rc propagates", p.returncode, 0)
check("slot still held after exit", held(), True)
check("marker written", len(markers()), 1)

reap()
check("slot released when daemon dies",
      bool(wait_for(lambda: not held(), timeout=10)), True)
wait_for(lambda: markers() == [], timeout=10)
check("marker cleaned up", markers(), [])

# 3. A FAILED command that still spawned something must STILL be accounted. The
#    invariant is "a live browser holds a slot", not "a successful command holds
#    a slot" -- an unaccounted browser after a failed open is the whole hole.
reap()
slots()
publish(healthy=1)
p, _ = run("--label", "pwfail", "--resident", "--resident-probe", str(PROBE),
           "--", str(SPAWN), "7")
check("failing command's rc propagates", p.returncode, 7)
check("slot held despite failure", held(), True)
reap()
check("released after failure path too",
      bool(wait_for(lambda: not held(), timeout=10)), True)

# 4. NO SPAWN, NO KEEPER. A gated command that leaves nothing behind must return
#    its slot immediately, or every build would leak one.
slots()
publish(healthy=1)
run("--label", "nospawn", "--resident-probe", str(PROBE), "--", "true")
check("no keeper when nothing was spawned", held(), False)
check("no marker when nothing was spawned", markers(), [])

# 5. PROBE STRICTNESS. Only lines that are ENTIRELY digits may become pids. A
#    probe that prints a diagnostic must not be able to fabricate one -- a
#    fabricated pid never dies, and a keeper waiting on it holds a slot forever.
junk = BASE / "junk.sh"
junk.write_text(f"#!{BASH}\necho 'error: cannot read /proc/1234/x'\n"
                "echo 'warning 999999'\n")
junk.chmod(0o755)
slots()
publish(healthy=1)
run("--label", "junk", "--resident-probe", str(junk), "--", "true")
check("junk probe output fabricates no pid", held(), False)

# 6. FAIL-OPEN PATHS. No semaphore directory at all, and an empty one, both mean
#    "nothing to coordinate with" -- the command must still run. A build that
#    runs unthrottled is a nuisance; one that never runs is a broken machine.
env = dict(os.environ)
env.update(KX_BUILD_SEM_DIR=str(BASE / "nope"), HOME=str(HOME))
env.pop("KX_BUILD_SLOT_HELD", None)
p = subprocess.run(["bash", "-o", "nounset", str(SLOT), "--", "echo", "ran"],
                   env=env, capture_output=True, text=True)
check("runs with no semaphore dir", p.stdout.strip(), "ran")

for f in SEM.glob("slot.*"):
    f.unlink()
log_text()
p, _ = run("--label", "emptysem", "--", "echo", "ran")
check("runs with an empty semaphore", p.stdout.strip(), "ran")
check("empty semaphore does not stall (no wait was logged)",
      log_text(), "")

# 7. THE STATE-FILE CONTRACT. Every test above wrote the `allowed` line BY
#    HAND, which means a controller that changed the format could never fail
#    this suite. Bind the two ends: the REAL producer (Semaphore.publish) must
#    emit a line whose field positions match both this suite's writer and the
#    client's positional read (`cut -d' ' -f8` for healthy). The FIELDS tuple
#    in the controller is the contract; these assertions are its enforcement.
import importlib.util  # noqa: E402  (deliberate: only this section needs it)

spec = importlib.util.spec_from_file_location(
    "bsc", HERE / "build-semaphore-controller.py"
)
bsc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bsc)

F = bsc.Semaphore.FIELDS
check("healthy is field 8 (client cut -f8)", F.index("healthy"), 7)
check("allowed is field 1 (i3status fields[0])", F.index("allowed"), 0)
check("effective is field 2 (i3status fields[1])", F.index("effective"), 1)
check("resident is field 7 (i3status fields[6])", F.index("resident"), 6)

pub_sem = bsc.Semaphore(SEM / "pub", 16)
pub_sem.publish(4, 4, occupied=2, target=4, mark=3, resident=1, healthy=False)
line = (SEM / "pub" / "allowed").read_text().split()
check("publish emits one value per FIELDS entry", len(line), len(F))
check("publish healthy=False emits the 0 the gate blocks on",
      line[F.index("healthy")], "0")
check("publish resident lands where readers look",
      line[F.index("resident")], "1")

# And end-to-end: the REAL publisher's unhealthy line must actually gate a
# resident job (everything above it only checked bytes on disk).
slots()
pub_sem.dir = SEM
pub_sem.publish(4, 4, occupied=0, target=4, mark=0, resident=0, healthy=False)
log_text()
run("--label", "contract", "--resident", "--", "true")
check("real publish(healthy=False) blocks a resident job",
      "RESIDENT-WAIT" in log_text(), True)

reap()
summary(cleanup_dir=BASE)
