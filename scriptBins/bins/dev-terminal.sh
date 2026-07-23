until tmux has-session -t kawaka 2>/dev/null; do
  sleep 0.2
done
exec tmux attach-session -t kawaka
