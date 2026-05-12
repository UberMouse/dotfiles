# Weekly Update Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace hardcoded package list in weekly-update skill with discoverable UPDATE.md spec files

**Architecture:** Each package gets an UPDATE.md with YAML frontmatter (version_check, version_file, changelog source) and markdown body (update instructions). The skill discovers these files and processes them in order.

**Tech Stack:** Markdown with YAML frontmatter, Bash commands, Nix

---

## Task 1: Create claude-code UPDATE.md

**Files:**
- Create: `packages/claude-code/UPDATE.md`

**Step 1: Create the UPDATE.md spec**

```markdown
---
name: claude-code
version_check: npm view @anthropic-ai/claude-code version
version_file: packages/claude-code/package.nix
changelog_url: https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md
---

# Update Process

1. Get source hash:
   ```bash
   nix-prefetch-url "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${VERSION}/linux-x64/claude"
   nix hash convert --hash-algo sha256 --to sri <HASH_FROM_ABOVE>
   ```

2. Edit `packages/claude-code/package.nix`:
   - `version` → new version
   - `src.hash` → SRI hash from step 1
```

**Step 2: Commit**

```bash
git add packages/claude-code/UPDATE.md
git commit -m "feat(autoupdate): add claude-code UPDATE.md spec"
```

---

## Task 2: Create plannotator UPDATE.md

**Files:**
- Create: `packages/plannotator/UPDATE.md`

**Step 1: Create the UPDATE.md spec**

```markdown
---
name: plannotator
version_check: curl -fsSL "https://api.github.com/repos/backnotprop/plannotator/releases/latest" | grep '"tag_name"' | cut -d'"' -f4 | sed 's/^v//'
version_file: packages/plannotator/package.nix
changelog_github: backnotprop/plannotator
---

# Update Process

1. Get binary hash:
   ```bash
   nix-prefetch-url "https://github.com/backnotprop/plannotator/releases/download/v${VERSION}/plannotator-linux-x64"
   nix hash convert --hash-algo sha256 --to sri <HASH_FROM_ABOVE>
   ```

2. Edit `packages/plannotator/package.nix`:
   - `version` → new version (without `v` prefix)
   - `src.hash` → SRI hash from step 1
```

**Step 2: Commit**

```bash
git add packages/plannotator/UPDATE.md
git commit -m "feat(autoupdate): add plannotator UPDATE.md spec"
```

---

## Task 3: Create ccstatusline UPDATE.md

**Files:**
- Create: `packages/ccstatusline/UPDATE.md`

**Step 1: Create the UPDATE.md spec**

```markdown
---
name: ccstatusline
version_check: npm view ccstatusline version
version_file: packages/ccstatusline/package.nix
changelog_github: sirmalloc/ccstatusline
---

# Update Process

1. Get tarball hash:
   ```bash
   nix-prefetch-url --unpack "https://registry.npmjs.org/ccstatusline/-/ccstatusline-${VERSION}.tgz"
   nix hash convert --hash-algo sha256 --to sri <HASH_FROM_ABOVE>
   ```

2. Edit `packages/ccstatusline/package.nix`:
   - `version` → new version
   - `src.hash` → SRI hash from step 1
```

**Step 2: Commit**

```bash
git add packages/ccstatusline/UPDATE.md
git commit -m "feat(autoupdate): add ccstatusline UPDATE.md spec"
```

---

## Task 4: Create pi-coding-agent UPDATE.md

**Files:**
- Create: `packages/pi-coding-agent/UPDATE.md`

**Step 1: Create the UPDATE.md spec**

This package uses `buildNpmPackage` which requires the npmDepsHash build-fail-extract cycle.

```markdown
---
name: pi
version_check: npm view @mariozechner/pi-coding-agent version
version_file: packages/pi-coding-agent/package.nix
changelog_github: badlogic/pi-mono
---

# Update Process

1. Get tarball hash:
   ```bash
   nix-prefetch-url --unpack "https://registry.npmjs.org/@mariozechner/pi-coding-agent/-/pi-coding-agent-${VERSION}.tgz"
   nix hash convert --hash-algo sha256 --to sri <HASH_FROM_ABOVE>
   ```

2. Generate package-lock.json:
   ```bash
   cd /tmp && rm -rf pi-update && mkdir pi-update && cd pi-update
   curl -sL "https://registry.npmjs.org/@mariozechner/pi-coding-agent/-/pi-coding-agent-${VERSION}.tgz" | tar -xzf - --strip-components=1
   npm install --package-lock-only
   cp package-lock.json ~/dotfiles/packages/pi-coding-agent/package-lock.json
   ```

3. Edit `packages/pi-coding-agent/package.nix`:
   - `version` → new version
   - `src.hash` → SRI hash from step 1
   - `npmDepsHash` → placeholder: `sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=`

4. Attempt build — it will fail with correct npmDepsHash:
   ```bash
   sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10
   ```

5. Extract correct `npmDepsHash` from error output, update `packages/pi-coding-agent/package.nix`, rebuild.
```

**Step 2: Commit**

```bash
git add packages/pi-coding-agent/UPDATE.md
git commit -m "feat(autoupdate): add pi-coding-agent UPDATE.md spec"
```

---

## Task 5: Rewrite weekly-update skill

**Files:**
- Modify: `.claude/skills/weekly-update/SKILL.md`

**Step 1: Replace the skill content**

