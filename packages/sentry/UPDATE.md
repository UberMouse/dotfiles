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

1. Get the source hash (SRI, directly):
   ```bash
   nix store prefetch-file --json "https://github.com/getsentry/cli/releases/download/${VERSION}/sentry-linux-x64" | jq -r .hash
   ```

2. Edit `packages/sentry/package.nix`:
   - `version` → new version
   - `src.hash` → hash from step 1

3. Verify in isolation:
   ```bash
   nix build .#sentry && ./result/bin/sentry --version
   ```
