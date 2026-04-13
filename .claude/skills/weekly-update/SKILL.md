---
name: weekly-update
description: Use when performing the weekly system update - updating claude-code, plannotator, grackle, nix flake inputs, and rebuilding the NixOS system
---

# Weekly Update

Orchestrates the recurring weekly update: claude-code package, plannotator package, grackle container image, flake inputs, and system rebuild.

## Process

### 1. Check Latest Claude Code Version

```bash
npm view @anthropic-ai/claude-code version
```

Compare against the current version in `packages/claude-code/package.nix`. If already at the latest version, skip to step 3.

### 2. Update Claude Code

Invoke the `update-claude-code` skill via the Skill tool, passing the target version. Follow that skill's full process including the npmDepsHash build-fail-extract cycle — handle it automatically without prompting the user.

### 3. Check Latest Plannotator Version

```bash
curl -fsSL "https://api.github.com/repos/backnotprop/plannotator/releases/latest" | grep '"tag_name"' | cut -d'"' -f4
```

Compare against the current version in `packages/plannotator/package.nix` (the `version` field, noting the GitHub tag has a `v` prefix). If already at the latest version, skip to step 5.

### 4. Update Plannotator

Get the new binary hash:

```bash
nix-prefetch-url "https://github.com/backnotprop/plannotator/releases/download/v${VERSION}/plannotator-linux-x64"
nix hash convert --hash-algo sha256 --to sri <HASH_FROM_ABOVE>
```

Edit `packages/plannotator/package.nix`:
- `version` → new version (without `v` prefix)
- `src.hash` → SRI hash from above

### 5. Check Latest Grackle Nightly

```bash
TOKEN=$(curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:nick-pape/grackle:pull" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
curl -fsSL -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/nick-pape/grackle/tags/list" | python3 -c "import sys,json; tags=json.load(sys.stdin)['tags']; nightlies=[t for t in tags if t.startswith('nightly-')]; print(sorted(nightlies)[-1])"
```

Compare against the current image tag in `grackle.nix`. If already at the latest nightly, skip to step 7.

### 6. Update Grackle

Edit `grackle.nix` — update the image tag in the `image` field (e.g., `nightly-20260412` → `nightly-20260415`).

### 7. Update Flake Inputs

```bash
cd ~/dotfiles && nix flake update
```

### 8. Rebuild System

```bash
sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10
```

This is also the verification step — if the build succeeds, everything is working.

### 9. Commit

Stage all changed files and commit with a summary message. Format:

```
weekly update: claude-code X.Y.Z → A.B.C, plannotator X.Y.Z → A.B.C, grackle nightly-YYYYMMDD → nightly-YYYYMMDD, flake inputs
```

Omit any component that was already current:

```
weekly update: flake inputs
weekly update: claude-code X.Y.Z → A.B.C, flake inputs
weekly update: grackle nightly-YYYYMMDD → nightly-YYYYMMDD, flake inputs
```

## Temporary Workarounds

- **Cursor hash overlay (added 2026-04-13):** A `cursor-hash-fix` overlay was added to `flake.nix` to work around an upstream AppImage hash mismatch in nixpkgs-unstable-small for `code-cursor` 3.0.16. On the next weekly update, check if the build succeeds without it — if so, remove the `cursor-hash-fix` overlay and the reference to it in the `unstable-small-pkgs` overlays list.

## Key Notes

- If claude-code is already at the latest version, skip straight to the plannotator check — don't treat it as an error.
- If plannotator is already at the latest version, skip straight to the Grackle check — don't treat it as an error.
- If Grackle is already at the latest nightly, skip straight to flake update — don't treat it as an error.
- The `nixos-rebuild switch` in step 8 serves as the final build. If claude-code was updated, the intermediate build in step 2 (to extract npmDepsHash) will have already failed and been retried as part of the update-claude-code skill.
