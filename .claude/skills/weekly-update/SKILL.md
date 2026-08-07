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
```

Sort alphabetically by package name from frontmatter.

### 2. Process Each Spec

For each UPDATE.md:

**a. Check versions**
- Run `version_check` command → latest version
- Read `version_file` → extract current version (a `version = "X.Y.Z"`-style
  assignment, unless the spec's body says where the version lives — e.g. rush's
  is the `@microsoft/rush` pin in its package.json)

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
- Some packages have more involved update flows than a version+hash bump — follow the spec instructions exactly
