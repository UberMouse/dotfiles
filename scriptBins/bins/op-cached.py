#!/usr/bin/env @python3@
# NOTE: the log()/runtime_dir/sock_path/pid_path block below is kept in sync
# BY HAND with op-cached-daemon.py. The nix `py` wrapper produces single
# self-contained files, so there is no import path between them -- if either
# side's paths or wire format change, change both (the wire format itself is
# additionally pinned by the READ2 line here and its parser in the daemon).
import socket
import os
import sys
import base64
import time
import subprocess
import signal

LOG = os.environ.get("OP_CACHED_DEBUG", "") != ""

def log(msg):
    if LOG:
        sys.stderr.write(f"[op-cached-client] {msg}\n")
        sys.stderr.flush()

runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
sock_path = os.path.join(runtime_dir, "op-cached.sock")
pid_path = os.path.join(runtime_dir, "op-cached.pid")
# Seconds to wait for accept(). A live daemon listens with a backlog of 16 and
# accepts instantly no matter what it is busy with, so this only has to outlast
# scheduling noise -- it is not sized for any real work.
CONNECT_TIMEOUT = float(os.environ.get("OP_CACHED_CONNECT_TIMEOUT", "5"))

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
    # Absolute store path substituted at build, NOT a bare PATH lookup. The
    # daemon's own 22-line WRAPPER_OP comment records what a coin-flip PATH
    # resolution did to `op`; spawning the daemon itself by bare name was the
    # same gamble one level up (and pinned whichever generation of the daemon
    # the ambient PATH happened to hold, across rebuilds).
    subprocess.Popen(
        ["@opCachedDaemon@"],
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
    # The timeout goes on BEFORE connect, which is the whole point. connect() on
    # a unix socket only blocks once the listen backlog is full -- i.e. when the
    # daemon has stopped calling accept() -- so a blocked connect is not a slow
    # daemon, it is a dead-in-the-water one. Setting the timeout after connect
    # (as this did) left that case completely untimed, so a daemon wedged on one
    # bad request took out every op-cached caller until the next reboot, even
    # though restart_daemon() below has always known how to fix it. It simply
    # never got to run.
    #
    # Measured, because the exception is not the obvious one: against a full
    # backlog a timeout-mode connect surfaces the kernel's EAGAIN as
    # BlockingIOError immediately, and only reports TimeoutError in other
    # stalls. Both subclass OSError, which is what the handler below keys on --
    # so catch OSError, never TimeoutError specifically.
    #
    # ensure_daemon() cannot cover this: a wedged daemon still has a live pid
    # and a bound socket, so every check it makes passes.
    s.settimeout(CONNECT_TIMEOUT)
    s.connect(sock_path)
    # Generous from here on. A cache miss blocks until a human approves the
    # 1Password dialog, and timing that out would abandon the fetch and cost an
    # extra prompt on the retry. Only the connect needs to be brisk.
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
    # Guarded, because this retry is no longer the rare path it was: a connect
    # timeout now routes here. Callers run us as TOKEN="$(op-cached read ...)",
    # and a Python traceback on stderr there is far less legible than saying
    # what actually went wrong.
    try:
        response = send_request()
    except OSError as e2:
        sys.stderr.write(f"op-cached: daemon unreachable after restart: {e2}\n")
        sys.exit(1)

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
