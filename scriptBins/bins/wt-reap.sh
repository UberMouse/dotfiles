# wt-reap -- delete agent worktrees that hold nothing worth keeping.
#
# WHY THIS EXISTS. On 2026-08-10 the root filesystem hit 100%. Nothing was
# broken: nix.gc had run that morning and freed 244.9 MiB. The store was not
# the problem and neither was the GC -- 79 worktrees under
# <repo>/.claude/worktrees/ held ~2.5G each of rush/pnpm node_modules, and
# their .direnv trees had planted 457 indirect GC roots in
# /nix/var/nix/gcroots/auto pinning essentially the whole live store. GC
# could not reclaim what was rooted, and no GC of any kind reclaims
# node_modules. Of those 79 worktrees, 70 had no commits beyond origin/HEAD
# and no uncommitted work: pure cost.
#
# AGE IS NOT THE SIGNAL. Every one of those 79 had been touched within 6
# days -- worktrees are created faster than any honest retention window, so a
# `--delete-older-than`-shaped rule fires on nothing exactly when it is most
# needed. The criterion is git state: a worktree whose branch adds no commits
# to the integration branch, and whose working tree adds no changes, contains
# by construction nothing that does not already exist in the repository.
#
# Removing the worktree also removes its .direnv, which makes the auto GC
# roots dangle, which lets the next nix-gc reclaim the store paths they held.
# That second-order effect is the larger half of the win and the reason this
# reaps whole worktrees rather than just evicting node_modules.
#
# DELETIONS DO NOT COUNT AS WORK. The overwhelmingly common dirty state here
# is a wholesale ` D` removal of the .quint/ tree (86-120 paths at a time,
# same shape in seven separate worktrees). Those files exist in the commit;
# deleting the worktree loses nothing. Modifications and new files DO count
# and always veto.
#
# The reaper is deliberately monotone: every check can only ever move a
# worktree from "reap" to "keep". There is no flag that overrides a veto,
# because the failure this guards against is silent and unrecoverable.

usage() {
  cat <<'EOF'
wt-reap [-n] [-y] [--no-size] [REPO...]

Delete worktrees that add no commits to the integration branch and carry no
uncommitted modifications or new files.

  -n, --dry-run       report the plan, delete nothing
  -y, --yes           delete without the confirmation prompt (timer mode)
      --no-size       skip the du pass (dry-run reports sizes by default)

Branches are deliberately left alone. They cost bytes, the worktrees cost
gigabytes, and a branch is the only trace left that a line of work existed.

With no REPO, scans $WT_REAP_ROOT (default ~/code) one level deep for git
repositories.

Env seams (tests): WT_REAP_ROOT, WT_REAP_PROC (default /proc).
EOF
}

dry_run=0
assume_yes=0
want_size=""
repos=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -n | --dry-run) dry_run=1 ;;
    -y | --yes) assume_yes=1 ;;
    --no-size) want_size=0 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      printf 'wt-reap: unknown option %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *) repos+=("$1") ;;
  esac
  shift
done

# Sizes are for a human reading a plan; the timer's output goes to the
# journal where nobody reads them, and the du pass over ~80 node_modules
# trees is by far the slowest thing here.
[ -n "$want_size" ] || want_size=$dry_run

PROC="${WT_REAP_PROC:-/proc}"
ROOT="${WT_REAP_ROOT:-$HOME/code}"

# The plan is carried as repo<TAB>worktree pairs, and the removal pass sorts
# them by path length through awk -F'\t'. Named rather than written as a
# literal tab: an invisible character is the one thing in this file a future
# edit can silently destroy, and destroying it splits every path on nothing.
TAB=$'\t'

# ---------------------------------------------------------------------------
# Live-process guard.
#
# NOT one of the qualifying criteria -- it is a guard against deleting a
# directory that is in use RIGHT NOW. A worktree created minutes ago, with
# `rush install` still running in it, legitimately has no commits and no
# modifications: it passes every git test while being the single worst thing
# on the disk to delete. (Exactly today's kxai-propose-layer-attributes,
# created 10:04 and 2.7G by 10:06.) Collect every process cwd ONCE rather
# than re-walking /proc per worktree.
# ---------------------------------------------------------------------------
cwds=()
collect_cwds() {
  local p target
  for p in "$PROC"/[0-9]*; do
    target=$(readlink "$p/cwd" 2>/dev/null) || continue
    [ -n "$target" ] && cwds+=("$target")
  done
}

