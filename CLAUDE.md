# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

NixOS dotfiles repository using Nix Flakes. The entire system (OS config + user dotfiles) is declared in Nix and deployed as a single flake output.

## Apply Changes

```bash
sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10
```

You can run this yourself

This is also aliased as `hms` in the shell.

## Architecture

**Entry point:** `flake.nix` defines a single NixOS configuration (`ubermouse`) that composes:
- `nixos.nix` — system-level config (services, users, i3, hardware)
- `home.nix` — user-level config via home-manager (packages, programs, dotfiles)
- `work-vm.nix` — VMware hardware config (imported by nixos.nix)

**Application modules** (imported by home.nix):
- `i3.nix`, `zsh.nix`, `neovim.nix`, `scriptBins.nix`

**Custom packages** (applied as overlays in flake.nix):
- `packages/claude-code/package.nix` — claude-code CLI built with `buildNpmPackage`
- `packages/tabby-terminal/package.nix` — Tabby terminal built with `buildNpmPackage`

**Three nixpkgs channels:** stable (`nixpkgs` / 25.11), `nixpkgs-unstable`, and `nixpkgs-unstable-small`. Most packages come from unstable. The `unstable-pkgs` and `unstable-small-pkgs` are passed via `specialArgs`/`extraSpecialArgs`.

## Key Patterns

- Home-manager runs as a NixOS module (not standalone), so changes require `nixos-rebuild switch`
- Custom packages use overlays defined in `flake.nix` and are consumed from `unstable-pkgs`
- The personal `~/.claude/CLAUDE.md` is managed by home-manager: `claude/CLAUDE.md` is symlinked to `~/.claude/CLAUDE.md` (see home.nix)
- Git is configured with SSH signing via 1Password agent

## Updating Custom Packages

For claude-code specifically, use the `/update-claude-code` skill which automates the multi-step hash update process. The general pattern for `buildNpmPackage` updates: update version, update `src.hash` (via `nix-prefetch-url --unpack`), set `npmDepsHash` to a placeholder, build to get the correct hash from the error message, then update.
