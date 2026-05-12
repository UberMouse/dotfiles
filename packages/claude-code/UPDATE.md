---
name: claude-code
version_check: npm view @anthropic-ai/claude-code version
version_file: packages/claude-code/package.nix
changelog_url: https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md
---

# Update Process

1. Get source hash:
   ```bash
   nix-prefetch-url "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/${VERSION}/linux-x64/claude"
   nix hash convert --hash-algo sha256 --to sri <HASH_FROM_ABOVE>
   ```

2. Edit `packages/claude-code/package.nix`:
   - `version` → new version
   - `src.hash` → SRI hash from step 1