in_use() {
  local wt=$1 c
  for c in ${cwds[@]+"${cwds[@]}"}; do
    case "$c" in
      "$wt" | "$wt"/*) return 0 ;;
    esac
  done
  return 1
}

# ---------------------------------------------------------------------------
# The integration branch to measure against.
#
# origin/HEAD when the remote publishes it, else the conventional names, else
# nothing -- and "nothing" means SKIP THE REPO. A missing base ref must never
# degrade into comparing against an empty range, which would score every
# branch as having no unique commits and reap the lot.
# ---------------------------------------------------------------------------
base_ref() {
  local repo=$1 ref
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$ref" ]; then
    printf '%s\n' "$ref"
    return 0
  fi
  for ref in origin/master origin/main master main; do
    if git -C "$repo" rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
      printf '%s\n' "$ref"
      return 0
    fi
  done
  return 1
}

# A worktree is clean if every porcelain line is a deletion. Both the staged
# ("D ") and unstaged (" D") forms count; anything else -- modification,
# addition, untracked, rename, conflict -- vetoes.
#
# Remaining args are every worktree in the repo; the descendants of $wt are
# excluded by pathspec. A NESTED WORKTREE IS NOT DIRT: it registers against
# the same repository and is judged on its own merits, but to `git status` in
# the parent it is just an untracked directory, reported forever as `?? .claude/`.
# Without this exclusion no worktree that ever hosted a nested one could be
# reaped again -- a leak that surfaces only as "the reaper gradually stopped
# helping". kawaka happens to gitignore .claude/worktrees, which hides the
# bug there; the reaper must not depend on a downstream repo's .gitignore.
# The exclusion is surgical, not a blanket skip: a real untracked file beside
# the nested worktree still vetoes (asserted in the suite).
tree_is_clean() {
  local wt=$1
  shift
  local line other rel
  local specs=()
  for other in "$@"; do
    case "$other" in
      "$wt"/*)
        rel=${other#"$wt"/}
        specs+=(":(exclude)$rel")
        ;;
    esac
  done
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "D "* | " D"*) continue ;;
      *) return 1 ;;
    esac
  done < <(git -C "$wt" status --porcelain -- . ${specs[@]+"${specs[@]}"} 2>/dev/null)
  return 0
}

adds_no_commits() {
  local wt=$1 base=$2 n
  n=$(git -C "$wt" rev-list --count "$base"..HEAD 2>/dev/null) || return 1
  [ "$n" = "0" ]
}

# ---------------------------------------------------------------------------
# Per-repo pass.
# ---------------------------------------------------------------------------
total_reap=0
total_keep=0
plan=()

plan_repo() {
  local repo=$1 base wt line
  local worktrees=() reapable=() kept=()

  base=$(base_ref "$repo") || {
    printf 'wt-reap: %s: no integration ref (origin/HEAD, master, main) -- skipping\n' \
      "$repo" >&2
    return 0
  }

  # The main worktree is always listed first by `git worktree list`; it is
  # never a candidate.
  local first=1
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        if [ "$first" = 1 ]; then
          first=0
        else
          worktrees+=("${line#worktree }")
        fi
        ;;
    esac
  done < <(git -C "$repo" worktree list --porcelain 2>/dev/null)

  [ "${#worktrees[@]}" -gt 0 ] || return 0

  for wt in "${worktrees[@]}"; do
    if [ ! -d "$wt" ]; then
      # Registered but gone: `git worktree prune` at the end collects it.
      continue
    fi
    if in_use "$wt"; then
      kept+=("$wt")
      continue
    fi
    if adds_no_commits "$wt" "$base" && tree_is_clean "$wt" "${worktrees[@]}"; then
      reapable+=("$wt")
    else
      kept+=("$wt")
    fi
  done

  # ---------------------------------------------------------------------
  # Containment. Worktrees nest (measured three deep:
  # a/.claude/worktrees/b/.claude/worktrees/c), and every level registers
  # against the SAME repository. Removing a parent takes its children with
  # it on the filesystem regardless of what they hold, so a parent may only
  # be reaped if every worktree beneath it is itself reapable. Without this,
  # one kept child is destroyed by its disposable parent -- and git reports
  # nothing, because from git's side the child was merely pruned.
  # ---------------------------------------------------------------------
  local survivors=() k drop
  for wt in ${reapable[@]+"${reapable[@]}"}; do
    drop=0
    for k in ${kept[@]+"${kept[@]}"}; do
      case "$k" in
        "$wt"/*)
          drop=1
          break
          ;;
      esac
    done
    if [ "$drop" = 1 ]; then
      kept+=("$wt")
    else
      survivors+=("$wt")
    fi
  done

  total_keep=$((total_keep + ${#kept[@]}))
  for wt in ${survivors[@]+"${survivors[@]}"}; do
    plan+=("$repo$TAB$wt")
    total_reap=$((total_reap + 1))
  done
}

if [ "${#repos[@]}" -eq 0 ]; then
  for d in "$ROOT"/*; do
    [ -d "$d/.git" ] || [ -f "$d/.git" ] || continue
    repos+=("$d")
  done
fi

if [ "${#repos[@]}" -eq 0 ]; then
  printf 'wt-reap: no git repositories under %s\n' "$ROOT" >&2
  exit 0
fi

collect_cwds
for r in "${repos[@]}"; do
  plan_repo "$r"
done

if [ "$total_reap" = 0 ]; then
  printf 'wt-reap: nothing to reap (%d worktrees kept)\n' "$total_keep"
  exit 0
fi

printf 'wt-reap: %d worktree(s) to remove, %d kept\n\n' "$total_reap" "$total_keep"

reclaim=0
for entry in "${plan[@]}"; do
  wt=${entry#*"$TAB"}
  if [ "$want_size" = 1 ]; then
    sz=$(du -sx --block-size=1 "$wt" 2>/dev/null | cut -f1)
    [ -n "$sz" ] || sz=0
    reclaim=$((reclaim + sz))
    printf '  %8s  %s\n' "$(numfmt --to=iec "$sz")" "$wt"
  else
    printf '  %s\n' "$wt"
  fi
done

if [ "$want_size" = 1 ]; then
  printf '\n  total: %s\n' "$(numfmt --to=iec "$reclaim")"
  # The store paths their .direnv roots pinned are freed by the NEXT nix-gc,
  # not by this run -- the roots dangle immediately but nothing collects
  # them here. Say so, or the reported total reads as the whole win.
  printf '  (plus whatever the next nix-gc reclaims once their .direnv GC roots dangle)\n'
fi

if [ "$dry_run" = 1 ]; then
  printf '\ndry run -- nothing deleted\n'
  exit 0
fi

if [ "$assume_yes" != 1 ]; then
  printf '\nremove these %d worktree(s)? [y/N] ' "$total_reap"
  read -r reply
  case "$reply" in
    y | Y | yes | YES) ;;
    *)
      printf 'aborted\n'
      exit 1
      ;;
  esac
fi

# Deepest-first, so a nested worktree is deregistered by git before anything
# above it is unlinked from the filesystem.
failed=0
removed=0
while IFS= read -r entry; do
  repo=${entry%%"$TAB"*}
  wt=${entry#*"$TAB"}
  # --force because the pure-deletion dirty state above is still "dirty" to
  # git. It does NOT widen what gets reaped: the gate is the plan, which was
  # decided before any removal ran.
  if git -C "$repo" worktree remove --force "$wt" 2>/dev/null; then
    removed=$((removed + 1))
  elif rm -rf "$wt"; then
    # A worktree git refuses to remove (corrupt admin dir, submodule
    # leftovers) still has to go; prune below re-syncs the registration.
    removed=$((removed + 1))
  else
    printf 'wt-reap: failed to remove %s\n' "$wt" >&2
    failed=$((failed + 1))
  fi
done < <(printf '%s\n' "${plan[@]}" | awk -F'\t' '{print length($2)"\t"$0}' \
  | sort -rn | cut -f2-)

for r in "${repos[@]}"; do
  git -C "$r" worktree prune 2>/dev/null
done

printf 'wt-reap: removed %d worktree(s)' "$removed"
[ "$failed" -gt 0 ] && printf ', %d failed' "$failed"
printf '\n'
exit $((failed > 0))
