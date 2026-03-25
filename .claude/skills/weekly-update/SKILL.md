---
name: weekly-update
description: Use when performing the weekly system update - updating claude-code, plannotator, nix flake inputs, and rebuilding the NixOS system
---

# Weekly Update

Orchestrates the recurring weekly update: claude-code package, plannotator package, flake inputs, and system rebuild.

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

### 5. Update Flake Inputs

```bash
cd ~/dotfiles && nix flake update
```

### 6. Rebuild System

```bash
sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10
```

This is also the verification step — if the build succeeds, everything is working.

### 7. Commit

Stage all changed files and commit with a summary message. Format:

```
weekly update: claude-code X.Y.Z → A.B.C, plannotator X.Y.Z → A.B.C, flake inputs
```

Omit any component that was already current:

```
weekly update: flake inputs
weekly update: claude-code X.Y.Z → A.B.C, flake inputs
weekly update: plannotator X.Y.Z → A.B.C, flake inputs
```

## Key Notes

- If claude-code is already at the latest version, skip straight to the plannotator check — don't treat it as an error.
- If plannotator is already at the latest version, skip straight to flake update — don't treat it as an error.
- The `nixos-rebuild switch` in step 6 serves as the final build. If claude-code was updated, the intermediate build in step 2 (to extract npmDepsHash) will have already failed and been retried as part of the update-claude-code skill.
