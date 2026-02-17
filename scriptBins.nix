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
        echo "Example: rush-logs @kx/data-manager test-storybook"
        exit 1
      fi

      PACKAGE="$1"
      PHASE="$2"

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
  ];
}
