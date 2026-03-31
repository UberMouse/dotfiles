{ pkgs, ... }:

{
  home.packages = [
    (pkgs.writeScriptBin "koordinates-dev-protocol" ''
      #!/usr/bin/env bash
      curl -X POST -H 'Content-Type: application/json' -d "{\"url\": \"$1\"}" http://localhost:7281
    '')
    (pkgs.writeScriptBin "scratch-terminal" ''
      #!/usr/bin/env bash
      set -e

      # Find the first existing tmux session
      MAIN_SESSION=$(${pkgs.tmux}/bin/tmux list-sessions -F '#{session_name}' 2>/dev/null | head -1)

      if [ -z "$MAIN_SESSION" ]; then
        # No tmux session exists yet — create one with the kawaka windows
        ${pkgs.tmux}/bin/tmux new-session -d -s main -n kawaka -c "$HOME/code/kawaka"
        ${pkgs.tmux}/bin/tmux new-window -t main -n kawaka2 -c "$HOME/code/kawaka2"
        ${pkgs.tmux}/bin/tmux new-window -t main -n kawaka3 -c "$HOME/code/kawaka3"
        MAIN_SESSION="main"
      else
        # Session exists — create kawaka windows if they don't already exist
        ${pkgs.tmux}/bin/tmux has-session -t "$MAIN_SESSION:kawaka" 2>/dev/null || \
          ${pkgs.tmux}/bin/tmux new-window -t "$MAIN_SESSION" -n kawaka -c "$HOME/code/kawaka"
        ${pkgs.tmux}/bin/tmux has-session -t "$MAIN_SESSION:kawaka2" 2>/dev/null || \
          ${pkgs.tmux}/bin/tmux new-window -t "$MAIN_SESSION" -n kawaka2 -c "$HOME/code/kawaka2"
        ${pkgs.tmux}/bin/tmux has-session -t "$MAIN_SESSION:kawaka3" 2>/dev/null || \
          ${pkgs.tmux}/bin/tmux new-window -t "$MAIN_SESSION" -n kawaka3 -c "$HOME/code/kawaka3"
      fi

      # Create a grouped session that shares windows with the main session
      # but allows independent window selection
      ${pkgs.tmux}/bin/tmux new-session -d -t "$MAIN_SESSION" -s scratch 2>/dev/null || true

      # Select the kawaka window and attach
      ${pkgs.tmux}/bin/tmux select-window -t scratch:kawaka
      exec ${pkgs.tmux}/bin/tmux attach-session -t scratch
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

      LOG_PATH="$RUSH_ROOT/$PROJECT_FOLDER/rush-logs/$SHORT_NAME._phase_$PHASE.log"

      if [ ! -f "$LOG_PATH" ]; then
        echo "Error: Log file not found: $LOG_PATH"
        exit 1
      fi

      ${pkgs.bat}/bin/bat "$LOG_PATH"
    '')
    (pkgs.writeScriptBin "rush" ''
      #!/usr/bin/env bash
      set -e
      DIR="$PWD"
      while [ "$DIR" != "/" ]; do
        [ -f "$DIR/common/scripts/install-run-rush.js" ] && exec node "$DIR/common/scripts/install-run-rush.js" "$@"
        DIR="$(dirname "$DIR")"
      done
      echo "Error: Could not find install-run-rush.js in any parent directory" >&2
      exit 1
    '')
    (pkgs.writeScriptBin "rushx" ''
      #!/usr/bin/env bash
      set -e
      DIR="$PWD"
      while [ "$DIR" != "/" ]; do
        [ -f "$DIR/common/scripts/install-run-rushx.js" ] && exec node "$DIR/common/scripts/install-run-rushx.js" "$@"
        DIR="$(dirname "$DIR")"
      done
      echo "Error: Could not find install-run-rushx.js in any parent directory" >&2
      exit 1
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
  ];
}
