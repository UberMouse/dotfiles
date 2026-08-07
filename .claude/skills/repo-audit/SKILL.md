---
name: repo-audit
description: Use for the periodic (monthly-ish) drift sweep - checks docs against reality, hunts dead code and orphaned pins, and verifies the gitignore still covers agent runtime state
---

# Repo Audit

A drift sweep for this dotfiles repo. Run it when asked, or when the repo
feels like it has accumulated cruft. The mechanical checks (`nix flake check`)
run continuously; this skill covers what only judgment can check. The
2026-08-07 audit that motivated it found 144 MiB of committed agent
transcripts, a package silently frozen for 3 months by a wrong hash command,
and a CLAUDE.md describing a package that no longer existed — all invisible to
day-to-day work.

## Checks, in order

### 1. Docs vs reality

- Every file path, package name, symbol, and version number stated in
  `CLAUDE.md` must exist/match. Grep for each named path and symbol; `ls
  packages/` against the package list; the nixpkgs channel in prose vs
  `flake.nix` inputs.
- Every `packages/*/UPDATE.md`: does `version_file` exist, does the
  `version_check` command run, do URLs in the body still resolve (spot-check),
  and does the fetcher match the hash command (`fetchurl` ↔ plain
  `prefetch-file`; `fetchzip` ↔ `--unpack` NAR hash)? A mismatch silently
  freezes the package: every weekly update fails its hash step and gets
  skipped.
- Line-number references anywhere in docs ("line ~128") are rot by
  definition — replace with greppable anchors.

### 2. Dead code and orphans

- `.nix` files at repo root not reachable from `flake.nix` (grep each
  filename across all `.nix`).
- Version pins with no owner: anything pinned in `home.nix`/`cgroups.nix`
  (npm:… strings, explicit versions) that no UPDATE.md covers.
- Overlay attrs never consumed; packages in `packages/` not in the overlay.
- Config files (`p10k/`, `nohang/`, `i3-workspaces/`, root-level rc files)
  not referenced from any `.nix`.
- `git log --format=%s -20 -- <path>` on anything suspicious: a file untouched
  since its subsystem was removed is residue.

### 3. Repo weight and hygiene

- `git ls-tree -r -l HEAD | sort -k4 -n | tail` — any tracked blob over ~1 MB
  needs a reason; agent transcripts/session state never belong in git.
- `git ls-files -s | awk '$1 == 120000'` — tracked symlinks. A symlink into
  `/nix/store` is a committed `result` (56 bytes, invisible to the size check
  above — exactly how one survived the 2026-08-07 audit).
- `du -sh */ .*/ 2>/dev/null | sort -h | tail` — large untracked trees inside
  the repo (node_modules, agent state) should be ignored or relocated.
- New agent-runtime directories (`.pi/`-shaped) must be in the tracked
  `.gitignore`, NOT `.git/info/exclude` (machine-local, doesn't survive a
  clone — that gap is exactly how the 144 MiB got committed).
- `docs/plans/` should contain only live plans; shipped ones get deleted
  (history keeps them).

### 4. Cross-file contracts

- The residency contract: `kx-build-slot.sh` (keeper/marker) ↔
  `packages/playwright-cli/package.nix` (probe + cliDaemon assertion) ↔
  `Semaphore.resident()`/`FIELDS` in the controller. The fast test suite
  binds the state-file format; verify the *pointers between the files* still
  name symbols that exist.
- `memory-policy.nix` is the only place the desktop-floor/pool-ceiling
  numbers live; grep for stray `"8G"`/`"18G"`/`"20G"` literals that bypass it
  (comments citing history are fine; option values are not).
- Prose in prompts/comments stating machine facts (RAM, core counts, cgroup
  caps) must be interpolated from the source, never hand-copied — see the
  stall-diagnosis prompt for the pattern.

### 5. Report

Deliver findings as a prioritized list (file:line, issue, why it matters,
concrete fix). Fix trivial items directly; batch the rest into proposed
commits and ask before structural changes.
