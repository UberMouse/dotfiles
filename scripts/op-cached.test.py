#!/usr/bin/env python3
"""Exercise the op-cached client/daemon pair against a fake `op`.

    python3 scripts/op-cached.test.py

NOTHING HERE TOUCHES 1PASSWORD. The daemon's @opShimPaths@ are substituted
with bash fakes that deliberately IGNORE the `op` path they are handed: on a
dev box resolve_op() picks the real setgid wrapper at /run/wrappers/bin/op,
and running it would raise real prompts. Inside the nix sandbox that wrapper
does not exist and resolve_op() falls back to shutil.which("op"), which finds
the stub this suite puts on PATH -- the same fixtures therefore pass in both
worlds. Every fetch a fake shim serves is appended to one log; the hit/miss
assertions count those lines, keyed by uri.

Each section gets its own XDG_RUNTIME_DIR so daemons cannot cross-talk, and
everything spawned is reaped on the way out. Daemons are found by EXACT
argv-field match on the substituted daemon path, never by pattern (the
pgrep -f self-match trap).
"""

import base64
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from testlib import check, summary, wait_for  # noqa: E402

BINS = HERE.parent / "scriptBins" / "bins"
# Resolved at runtime rather than #!/usr/bin/env: the nix build sandbox
# (where this runs as a flake check) has no /usr/bin/env.
BASH = shutil.which("bash")
PY = sys.executable
BASE = Path(tempfile.mkdtemp(prefix="op-cached-test."))

OP_LOG = BASE / "op-invocations.log"
FAIL_FLAG = BASE / "op-fail"

# Stub `op` on PATH for the sandbox case only: resolve_op() must find SOME
# binary or every cache miss dies at "no `op` binary found". It is never
# executed -- the fake shims below ignore the op argv they are handed.
FAKEBIN = BASE / "fakebin"
FAKEBIN.mkdir()
(FAKEBIN / "op").write_text(f"#!{BASH}\nexit 0\n")
(FAKEBIN / "op").chmod(0o755)


def make_shim(caller):
    """A stand-in for op-1p-<caller>: logs the fetch, prints a secret derived
    from caller+uri (which is what the isolation assertions read back), and
    reports its exit status over the daemon's status pipe exactly like the C
    shim's write_status()."""
    p = BASE / f"shim-{caller}"
    p.write_text(
        f"#!{BASH}\n"
        'statusfd=$1; shift\n'
        "# argv now: <op-path> read --account ACCT URI. The op path is\n"
        "# deliberately unused -- see the suite docstring.\n"
        f"printf '%s\\t%s\\t%s\\n' {caller} \"$4\" \"$5\" >> {OP_LOG}\n"
        f"if [ -e {FAIL_FLAG} ]; then\n"
        "  echo 'fake op: simulated failure'\n"
        '  echo 1 >&"$statusfd"\n'
        "  exit 0\n"
        "fi\n"
        f"printf 'secret:{caller}:%s' \"$5\"\n"
        'echo 0 >&"$statusfd"\n'
    )
    p.chmod(0o755)
    return str(p)


SHIMS = {c: make_shim(c) for c in ("unknown", "bk")}


def build(src_name, subs, dest):
    text = (BINS / f"{src_name}.py").read_text()
    # Rewrite the shebang whole (not just @python3@): substituting the token
    # alone leaves /usr/bin/env in front, which the sandbox lacks.
    text = text.replace("#!/usr/bin/env @python3@", f"#!{PY}", 1)
    for k, v in subs.items():
        text = text.replace(f"@{k}@", v)
    dest.write_text(text)
    dest.chmod(0o755)


DAEMON = BASE / "op-cached-daemon"
build("op-cached-daemon", {"opShimPaths": json.dumps(SHIMS)}, DAEMON)
CLIENT = BASE / "op-cached"
build("op-cached", {"opCachedDaemon": str(DAEMON)}, CLIENT)

# A "daemon" that strands its client: creates sock_path as a plain FILE (so
# start_daemon's existence poll passes) that connect() then refuses. Drives
# the retry path's failure leg without waiting out start_daemon's 5s poll.
STRANDER = BASE / "strander"
STRANDER.write_text(
    f"#!{BASH}\n"
    ': > "$XDG_RUNTIME_DIR/op-cached.sock"\n'
    "sleep 3\n"
)
STRANDER.chmod(0o755)
CLIENT2 = BASE / "op-cached-stranding"
build("op-cached", {"opCachedDaemon": str(STRANDER)}, CLIENT2)

