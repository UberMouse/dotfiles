---
name: weekly-update
description: Use when performing the weekly system update - updating claude-code to latest npm version, updating nix flake inputs, and rebuilding the NixOS system
---

# Weekly Update

Orchestrates the recurring weekly update: claude-code package, flake inputs, and system rebuild.

## Process

### 1. Check Latest Claude Code Version

```bash
npm view @anthropic-ai/claude-code version
```

Compare against the current version in `packages/claude-code/package.nix`. If already at the latest version, skip to step 3.

### 2. Update Claude Code

Invoke the `update-claude-code` skill via the Skill tool, passing the target version. Follow that skill's full process including the npmDepsHash build-fail-extract cycle — handle it automatically without prompting the user.

### 3. Update Flake Inputs

```bash
cd ~/dotfiles && nix flake update
```

### 4. Rebuild System

```bash
sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10
```

This is also the verification step — if the build succeeds, everything is working.

### 5. Commit

Stage all changed files and commit with a summary message. Format:

```
weekly update: claude-code X.Y.Z → A.B.C, flake inputs
```

If claude-code was already current, omit the version change from the message:

```
weekly update: flake inputs
```

## Key Notes

- If claude-code is already at the latest version, skip straight to flake update — don't treat it as an error.
- The `nixos-rebuild switch` in step 4 serves as the final build. If claude-code was updated, the intermediate build in step 2 (to extract npmDepsHash) will have already failed and been retried as part of the update-claude-code skill.
