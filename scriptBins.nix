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
  ];
}
