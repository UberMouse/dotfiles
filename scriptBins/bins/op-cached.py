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
i = 0
while i < len(args):
    if args[i] == "--account" and i + 1 < len(args):
        account = args[i + 1]; i += 2
    elif args[i].startswith("--account="):
        account = args[i].split("=", 1)[1]; i += 1
    elif args[i].startswith("op://"):
        uri = args[i]; i += 1
    else:
        i += 1

if not account or not uri:
    sys.stderr.write("op-cached: usage: op-cached read --account ACCT op://...\n")
    sys.exit(1)

log(f"account={account} uri={uri}")

def start_daemon():
    log("starting daemon...")
    env = os.environ.copy()
    subprocess.Popen(
        ["op-cached-daemon"],
        env=env,
        start_new_session=True,
    )
    for _ in range(50):
        if os.path.exists(sock_path):
            log("daemon socket appeared")
            return True
        time.sleep(0.1)
    sys.stderr.write("op-cached: daemon failed to start\n")
    sys.exit(1)

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
            try: os.unlink(sock_path)
            except OSError: pass
            try: os.unlink(pid_path)
            except OSError: pass
            start_daemon()

def send_request():
    log("connecting to daemon...")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.settimeout(300)
    log("connected, sending request...")
    s.sendall(f"READ\t{account}\t{uri}\n".encode())
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
    log(f"got response: {response[:80]}...")
    return response

ensure_daemon()

try:
    response = send_request()
except (ConnectionRefusedError, FileNotFoundError, OSError) as e:
    log(f"connection failed ({e}), retrying with fresh daemon...")
    try: os.unlink(sock_path)
    except OSError: pass
    try: os.unlink(pid_path)
    except OSError: pass
    start_daemon()
    response = send_request()

parts = response.split("\t", 1)
if len(parts) != 2:
    sys.stderr.write(f"op-cached: bad response from daemon: {response!r}\n")
    sys.exit(1)

status, payload = parts
log(f"status={status}")

if status == "OK":
    sys.stdout.write(base64.b64decode(payload).decode())
    sys.stdout.flush()
else:
    sys.stderr.write(base64.b64decode(payload).decode())
    sys.exit(1)
