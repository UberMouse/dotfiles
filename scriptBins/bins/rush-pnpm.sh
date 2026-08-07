# `node` is deliberately NOT a runtimeInput (the project's own node must
# win -- see the inheritPath note in default.nix), so its absence is a real
# possibility and deserves better than a raw "command not found".
if ! command -v node >/dev/null 2>&1; then
  echo "Error: no 'node' on PATH (rush-pnpm runs the repo's install-run script with the ambient node)" >&2
  exit 1
fi
DIR="$PWD"
while [ "$DIR" != "/" ]; do
  [ -f "$DIR/common/scripts/install-run-rush-pnpm.js" ] && exec node "$DIR/common/scripts/install-run-rush-pnpm.js" "$@"
  DIR="$(dirname "$DIR")"
done
echo "Error: Could not find install-run-rush-pnpm.js in any parent directory" >&2
exit 1
