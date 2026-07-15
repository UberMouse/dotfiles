{ pkgs, unstable-pkgs, unstable-small-pkgs, ... }:

let
  # Mirror of i3status's compiled-in default config (the same modules the bar
  # showed before) but with output_format forced to i3bar, so i3status emits
  # COLORED JSON blocks. The wt-cgroup-i3status wrapper passes those blocks
  # through untouched and prepends the worktree block. Without this, i3status
  # run behind the wrapper's pipe auto-detects "not i3bar" and drops to
  # uncoloured plain text.
  i3statusConf = pkgs.writeText "i3status.conf" ''
    general {
            colors = true
            interval = 5
            output_format = "i3bar"
    }

    order += "ipv6"
    order += "wireless _first_"
    order += "ethernet _first_"
    order += "battery all"
    order += "disk /"
    order += "load"
    order += "memory"
    order += "tztime local"

    wireless _first_ {
            format_up = "W: (%quality at %essid) %ip"
            format_down = "W: down"
    }

    ethernet _first_ {
            format_up = "E: %ip (%speed)"
            format_down = "E: down"
    }

    battery all {
            format = "%status %percentage %remaining"
    }

    disk "/" {
            format = "%avail"
    }

    load {
            format = "%1min"
    }

    memory {
            format = "%used | %available"
            threshold_degraded = "1G"
            format_degraded = "MEMORY < %available"
    }

    tztime local {
            format = "%Y-%m-%d %H:%M:%S"
    }
  '';
