# koordinates-dev-protocol -- x-scheme-handler for koordinates:// links.
# Forwards the clicked URL to the local dev listener; wired up via the desktop
# entry + mimeApps in home.nix.

# 7281: the Koordinates dev-server's protocol-handler listener.
PORT=7281

if [ -z "${1:-}" ]; then
  echo "koordinates-dev-protocol: no URL argument (invoked outside the x-scheme-handler?)" >&2
  exit 2
fi

# -f so a dead listener yields a non-zero exit (visible in journalctl for the
# handler unit) instead of a silent no-op.
curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
  -d "{\"url\": \"$1\"}" "http://localhost:$PORT" \
  || echo "koordinates-dev-protocol: dev listener on :$PORT not responding" >&2
