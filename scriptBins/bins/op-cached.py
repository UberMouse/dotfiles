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
import binascii
import fcntl
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
# Client-only (the daemon never takes it), so NOT part of the hand-synced
# block above: serialises the unlink/spawn dance -- see serialised() below.
lock_path = os.path.join(runtime_dir, "op-cached.lock")
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

def serialised(dance):
    """Run dance() -- an unlink/spawn of the daemon -- with the spawn lock held.

    Two clients that both found no socket used to both spawn a daemon; each
    daemon unlinks sock_path before binding, so the loser's unlink stranded the
    winner's freshly bound socket, and the NEXT client spawned a third daemon --
    one wasted 1Password prompt per collision. Only the spawn/unlink dance is
    locked; every read path stays lock-free.

    The loser waits for the winner instead of dancing over it, then takes the
    winner's socket as its answer. Every lock failure fails OPEN into the old
    unserialised behaviour: racy beats wedged for a client sitting inside a
    TOKEN="$(...)" capture.
    """
    try:
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    except OSError as e:
        log(f"spawn lock unavailable ({e}), dancing unserialised")
        dance()
        return
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            log("another client holds the spawn lock, waiting for it...")
            # Poll rather than block so a winner wedged mid-dance cannot wedge
            # us with it. Its worst case is ~7s (2s SIGTERM wait in
            # restart_daemon + 5s socket wait in start_daemon); 10s covers it.
            for _ in range(100):
                time.sleep(0.1)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError:
                    pass
            else:
                log("spawn lock never freed, dancing unserialised")
                dance()
                return
            if os.path.exists(sock_path):
                # The winner delivered while we waited. Its daemon is fresher
                # than whatever diagnosis brought us here (even "wedged": the
                # winner has already replaced that one), so take its socket
                # rather than killing it for a THIRD daemon.
                log("winner's socket is up, skipping our own spawn")
                return
        dance()
    finally:
        os.close(fd)

def start_daemon_if_still_absent():
    # Re-checked under the lock: between our caller's look and the lock grant
    # another client may have finished the whole dance, and spawning over its
    # live daemon would re-open the exact strand the lock exists to close.
    if os.path.exists(sock_path):
        log("socket appeared while we waited for the spawn lock")
        return
    start_daemon()

def ensure_daemon():
    if not os.path.exists(sock_path):
        log("no socket, starting daemon")
        serialised(start_daemon_if_still_absent)
    elif os.path.exists(pid_path):
        try:
            pid = int(open(pid_path).read().strip())
            os.kill(pid, 0)
            log("daemon already running")
        except (OSError, ValueError):
            log("stale pidfile, restarting daemon")
            serialised(restart_daemon)

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
    try:
        return parts[0], base64.b64decode(parts[1])
    except binascii.Error as e:
        # The error alone, NEVER the payload: on the OK path the undecodable
        # bytes are still (mangled) secret material, and this lands on the
        # stderr of a TOKEN="$(...)" capture.
        sys.stderr.write(f"op-cached: undecodable payload from daemon ({parts[0]}): {e}\n")
        sys.exit(1)

ensure_daemon()

try:
    response = send_request()
except (ConnectionRefusedError, FileNotFoundError, OSError) as e:
    log(f"connection failed ({e}), retrying with fresh daemon...")
    serialised(restart_daemon)
    # Guarded, because this retry is no longer the rare path it was: a connect
    # timeout now routes here. Callers run us as TOKEN="$(op-cached read ...)",
    # and a Python traceback on stderr there is far less legible than saying
    # what actually went wrong. ValueError covers a reply that is not UTF-8
    # (recv's decode) -- same legibility rule, same verdict.
    try:
        response = send_request()
    except (OSError, ValueError) as e2:
        sys.stderr.write(f"op-cached: daemon unreachable after restart: {e2}\n")
        sys.exit(1)

status, payload = parse_response(response)

# A daemon from an earlier generation survives nixos-rebuild -- it holds the
# socket until its idle timeout -- and it predates READ2, so it rejects us as
# "unknown command". Swap it for the current build and retry exactly once.
if status == "ERR" and payload == b"unknown command":
    log("pre-READ2 daemon still listening, replacing it")
    serialised(restart_daemon)
    # Same guard shape as the connect-failure retry above: this talks to a
    # daemon we just replaced, and every way THAT can go wrong (unreachable
    # socket, non-UTF-8 reply) used to traceback inside the capture.
    try:
        status, payload = parse_response(send_request())
    except (OSError, ValueError) as e:
        sys.stderr.write(f"op-cached: daemon unreachable after restart: {e}\n")
        sys.exit(1)

if status == "OK":
    sys.stdout.write(payload.decode())
    sys.stdout.flush()
else:
    sys.stderr.write(payload.decode())
    sys.exit(1)
