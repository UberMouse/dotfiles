---
name: claude-code
version_check: curl -fsSL https://downloads.claude.ai/claude-code-releases/latest
version_file: packages/claude-code/manifest.json
changelog_url: https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md
---

# Update Process

claude-code is nixpkgs' own derivation (wrapper env, alsa-lib, install check)
with only the version `manifest` overridden — see `packages/default.nix`. The
vendored `manifest.json` is the VERBATIM upstream manifest for the pinned
version (same file nixpkgs' own update.sh vendors), so the update is one
fetch, no hashes to compute:

1. Refresh the manifest:
   ```bash
   curl -fsSL "https://downloads.claude.ai/claude-code-releases/${VERSION}/manifest.json" \
     -o packages/claude-code/manifest.json
   ```

2. Verify in isolation (nixpkgs' derivation runs `claude --version` as an
   install check):
   ```bash
   nix build --no-link .#claude-code
   ```

If this override ever stops applying cleanly (nixpkgs renamed the `manifest`
argument or restructured the package), compare against
`pkgs/by-name/cl/claude-code/package.nix` in the pinned nixpkgs-unstable and
adjust `packages/default.nix` — do NOT resurrect a full local copy of the
derivation; tracking upstream's packaging is the point.
