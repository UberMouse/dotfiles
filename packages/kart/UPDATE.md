---
name: kart
version_check: gh api repos/koordinates/kart/releases/latest --jq '.tag_name | ltrimstr("v")'
version_file: packages/kart/package.nix
changelog_github: koordinates/kart
---

# Update Process

Prebuilt linux-x86_64 tarball from GitHub Releases, patchelf'd against the
runtime libs listed in `package.nix`.

1. Get the tarball hash (SRI, directly):
   ```bash
   nix store prefetch-file --json "https://github.com/koordinates/kart/releases/download/v${VERSION}/Kart-${VERSION}-linux-x86_64.tar.gz" | jq -r .hash
   ```

2. Edit `packages/kart/package.nix`:
   - `version` → new version (without `v` prefix)
   - `src.hash` → hash from step 1

3. Verify in isolation:
   ```bash
   nix build .#kart && ./result/bin/kart --version
   ```
   If autoPatchelf fails on a new missing library, add it to `buildInputs`.
