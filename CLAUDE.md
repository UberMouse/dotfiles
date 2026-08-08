# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

NixOS dotfiles repository using Nix Flakes. The entire system (OS config + user dotfiles) is declared in Nix and deployed as a single flake output.

## Apply Changes

```bash
sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10
```

You can run this yourself, including in background sessions: `sudo` prompts route
to the user, who can approve them out of band — so run the `switch` directly
rather than falling back to a non-privileged `nixos-rebuild build`.

This is also aliased as `hms` in the shell.

## Verify Before You Switch

- `nix flake check` — builds the full system closure, runs the lints
  (statix, deadnix, shellcheck on `scripts/` AND `scriptBins/bins/`, ruff +
  py_compile, forbidden-pattern and docs-liveness tripwires), fails on an
  unformatted tree, and runs the deterministic test suites in the sandbox.
- `nix build .#<name>` — builds one custom package in isolation (seconds);
  the way to verify a version/hash bump.
- `scripts/run-tests.sh` — every `scripts/*.test.py` suite (discovered by
  glob, never listed) plus the lint tripwires. All deterministic: policy is
  unit-tested against a pure `decide()` with an injected clock, blocking is
  asserted from log lines rather than elapsed time, and slow-converging
  outcomes are polled via `testlib.wait_for`, never fixed sleeps.
- `nix fmt` — formats the tree (nixfmt-rfc-style via treefmt). Whole-tree
  mechanical reformats get their SHA added to `.git-blame-ignore-revs`.
- A `pre-push` hook (`hooks/pre-push`, wired via a gitdir-scoped includeIf
  in home.nix) runs every flake check except `toplevel` automatically — the
  list is derived from the flake, never hardcoded. NOTE: a machine-local
  `.git/config` `core.hooksPath` silently overrides this wiring (found dead
  exactly that way 2026-08-07); `git config --show-scope --get-all
  core.hooksPath` — a `local` row is the bug.
- There is deliberately NO CI (a GitHub Actions workflow was added 2026-08-07
  and removed next day — taylorl doesn't want to deal with it). Do not
  re-suggest one in audits; the pre-push hook and `nix flake check` before a
  switch are the only gates, so keeping the hook wiring alive (above) is
  load-bearing.

## Architecture

**Entry point:** `flake.nix` defines a single NixOS configuration (`ubermouse`)
composing, in module order:
- `work-vm.nix` — VMware hardware (filesystems, LUKS). Machine-unique; listed
  in the flake's module list so `nixos.nix` stays host-generic.
- `nixos.nix` — system-level config (services, users, i3, OOM protection)
- the kolide-launcher input's NixOS module — a root-privileged endpoint agent,
  enabled in `nixos.nix`. It tracks upstream `main` and moves with the weekly
  `nix flake update` like every other input; it deliberately has NO UPDATE.md
  (retired 3547f73 — not worth the weekly question). Don't re-flag the
  missing spec in audits.
- `home.nix` — user-level config via home-manager (packages, programs)
- `cgroups.nix` — the worktrees resource-pool subsystem (pool slices + the
  governor/monitor/semaphore-controller services); imported by `home.nix`
- `memory-policy.nix` — THE memory partition numbers (desktop floor, pool
  ceiling), shared by `nixos.nix` and `cgroups.nix`, with the margin invariant
  enforced as an eval-time assertion. Change the numbers there, nowhere else.

**Application modules** (imported by home.nix):
- `i3.nix`, `zsh.nix`, `neovim.nix`, `scriptBins/` (per-script files under
  `scriptBins/bins/`, wired by `scriptBins/default.nix`)

**Custom packages:** one directory per package under `packages/<name>/`
(`package.nix` + `UPDATE.md`), AUTO-DISCOVERED by `packages/default.nix` into
the overlay — adding a package is one directory, no flake.nix edit. The
flake's `packages.x86_64-linux` output derives its attr list from the same
discovery, so the two cannot drift. Directories WITHOUT a `package.nix` are
deliberate: `playwright/` is a check-only UPDATE.md spec for a flake input
(check-only is declared by `mode:` in the spec's own frontmatter, never
listed in the skill), and `claude-code/` holds only a version manifest —
claude-code is nixpkgs' own derivation with `manifest` overridden (the weekly
bump is one `curl` of the upstream manifest.json).

