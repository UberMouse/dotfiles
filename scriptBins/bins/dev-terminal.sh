# dev-terminal -- attach to the `kawaka` tmux session once it exists.
#
# The session is CREATED by scratch-terminal (i3 startup runs both: the
# scratchpad terminal builds the sessions, this one attaches to the main one).
# So this wait is for scratch-terminal to finish its setup -- normally well
# under a second.
#
# BOUNDED, not forever: if scratch-terminal never ran or died mid-setup, an
# unbounded loop leaves a blank terminal hanging with no diagnostic (compare
# claude-agents.sh, which bounds the identical shape). 150 x 0.2s = 30s.
tries=0
until tmux has-session -t kawaka 2>/dev/null; do
  tries=$((tries + 1))
  if [ "$tries" -ge 150 ]; then
    echo "dev-terminal: tmux session 'kawaka' never appeared (does scratch-terminal run at i3 startup?)" >&2
    exit 1
  fi
  sleep 0.2
done
exec tmux attach-session -t kawaka
