---
name: sentry
version_check: gh api repos/getsentry/cli/releases/latest --jq '.tag_name | ltrimstr("v")'
version_file: packages/sentry/package.nix
changelog_github: getsentry/cli
---

# Update Process

This is the new Sentry CLI (`getsentry/cli`, binary name `sentry`), not nixpkgs'
older `sentry-cli`. Distributed as a bun-compiled linux-x64 binary from GitHub
Releases.

1. Bump version + binary hash in one step:
   ```bash
   nix run nixpkgs#nix-update -- --flake --version=${VERSION} sentry
   ```

2. Verify in isolation (the derivation runs `sentry --version` as an install
   check):
   ```bash
   nix build --no-link .#sentry
   ```
