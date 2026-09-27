---
name: whatpulse
version_check: curl -fsSL https://releases.whatpulse.org/latest/linux/version.json | jq -r .version
version_file: packages/whatpulse/package.nix
changelog_url: https://whatpulse.org/releasenotes
---

# Update Process

The AppImage has no versioned download URL — only
`releases.whatpulse.org/latest/linux/…`, so the `fetchurl` hash is the only
real pin (see the comment above `src` in `package.nix`). That rules out
`nix-update`: there is no version in the URL for it to substitute. The
`version_check` endpoint is the same `version.json` the client's own updater
polls, sitting beside the AppImage.

1. Prefetch the current AppImage (`fetchurl` ↔ `nix store prefetch-file`):
   ```bash
   nix store prefetch-file --json \
     https://releases.whatpulse.org/latest/linux/whatpulse-linux-latest_amd64.AppImage \
     | jq -r .hash
   ```

2. Set the `version = "…"` and the `src` `hash = "…"` in `package.nix`
   TOGETHER. `version` is a label only here — the URL never changes, so a
   version bump without the new hash still builds from the store cache and
   only fails on the next refetch.

3. Confirm the fetched file really is `${VERSION}` — `version` is only a
   label, so this guards against upstream publishing between the version
   check and the prefetch:
   ```bash
   strings "$(nix build --no-link --print-out-paths .#whatpulse.extracted)/usr/bin/whatpulse" \
     | grep -qx "${VERSION}" && echo ok
   ```

4. Verify in isolation:
   ```bash
   nix build --no-link .#whatpulse
   ```
