---
name: playwright-input
# check-only: there is no `version = "X.Y.Z"` to extract or bump; the pin is a
# flake.lock rev and this spec only ever REPORTS. The weekly-update skill
# skips version-file extraction for mode: check-only specs and follows the
# body directly.
mode: check-only
version_check: nix eval --raw "github:pietdevries94/playwright-web-flake#playwright-driver.version"
version_file: flake.lock
---

# Check Process (never auto-update)

This spec tracks the `playwright` FLAKE INPUT, not a package directory. The
input is `pietdevries94/playwright-web-flake`, rev-pinned — see the comment on
`inputs.playwright` in `flake.nix` for why it is rev-pinned and not
branch-tracking, and for the source history.

**Source choice.** It moved here from the fork `Pentusha/playwright-web-flake`
on 2026-11-04 because upstream was shipping driver releases sooner. Pentusha
stays the fallback. Either direction, a switch is proven only by `nix build
.#playwright-cli` (it builds every browser, webkit included) plus a launch of
all three engines — NEVER by matching version numbers: on 2026-09-14 the two
sat at an identical 1.63.0 and pietdevries94 failed to build (webkit missing
`libmanette`). If HEAD here stalls behind a release the fork already has,
report both versions; don't switch without the build proof.

So the weekly question is just whether our pin has fallen behind:

1. Get what the CURRENT pin provides:
   ```bash
   nix eval --raw "github:pietdevries94/playwright-web-flake/$(jq -r '.nodes.playwright.locked.rev' flake.lock)#playwright-driver.version"
   ```

2. Compare with `version_check`'s answer (the source's HEAD version).

3. **If HEAD is ahead of the pin**: report the two versions and STOP. Never
   bump this input yourself — it rebuilds the driver + browsers, and
   `packages/playwright-cli/UPDATE.md` documents the CLI-version coupling that
   must be re-checked afterwards. A bump is worth proposing when a newer
   `@playwright/cli` is blocked on it (that is what drove the 2026-09-14 bump);
   otherwise there is no reason to rebuild every browser.

4. **Otherwise**: note "playwright pin current" and move on.
