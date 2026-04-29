---
name: weekly-update
description: Use when performing the weekly system update - updating claude-code, plannotator, ccstatusline, nix flake inputs, and rebuilding the NixOS system
---

# Weekly Update

Orchestrates the recurring weekly update: claude-code package, plannotator package, ccstatusline package, flake inputs, and system rebuild.

## Process

### 1. Check Latest Claude Code Version

```bash
npm view @anthropic-ai/claude-code version
```

Compare against the current version in `packages/claude-code/package.nix`. If already at the latest version, skip to step 4.

### 2. Update Claude Code

Invoke the `update-claude-code` skill via the Skill tool, passing the target version. Follow that skill's full process including the npmDepsHash build-fail-extract cycle — handle it automatically without prompting the user.

### 3. Summarize Claude Code Changes

If claude-code was updated in step 2, summarize the changelog entries between the old and new versions. The tarball extracted to `/tmp/claude-code-update/` in the `update-claude-code` skill contains `CHANGELOG.md`.

Read `/tmp/claude-code-update/CHANGELOG.md`, extract the entries for every version strictly greater than the old version and up to and including the new version, and present a concise summary to the user before continuing. Group by version with the most notable changes highlighted.

Skip this step if claude-code was not updated.

### 4. Check Latest Plannotator Version

```bash
curl -fsSL "https://api.github.com/repos/backnotprop/plannotator/releases/latest" | grep '"tag_name"' | cut -d'"' -f4
```

Compare against the current version in `packages/plannotator/package.nix` (the `version` field, noting the GitHub tag has a `v` prefix). If already at the latest version, skip to step 6.

### 5. Update Plannotator

Get the new binary hash:

```bash
nix-prefetch-url "https://github.com/backnotprop/plannotator/releases/download/v${VERSION}/plannotator-linux-x64"
nix hash convert --hash-algo sha256 --to sri <HASH_FROM_ABOVE>
```

Edit `packages/plannotator/package.nix`:
- `version` → new version (without `v` prefix)
- `src.hash` → SRI hash from above

### 6. Check Latest ccstatusline Version

```bash
npm view ccstatusline version
```

Compare against the current version in `packages/ccstatusline/package.nix`. If already at the latest version, skip to step 8.

### 7. Update ccstatusline

Get the new tarball hash:

```bash
nix-prefetch-url --unpack "https://registry.npmjs.org/ccstatusline/-/ccstatusline-${VERSION}.tgz"
nix hash convert --hash-algo sha256 --to sri <HASH_FROM_ABOVE>
```

Edit `packages/ccstatusline/package.nix`:
- `version` → new version
- `src.hash` → SRI hash from above

### 8. Update Flake Inputs

```bash
cd ~/dotfiles && nix flake update
```

### 9. Rebuild System

```bash
sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10
```

This is also the verification step — if the build succeeds, everything is working.

### 10. Commit

Stage all changed files and commit with a summary message. Format:

```
weekly update: claude-code X.Y.Z → A.B.C, plannotator X.Y.Z → A.B.C, ccstatusline X.Y.Z → A.B.C, flake inputs
```

Omit any component that was already current:

```
weekly update: flake inputs
weekly update: claude-code X.Y.Z → A.B.C, flake inputs
weekly update: ccstatusline X.Y.Z → A.B.C, flake inputs
```

## Key Notes

- If claude-code is already at the latest version, skip straight to the plannotator check — don't treat it as an error.
- If plannotator is already at the latest version, skip straight to the ccstatusline check — don't treat it as an error.
- If ccstatusline is already at the latest version, skip straight to flake update — don't treat it as an error.
- The `nixos-rebuild switch` in step 9 serves as the final build. If claude-code was updated, the intermediate build in step 2 (to extract npmDepsHash) will have already failed and been retried as part of the update-claude-code skill.
