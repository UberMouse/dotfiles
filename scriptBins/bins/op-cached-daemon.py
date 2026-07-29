#!/usr/bin/env @python3@
import socket, os, subprocess, base64, time, signal, sys, json

LOG = os.environ.get("OP_CACHED_DEBUG", "") != ""

# caller name -> absolute path of that caller's op-1p-shim build. `op` is never
# spawned directly: the shim becomes its parent process, which is the name
# 1Password shows in its prompt and pins the grant to. See op-1p-shim.c.
SHIMS = json.loads('''@opShimPaths@''')

def log(msg):
    if LOG:
        sys.stderr.write(f"[op-cached-daemon] {msg}\n")
        sys.stderr.flush()

runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
sock_path = os.path.join(runtime_dir, "op-cached.sock")
pid_path = os.path.join(runtime_dir, "op-cached.pid")
ttl = int(os.environ.get("OP_CACHED_TTL", "900"))
idle_timeout = int(os.environ.get("OP_CACHED_IDLE_TIMEOUT", "1800"))

log(f"starting: sock={sock_path} ttl={ttl} idle={idle_timeout}")

cache = {}

def run_via_shim(shim, argv):
    """Run argv under `shim`, returning (combined output, exit status).

    The shim double-forks so it can reparent to init (see op-1p-shim.c), which
    means the process we spawn here exits almost immediately and its wait status
    says nothing about `op`. Output still arrives normally -- the orphan inherits
    the pipe, so reading to EOF waits for the real work -- and the exit status
    comes back over a second pipe the shim writes to before exiting.
    """
    status_r, status_w = os.pipe()
    os.set_inheritable(status_w, True)
    try:
        proc = subprocess.Popen(
            [shim, str(status_w)] + argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            pass_fds=(status_w,),
        )
        # Drop OUR copy of the write end, or the read below never sees EOF.
        os.close(status_w)
        status_w = None
        output = proc.stdout.read()
        proc.stdout.close()
        proc.wait()  # reaps the short-lived intermediate parent only

        raw = b""
        while True:
            chunk = os.read(status_r, 16)
            if not chunk:
                break
            raw += chunk
        try:
            rc = int(raw.strip())
        except ValueError:
            log(f"shim returned no usable status ({raw!r}), assuming failure")
            rc = 1
        return output, rc
    finally:
        if status_w is not None:
            os.close(status_w)
        os.close(status_r)

def cleanup(*_):
    log("cleanup")
    # Only remove the files while they are still OURS. A client that replaced us
    # may already have started a newer daemon which rebound both paths; blindly
    # unlinking on the way out (e.g. at idle timeout) would strand it -- its
    # socket would vanish and the next client would spawn yet another daemon,
    # costing an extra 1Password prompt.
    try:
        owned = int(open(pid_path).read().strip()) == os.getpid()
    except (OSError, ValueError):
        owned = False
    if owned:
        try: os.unlink(sock_path)
        except OSError: pass
        try: os.unlink(pid_path)
        except OSError: pass
    else:
        log("files belong to a newer daemon, leaving them alone")
    sys.exit(0)

signal.signal(signal.SIGTERM, cleanup)
signal.signal(signal.SIGINT, cleanup)

try: os.unlink(sock_path)
except OSError: pass

with open(pid_path, "w") as f:
    f.write(str(os.getpid()))
log(f"pid={os.getpid()}")

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(sock_path)
os.chmod(sock_path, 0o600)
sock.listen(1)
sock.settimeout(idle_timeout)
log("listening")

try:
    while True:
        log("waiting for connection...")
        try:
            conn, _ = sock.accept()
        except socket.timeout:
            log("idle timeout, exiting")
            break

        log("accepted connection")
        try:
            data = conn.recv(4096).decode().strip()
            log(f"received: {repr(data)}")
            # uri is last and may legitimately contain tabs, so maxsplit keeps
            # it intact. READ2 (vs the original READ) carries the caller name;
            # the version bump is what lets a new client detect a pre-shim
            # daemon still holding the socket and replace it.
            parts = data.split("\t", 3)

            if len(parts) == 4 and parts[0] == "READ2":
                caller, account, uri = parts[1], parts[2], parts[3]
            elif len(parts) >= 3 and parts[0] == "READ":
                # Legacy client. A long-lived shell keeps the pre-rebuild
                # op-cached in its command hash table until it rehashes, so
                # clients that predate READ2 keep arriving for a while after a
                # switch. Rejecting them would break `bk` in those shells for no
                # good reason; they simply get the unlabelled shim.
                log("legacy READ request, treating caller as unknown")
                caller, account = "unknown", parts[1]
                uri = "\t".join(parts[2:])
            else:
                log(f"bad request: parts={parts}")
                err = base64.b64encode(b"unknown command").decode()
                conn.sendall(f"ERR\t{err}\n".encode())
                continue
            # Never index SHIMS with the client-supplied name directly -- it
            # selects a binary to execute. Anything unrecognised gets the
            # "unknown" shim rather than an error, so an unlabelled caller still
            # works and still shows a real name in the prompt.
            shim = SHIMS.get(caller)
            if shim is None:
                log(f"unrecognised caller {caller!r}, using 'unknown' shim")
                caller, shim = "unknown", SHIMS["unknown"]

            # Keyed by caller as well as secret: the per-caller grant would be
            # meaningless if tool B could read a secret out of the cache that
            # tool A's authorization had fetched.
            key = f"{caller}\t{account}\t{uri}"
            now = time.time()

            if key in cache and now - cache[key][1] < ttl:
                log(f"cache hit for {uri} (caller={caller})")
                encoded = cache[key][0]
            else:
                log(f"cache miss for {uri} (caller={caller}), calling op read via {shim}...")
                value, rc = run_via_shim(shim, ["op", "read", "--account", account, uri])
                if rc != 0:
                    log(f"op read failed rc={rc}: {value}")
                    err = base64.b64encode(value.rstrip(b"\n") or b"op read failed").decode()
                    conn.sendall(f"ERR\t{err}\n".encode())
                    continue
                log(f"op read succeeded, {len(value)} bytes")
                encoded = base64.b64encode(value.rstrip(b"\n")).decode()
                cache[key] = (encoded, now)

            log(f"sending OK response")
            conn.sendall(f"OK\t{encoded}\n".encode())
            log(f"response sent")
        finally:
            conn.close()
            log("connection closed")
finally:
    cleanup()
