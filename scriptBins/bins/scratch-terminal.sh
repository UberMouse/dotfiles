# scratch-terminal -- build the standing tmux sessions and attach `scratch`.
#
# CREATES the `kawaka` session that dev-terminal waits on and attaches (i3
# startup runs both; dev-terminal polls for this one to finish its setup).
#
# Every kawaka pane dir goes through d() below: these are monorepo paths
# that move in restructures, and under errexit a `tmux split-window -c
# <missing dir>` used to kill the script MID-SETUP -- leaving a session
# that exists (so dev-terminal's guard passes) but is missing windows, with
# no message anywhere. A missing dir now warns and falls back to the repo
# root, so a reshuffle degrades to a noisy pane in the wrong dir instead of
# a silently truncated session.

KAWAKA="$HOME/code/kawaka"

d() {
  # Pane dir under the monorepo, or its root with a warning if it moved.
  if [ -d "$KAWAKA/$1" ]; then
    printf '%s' "$KAWAKA/$1"
  else
    echo "scratch-terminal: $KAWAKA/$1 is gone (monorepo restructure?) - pane opens at repo root" >&2
    printf '%s' "$KAWAKA"
  fi
}

# kawaka session: matai / map-viewer / rimu / scratch windows
if ! tmux has-session -t kawaka 2>/dev/null; then
  tmux new-session -d -s kawaka -n matai -c "$KAWAKA"
  tmux split-window -h -t kawaka:matai -c "$(d packages/apps/matai)"

  tmux new-window -t kawaka -n map-viewer -c "$KAWAKA"
  tmux split-window -h -t kawaka:map-viewer -c "$(d packages/embeds/map-viewer/core)"
  tmux split-window -v -t kawaka:map-viewer.1 -c "$(d packages/embeds/map-viewer/integration-tests)"
  tmux split-window -h -t kawaka:map-viewer.2 -c "$(d packages/embeds/map-viewer/integration-tests)"

  tmux new-window -t kawaka -n rimu -c "$KAWAKA"
  tmux split-window -h -t kawaka:rimu -c "$(d packages/apps/rimu/core)"
  tmux split-window -v -t kawaka:rimu.1 -c "$(d packages/apps/rimu)"

  tmux new-window -t kawaka -n scratch -c "$KAWAKA"
  tmux split-window -h -t kawaka:scratch -c "$(d packages/embeds/map-viewer/integration-tests)"

  tmux select-window -t kawaka:matai
fi

# code session: dotfiles / code windows
if ! tmux has-session -t code 2>/dev/null; then
  tmux new-session -d -s code -n dotfiles -c "$HOME/dotfiles"
  tmux split-window -h -t code:dotfiles -c "$HOME/dotfiles"
  tmux new-window -t code -n code -c "$HOME/code"
  tmux select-window -t code:dotfiles
fi

# main session: single kawaka window — scratch is a grouped view of it
if ! tmux has-session -t main 2>/dev/null; then
  tmux new-session -d -s main -n kawaka -c "$KAWAKA"
fi
tmux new-session -d -t main -s scratch 2>/dev/null || true

tmux select-window -t scratch:kawaka
exec tmux attach-session -t scratch
