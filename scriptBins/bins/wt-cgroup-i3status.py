#!/usr/bin/env @python3@
# wt-cgroup-i3status -- i3bar status_command that prepends a worktrees.slice
# cgroup-usage block to the LEFT of the normal i3status output.
#
# It runs i3status forced into i3bar (coloured JSON) output via a config
# mirroring i3status's built-in defaults, passes those coloured blocks
# through untouched, and prepends our own block:
#   active:  "⚙ 2.4/12c 4.2G/16G 3wt"  (cores/cap, mem/cap, active buckets),
#            colored green/yellow/red by peak CPU-or-mem utilisation;
#   idle:    "⚙ idle" dimmed, when the pool is absent or below the CPU floor.
# CPU% is the pool's usage_usec delta averaged over each i3status tick (~5s),
# so no extra sampling sleep is needed. cgtop convention: 100% == one core.
#
# Env: WT_BAR_ACTIVE_CORES=<cores> -- below this the block reads "idle"
#      (default 0.15, i.e. 15% of one core).
import sys, os, json, time, subprocess, signal

I3STATUS = "@i3status@"

UID = os.getuid()
POOL = f"/sys/fs/cgroup/user.slice/user-{UID}.slice/user@{UID}.service/worktrees.slice"

ACTIVE_CORES = float(os.environ.get("WT_BAR_ACTIVE_CORES", "0.15"))

# Palette lifted from the dunst catppuccin-mocha theme in home.nix.
GREEN, YELLOW, RED, DIM = "#a6e3a1", "#f9e2af", "#f38ba8", "#6c7086"

def read_int(path):
    try:
        with open(path) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None

def read_usage_usec():
    try:
        with open(POOL + "/cpu.stat") as f:
            for line in f:
                if line.startswith("usage_usec"):
                    return int(line.split()[1])
    except OSError:
        return None
    return None

def cap_cores():
    try:
        with open(POOL + "/cpu.max") as f:
            quota, period = f.read().split()[:2]
        return None if quota == "max" else int(quota) / int(period)
    except (OSError, ValueError):
        return None

def mem_high():
    try:
        with open(POOL + "/memory.high") as f:
            v = f.read().strip()
        return None if v == "max" else int(v)
    except (OSError, ValueError):
        return None

def human(nbytes):
    if nbytes is None:
        return "?"
    g = nbytes / (1024 ** 3)
    if g >= 1:
        return f"{g:.1f}G"
    m = nbytes / (1024 ** 2)
    if m >= 1:
        return f"{m:.0f}M"
    return f"{nbytes / 1024:.0f}k"

def active_buckets():
    n = 0
    try:
        for name in os.listdir(POOL):
            pids = read_int(os.path.join(POOL, name, "pids.current"))
            if pids and pids > 0:
                n += 1
    except OSError:
        pass
    return n

def block(full, color):
    return {"full_text": full, "color": color, "name": "worktrees",
            "markup": "none", "separator": True}

prev_usage = None
prev_t = None

def worktree_block():
    global prev_usage, prev_t
    if not os.path.isdir(POOL):
        prev_usage, prev_t = None, None
        return block("⚙ idle", DIM)

    usage = read_usage_usec()
    now = time.monotonic()
    cores = 0.0
    if usage is not None and prev_usage is not None and now > prev_t:
        cores = max(0.0, (usage - prev_usage) / 1e6 / (now - prev_t))
    prev_usage, prev_t = usage, now

    if cores < ACTIVE_CORES:
        return block("⚙ idle", DIM)

    cap = cap_cores()
    mem = read_int(POOL + "/memory.current")
    memhigh = mem_high()
    nwt = active_buckets()

    cpu_txt = f"{cores:.1f}/{cap:.0f}c" if cap else f"{cores:.1f}c"
    mem_txt = f"{human(mem)}/{human(memhigh)}" if memhigh else human(mem)
    full = f"⚙ {cpu_txt} {mem_txt} {nwt}wt"

    cpu_u = (cores / cap) if cap else 0.0
    mem_u = (mem / memhigh) if (mem and memhigh) else 0.0
    u = max(cpu_u, mem_u)
    color = GREEN if u < 0.5 else (YELLOW if u < 0.8 else RED)
    return block(full, color)

def main():
    proc = subprocess.Popen(
        [I3STATUS, "-c", "@i3statusConf@"],
        stdout=subprocess.PIPE, stdin=subprocess.DEVNULL, text=True, bufsize=1)

    def term(*_):
        try:
            proc.terminate()
        except Exception:
            pass
        sys.exit(0)

    signal.signal(signal.SIGTERM, term)
    signal.signal(signal.SIGINT, term)

    sys.stdout.write('{"version":1}\n[\n')
    sys.stdout.flush()

    first = True
    for raw in proc.stdout:
        s = raw.strip()
        if s.startswith(","):        # i3bar continuation lines: ",[ ... ]"
            s = s[1:].strip()
        # Skip the protocol header and the opening "[".
        if not s or s == "[" or (s.startswith("{") and "version" in s):
            continue
        # i3status is configured for i3bar JSON, so pass its coloured blocks
        # through. Fall back to wrapping a plain-text line as one block.
        if s.startswith("["):
            try:
                status_blocks = json.loads(s)
            except json.JSONDecodeError:
                status_blocks = [{"full_text": s, "markup": "none"}]
        else:
            status_blocks = [{"full_text": raw.rstrip("\n"),
                              "markup": "none", "separator": True}]

        line = json.dumps([worktree_block()] + status_blocks)
        sys.stdout.write(("" if first else ",") + line + "\n")
        sys.stdout.flush()
        first = False

    term()

main()
