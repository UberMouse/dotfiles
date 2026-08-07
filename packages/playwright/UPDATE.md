---
name: playwright-input
version_check: nix eval --raw "github:pietdevries94/playwright-web-flake#playwright-driver.version"
version_file: flake.nix
---

# Check Process (never auto-update)

This spec tracks the `playwright` FLAKE INPUT, not a package directory. The
input is pinned to a rev of Pentusha's fork of playwright-web-flake because
upstream (pietdevries94) had not shipped 1.62 when the fork carried needed
build fixes — see the comment on `inputs.playwright` in `flake.nix`.

A pinned fork of an abandoned-able repo is the kind of dependency that quietly
becomes load-bearing; this spec exists so the weekly run keeps asking the
question the flake.nix comment can't.

There is no `version = "X.Y.Z"` in `version_file` to compare against — the pin
is a rev. Instead, each weekly run:

1. Get what the CURRENT pin provides:
   ```bash
   nix eval --raw "github:Pentusha/playwright-web-flake/$(jq -r '.nodes.playwright.locked.rev' flake.lock)#playwright-driver.version"
   ```

2. Compare with `version_check`'s answer (upstream's HEAD version).

3. **If upstream now provides >= the fork pin's version**: report to the user
   that `inputs.playwright` can likely move back to
   `github:pietdevries94/playwright-web-flake`, and STOP. Never bump this
   input yourself — it rebuilds the driver + browsers and the fork carries
   hand-applied build fixes; the flake.nix comment has the details, and
   `packages/playwright-cli/UPDATE.md` documents the CLI-version coupling that
   must be re-checked afterwards.

4. **Otherwise**: note "playwright fork still ahead of upstream" and move on.