**Two nixpkgs channels:** stable (`nixpkgs` — the release is whatever
`flake.nix` pins; don't restate the number in prose, it rots) and
`nixpkgs-unstable`. Passed via `specialArgs`/`extraSpecialArgs`. (A third,
unstable-small, existed solely for fresher claude-code; the manifest override
made channel freshness irrelevant and it was dropped.) The channel RULE:
ordinary packages come from stable; unstable exists as the overlay's base —
only the custom/overlaid packages (and playwright, whose flake follows
stable) resolve from it. A non-custom package taken from unstable needs a
recorded reason, or it's drift.

## Docs Layout

- `CLAUDE.md` — standing rules and traps an agent needs on every task.
- `docs/plans/` — live implementation plans only; delete on ship (history
  keeps them).
- `docs/notes/` — dated investigation write-ups worth keeping. Subject to
  the same no-hand-copied-machine-facts rule as everything else; a note
  whose numbers have rotted gets deleted, not corrected.
- `packages/*/UPDATE.md` — per-package update specs (see below).
- `README.md` — bootstrap + day-to-day pointer; it deliberately defers to
  this file so the two never drift.

The lint's docs-liveness check walks CLAUDE.md, README.md, `docs/**/*.md`,
the skills, and the COMMENT LINES of every `.nix` file (Nix comments narrate
the tree layout — `packages/default.nix` named a deleted directory for three
commits before they joined the corpus), so a path named anywhere in them
must exist.

## Conventions

- Conventional commits, scoped, imperative, with subjects that carry the *why*:
  `feat(cgroup): pace growth against load, not a clock`. Automated version
  bumps commit as `chore(deps): …` (the weekly-update skill's format), so they
  are distinguishable from changes to the tooling itself.
- UPDATE.md specs use greppable anchors, never line numbers ("the
  `npm:…` pin", not "line ~128"), and the hash command must match the fetcher:
  `fetchurl` ↔ `nix store prefetch-file`; `fetchzip` ↔ `nix-prefetch-url
  --unpack` + convert. A mismatch silently freezes the package: every weekly
  run fails its hash step and skips it (this happened for 3 months once).
- Machine facts (RAM sizes, cgroup caps, core counts) are never hand-copied
  into prompts, comments-as-config, or docs — interpolate from the source
  (see the stall-diagnosis prompt in `scripts/cgroup-pressure-monitor.sh` and
  `memory-policy.nix`). Hand-copied numbers rot silently and poison whatever
  reasons from them.

## Key Patterns

- Home-manager runs as a NixOS module (not standalone), so changes require `nixos-rebuild switch`
- The personal `~/.claude/CLAUDE.md` is managed by home-manager: `claude/CLAUDE.md` is symlinked to `~/.claude/CLAUDE.md` (see home.nix)
- Git is configured with SSH signing via 1Password agent
- Agent runtime state (`.pi/`-shaped directories, `.claude/` scratch) is
  ignored via the tracked `.gitignore`, never `.git/info/exclude` (machine-
  local, doesn't survive a clone — that gap once let 144 MiB of agent
  transcripts get committed by an automated `git add -A`). `.claude/` is an
  ALLOWLIST (`.claude/*` + `!` entries for the tracked paths): the harness
  grows new state files on its own schedule, so tracking a new `.claude/`
  path means adding a `!` line, and everything unlisted is ignored by
  default

## Build Semaphore

Heavy jobs (typechecks, jest shards, browser launches) wrap themselves in
`kx-build-slot`. A controller (`scripts/build-semaphore-controller.py`) publishes
`max_slots` slot files in `$XDG_RUNTIME_DIR/kx-build-sem/` and throttles capacity by
**holding slots itself** — it withholds from the top, clients scan from the
bottom, and the two never contend. Every tool in this subsystem honours a
`KX_POOL` env override for the pool cgroup path (tests point it at a synthetic
tree); the sites spell the default differently (`$USERAT`, `$U`, f-strings),
so the lint check enforces the invariant that actually matters — every
path-construction site carries its `KX_POOL`/`KX_SEM_POOL` override within
two lines.

Traps when diagnosing it:

- **Held-back ≠ in-use.** A slot the controller is withholding and a slot a job
  occupies are both just `flock` failures — indistinguishable from outside. Do
  NOT probe with `flock` and conclude anything; probing also corrupts a running
  controller, since a test-and-release reads as an admission and restarts its
  grant clock. Read the `allowed` file instead. Its field order is defined
  ONCE, by the `Semaphore.FIELDS` tuple in the controller
  (`allowed effective max_slots occupied target mark resident healthy`,
  append-only), and the fast suite asserts every reader's indices against it.
  `1 1 16 1 1 1 0 1` means capacity 1, one job running, no browsers, load test
  passing — a *healthy* saturated semaphore, not a stuck one. The file's
  mtime is a HEARTBEAT: the controller re-publishes every tick (unchanged or
  not — that is a contract, never optimize it to publish-on-change), and
  readers treat age beyond `KX_SEM_STALE_AFTER` (~3 ticks) as controller-dead
  — the client fails open instead of trusting a stale `healthy=0`, and
  i3status shows "off" instead of a dead controller rendering as "idle".
- **Some slots are held by browsers, not builds.** `playwright-cli open` gates
  the launch *and* keeps the slot for as long as the browser lives, via a keeper
  subshell forked (never exec'd — fork shares the open file description and so
  inherits the lock without a re-acquire race). Those slots are marked in
  `$XDG_RUNTIME_DIR/kx-build-sem/resident/` (format: `keeper=<pid>`, parsed by
  `Semaphore.resident()`), and the controller raises its floor by that count so
  residents can never squeeze build admission to zero. Build capacity is
  therefore `allowed - resident`, not `allowed`.
- **A resident job waits on the load test, not just on a free slot** (`--resident`).
  The floor keeps one slot free whenever no *build* is running, and that slot is
  free regardless of memory. A browser that took it became resident, which raised
  the floor, which freed the next one — self-feeding. Measured 2026-08-07: twelve
  browsers admitted onto a pool at 15.5G/16G with `psi10=40%`, `allowed` pinned at
  1 throughout. Any future job that leaves something resident behind must pass
  `--resident`, or it will find the same open door.
- **Residency is capped** (`KX_SEM_MAX_RESIDENT`, default `max_slots - ceil`).
  The published `healthy` field is the load test AND the cap — only resident
  admissions read it, so at cap new browsers queue while builds are untouched.
  Without the cap, enough browsers make every slot keeper-held and every build
  runs ungated after its timeout.

Three files have to agree on residency — `kx-build-slot.sh` (keeper + marker),
`packages/playwright-cli/package.nix` (`--resident-probe`; its build ASSERTS
the probe's cliDaemon.js path still exists so a playwright bump can't silently
kill residency), and `build-semaphore-controller.py` (`Semaphore.resident()` +
the dynamic floor). Change one, check the other two.

Two standing traps when working on any of this:

- **Never identify processes with `pgrep -f`.** It matches the pattern against
  every process's full command line, so the probe matches *itself*, plus any
  grep or editor holding the string. Measured 6 daemons against 4 real ones on
  2026-08-07. Use `kx-proc-find` (glob per argv field, matched in order,
  self-excluding) — the lint check fails on any new `pgrep -f`.
- **Guards phrased against total occupancy silently die once browsers exist.**
  `if occupied == 0` never fires again while a session is open. The build-
  progress guard has to read `occupied - resident`. This is the same shape as
  the `compgen` and dead-actuator bugs: a test that can no longer be true,
  quietly disabling a safety property while the log still looks healthy.

Tests: `scripts/run-tests.sh` discovers and runs every `scripts/*.test.py`
suite (shared harness in `scripts/testlib.py` — `check`/`wait_for`/`summary`),
and ALL of them also run sandboxed under `nix flake check`. The semaphore
splits in two: `build-semaphore-policy.test.py` (the control law as
pure-`decide()` unit tests with injected clocks) and
`build-semaphore-controller.test.py` (the machinery — flock reconcile,
publish heartbeat, marker pruning, orphan-slot sweep — running the real
`main()` in a thread with a stepping sleep stub, so each tick is exact and
the suite finishes in well under a second). The machinery suite's genuinely
host-only checks (kernel signal delivery, flock drop on real process death)
run only under `KX_TEST_HOST_ONLY=1`, which run-tests.sh exports; in the
sandbox they SKIP loudly. The rest — `kx-build-slot.test.py` (client half +
the state-format and resident-marker contracts), `cgroup-governor.test.py`
(the extracted tick decision, detection functions AND actuator failure paths
against a synthetic pool), `kx-proc-find.test.py` (argv-matching semantics
against real fixture processes), `wt-cgroup-i3status.test.py`,
`cgroup-thaw-all.test.py`, `op-cached.test.py`, `claude-usage.test.py` — are
all sandboxed flake checks too. Anything testable without a live control
loop belongs in a unit test, not a new integration harness.

## Updating Custom Packages

Use `/weekly-update` to update all packages with UPDATE.md specs. Each package in `packages/*/UPDATE.md` defines its own version check command and update process. For manual updates, follow the instructions in the relevant UPDATE.md file, and verify with `nix build .#<flake_attr>` (the spec frontmatter's `flake_attr`, defaulting to its `name`) before switching.

Use `/repo-audit` for the periodic drift sweep (docs vs reality, dead code,
orphaned pins, repo weight, cross-file contracts).
