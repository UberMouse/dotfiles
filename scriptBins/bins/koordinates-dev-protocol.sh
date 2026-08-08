# koordinates-dev-protocol -- x-scheme-handler for koordinates:// links.
# Forwards the clicked URL to the local dev listener; wired up via the desktop
# entry + mimeApps in home.nix.

# 7281: the Koordinates dev-server's protocol-handler listener.
PORT=7281

if [ -z "${1:-}" ]; then
  echo "koordinates-dev-protocol: no URL argument (invoked outside the x-scheme-handler?)" >&2
  exit 2
fi

# jq builds the body so the URL is JSON-escaped: $1 arrives from whatever the
# browser passed the x-scheme-handler, i.e. click-attacker-influenced -- a
# crafted link containing a quote must not be able to inject fields into the
# request the dev listener acts on.
#
# -f so a dead listener yields a non-zero exit (visible in journalctl for the
# handler unit) instead of a silent no-op.
jq -n --arg url "$1" '{url: $url}' \
  | curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
      -d @- "http://localhost:$PORT" \
  || {
    # The echo alone would make the script exit 0 (echo is the last command
    # and succeeds), silently un-delivering the promise above.
    echo "koordinates-dev-protocol: dev listener on :$PORT not responding" >&2
    exit 1
  }
