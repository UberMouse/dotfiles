---
name: playwright-cli
version_check: npm view @playwright/cli version
# The current version is the lock's top-level `version` field: package.nix
# holds no version literal (it derives one FROM this lock, so the two cannot
# disagree by construction).
version_file: packages/playwright-cli/package-lock.json
# @playwright/cli is developed in the playwright monorepo; the standalone
# microsoft/playwright-cli repo is the long-archived pre-1.x tool.
changelog_github: microsoft/playwright
---

# Update Process

The official `@playwright/cli` npm package, fetched as a tarball (`fetchzip`) and
built with `buildNpmPackage`. A vendored `package-lock.json` (copied over the
tarball's own in `postPatch`) plus `npmDepsHash` pin the npm deps. The
`postInstall` swaps the bundled playwright/playwright-core for the
`playwright-web-flake` copies that match the nix-provided browsers — leave that
wiring alone; only the version/hashes below change on an update.

## ⚠️ Version coupling — the flake gates which CLI version is installable

`postInstall` symlinks the `playwright` / `playwright-core` (and their browser
binaries) from the `playwright-web-flake` input into the CLI's `node_modules`,
replacing the tarball's own copies. So the CLI only works when the `playwright`
major.minor it pins matches the version that flake provides. **The install target
is therefore not necessarily the latest CLI (`version_check`'s answer) — it's the
newest CLI whose playwright dep the flake can satisfy.** Do NOT blindly update to
latest.

Gather the three versions that drive the decision:

```bash
# (a) what the flake CURRENTLY provides (the pinned input):
nix eval --raw "github:Pentusha/playwright-web-flake/$(jq -r '.nodes.playwright.locked.rev' flake.lock)#playwright-driver.version"

# (b) what the LATEST CLI wants:
npm view @playwright/cli version                     # latest CLI version
npm view @playwright/cli dependencies.playwright     # its pinned playwright

# (c) whether the flake HEADs have moved on (i.e. would a flake bump help?):
nix eval --raw "github:Pentusha/playwright-web-flake#playwright-driver.version"   # the fork we track
nix eval --raw "github:pietdevries94/playwright-web-flake#playwright-driver.version" # upstream
```

Then decide:

- **Latest CLI's playwright major.minor == (a):** update straight to the latest
  CLI, no flake change. Run the steps below.

- **Latest CLI wants a NEWER playwright than (a):** do NOT jump to latest.
  1. Find the newest CLI version whose playwright major.minor still equals (a)
     — that much is installable now with no flake change. Walk candidates with
     `npm view @playwright/cli@<v> dependencies.playwright`. If such a version is
     newer than the currently pinned one, update to it via the steps below.
  2. Going past that requires bumping the `playwright` flake input. Use (c) to see
     if it would even help: if a fork/upstream HEAD provides the playwright
     major.minor a newer CLI wants, a flake bump would unblock it; if every HEAD
     is still behind (as when the CLI wants 1.62 but the fork is at 1.61), no bump
     helps yet — that CLI version simply isn't installable.
  3. **Never bump `inputs.playwright` (or `flake.lock`'s playwright node) on your
     own.** It rebuilds the driver + browsers, and the fork carries hand-applied
     build fixes (see the comment on `inputs.playwright` in `flake.nix`) — always
     get explicit user permission first. Report (a), (b), and (c) and what a bump
     would/wouldn't unblock, then wait.

After a permitted flake bump, refresh the input with
`nix flake update playwright` (the input is named `playwright`) and re-check (a)
before continuing.

## Steps (install the CLI version chosen above)

1. Get the source (`fetchzip`) hash — `--unpack` matches `fetchzip`'s NAR hash:
   ```bash
   nix-prefetch-url --unpack "https://registry.npmjs.org/@playwright/cli/-/cli-${VERSION}.tgz"
   nix hash convert --hash-algo sha256 --to sri <HASH_FROM_ABOVE>
   ```

2. Regenerate the vendored lock file from the new tarball:
   ```bash
   cd /tmp && rm -rf pwcli-update && mkdir pwcli-update && cd pwcli-update
   curl -sL "https://registry.npmjs.org/@playwright/cli/-/cli-${VERSION}.tgz" | tar -xzf - --strip-components=1
   npm install --package-lock-only --ignore-scripts
   cp package-lock.json ~/dotfiles/packages/playwright-cli/package-lock.json
   ```

3. Compute the new `npmDepsHash` directly from the regenerated lock file (no
   build-fail round trip). NOTE the `cd`: step 2 left the shell in
   /tmp/pwcli-update, and this path is repo-root-relative:
   ```bash
   cd ~/dotfiles && nix run nixpkgs#prefetch-npm-deps -- packages/playwright-cli/package-lock.json
   ```

4. Edit `packages/playwright-cli/package.nix`:
   - `src.hash` → SRI hash from step 1
   - `npmDepsHash` → hash from step 3
   - (NOT `version` — it is derived from the vendored lock regenerated in
     step 2, so version and lock cannot disagree by construction)

5. Verify in isolation (the derivation runs the wrapper's `--version` as an
   install check):
   ```bash
   nix build --no-link .#playwright-cli
   ```
   The build ASSERTS that playwright-core still ships
   `lib/entry/cliDaemon.js` — the path the browser-residency probe matches. If
   it fails there, a playwright bump moved the daemon entry point: update
   `daemonProbe` in `package.nix` and re-check the residency contract
   (kx-build-slot.sh + Semaphore.resident(), see CLAUDE.md).
