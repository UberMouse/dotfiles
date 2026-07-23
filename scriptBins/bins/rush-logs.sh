if [ $# -lt 2 ]; then
  echo "Usage: rush-logs <package-name> <phase-name>"
  echo "  Use '.' as package-name for the package in the current directory"
  echo "Example: rush-logs @kx/data-manager test-storybook"
  exit 1
fi

PACKAGE="$1"
PHASE="$2"

# Resolve "." to the package name in the current directory
if [ "$PACKAGE" = "." ]; then
  if [ ! -f "package.json" ]; then
    echo "Error: No package.json found in current directory"
    exit 1
  fi
  PACKAGE=$(jq -r '.name' package.json)
  if [ -z "$PACKAGE" ] || [ "$PACKAGE" = "null" ]; then
    echo "Error: Could not read package name from package.json"
    exit 1
  fi
fi

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
PROJECT_FOLDER=$(perl -0777 -pe 's|/\*.*?\*/||gs; s|^\s*//[^\n]*||gm; s|\r||g' "$RUSH_ROOT/rush.json" | jq -r --arg pkg "$PACKAGE" '.projects[] | select(.packageName == $pkg) | .projectFolder')

if [ -z "$PROJECT_FOLDER" ]; then
  echo "Error: Package '$PACKAGE' not found in rush.json"
  exit 1
fi

# Strip scope from package name: @kx/data-manager -> data-manager
SHORT_NAME="${PACKAGE##*/}"

LOGS_DIR="$RUSH_ROOT/$PROJECT_FOLDER/rush-logs"
LOG_PATH="$LOGS_DIR/$SHORT_NAME._phase_$PHASE.log"

if [ -f "$LOG_PATH" ]; then
  exec bat "$LOG_PATH"
fi

# Sharded: collect shard logs sorted numerically by shard index.
SHARD_PREFIX="$SHORT_NAME._phase_${PHASE}_shard_"
mapfile -t SHARDS < <(
  # shellcheck disable=SC2010  # shard log names are ours; sorted numerically below
  ls -1 "$LOGS_DIR" 2>/dev/null \
    | grep -E "^${SHARD_PREFIX}[0-9]+\.log$" \
    | awk -v p="$SHARD_PREFIX" '{ n=$0; sub("^"p,"",n); sub("\\.log$","",n); print n"\t"$0 }' \
    | sort -n -k1,1 \
    | cut -f2
)

if [ "${#SHARDS[@]}" -eq 0 ]; then
  echo "Error: Log file not found: $LOG_PATH"
  echo "       (and no shard logs matching ${SHARD_PREFIX}<N>.log)"
  exit 1
fi

if [ ! -t 1 ]; then
  for f in "${SHARDS[@]}"; do
    N="${f#"$SHARD_PREFIX"}"
    N="${N%.log}"
    echo "===== shard $N ====="
    cat "$LOGS_DIR/$f"
    echo
  done
  exit 0
fi

printf '%s\n' "${SHARDS[@]}" \
  | fzf \
      --preview "bat --color=always --style=plain \"$LOGS_DIR\"/{}" \
      --preview-window=right:85% \
      --prompt="shard> " \
      --disabled \
      --bind 'ctrl-g:preview-bottom' \
      --bind 'g:preview-top' \
      --bind 'G:preview-bottom' \
      --bind 'ctrl-d:preview-half-page-down' \
      --bind 'ctrl-u:preview-half-page-up' \
      --bind 'ctrl-f:preview-page-down' \
      --bind 'ctrl-b:preview-page-up'
