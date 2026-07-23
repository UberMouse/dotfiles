CURRENT=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT" = "HEAD" ]; then
  echo "Error: detached HEAD state, cannot determine current branch" >&2
  exit 1
fi

# Find the nearest parent branch: the local branch whose tip is an
# ancestor of HEAD with the fewest commits in between.
BEST_BRANCH=""
BEST_COUNT=""

while IFS= read -r branch; do
  [ "$branch" = "$CURRENT" ] && continue

  if git merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
    COUNT=$(git rev-list --count "$branch..HEAD")
    if [ -z "$BEST_COUNT" ] || [ "$COUNT" -lt "$BEST_COUNT" ]; then
      BEST_COUNT="$COUNT"
      BEST_BRANCH="$branch"
    fi
  fi
done < <(git branch --format='%(refname:short)')

if [ -z "$BEST_BRANCH" ]; then
  echo "Error: could not find a parent branch for '$CURRENT'" >&2
  exit 1
fi

echo "Rebasing $CURRENT onto $BEST_BRANCH ($BEST_COUNT commits)"
exec git rebase -i --autosquash "$BEST_BRANCH"
