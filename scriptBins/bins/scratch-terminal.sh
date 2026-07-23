# kawaka session: matai / map-viewer / rimu / scratch windows
if ! tmux has-session -t kawaka 2>/dev/null; then
  tmux new-session -d -s kawaka -n matai -c "$HOME/code/kawaka"
  tmux split-window -h -t kawaka:matai -c "$HOME/code/kawaka/packages/apps/matai"

  tmux new-window -t kawaka -n map-viewer -c "$HOME/code/kawaka"
  tmux split-window -h -t kawaka:map-viewer -c "$HOME/code/kawaka/packages/embeds/map-viewer/core"
  tmux split-window -v -t kawaka:map-viewer.1 -c "$HOME/code/kawaka/packages/embeds/map-viewer/integration-tests"
  tmux split-window -h -t kawaka:map-viewer.2 -c "$HOME/code/kawaka/packages/embeds/map-viewer/integration-tests"

  tmux new-window -t kawaka -n rimu -c "$HOME/code/kawaka"
  tmux split-window -h -t kawaka:rimu -c "$HOME/code/kawaka/packages/apps/rimu/core"
  tmux split-window -v -t kawaka:rimu.1 -c "$HOME/code/kawaka/packages/apps/rimu"

  tmux new-window -t kawaka -n scratch -c "$HOME/code/kawaka"
  tmux split-window -h -t kawaka:scratch -c "$HOME/code/kawaka/packages/embeds/map-viewer/integration-tests"

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
  tmux new-session -d -s main -n kawaka -c "$HOME/code/kawaka"
fi
tmux new-session -d -t main -s scratch 2>/dev/null || true

tmux select-window -t scratch:kawaka
exec tmux attach-session -t scratch
