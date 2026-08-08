# dotfiles

NixOS flake for the single host **ubermouse** — a VMware guest (LUKS root)
running i3. The whole system, OS config and user dotfiles alike, is one flake
output; home-manager runs as a NixOS module, so there is exactly one apply
command.

## Day to day

```bash
sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10   # aliased: hms
nix flake check          # full closure + lints + formatting + test suites
nix build .#<pkg>        # one custom package in isolation (verifies a bump)
nix fmt                  # format the tree
scripts/run-tests.sh     # the fast local test loop
```

`/weekly-update` (a Claude Code skill) handles the Monday package/input bumps;
`/repo-audit` is the periodic drift sweep. Architecture, conventions, and the
build-semaphore/cgroup subsystem docs live in [CLAUDE.md](CLAUDE.md) — this
file deliberately stays a pointer so the two never drift.

## Bootstrapping a new machine

1. Install NixOS (graphical installer is fine). Flakes are configured by this
   repo once switched, but the stock installer does NOT enable them — which
   is why step 5 passes `NIX_CONFIG` for the first switch.
2. Clone over HTTPS: `git clone https://github.com/UberMouse/dotfiles.git ~/dotfiles`.
   (Not SSH — the 1Password SSH agent doesn't exist until step 4. Switch the
   remote to `git@github.com:UberMouse/dotfiles.git` after signing in.)
3. Regenerate hardware config and MERGE its `fileSystems`/`boot.initrd`
   stanzas into `work-vm.nix` — the filesystem/LUKS UUIDs there are
   machine-unique (`nixos-generate-config --show-hardware-config`). Do NOT
   replace the whole file: it also carries hand-written host identity the
   generator does not emit (hostname, the GRUB/cryptodisk bootloader config,
   the host-facts-derived boot device) — a wholesale replace produces an
   unbootable, unnamed system.
4. Out-of-repo dependencies to restore by hand:
   - `/root/nixos/openvpn/staff.conf` — the staff VPN config
     (`services.openvpn` points at it; not tracked, contains key material).
   - `~/.config/kx/host-ip` — the VMware host's LAN address for the
     voice-assistant hotkey relay (see `scriptBins/bins/kx-host-hotkey.sh`).
   - 1Password sign-in (the SSH agent, commit signing, and the op-cached
     token wrappers all hang off it).
5. First switch, with flakes force-enabled for the not-yet-switched host:

   ```bash
   sudo NIX_CONFIG="experimental-features = nix-command flakes" \
     nixos-rebuild switch --flake ~/dotfiles#ubermouse
   ```

   Subsequent rebuilds are plain `hms` — the repo's own
   `nix.settings.experimental-features` applies from here on.