# A wedged daemon: owns socket + pidfile like the real one, but never
# accepts, so its backlog fills and connect() starts failing -- the exact
# state the client's connect-timeout replacement path exists for.
WEDGE = BASE / "wedge.py"
WEDGE.write_text(
    "import os, socket, time\n"
    "rd = os.environ['XDG_RUNTIME_DIR']\n"
    "open(os.path.join(rd, 'op-cached.pid'), 'w').write(str(os.getpid()))\n"
    "s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
    "s.bind(os.path.join(rd, 'op-cached.sock'))\n"
    "s.listen(0)\n"
    "print('ready', flush=True)\n"
    "time.sleep(600)\n"
)

# A scripted daemon that answers every request with $FAKE_REPLY verbatim.
# FAKE_REPLY='ERR\t<b64 unknown command>' plays a pre-READ2 daemon;
# FAKE_REPLY='OK\tabcde' plays one whose payload is not base64.
FAKE = BASE / "fake-daemon.py"
FAKE.write_text(
    "import os, socket\n"
    "rd = os.environ['XDG_RUNTIME_DIR']\n"
    "reply = os.environ['FAKE_REPLY'].encode() + b'\\n'\n"
    "open(os.path.join(rd, 'op-cached.pid'), 'w').write(str(os.getpid()))\n"
    "s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
    "s.bind(os.path.join(rd, 'op-cached.sock'))\n"
    "s.listen(16)\n"
    "print('ready', flush=True)\n"
    "while True:\n"
    "    c, _ = s.accept()\n"
    "    c.recv(4096)\n"
    "    c.sendall(reply)\n"
    "    c.close()\n"
)

RUNS = []
SPAWNED = []


def runtime(name):
    d = BASE / f"run-{name}"
    d.mkdir()
    RUNS.append(d)
    return d


def mkenv(rd, extra=None):
    env = dict(os.environ)
    env["XDG_RUNTIME_DIR"] = str(rd)
    env["PATH"] = str(FAKEBIN) + os.pathsep + env.get("PATH", "")
    env["OP_CACHED_DEBUG"] = "1"
    # Belt-and-braces against a missed reap: any daemon this suite leaks
    # idles out on its own instead of squatting for the default 1800s.
    env["OP_CACHED_IDLE_TIMEOUT"] = "120"
    if extra:
        env.update(extra)
    return env


def client(rd, *args, extra=None, exe=None):
    return subprocess.run(
        [PY, str(exe or CLIENT), "read", *args],
        env=mkenv(rd, extra), capture_output=True, text=True, timeout=30,
    )


def fetch_count(uri):
    try:
        lines = OP_LOG.read_text().splitlines()
    except OSError:
        return 0
    return sum(1 for line in lines if line.endswith("\t" + uri))


