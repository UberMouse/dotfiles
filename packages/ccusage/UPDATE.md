---
name: ccusage
version_check: npm view @ccusage/ccusage-linux-x64 version
version_file: packages/ccusage/package.nix
changelog_github: ryoppippi/ccusage
---

# Update Process

Prebuilt static linux-x64 binary from the `@ccusage/ccusage-linux-x64` npm
tarball (`fetchzip`). Check the native package's version, not the `ccusage`
shim's: the shim is published alongside it, but the binary is what we fetch.

1. Bump version + tarball hash in one step:
   ```bash
   nix run nixpkgs#nix-update -- --flake --version=${VERSION} ccusage
   ```

2. Verify in isolation (the derivation runs `ccusage --version` as an install
   check):
   ```bash
   nix build --no-link .#ccusage
   ```

3. After switching, check the caching wrapper (`scriptBins/bins/ccusage.py`)
   still agrees with the new binary. It renders daily/weekly/monthly itself
   from cached `daily --json` rows, so it depends on that JSON shape and on
   a `--since` run producing the same rows for its days as a full run. The
   bump changes the binary's store path, which is part of the cache key, so
   the first run recomputes every day (one full run); then:
   ```bash
   ccusage -b > /dev/null && ccusage --verify-cache
   ```
   It re-runs ccusage over the whole history (~35s) and compares every
   cached day. A `tokens` mismatch means rows no longer partition by
   `--since` (check the changelog for dedup or date-filter changes). A
   `cost only` mismatch with exact tokens is online pricing drift since the
   day was cached, not a wrapper bug.
