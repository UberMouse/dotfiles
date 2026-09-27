---
name: whatpulse-pcap-service
version_check: gh api repos/whatpulse/linux-external-pcap-service/releases/latest --jq '.tag_name | ltrimstr("v")'
version_file: packages/whatpulse-pcap-service/package.nix
changelog_github: whatpulse/linux-external-pcap-service
---

# Update Process

Built from the GitHub source tag, with the root-privilege check patched out
(the `postPatch` in `package.nix`) so the unit in `nixos.nix` can run it as a
capability-only DynamicUser.

1. Bump version + source hash in one step:
   ```bash
   nix run nixpkgs#nix-update -- --flake --version=${VERSION} whatpulse-pcap-service
   ```

2. Verify in isolation (the derivation runs `--version` as an install check):
   ```bash
   nix build --no-link .#whatpulse-pcap-service
   ```
   If the `--replace-fail` in `postPatch` fails, upstream moved the
   `geteuid() != 0` check: find the new root gate in `captureservice.cpp` and
   re-target the substitution. Do NOT drop the patch — without it the service
   exits at startup under the unit's DynamicUser.

3. After the switch, confirm it still captures without root:
   ```bash
   journalctl -u whatpulse-pcap-service -b --no-pager | tail -20
   ```
