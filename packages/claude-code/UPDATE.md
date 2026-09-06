---
name: claude-code
version_check: curl -fsSL https://downloads.claude.ai/claude-code-releases/latest
version_file: packages/claude-code/manifest.zst.json
changelog_url: https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md
---

# Update Process

The current version is the top-level `version` field of the vendored manifest
(`version_file` above is a JSON manifest, not a `version = "X.Y.Z"` nix
assignment).

claude-code is nixpkgs' own derivation (wrapper env, alsa-lib, install check)
with only the version `manifest` overridden — see `packages/default.nix`. The
vendored manifest is the VERBATIM upstream one for the pinned version (same
file nixpkgs' own update.sh vendors), so the update is one fetch, no hashes to
compute.

It must be the **ZSTD** manifest — the `.zst.json` URL, whose `binary` is
`claude.zst`. Upstream's installPhase runs `unzstd` on the fetched artifact,
so vendoring the plain (uncompressed) manifest fetches a raw binary and the
build dies with `zstd: unsupported format`. That is exactly what happened on
2026-09-07, when nixpkgs switched its default to the compressed artifact and
the plain manifest this spec used to fetch stopped building.

1. Refresh the manifest:
   ```bash
   curl -fsSL "https://downloads.claude.ai/claude-code-releases/${VERSION}/manifest.zst.json" \
     -o packages/claude-code/manifest.zst.json
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