def alive(pid):
    """Mirrors the client's still_running: a zombie counts as gone."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return False


def find_daemons():
    """Pids whose argv contains the substituted daemon path as an EXACT
    field (list membership, so no pattern can self-match)."""
    pids = []
    for p in Path("/proc").iterdir():
        if not p.name.isdigit():
            continue
        try:
            argv = (p / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        if str(DAEMON).encode() in argv:
            pids.append(int(p.name))
    return pids


def kill_daemons():
    for pid in find_daemons():
        try:
            os.kill(pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    wait_for(lambda: not find_daemons(), timeout=5)


def spawn(script, rd, extra=None):
    """Start a fixture daemon and block on its 'ready' line, so no test races
    its bind."""
    p = subprocess.Popen(
        [PY, str(script)], env=mkenv(rd, extra),
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    SPAWNED.append(p)
    p.stdout.readline()
    return p


def raw_request(rd, line):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(10)
    c.connect(str(rd / "op-cached.sock"))
    c.sendall(line.encode())
    buf = b""
    while b"\n" not in buf:
        chunk = c.recv(4096)
        if not chunk:
            break
        buf += chunk
    c.close()
    return buf.decode().strip()


def dump_logs():
    for d in RUNS:
        lg = d / "op-cached-daemon.log"
        if lg.exists():
            print(f"--- {lg} ---")
            print(lg.read_text())


try:
    # 1. CACHE HIT vs MISS, PER-CALLER ISOLATION, ERR PROPAGATION, and the
    #    wire's legacy replies -- one daemon, default (900s) ttl so nothing
    #    here is clock-sensitive.
    RD = runtime("cache")
    uri = "op://vault/item/field"
    p = client(RD, "--as", "bk", "--account", "acct", uri)
    check("miss returns the fetched secret", (p.returncode, p.stdout),
          (0, f"secret:bk:{uri}"))
    check("miss ran the fake op once", fetch_count(uri), 1)
    mode = (RD / "op-cached.sock").stat().st_mode & 0o777
    check("socket is owner-only", oct(mode), oct(0o600))

    p = client(RD, "--as", "bk", "--account", "acct", uri)
    check("hit returns the same secret", (p.returncode, p.stdout),
          (0, f"secret:bk:{uri}"))
    check("hit did not run op again", fetch_count(uri), 1)

    # Same secret, different caller: MUST refetch (a hit here would let tool
    # B read a secret out of tool A's authorization).
    p = client(RD, "--as", "unknown", "--account", "acct", uri)
    check("other caller is a miss", (p.returncode, p.stdout),
          (0, f"secret:unknown:{uri}"))
    check("other caller refetched", fetch_count(uri), 2)
    p = client(RD, "--as", "bk", "--account", "acct", uri)
    check("original caller still cached", fetch_count(uri), 2)

    # `op read` failing must land on the client's stderr and exit code, not
    # in the cache.
    FAIL_FLAG.touch()
    bad = "op://vault/item/broken"
    p = client(RD, "--as", "bk", "--account", "acct", bad)
    check("op failure exits nonzero", p.returncode, 1)
    check("op failure reaches stderr",
          "fake op: simulated failure" in p.stderr, True)
    FAIL_FLAG.unlink()
    p = client(RD, "--as", "bk", "--account", "acct", bad)
    check("failure was not cached", (p.returncode, p.stdout),
          (0, f"secret:bk:{bad}"))

    # Wire-level legacy behaviour, straight at the socket: garbage gets the
    # versioned "unknown command" ERR (what a NEW client keys its daemon
    # replacement on), and a v1 READ still gets served via the unknown shim.
    want_err = "ERR\t" + base64.b64encode(b"unknown command").decode()
    check("garbage request gets the unknown-command reply",
          raw_request(RD, "BOGUS\n"), want_err)
    legacy_uri = "op://vault/legacy/field"
    got = raw_request(RD, f"READ\tacct\t{legacy_uri}\n")
    want = "OK\t" + base64.b64encode(f"secret:unknown:{legacy_uri}".encode()).decode()
    check("legacy READ served as caller=unknown", got, want)

    # 2. TTL SLIDES ON USE. ttl=2s; refetches at 1.1s intervals must stay
    #    hits past the 2s mark (the slide), and 2.2s of silence must expire
    #    the entry. Wall-clock timed, so a badly loaded box can flake the
    #    hit assertions -- margins are ~0.9s.
    RD = runtime("ttl")
    uri = "op://vault/ttl/field"
    ttl_env = {"OP_CACHED_TTL": "2"}
    t0 = time.time()
    client(RD, "--as", "bk", "--account", "acct", uri, extra=ttl_env)
    time.sleep(1.1)
    client(RD, "--as", "bk", "--account", "acct", uri, extra=ttl_env)
    time.sleep(1.1)
    client(RD, "--as", "bk", "--account", "acct", uri, extra=ttl_env)
    elapsed = time.time() - t0
    check("slide window really exceeded the ttl", elapsed > 2.0, True)
    check("kept-warm entry never refetched", fetch_count(uri), 1)
    time.sleep(2.2)
    client(RD, "--as", "bk", "--account", "acct", uri, extra=ttl_env)
    check("idle entry expired after ttl", fetch_count(uri), 2)

    # 3. PIDFILE OWNERSHIP ON EXIT. A daemon that still owns the pidfile
    #    removes both files; one that has been replaced (pidfile holds some
    #    other pid) must leave them for its successor.
    RD = runtime("cleanup")
    client(RD, "--as", "bk", "--account", "acct", "op://vault/own/x")
    pid = int((RD / "op-cached.pid").read_text())
    os.kill(pid, signal.SIGTERM)
    check("owned exit removes socket and pidfile",
          bool(wait_for(lambda: not (RD / "op-cached.sock").exists()
                        and not (RD / "op-cached.pid").exists(), timeout=5)),
          True)

    client(RD, "--as", "bk", "--account", "acct", "op://vault/own/y")
    pid = int((RD / "op-cached.pid").read_text())
    (RD / "op-cached.pid").write_text("999999999")
    os.kill(pid, signal.SIGTERM)
    wait_for(lambda: not alive(pid), timeout=5)
    check("disowned exit leaves the socket", (RD / "op-cached.sock").exists(), True)
    check("disowned exit leaves the pidfile", (RD / "op-cached.pid").exists(), True)

    # 4. WEDGED-DAEMON REPLACEMENT. Fill a never-accepting daemon's backlog
    #    so connect() fails fast; the client must kill it by pidfile, spawn a
    #    real daemon, and still answer -- all inside one invocation.
    RD = runtime("wedge")
    wedge = spawn(WEDGE, RD)
    holders, full = [], False
    for _ in range(8):
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(0.3)
        try:
            c.connect(str(RD / "op-cached.sock"))
            holders.append(c)
        except OSError:
            c.close()
            full = True
            break
    check("wedge backlog saturated", full, True)
    uri = "op://vault/wedge/x"
    p = client(RD, "--as", "bk", "--account", "acct", uri,
               extra={"OP_CACHED_CONNECT_TIMEOUT": "0.5"})
    check("client replaced the wedged daemon and answered",
          (p.returncode, p.stdout), (0, f"secret:bk:{uri}"))
    check("wedged daemon was terminated",
          wait_for(lambda: wedge.poll(), timeout=5) is not None, True)
    for c in holders:
        c.close()

    # 5. STARTUP SERIALISATION. Two clients racing from no-daemon: exactly
    #    one daemon may exist afterwards, exactly one fetch may have run,
    #    and BOTH clients must get the secret. Before the spawn lock, the
    #    loser's daemon unlinked the winner's socket and stranded it.
    kill_daemons()
    RD = runtime("race")
    uri = "op://vault/race/x"
    argv = [PY, str(CLIENT), "read", "--as", "bk", "--account", "acct", uri]
    env = mkenv(RD)
    racers = [subprocess.Popen(argv, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
              for _ in range(2)]
    outs = [p.communicate(timeout=30) for p in racers]
    for i, p in enumerate(racers):
        check(f"racing client {i} got the secret",
              (p.returncode, outs[i][0]), (0, f"secret:bk:{uri}"))
    check("race ran exactly one fetch", fetch_count(uri), 1)
    check("race left exactly one daemon", len(find_daemons()), 1)

    # 6. RETRY-PATH LEGIBILITY: an undecodable payload must die with one
    #    op-cached: line, never a traceback -- this is stderr inside a
    #    TOKEN="$(...)" capture.
    RD = runtime("corrupt")
    spawn(FAKE, RD, extra={"FAKE_REPLY": "OK\tabcde"})
    p = client(RD, "--as", "bk", "--account", "acct", "op://vault/corrupt/x")
    check("corrupt payload exits nonzero", p.returncode, 1)
    check("corrupt payload names the problem", "undecodable payload" in p.stderr, True)
    check("corrupt payload raises no traceback", "Traceback" in p.stderr, False)

    # 7. PRE-READ2 UPGRADE, both legs. Success: a daemon answering only
    #    "unknown command" is replaced mid-invocation and the retry answers.
    unknown_reply = "ERR\t" + base64.b64encode(b"unknown command").decode()
    RD = runtime("upgrade")
    old = spawn(FAKE, RD, extra={"FAKE_REPLY": unknown_reply})
    uri = "op://vault/upgrade/x"
    p = client(RD, "--as", "bk", "--account", "acct", uri)
    check("pre-READ2 daemon replaced and retry answered",
          (p.returncode, p.stdout), (0, f"secret:bk:{uri}"))
    check("pre-READ2 daemon was terminated",
          wait_for(lambda: old.poll(), timeout=5) is not None, True)

    # Failure: the replacement never comes up as a socket (CLIENT2's daemon
    # strands it with a plain file). Must be the same one-line verdict as
    # the guarded connect-failure retry, not a traceback.
    RD = runtime("retryfail")
    spawn(FAKE, RD, extra={"FAKE_REPLY": unknown_reply})
    p = client(RD, "--as", "bk", "--account", "acct", "op://vault/retry/x",
               exe=CLIENT2)
    check("failed retry exits nonzero", p.returncode, 1)
    check("failed retry names the problem",
          "unreachable after restart" in p.stderr, True)
    check("failed retry raises no traceback", "Traceback" in p.stderr, False)
finally:
    for p in SPAWNED:
        if p.poll() is None:
            p.kill()
        try:
            p.wait(timeout=5)
        except Exception:
            pass
    kill_daemons()

summary(cleanup_dir=BASE, extra_on_fail=dump_logs)
