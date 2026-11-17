---
name: plannotator
version_check: gh api repos/backnotprop/plannotator/releases/latest --jq '.tag_name | ltrimstr("v")'
version_file: packages/plannotator/package.nix
changelog_github: backnotprop/plannotator
---

# Update Process

Built from source (so `patches/` can customise it), not upstream's release
binary. A bump moves two hashes: the source tarball and the `node_modules`
fixed-output derivation.

1. Bump version + both hashes in one step:
   ```bash
   nix run nixpkgs#nix-update -- --flake --version=${VERSION} --subpackage node_modules plannotator
   ```

2. Verify in isolation (the derivation runs `plannotator --version` as an
   install check):
   ```bash
   nix build --no-link .#plannotator
   ```
   - **A patch fails to apply** (`Hunk #1 FAILED` in the patch phase):
     rebase the patches onto the new tag (see "Rebasing" below), then rebuild.
     Don't skip the bump because of it, and don't drop a patch to make it
     apply.
   - **The build itself fails**: diff upstream's
     `.github/workflows/release.yml` between the old and new tag. The
     derivation's buildPhase mirrors its "Build UI" and "Compile binaries"
     steps, and its Bun pin should equal unstable's `bun`.

3. Update the Claude Code plugin (not flake-managed; touches `~/.claude/plugins/`):
   ```bash
   claude plugin update plannotator@plannotator
   ```

# Patches

`patches/*.patch` are applied in filename order to the source of the pinned
tag. They are `git format-patch` output, so the commit message is the patch's
documentation: say what it changes and why.

## Making or editing a patch

```bash
V=$(nix eval --raw .#plannotator.version)
W=$(mktemp -d)/plannotator
git clone --branch "v$V" https://github.com/backnotprop/plannotator "$W"
cd "$W" && git switch -c local
setopt null_glob; p=(~/dotfiles/packages/plannotator/patches/*.patch); (( $#p )) && git am "${p[@]}"
# ... edit, `git commit` (one commit per patch) ...
rm -f ~/dotfiles/packages/plannotator/patches/*.patch
git format-patch "v$V" -o ~/dotfiles/packages/plannotator/patches/
```

To try a change before it's packaged, run it straight from the checkout:
`bun install && bun run --cwd apps/hook dev` for the UI (see upstream's
`CLAUDE.md`), or rebuild the package with `nix build .#plannotator`.

A patch that touches any `package.json` or `bun.lock` must ALSO be applied
in the `node_modules` derivation (add `patches` to it in `package.nix`) and
its hash refreshed. That derivation deliberately gets the unpatched source,
so a dependency change made only by a patch would build against the old tree.

The guides.show viewer pin is built from the UNPATCHED source (`viewerPin`
in `package.nix`), so patches never move it. The other side of that: an
exported guide (Download portable guide, share links) shows upstream's
viewer, not our patched one. The in-app Guide view is ours.

## Current patches

- `0001` un-holds the Inbox's Code review and Shape switches (#2588's
  context notes are gated on Code review). Upstream deletes `switchesHeld`
  at 0.29, so when this patch stops applying, check the switches show
  without it and delete the patch rather than rebasing it.
- `0002` turns on upstream's `fitFileHeights` in the review app's Guide
  view (#2643): each file's box as tall as its diff, not a 620px scroller.
  Upstream may adopt it or replace the 620px cap; check on rebase.
- `0003` scrolls the Inbox's review back to the top when a chapter is ticked
  Reviewed (the tick folds it, stranding the view). ReviewPane only, through
  its own `toChapter(null)`; un-ticking stays put. Carries its own DOM test
  in `reviewPaneGuide.test.tsx`.

## Rebasing onto a new tag

Same checkout as above, with the patches applied on the OLD tag. Then:

```bash
git fetch origin tag "v$NEW" && git rebase --onto "v$NEW" "v$OLD" local
# resolve conflicts, `git rebase --continue`
rm -f ~/dotfiles/packages/plannotator/patches/*.patch
git format-patch "v$NEW" -o ~/dotfiles/packages/plannotator/patches/
```
