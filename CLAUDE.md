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
  (statix, deadnix, shellcheck on `scripts/`, py_compile, forbidden-pattern
  and docs-liveness checks), and runs the fast semaphore suite in the sandbox.
- `nix build .#<name>` — builds one custom package in isolation (seconds);
  the way to verify a version/hash bump.
- `scripts/run-tests.sh` — all five script test suites (~200 assertions, all
  deterministic; the controller suite unit-tests a pure `decide()` with an
  injected clock, so nothing here is wall-clock sensitive).
- `nix fmt` — formats the tree (nixfmt-rfc-style via treefmt). Whole-tree
  mechanical reformats get their SHA added to `.git-blame-ignore-revs`.

## Architecture

**Entry point:** `flake.nix` defines a single NixOS configuration (`ubermouse`)
composing, in module order:
- `work-vm.nix` — VMware hardware (filesystems, LUKS). Machine-unique; listed
  in the flake's module list so `nixos.nix` stays host-generic.
- `nixos.nix` — system-level config (services, users, i3, OOM protection)
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
deliberate: `playwright/` and `kolide-launcher/` are check-only UPDATE.md
specs for flake inputs, and `claude-code/` holds only a version manifest —
claude-code is nixpkgs' own derivation with `manifest` overridden (the weekly
bump is one `curl` of the upstream manifest.json).

**Two nixpkgs channels:** stable (`nixpkgs` — the release is whatever
`flake.nix` pins; don't restate the number in prose, it rots) and
`nixpkgs-unstable`. Passed via `specialArgs`/`extraSpecialArgs`. (A third,
unstable-small, existed solely for fresher claude-code; the manifest override
made channel freshness irrelevant and it was dropped.)

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
  transcripts get committed by an automated `git add -A`)

## Build Semaphore

Heavy jobs (typechecks, jest shards, browser launches) wrap themselves in
`kx-build-slot`. A controller (`scripts/build-semaphore-controller.py`) publishes
16 slot files in `$XDG_RUNTIME_DIR/kx-build-sem/` and throttles capacity by
**holding slots itself** — it withholds from the top, clients scan from the
bottom, and the two never contend. Every tool in this subsystem honours a
`KX_POOL` env override for the pool cgroup path (tests point it at a synthetic
tree); the default string is byte-identical at every site and the lint check
trips if a copy drifts.

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
  passing — a *healthy* saturated semaphore, not a stuck one.
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

Tests: `scripts/run-tests.sh` runs all five suites, all deterministic —
`kx-build-slot.test.py` (client half + the state-format contract; also runs as
a flake check in the sandbox), `build-semaphore-controller.test.py` (the
control law as pure-`decide()` unit tests with injected clocks, plus a few
convergence-polled integration tests), `cgroup-governor.test.py` (governor
functions against a synthetic pool), `wt-cgroup-i3status.test.py` (the bar's
resident-split arithmetic), and `cgroup-thaw-all.test.py` (the
ExecStopPost-of-last-resort, end to end). Anything testable without a live
control loop belongs in a unit test, not a new integration harness.

## Updating Custom Packages

Use `/weekly-update` to update all packages with UPDATE.md specs. Each package in `packages/*/UPDATE.md` defines its own version check command and update process. For manual updates, follow the instructions in the relevant UPDATE.md file, and verify with `nix build .#<name>` before switching.

Use `/repo-audit` for the periodic drift sweep (docs vs reality, dead code,
orphaned pins, repo weight, cross-file contracts).
