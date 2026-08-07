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

## Architecture

**Entry point:** `flake.nix` defines a single NixOS configuration (`ubermouse`) that composes:
- `nixos.nix` — system-level config (services, users, i3, hardware)
- `home.nix` — user-level config via home-manager (packages, programs, dotfiles)
- `work-vm.nix` — VMware hardware config (imported by nixos.nix)

**Application modules** (imported by home.nix):
- `i3.nix`, `zsh.nix`, `neovim.nix`, `scriptBins/` (per-script files under `scriptBins/bins/`, wired by `scriptBins/default.nix`)

**Custom packages** (applied as overlays in flake.nix):
- `packages/claude-code/package.nix` — claude-code CLI (prebuilt binary)
- `packages/tabby-terminal/package.nix` — Tabby terminal built with `buildNpmPackage`

**Three nixpkgs channels:** stable (`nixpkgs` / 25.11), `nixpkgs-unstable`, and `nixpkgs-unstable-small`. Most packages come from unstable. The `unstable-pkgs` and `unstable-small-pkgs` are passed via `specialArgs`/`extraSpecialArgs`.

## Key Patterns

- Home-manager runs as a NixOS module (not standalone), so changes require `nixos-rebuild switch`
- Custom packages use overlays defined in `flake.nix` and are consumed from `unstable-pkgs`
- The personal `~/.claude/CLAUDE.md` is managed by home-manager: `claude/CLAUDE.md` is symlinked to `~/.claude/CLAUDE.md` (see home.nix)
- Git is configured with SSH signing via 1Password agent

## Build Semaphore

Heavy jobs (typechecks, jest shards, browser launches) wrap themselves in
`kx-build-slot`. A controller (`scripts/build-semaphore-controller.py`) publishes
16 slot files in `$XDG_RUNTIME_DIR/kx-build-sem/` and throttles capacity by
**holding slots itself** — it withholds from the top, clients scan from the
bottom, and the two never contend.

Two traps when diagnosing it:

- **Held-back ≠ in-use.** A slot the controller is withholding and a slot a job
  occupies are both just `flock` failures — indistinguishable from outside. Do
  NOT probe with `flock` and conclude anything; probing also corrupts a running
  controller, since a test-and-release reads as an admission and restarts its
  grant clock. Read the `allowed` file instead. Its fields are
  `allowed effective max_slots occupied target mark resident healthy`,
  appended-only, so `1 1 16 1 1 1 0 1` means capacity 1, one job running, no
  browsers, load test passing — a *healthy* saturated semaphore, not a stuck one.
- **Some slots are held by browsers, not builds.** `playwright-cli open` gates
  the launch *and* keeps the slot for as long as the browser lives, via a keeper
  subshell forked (never exec'd — fork shares the open file description and so
  inherits the lock without a re-acquire race). Those slots are marked in
  `$XDG_RUNTIME_DIR/kx-build-sem/resident/`, and the controller raises its floor
  by that count so residents can never squeeze build admission to zero. Build
  capacity is therefore `allowed - resident`, not `allowed`.
- **A resident job waits on the load test, not just on a free slot** (`--resident`).
  The floor keeps one slot free whenever no *build* is running, and that slot is
  free regardless of memory. A browser that took it became resident, which raised
  the floor, which freed the next one — self-feeding. Measured 2026-08-07: twelve
  browsers admitted onto a pool at 15.5G/16G with `psi10=40%`, `allowed` pinned at
  1 throughout. Any future job that leaves something resident behind must pass
  `--resident`, or it will find the same open door.

Three files have to agree on residency — `kx-build-slot.sh` (keeper + marker),
`packages/playwright-cli/package.nix` (`--resident-probe`), and
`build-semaphore-controller.py` (`Semaphore.resident()` + the dynamic floor).
Change one, check the other two.

Two standing traps when working on any of this:

- **Never identify processes with `pgrep -f`.** It matches the pattern against
  every process's full command line, so the probe matches *itself*, plus any
  grep or editor holding the string. Measured 6 daemons against 4 real ones on
  2026-08-07. Match `/proc/<pid>/cmdline` argv fields exactly instead.
- **Guards phrased against total occupancy silently die once browsers exist.**
  `if occupied == 0` never fires again while a session is open. The build-
  progress guard has to read `occupied - resident`. This is the same shape as
  the `compgen` and dead-actuator bugs: a test that can no longer be true,
  quietly disabling a safety property while the log still looks healthy.

Two suites, and reach for the fast one first:

- `scripts/kx-build-slot.test.py` — the client half (resident gate, keeper
  lifetime, fail-open paths). Writes the state file by hand instead of starting a
  controller, so it is deterministic and finishes in seconds. Anything testable
  without the control loop belongs here.
- `scripts/build-semaphore-controller.test.py` — the control loop itself, against
  a synthetic cgroup. Takes a few minutes; tests 14–17 cover residency.

Its ramp and dwell assertions are wall-clock timed, so they **flake on a loaded
box** — a failure in tests 4–9 while builds or browsers are running is usually
the machine, not the change. Re-run on a quiet machine before believing it, and
note the suite aborts at the first `hold()` that finds no slot, so an early
flake hides every later test. To check one property without the ramp, drive the
controller directly against a synthetic pool rather than extending this file.

## Updating Custom Packages

Use `/weekly-update` to update all packages with UPDATE.md specs. Each package in `packages/*/UPDATE.md` defines its own version check command and update process. For manual updates, follow the instructions in the relevant UPDATE.md file.
