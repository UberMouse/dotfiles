#!/usr/bin/env @python3@
import socket, os, sys, base64, time, subprocess, signal

LOG = os.environ.get("OP_CACHED_DEBUG", "") != ""

def log(msg):
    if LOG:
        sys.stderr.write(f"[op-cached-client] {msg}\n")
        sys.stderr.flush()

runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
sock_path = os.path.join(runtime_dir, "op-cached.sock")
pid_path = os.path.join(runtime_dir, "op-cached.pid")

args = sys.argv[1:]
log(f"start: args={args}")

if not args or args[0] != "read":
    sys.stderr.write("op-cached: only 'read' subcommand is supported\n")
    sys.exit(1)
args = args[1:]

account = ""
uri = ""
caller = "unknown"
i = 0
while i < len(args):
    if args[i] == "--account" and i + 1 < len(args):
        account = args[i + 1]; i += 2
    elif args[i].startswith("--account="):
        account = args[i].split("=", 1)[1]; i += 1
    elif args[i] == "--as" and i + 1 < len(args):
        caller = args[i + 1]; i += 2
    elif args[i].startswith("--as="):
        caller = args[i].split("=", 1)[1]; i += 1
    elif args[i].startswith("op://"):
        uri = args[i]; i += 1
    else:
        i += 1

if not account or not uri:
    sys.stderr.write(
        "op-cached: usage: op-cached read [--as CALLER] --account ACCT op://...\n"
    )
    sys.exit(1)

# --as picks which op-1p-shim fetches the secret, and therefore the name
# 1Password puts in its prompt (see op-1p-shim.c). Reject anything that could
# smuggle a tab/newline into the wire format below; the daemon separately
# refuses names it has no shim for, so an unknown name is merely unlabelled,
# not dangerous.
if not caller or not all(c.isalnum() or c == "-" for c in caller):
    log(f"ignoring unusable --as {caller!r}")
    caller = "unknown"

log(f"caller={caller} account={account} uri={uri}")

def start_daemon():
    log("starting daemon...")
    env = os.environ.copy()
    # Detach the daemon's stdio. It deliberately outlives this client, so any fd
    # it inherits stays open for its whole life -- and callers invoke us as
    # TOKEN="$(op-cached read ...)", where the shell blocks until EVERY writer to
    # the capture pipe closes. Inheriting stdout therefore wedges the calling
    # shell until the daemon idles out, but only on the call that happens to
    # spawn it, which makes the hang look intermittent. Debug logs go to a file
    # rather than the inherited stderr for exactly the same reason.
    errlog = subprocess.DEVNULL
    if LOG:
        errlog = open(os.path.join(runtime_dir, "op-cached-daemon.log"), "a")
        log(f"daemon stderr -> {errlog.name}")
    subprocess.Popen(
        ["op-cached-daemon"],
        env=env,
        start_new_session=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=errlog,
    )
    for _ in range(50):
        if os.path.exists(sock_path):
            log("daemon socket appeared")
            return True
        time.sleep(0.1)
    sys.stderr.write("op-cached: daemon failed to start\n")
    sys.exit(1)

def still_running(pid):
    """True only while pid can still execute code.

    A zombie is treated as gone: it has already run its exit handlers, so it
    can no longer touch the socket. os.kill(pid, 0) alone would say "alive" for
    a zombie and make us wait out the whole timeout for nothing.
    """
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().rsplit(")", 1)[1].split()[0] != "Z"
    except (OSError, IndexError):
        return False

def restart_daemon():
    """Replace whatever daemon currently owns the socket with a fresh one."""
    try:
        pid = int(open(pid_path).read().strip())
    except (OSError, ValueError):
        pid = None
    if pid is not None:
        # SIGTERM rather than merely unlinking the socket, and wait for the exit
        # to complete BEFORE starting the replacement. A daemon predating the
        # ownership check in cleanup() unlinks both paths unconditionally on its
        # way out, so letting one die after the new daemon has bound would strand
        # the new daemon -- its socket would vanish and the next client would
        # spawn yet another one, costing a needless 1Password prompt.
        log(f"terminating old daemon pid={pid}")
        try: os.kill(pid, signal.SIGTERM)
        except OSError: pass
        for _ in range(40):
            if not still_running(pid):
                break
            time.sleep(0.05)
        else:
            log(f"daemon pid={pid} did not exit; replacing it anyway")
    for path in (sock_path, pid_path):
        try: os.unlink(path)
        except OSError: pass
    start_daemon()

def ensure_daemon():
    if not os.path.exists(sock_path):
        log("no socket, starting daemon")
        start_daemon()
    elif os.path.exists(pid_path):
        try:
            pid = int(open(pid_path).read().strip())
            os.kill(pid, 0)
            log("daemon already running")
        except (OSError, ValueError):
            log("stale pidfile, restarting daemon")
            restart_daemon()

def send_request():
    log("connecting to daemon...")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.settimeout(300)
    log("connected, sending request...")
    s.sendall(f"READ2\t{caller}\t{account}\t{uri}\n".encode())
    log("request sent, waiting for response...")
    buf = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
        if b"\n" in buf:
            break
    s.close()
    response = buf.decode().strip()
    # NEVER log the payload, not even truncated: it is base64 of the secret, and
    # 80 chars of that is enough to carry a whole API token into a terminal
    # scrollback or CI log. Status plus size is all that is useful anyway.
    log(f"got response: {response.split(chr(9), 1)[0]} ({len(response)} bytes)")
    return response

def parse_response(response):
    parts = response.split("\t", 1)
    if len(parts) != 2:
        sys.stderr.write(f"op-cached: bad response from daemon: {response!r}\n")
        sys.exit(1)
    log(f"status={parts[0]}")
    return parts[0], base64.b64decode(parts[1])

ensure_daemon()

try:
    response = send_request()
except (ConnectionRefusedError, FileNotFoundError, OSError) as e:
    log(f"connection failed ({e}), retrying with fresh daemon...")
    restart_daemon()
    response = send_request()

status, payload = parse_response(response)

# A daemon from an earlier generation survives nixos-rebuild -- it holds the
# socket until its idle timeout -- and it predates READ2, so it rejects us as
# "unknown command". Swap it for the current build and retry exactly once.
if status == "ERR" and payload == b"unknown command":
    log("pre-READ2 daemon still listening, replacing it")
    restart_daemon()
    status, payload = parse_response(send_request())

if status == "OK":
    sys.stdout.write(payload.decode())
    sys.stdout.flush()
else:
    sys.stderr.write(payload.decode())
    sys.exit(1)
