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
mode: check-only               # Optional: spec only REPORTS, never bumps
flake_attr: <attr>             # Optional: flake package attr, default = name
changelog_url: <url>           # Optional: URL to changelog file
changelog_github: <owner/repo> # Optional: GitHub repo for release notes
---
```

`mode: check-only` marks specs that track a flake-input rev rather than a
version string. Which specs those are is declared ONLY in their own
frontmatter — this skill deliberately names no packages, so adding or
removing a spec never requires editing the skill. For check-only specs, skip
step 2a's version-file extraction entirely — there is no `version = "X.Y.Z"`
to find — and just follow the body, which ends in a report to the user,
never an edit.

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
- If the frontmatter says `mode: check-only`: follow the body directly (it
  compares revs and reports); skip the version extraction below.
- Run `version_check` command → latest version
- Read `version_file` → extract current version (a `version = "X.Y.Z"`-style
  assignment by default; a spec whose version lives elsewhere — a dependency
  pin, a lock-file field — says exactly where in its own body, next to the
  `version_file` it points at)

**b. If current == latest**: Log "package-name already at X.Y.Z" and skip to next spec.

**c. If current != latest**:
- Follow the instructions in the markdown body, substituting `${VERSION}` with the new version
- Verify the package in isolation with `nix build .#<flake_attr>` — the
  frontmatter's `flake_attr`, defaulting to `name` (rush's attr is `rushjs`,
  which is why the field exists) — BEFORE moving to the next spec: a bad hash
  surfaces in seconds here instead of aborting the whole run at the system
  rebuild
- After completing the update, fetch and summarize changelog (see Changelog Handling below)
- Record "name oldVer → newVer" for the final commit message

### 3. Update Flake Inputs

```bash
cd ~/dotfiles && nix flake update
```

### 4. Check, then Rebuild

```bash
nix flake check
```

runs eval, the lints, and the fast test suite — catching breakage before the
switch touches the live system. Then:

```bash
sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10
```

### 5. Commit

Stage all changed files and commit with format:

```
chore(deps): name1 X.Y.Z → A.B.C, name2 X.Y.Z → A.B.C, flake inputs
```

(`chore(deps):` so automated bumps are distinguishable in history from changes
to this skill itself, which commit as `docs(weekly-update):` or similar.)

Omit packages that were already current. If no packages were updated:

```
chore(deps): flake inputs
```

## Changelog Handling

After each package update, summarize the changelog. Handle two source types:

**changelog_url**: Fetch via curl, extract entries between old and new versions.

**changelog_github**: Use GitHub API, substituting the real old/new versions
(the `test()` regex must contain the literal version strings, e.g.
`test("v?(1\\.61\\.1|1\\.62\\.1)")` — the placeholder form below is a
template, not a runnable command):
```bash
gh api repos/owner/repo/releases --jq '.[] | select(.tag_name | test("v?(${OLD}|${NEW})")) | "\(.tag_name): \(.name // .tag_name)\n\(.body)"'
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
- The final `nixos-rebuild switch` is the integration step, NOT the
  verification — each spec verifies in isolation (step 2c) before the run
  moves on, and `nix flake check` gates the switch
- Some packages have more involved update flows than a version+hash bump — follow the spec instructions exactly
