DIR="$PWD"
while [ "$DIR" != "/" ]; do
  [ -f "$DIR/common/scripts/install-run-rush-pnpm.js" ] && exec node "$DIR/common/scripts/install-run-rush-pnpm.js" "$@"
  DIR="$(dirname "$DIR")"
done
echo "Error: Could not find install-run-rush-pnpm.js in any parent directory" >&2
exit 1