in
{
  home.packages = [
    (pkgs.writeScriptBin "koordinates-dev-protocol" ''
      #!/usr/bin/env bash
      curl -X POST -H 'Content-Type: application/json' -d "{\"url\": \"$1\"}" http://localhost:7281
    '')
    (pkgs.writeScriptBin "dev-terminal" ''
      #!/usr/bin/env bash
      until ${pkgs.tmux}/bin/tmux has-session -t kawaka 2>/dev/null; do
        sleep 0.2
      done
      exec ${pkgs.tmux}/bin/tmux attach-session -t kawaka
    '')
    (pkgs.writeScriptBin "scratch-terminal" ''
      #!/usr/bin/env bash
      set -e

      tmux=${pkgs.tmux}/bin/tmux

      # kawaka session: matai / map-viewer / rimu / scratch windows
      if ! $tmux has-session -t kawaka 2>/dev/null; then
        $tmux new-session -d -s kawaka -n matai -c "$HOME/code/kawaka"
        $tmux split-window -h -t kawaka:matai -c "$HOME/code/kawaka/packages/apps/matai"

        $tmux new-window -t kawaka -n map-viewer -c "$HOME/code/kawaka"
        $tmux split-window -h -t kawaka:map-viewer -c "$HOME/code/kawaka/packages/embeds/map-viewer/core"
        $tmux split-window -v -t kawaka:map-viewer.1 -c "$HOME/code/kawaka/packages/embeds/map-viewer/integration-tests"
        $tmux split-window -h -t kawaka:map-viewer.2 -c "$HOME/code/kawaka/packages/embeds/map-viewer/integration-tests"

        $tmux new-window -t kawaka -n rimu -c "$HOME/code/kawaka"
        $tmux split-window -h -t kawaka:rimu -c "$HOME/code/kawaka/packages/apps/rimu/core"
        $tmux split-window -v -t kawaka:rimu.1 -c "$HOME/code/kawaka/packages/apps/rimu"

        $tmux new-window -t kawaka -n scratch -c "$HOME/code/kawaka"
        $tmux split-window -h -t kawaka:scratch -c "$HOME/code/kawaka/packages/embeds/map-viewer/integration-tests"

        $tmux select-window -t kawaka:matai
      fi

      # code session: dotfiles / code windows
      if ! $tmux has-session -t code 2>/dev/null; then
        $tmux new-session -d -s code -n dotfiles -c "$HOME/dotfiles"
        $tmux split-window -h -t code:dotfiles -c "$HOME/dotfiles"
        $tmux new-window -t code -n code -c "$HOME/code"
        $tmux select-window -t code:dotfiles
      fi

      # main session: single kawaka window — scratch is a grouped view of it
      if ! $tmux has-session -t main 2>/dev/null; then
        $tmux new-session -d -s main -n kawaka -c "$HOME/code/kawaka"
      fi
      $tmux new-session -d -t main -s scratch 2>/dev/null || true

      $tmux select-window -t scratch:kawaka
      exec $tmux attach-session -t scratch
    '')
    (pkgs.writeScriptBin "rush-logs" ''
      #!/usr/bin/env bash
      set -e

      if [ $# -lt 2 ]; then
        echo "Usage: rush-logs <package-name> <phase-name>"
        echo "  Use '.' as package-name for the package in the current directory"
        echo "Example: rush-logs @kx/data-manager test-storybook"
        exit 1
      fi

      PACKAGE="$1"
      PHASE="$2"

      # Resolve "." to the package name in the current directory
      if [ "$PACKAGE" = "." ]; then
        if [ ! -f "package.json" ]; then
          echo "Error: No package.json found in current directory"
          exit 1
        fi
        PACKAGE=$(${pkgs.jq}/bin/jq -r '.name' package.json)
        if [ -z "$PACKAGE" ] || [ "$PACKAGE" = "null" ]; then
          echo "Error: Could not read package name from package.json"
          exit 1
        fi
      fi

      # Walk up from PWD looking for rush.json
      DIR="$PWD"
      while [ "$DIR" != "/" ]; do
        if [ -f "$DIR/rush.json" ]; then
          RUSH_ROOT="$DIR"
          break
        fi
        DIR="$(dirname "$DIR")"
      done

      if [ -z "$RUSH_ROOT" ]; then
        echo "Error: Could not find rush.json in any parent directory"
        exit 1
      fi

      # Find the project folder from rush.json (strip JSONC comments and \r)
      PROJECT_FOLDER=$(${pkgs.perl}/bin/perl -0777 -pe 's|/\*.*?\*/||gs; s|^\s*//[^\n]*||gm; s|\r||g' "$RUSH_ROOT/rush.json" | ${pkgs.jq}/bin/jq -r --arg pkg "$PACKAGE" '.projects[] | select(.packageName == $pkg) | .projectFolder')

      if [ -z "$PROJECT_FOLDER" ]; then
        echo "Error: Package '$PACKAGE' not found in rush.json"
        exit 1
      fi

      # Strip scope from package name: @kx/data-manager -> data-manager
      SHORT_NAME="''${PACKAGE##*/}"

      LOGS_DIR="$RUSH_ROOT/$PROJECT_FOLDER/rush-logs"
      LOG_PATH="$LOGS_DIR/$SHORT_NAME._phase_$PHASE.log"

      if [ -f "$LOG_PATH" ]; then
        exec ${pkgs.bat}/bin/bat "$LOG_PATH"
      fi

      # Sharded: collect shard logs sorted numerically by shard index.
      SHARD_PREFIX="$SHORT_NAME._phase_''${PHASE}_shard_"
      mapfile -t SHARDS < <(
        ${pkgs.coreutils}/bin/ls -1 "$LOGS_DIR" 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep -E "^''${SHARD_PREFIX}[0-9]+\.log$" \
          | ${pkgs.gawk}/bin/awk -v p="$SHARD_PREFIX" '{ n=$0; sub("^"p,"",n); sub("\\.log$","",n); print n"\t"$0 }' \
          | ${pkgs.coreutils}/bin/sort -n -k1,1 \
          | ${pkgs.coreutils}/bin/cut -f2
      )

      if [ ''${#SHARDS[@]} -eq 0 ]; then
        echo "Error: Log file not found: $LOG_PATH"
        echo "       (and no shard logs matching ''${SHARD_PREFIX}<N>.log)"
        exit 1
      fi

      if [ ! -t 1 ]; then
        for f in "''${SHARDS[@]}"; do
          N="''${f#$SHARD_PREFIX}"
          N="''${N%.log}"
          echo "===== shard $N ====="
          ${pkgs.coreutils}/bin/cat "$LOGS_DIR/$f"
          echo
        done
        exit 0
      fi

      printf '%s\n' "''${SHARDS[@]}" \
        | ${pkgs.fzf}/bin/fzf \
            --preview "${pkgs.bat}/bin/bat --color=always --style=plain \"$LOGS_DIR\"/{}" \
            --preview-window=right:85% \
            --prompt="shard> " \
            --disabled \
            --bind 'ctrl-g:preview-bottom' \
            --bind 'g:preview-top' \
            --bind 'G:preview-bottom' \
            --bind 'ctrl-d:preview-half-page-down' \
            --bind 'ctrl-u:preview-half-page-up' \
            --bind 'ctrl-f:preview-page-down' \
            --bind 'ctrl-b:preview-page-up'
    '')
(pkgs.writeScriptBin "rush-pnpm" ''
      #!/usr/bin/env bash
      set -e
      DIR="$PWD"
      while [ "$DIR" != "/" ]; do
        [ -f "$DIR/common/scripts/install-run-rush-pnpm.js" ] && exec node "$DIR/common/scripts/install-run-rush-pnpm.js" "$@"
        DIR="$(dirname "$DIR")"
      done
      echo "Error: Could not find install-run-rush-pnpm.js in any parent directory" >&2
      exit 1
    '')
    (pkgs.writeScriptBin "op-cached-daemon" ''
      #!/usr/bin/env ${pkgs.python313}/bin/python3
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
    '')
    (pkgs.writeScriptBin "op-cached" ''
      #!/usr/bin/env ${pkgs.python313}/bin/python3
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
    '')
    (pkgs.writeScriptBin "bk" ''
      #!/usr/bin/env bash
      set -e
      export BUILDKITE_ORGANIZATION_SLUG="koordinates"
      export BUILDKITE_API_TOKEN="$(op-cached read --account koordinates.1password.com "op://Employee/buildkite-api-token/api-token")"
      exec ${pkgs.buildkite-cli}/bin/bk "$@"
    '')
    (pkgs.writeScriptBin "sentry" ''
      #!/usr/bin/env bash
      set -e
      # The token is for Koordinates' self-hosted Sentry; an env token carries
      # no host, so pin it here (otherwise the CLI assumes sentry.io and rejects
      # the matching .sentryclirc).
      export SENTRY_URL=https://sentry-live2.kx.gd
      # SENTRY_FORCE_ENV_TOKEN makes the injected token win over any stored
      # OAuth login, so 1Password is the single source of truth (like bk).
      export SENTRY_FORCE_ENV_TOKEN=1
      export SENTRY_AUTH_TOKEN="$(op-cached read --account koordinates.1password.com "op://Employee/sentry-api-token/api-token")"
      exec ${unstable-pkgs.sentry}/bin/sentry "$@"
    '')
    (pkgs.writeScriptBin "autosquash-branch" ''
      #!/usr/bin/env bash
      set -e

      CURRENT=$(${pkgs.git}/bin/git rev-parse --abbrev-ref HEAD)
      if [ "$CURRENT" = "HEAD" ]; then
        echo "Error: detached HEAD state, cannot determine current branch" >&2
        exit 1
      fi

      # Find the nearest parent branch: the local branch whose tip is an
      # ancestor of HEAD with the fewest commits in between.
      BEST_BRANCH=""
      BEST_COUNT=""

      while IFS= read -r branch; do
        [ "$branch" = "$CURRENT" ] && continue

        if ${pkgs.git}/bin/git merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
          COUNT=$(${pkgs.git}/bin/git rev-list --count "$branch..HEAD")
          if [ -z "$BEST_COUNT" ] || [ "$COUNT" -lt "$BEST_COUNT" ]; then
            BEST_COUNT="$COUNT"
            BEST_BRANCH="$branch"
          fi
        fi
      done < <(${pkgs.git}/bin/git branch --format='%(refname:short)')

      if [ -z "$BEST_BRANCH" ]; then
        echo "Error: could not find a parent branch for '$CURRENT'" >&2
        exit 1
      fi

      echo "Rebasing $CURRENT onto $BEST_BRANCH ($BEST_COUNT commits)"
      exec ${pkgs.git}/bin/git rebase -i --autosquash "$BEST_BRANCH"
    '')
    (pkgs.writeScriptBin "wt-cgroup-status" ''
      #!/usr/bin/env bash
      # wt-cgroup-status — snapshot (or --watch) of the worktrees.slice cgroup
      # budget: per-bucket CPU% / memory / tasks / CPU-pressure, plus the pool total
      # against its caps.
      #
      # Reads the cgroup v2 files directly (works even where systemd-cgtop prints "-"
      # for the CPU column of transient scopes) and un-escapes slice names back to
      # readable worktree names.
      #
      # CPU% is cgtop-style: 100% == one core. The pool cap of 1200% == 12 cores.
      #
      # Usage:
      #   wt-cgroup-status            one-shot snapshot
      #   wt-cgroup-status -w [SECS]  refresh every SECS seconds (default 2)
      #
      # Env: WT_CG_SAMPLE=<secs> — gap between the two CPU samples (default 1).
      set -u

      awk=${pkgs.gawk}/bin/awk
      sed=${pkgs.gnused}/bin/sed
      cat=${pkgs.coreutils}/bin/cat
      id=${pkgs.coreutils}/bin/id
      date=${pkgs.coreutils}/bin/date
      sleep=${pkgs.coreutils}/bin/sleep
      numfmt=${pkgs.coreutils}/bin/numfmt
      basename=${pkgs.coreutils}/bin/basename

      U=$($id -u)
      POOL="/sys/fs/cgroup/user.slice/user-$U.slice/user@$U.service/worktrees.slice"
      SAMPLE="''${WT_CG_SAMPLE:-1}"

      watch=0; interval=2
      case "''${1:-}" in
        -w|--watch) watch=1; [ -n "''${2:-}" ] && interval="$2" ;;
        -h|--help) $sed -n '2,16p' "$0"; exit 0 ;;
      esac

      if [ ! -d "$POOL" ]; then
        echo "worktrees.slice pool is not active yet."
        echo "It materializes on the first heavy command the hook wraps (or the first"
        echo "daemon started with CLAUDE_WORKTREE_CGROUP set). Nothing to show."
        exit 1
      fi

      unesc()   { local s="$1"; printf '%s' "''${s//\\x2d/-}"; }
      human()   { $numfmt --to=iec --suffix=B "''${1:-0}" 2>/dev/null || printf '%sB' "''${1:-0}"; }
      cpuusec() { $awk '/^usage_usec/{print $2}' "$1/cpu.stat" 2>/dev/null || echo 0; }
      psi10()   { $awk -F'[= ]' '/^some/{print $3}' "$1/cpu.pressure"    2>/dev/null || echo "-"; }
      mpsi10()  { $awk -F'[= ]' '/^some/{print $3}' "$1/memory.pressure" 2>/dev/null || echo "-"; }

      snapshot() {
        local quota period cap mhigh mhigh_h
        read -r quota period < "$POOL/cpu.max"
        if [ "$quota" = "max" ]; then cap="unlimited"; else cap="$(( quota * 100 / period ))%"; fi
        mhigh=$($cat "$POOL/memory.high" 2>/dev/null)
        if [ "$mhigh" = "max" ]; then mhigh_h="unlimited"; else mhigh_h=$(human "$mhigh"); fi

        # First CPU sample for the pool and every bucket.
        local d
        local -A u0
        u0[__pool__]=$(cpuusec "$POOL")
        local dirs=()
        for d in "$POOL"/*/; do [ -d "$d" ] || continue; dirs+=("$d"); u0["$d"]=$(cpuusec "$d"); done
        $sleep "$SAMPLE"

        # Pool line (second sample).
        local u1 pct pmem
        u1=$(cpuusec "$POOL"); pmem=$($cat "$POOL/memory.current" 2>/dev/null)
        pct=$(( (u1 - u0[__pool__]) / 10000 / SAMPLE ))
        printf '  POOL  %-24s  CPU %5s%% / %-9s  mem %9s / %-9s  psi cpu:%s mem:%s\n' \
          "worktrees.slice" "$pct" "$cap" "$(human "$pmem")" "$mhigh_h" "$(psi10 "$POOL")" "$(mpsi10 "$POOL")"
        printf '  %s\n' "-------------------------------------------------------------------------------"
        printf '  %-40s %7s %11s %6s %9s\n' "BUCKET" "CPU%" "MEM" "TASKS" "PSI(cpu)"

        if [ "''${#dirs[@]}" -eq 0 ]; then
          printf '  (no active buckets)\n'
          return
        fi
        for d in "''${dirs[@]}"; do
          local b u1b pctb mem tasks
          b=$($basename "$d"); b=''${b%.slice}; b=''${b#worktrees-}
          u1b=$(cpuusec "$d")
          pctb=$(( (u1b - ''${u0[$d]:-0}) / 10000 / SAMPLE ))
          mem=$($cat "$d/memory.current" 2>/dev/null)
          tasks=$($cat "$d/pids.current" 2>/dev/null || echo "?")
          printf '  %-40.40s %6s%% %11s %6s %9s\n' "$(unesc "$b")" "$pctb" "$(human "$mem")" "$tasks" "$(psi10 "$d")"
        done
      }

      if [ "$watch" = 1 ]; then
        while :; do
          clear 2>/dev/null || printf '\n\n'
          printf 'worktrees.slice cgroup budget — %s (refresh %ss · ctrl-c to quit)\n\n' \
            "$($date +%T 2>/dev/null || echo now)" "$interval"
          snapshot
          $sleep "$interval"
        done
      else
        snapshot
      fi
    '')
    (pkgs.writeScriptBin "wt-cgroup-i3status" ''
      #!/usr/bin/env ${pkgs.python313}/bin/python3
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

      I3STATUS = "${pkgs.i3status}/bin/i3status"

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
              [I3STATUS, "-c", "${i3statusConf}"],
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
    '')
    (pkgs.writeScriptBin "claude-agents" ''
      #!/usr/bin/env bash
      # claude-agents -- run `claude agents` inside the worktrees.slice cgroup
      # pool so the background-agent fleet shares the same 12-core / 16 GiB budget
      # as worktree builds. It lands in a dedicated leaf child slice
      # (worktrees-agents.slice) that takes one equal-weight share of the pool and
      # shows up as the "agents" bucket in wt-cgroup-status; every process the
      # agent view dispatches inherits that cgroup. cgroup v2 forbids processes in
      # an inner slice that has children, hence a child slice rather than the pool
      # root. No-ops gracefully to a direct run if the pool isn't active.
      set -u

      claude=${unstable-small-pkgs.claude-code}/bin/claude
      id=${pkgs.coreutils}/bin/id
      systemd_run=${pkgs.systemd}/bin/systemd-run

      u=$($id -u)
      pool="/sys/fs/cgroup/user.slice/user-$u.slice/user@$u.service/worktrees.slice"

      if [ -d "$pool" ]; then
        exec "$systemd_run" --user --scope --quiet --collect \
          --slice=worktrees-agents.slice \
          --description="claude agents (worktrees pool)" \
          -- "$claude" agents "$@"
      fi

      exec "$claude" agents "$@"
    '')
  ];
}
