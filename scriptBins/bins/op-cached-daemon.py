#!/usr/bin/env @python3@
import socket, os, subprocess, base64, time, signal, sys

LOG = os.environ.get("OP_CACHED_DEBUG", "") != ""

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

def cleanup(*_):
    log("cleanup")
    try: os.unlink(sock_path)
    except OSError: pass
    try: os.unlink(pid_path)
    except OSError: pass
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
            parts = data.split("\t", 2)

            if len(parts) != 3 or parts[0] != "READ":
                log(f"bad request: parts={parts}")
                err = base64.b64encode(b"unknown command").decode()
                conn.sendall(f"ERR\t{err}\n".encode())
                continue

            account, uri = parts[1], parts[2]
            key = f"{account}\t{uri}"
            now = time.time()

            if key in cache and now - cache[key][1] < ttl:
                log(f"cache hit for {uri}")
                encoded = cache[key][0]
            else:
                log(f"cache miss for {uri}, calling op read...")
                try:
                    value = subprocess.check_output(
                        ["op", "read", "--account", account, uri],
                        stderr=subprocess.STDOUT,
                    )
                    log(f"op read succeeded, {len(value)} bytes")
                    encoded = base64.b64encode(value.rstrip(b"\n")).decode()
                    cache[key] = (encoded, now)
                except subprocess.CalledProcessError as e:
                    log(f"op read failed: {e.output}")
                    err = base64.b64encode(e.output.rstrip(b"\n")).decode()
                    conn.sendall(f"ERR\t{err}\n".encode())
                    continue

            log(f"sending OK response")
            conn.sendall(f"OK\t{encoded}\n".encode())
            log(f"response sent")
        finally:
            conn.close()
            log("connection closed")
finally:
    cleanup()
