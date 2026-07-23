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

## Updating Custom Packages

Use `/weekly-update` to update all packages with UPDATE.md specs. Each package in `packages/*/UPDATE.md` defines its own version check command and update process. For manual updates, follow the instructions in the relevant UPDATE.md file.