```markdown
---
name: weekly-update
description: Use when performing the weekly system update - discovers UPDATE.md specs, updates packages, updates flake inputs, and rebuilds the NixOS system
---

# Weekly Update

Orchestrates the recurring weekly update by discovering and processing UPDATE.md spec files.

## Spec File Format

Each UPDATE.md has YAML frontmatter and markdown instructions:

```yaml
---
name: <package-name>           # Required: identifier for commit messages
version_check: <command>       # Required: outputs latest version
version_file: <path>           # Required: file containing current version
changelog_url: <url>           # Optional: URL to changelog file
changelog_path: <path>         # Optional: path in extracted tarball
changelog_github: <owner/repo> # Optional: GitHub repo for release notes
---
```

The body contains freeform update instructions with `${VERSION}` variable support.

## Process

### 1. Discover UPDATE.md Specs

Find all spec files:
```bash
find packages -maxdepth 2 -name "UPDATE.md" 2>/dev/null
find autoupdate -name "*.md" 2>/dev/null
```

Sort alphabetically by package name from frontmatter.

### 2. Process Each Spec

For each UPDATE.md:

**a. Check versions**
- Run `version_check` command → latest version
- Read `version_file` → extract current version (look for `version = "X.Y.Z"` pattern)

**b. If current == latest**: Log "package-name already at X.Y.Z" and skip to next spec.

**c. If current != latest**:
- Follow the instructions in the markdown body, substituting `${VERSION}` with the new version
- After completing the update, fetch and summarize changelog (see Changelog Handling below)
- Record "name oldVer → newVer" for the final commit message

### 3. Update Flake Inputs

```bash
cd ~/dotfiles && nix flake update
```

### 4. Rebuild System

```bash
sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10
```

This is the verification step. If the build succeeds, all updates are working.

### 5. Commit

Stage all changed files and commit with format:

```
weekly update: name1 X.Y.Z → A.B.C, name2 X.Y.Z → A.B.C, flake inputs
```

Omit packages that were already current. If no packages were updated:

```
weekly update: flake inputs
```

## Changelog Handling

After each package update, summarize the changelog. Handle three source types:

**changelog_url**: Fetch via curl, extract entries between old and new versions.

**changelog_path**: Read from the tarball extracted during update (e.g., `/tmp/package-update/CHANGELOG.md`).

**changelog_github**: Use GitHub API:
```bash
gh api repos/owner/repo/releases --jq '.[] | select(.tag_name | test("v?(old|new)")) | "\(.tag_name): \(.name // .tag_name)\n\(.body)"'
```

Present changelog summary to user:
```
## package-name X.Y.Z → A.B.C

**A.B.C** - Brief description
**X.Y.Z+1** - Brief description
```

If no changelog source configured: note "No changelog configured for package-name" and continue.

## Key Notes

- If a spec's version is already current, skip silently — this is normal
- The final `nixos-rebuild switch` serves as verification for all updates
- Some packages (like pi-coding-agent) have complex update flows with build-fail-extract cycles — follow the spec instructions exactly
- The `autoupdate/` directory is for packages without dedicated folders (e.g., version pins in home.nix)
```

**Step 2: Commit**

```bash
git add .claude/skills/weekly-update/SKILL.md
git commit -m "refactor(skill): rewrite weekly-update to use UPDATE.md specs"
```

---

## Task 6: Delete update-claude-code skill

**Files:**
- Delete: `.claude/skills/update-claude-code/` (entire directory)

**Step 1: Remove the skill directory**

```bash
rm -rf .claude/skills/update-claude-code
```

**Step 2: Commit**

```bash
git add -A
git commit -m "chore: remove update-claude-code skill (merged into UPDATE.md)"
```

---

## Task 7: Verify the implementation

**Step 1: Test spec discovery**

Run the discovery commands to verify specs are found:
```bash
find packages -maxdepth 2 -name "UPDATE.md" 2>/dev/null | sort
```

Expected output:
```
packages/ccstatusline/UPDATE.md
packages/claude-code/UPDATE.md
packages/pi-coding-agent/UPDATE.md
packages/plannotator/UPDATE.md
```

**Step 2: Verify frontmatter parsing works**

For each UPDATE.md, verify the frontmatter can be parsed:
```bash
head -20 packages/claude-code/UPDATE.md
```

Check that `name`, `version_check`, `version_file`, and changelog source are present.

**Step 3: Test version check commands**

Run each package's version_check command to ensure it works:
```bash
npm view @anthropic-ai/claude-code version
npm view ccstatusline version
npm view @mariozechner/pi-coding-agent version
curl -fsSL "https://api.github.com/repos/backnotprop/plannotator/releases/latest" | grep '"tag_name"' | cut -d'"' -f4 | sed 's/^v//'
```

Each should return a version number.

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Create claude-code UPDATE.md | `packages/claude-code/UPDATE.md` |
| 2 | Create plannotator UPDATE.md | `packages/plannotator/UPDATE.md` |
| 3 | Create ccstatusline UPDATE.md | `packages/ccstatusline/UPDATE.md` |
| 4 | Create pi-coding-agent UPDATE.md | `packages/pi-coding-agent/UPDATE.md` |
| 5 | Rewrite weekly-update skill | `.claude/skills/weekly-update/SKILL.md` |
| 6 | Delete update-claude-code skill | `.claude/skills/update-claude-code/` |
| 7 | Verify implementation | (verification only) |
