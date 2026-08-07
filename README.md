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

1. Install NixOS (graphical installer is fine; enable flakes are already
   configured by this repo once switched).
2. Clone: `git clone git@github.com:UberMouse/dotfiles.git ~/dotfiles`
3. Regenerate hardware config and replace `work-vm.nix` with it — the
   filesystem/LUKS UUIDs in that file are machine-unique
   (`nixos-generate-config --show-hardware-config`). Keep the module name so
   `flake.nix` still finds it.
4. Out-of-repo dependencies to restore by hand:
   - `/root/nixos/openvpn/staff.conf` — the staff VPN config
     (`services.openvpn` points at it; not tracked, contains key material).
   - `~/.config/kx/host-ip` — the VMware host's LAN address for the
     voice-assistant hotkey relay (see `scriptBins/bins/kx-host-hotkey.sh`).
   - 1Password sign-in (the SSH agent, commit signing, and the op-cached
     token wrappers all hang off it).
5. `sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse`
