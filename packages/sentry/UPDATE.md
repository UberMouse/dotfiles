---
name: sentry
version_check: gh api repos/getsentry/cli/releases/latest --jq '.tag_name | ltrimstr("v")'
version_file: packages/sentry/package.nix
changelog_url: https://github.com/getsentry/cli/releases
---

# Update Process

This is the new Sentry CLI (`getsentry/cli`, binary name `sentry`), not nixpkgs'
older `sentry-cli`. Distributed as a bun-compiled linux-x64 binary from GitHub
Releases.

1. Get source hash for the new version:
   ```bash
   nix-prefetch-url "https://github.com/getsentry/cli/releases/download/${VERSION}/sentry-linux-x64"
   nix hash convert --hash-algo sha256 --to sri <HASH_FROM_ABOVE>
   ```

2. Edit `packages/sentry/package.nix`:
   - `version` → new version
   - `src.hash` → SRI hash from step 1
