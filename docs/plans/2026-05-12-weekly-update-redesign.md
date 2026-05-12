# Weekly Update Skill Redesign

## Overview

Replace the hardcoded package list in the weekly-update skill with a data-driven approach using discoverable UPDATE.md spec files.

## Goals

- Make package updates declarative and self-documenting
- Unify changelog handling across all packages (not just claude-code)
- Support packages with and without dedicated folders
- Keep the update process flexible for complex flows (npmDepsHash cycles)

## Spec File Format

Each UPDATE.md uses YAML frontmatter for structured metadata and markdown body for update instructions:

```markdown
---
name: <package-name>           # Required: identifier used in commit messages
version_check: <command>       # Required: shell command that outputs latest version
version_file: <path>           # Required: file containing current version
changelog_url: <url>           # Optional: URL to fetch changelog
changelog_path: <path>         # Optional: path within extracted tarball
changelog_github: <owner/repo> # Optional: GitHub repo for release notes
---

# Update Process

[Freeform markdown instructions with ${VERSION} variable support]
```

Only one changelog source should be specified. The skill handles all three:
- `changelog_url`: Fetches directly via curl/WebFetch
- `changelog_path`: Reads from tarball extracted during update
- `changelog_github`: Uses `gh api` to fetch release notes between versions

## Discovery

Spec files are discovered from two locations:

1. `packages/*/UPDATE.md` - inline with packages that have folders
2. `autoupdate/*.md` - for packages without dedicated folders (e.g., version pins in home.nix)

Processing order: alphabetical by package name.

## Skill Workflow

```
1. Discover all UPDATE.md specs
2. For each spec:
   a. Run version_check command → get latest version
   b. Read version_file → extract current version
   c. If current == latest: skip (log "already current")
   d. If current != latest:
      - Follow instructions in body (with ${VERSION} substituted)
      - Fetch changelog and summarize changes between old → new
      - Record "name oldVer → newVer" for commit message
3. Run `nix flake update`
4. Run `sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10`
5. Commit with format: "weekly update: name1 X→Y, name2 A→B, flake inputs"
```

If all specs are current, commit message is just "weekly update: flake inputs".

## Changelog Presentation

After each package update, the skill presents changes:

```
## claude-code 2.1.126 → 2.1.138

**2.1.138** - Fixed streaming in batch mode
**2.1.135** - Added new /review command
**2.1.130** - Performance improvements for large repos
```

Packages without changelog configured: skill notes "No changelog configured" and continues.

## Files to Create

- `packages/claude-code/UPDATE.md`
- `packages/plannotator/UPDATE.md`
- `packages/ccstatusline/UPDATE.md`
- `packages/pi-coding-agent/UPDATE.md`

## Files to Modify

- `.claude/skills/weekly-update/SKILL.md` - rewrite to discover and process specs

## Files to Delete

- `.claude/skills/update-claude-code/` - functionality moves to claude-code's UPDATE.md
