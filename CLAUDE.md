# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

NixOS dotfiles repository using Nix Flakes. The entire system (OS config + user dotfiles) is declared in Nix and deployed as a single flake output.

## Apply Changes

```bash
sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10
```

You can run this yourself, including in background sessions: `sudo` prompts route
to the user, who can approve them out of band — so run the `switch` directly
rather than falling back to a non-privileged `nixos-rebuild build`.

This is also aliased as `hms` in the shell.

## Verify Before You Switch

- `nix flake check` — builds the full system closure, runs the lints
  (statix, deadnix, shellcheck on `scripts/` AND `scriptBins/bins/`, ruff +
  py_compile, forbidden-pattern and docs-liveness tripwires), fails on an
  unformatted tree, and runs the deterministic test suites in the sandbox.
- `nix build .#<name>` — builds one custom package in isolation (seconds);
  the way to verify a version/hash bump.
- `scripts/run-tests.sh` — every `scripts/*.test.py` suite (discovered by
  glob, never listed) plus the lint tripwires. All deterministic: policy is
  unit-tested against a pure `decide()` with an injected clock, blocking is
  asserted from log lines rather than elapsed time, and slow-converging
  outcomes are polled via `testlib.wait_for`, never fixed sleeps.
- `nix fmt` — formats the tree (nixfmt-rfc-style via treefmt). Whole-tree
  mechanical reformats get their SHA added to `.git-blame-ignore-revs`.
- A `pre-push` hook (`hooks/pre-push`, wired via a gitdir-scoped includeIf
  in home.nix) runs every flake check except `toplevel` automatically — the
  list is derived from the flake, never hardcoded. NOTE: a machine-local
  `.git/config` `core.hooksPath` silently overrides this wiring (found dead
  exactly that way 2026-08-07); `git config --show-scope --get-all
  core.hooksPath` — a `local` row is the bug.
- There is deliberately NO CI (a GitHub Actions workflow was added 2026-08-07
  and removed next day — taylorl doesn't want to deal with it). Do not
  re-suggest one in audits; the pre-push hook and `nix flake check` before a
  switch are the only gates, so keeping the hook wiring alive (above) is
  load-bearing.

## Architecture

**Entry point:** `flake.nix` defines a single NixOS configuration (`ubermouse`)
composing, in module order:
- `work-vm.nix` — VMware hardware (filesystems, LUKS). Machine-unique; listed
  in the flake's module list so `nixos.nix` stays host-generic.
- `nixos.nix` — system-level config (services, users, i3, OOM protection)
- the kolide-launcher input's NixOS module — a root-privileged endpoint agent,
  enabled in `nixos.nix`. It tracks upstream `main` and moves with the weekly
  `nix flake update` like every other input; it deliberately has NO UPDATE.md
  (retired 3547f73 — not worth the weekly question). Don't re-flag the
  missing spec in audits.
- `home.nix` — user-level config via home-manager (packages, programs)
- `cgroups.nix` — the worktrees resource-pool subsystem (pool slices + the
  governor/monitor/semaphore-controller services); imported by `home.nix`
- `memory-policy.nix` — THE memory partition numbers (desktop floor, pool
  ceiling), shared by `nixos.nix` and `cgroups.nix`, with the margin invariant
  enforced as an eval-time assertion. Change the numbers there, nowhere else.

**Application modules** (imported by home.nix):
- `i3.nix`, `zsh.nix`, `neovim.nix`, `scriptBins/` (per-script files under
  `scriptBins/bins/`, wired by `scriptBins/default.nix`)

**Custom packages:** one directory per package under `packages/<name>/`
(`package.nix` + `UPDATE.md`), AUTO-DISCOVERED by `packages/default.nix` into
the overlay — adding a package is one directory, no flake.nix edit. The
flake's `packages.x86_64-linux` output derives its attr list from the same
discovery, so the two cannot drift. Directories WITHOUT a `package.nix` are
deliberate: `playwright/` is a check-only UPDATE.md spec for a flake input
(check-only is declared by `mode:` in the spec's own frontmatter, never
listed in the skill), and `claude-code/` holds only a version manifest —
claude-code is nixpkgs' own derivation with `manifest` overridden (the weekly
bump is one `curl` of the upstream manifest.json).

**Two nixpkgs channels:** stable (`nixpkgs` — the release is whatever
`flake.nix` pins; don't restate the number in prose, it rots) and
`nixpkgs-unstable`. Passed via `specialArgs`/`extraSpecialArgs`. (A third,
unstable-small, existed solely for fresher claude-code; the manifest override
made channel freshness irrelevant and it was dropped.) The channel RULE:
ordinary packages come from stable; unstable exists as the overlay's base —
only the custom/overlaid packages (and playwright, whose flake follows
stable) resolve from it. A non-custom package taken from unstable needs a
recorded reason, or it's drift.

The lockfile carries exactly these two nixpkgs. A third used to ride in on the
oh-my-pi (`omp`) input, which was REMOVED 2026-09-14 — it was unused and its
rust-nightly-plus-~400-crates build dominated every `nix flake check`. Its
dedicated nix-community substituter in `nixos.nix` went with it, since nothing
else here needed that cache. Don't re-add either without a reason of its own.

**Not part of the flake:** `userscripts/` holds browser userscripts, kept here
only so a userscript manager can `@updateURL` them from raw.githubusercontent
(the repo is public, default branch `master` — that URL is the contract, so
moving or renaming a file there breaks every install silently). No Nix
imports them and no lint covers them; they are not built or installed by a
switch. Don't audit them for drift against the system config.

## Docs Layout

- `CLAUDE.md` — standing rules and traps an agent needs on every task.
- `docs/plans/` — live implementation plans only; delete on ship (history
  keeps them).
- `docs/notes/` — dated investigation write-ups worth keeping. Subject to
  the same no-hand-copied-machine-facts rule as everything else; a note
  whose numbers have rotted gets deleted, not corrected.
- `packages/*/UPDATE.md` — per-package update specs (see below).
- `README.md` — bootstrap + day-to-day pointer; it deliberately defers to
  this file so the two never drift.

The lint's docs-liveness check walks CLAUDE.md, README.md, `docs/**/*.md`,
the skills, and the COMMENT LINES of every `.nix` file (Nix comments narrate
the tree layout — `packages/default.nix` named a deleted directory for three
commits before they joined the corpus), so a path named anywhere in them
must exist.

## Conventions

- Conventional commits, scoped, imperative, with subjects that carry the *why*:
  `feat(cgroup): pace growth against load, not a clock`. Automated version
  bumps commit as `chore(deps): …` (the weekly-update skill's format), so they
  are distinguishable from changes to the tooling itself.
- UPDATE.md specs use greppable anchors, never line numbers ("the
  `npm:…` pin", not "line ~128"), and the hash command must match the fetcher:
  `fetchurl` ↔ `nix store prefetch-file`; `fetchzip` ↔ `nix-prefetch-url
  --unpack` + convert. A mismatch silently freezes the package: every weekly
  run fails its hash step and skips it (this happened for 3 months once).
- Machine facts (RAM sizes, cgroup caps, core counts) are never hand-copied
  into prompts, comments-as-config, or docs — interpolate from the source
  (see the stall-diagnosis prompt in `scripts/cgroup-pressure-monitor.sh` and
  `memory-policy.nix`). Hand-copied numbers rot silently and poison whatever
  reasons from them.

## Key Patterns

- Home-manager runs as a NixOS module (not standalone), so changes require `nixos-rebuild switch`
- The personal `~/.claude/CLAUDE.md` is managed by home-manager: `claude/CLAUDE.md` is symlinked to `~/.claude/CLAUDE.md` (see home.nix)
- Git is configured with SSH signing via 1Password agent
- Agent runtime state (`.pi/`-shaped directories, `.claude/` scratch) is
  ignored via the tracked `.gitignore`, never `.git/info/exclude` (machine-
  local, doesn't survive a clone — that gap once let 144 MiB of agent
  transcripts get committed by an automated `git add -A`). `.claude/` is an
  ALLOWLIST (`.claude/*` + `!` entries for the tracked paths): the harness
  grows new state files on its own schedule, so tracking a new `.claude/`
  path means adding a `!` line, and everything unlisted is ignored by
  default

## Build Semaphore

Heavy jobs (typechecks, jest shards, browser launches) wrap themselves in
`kx-build-slot`. A controller (`scripts/build-semaphore-controller.py`) publishes
`max_slots` slot files in `$XDG_RUNTIME_DIR/kx-build-sem/` and throttles capacity by
**holding slots itself** — it withholds from the top, clients scan from the
bottom, and the two never contend. Every tool in this subsystem honours a
`KX_POOL` env override for the pool cgroup path (tests point it at a synthetic
tree); the sites spell the default differently (`$USERAT`, `$U`, f-strings),
so the lint check enforces the invariant that actually matters — every
path-construction site carries its `KX_POOL`/`KX_SEM_POOL` override within
two lines.

Traps when diagnosing it:

- **`memory.current` IS NOT MEMORY IN USE — it counts page cache.** `free`
  files that same cache under `buff/cache`, not `used`, so a pool reading
  at its ceiling beside a machine reporting far less in use is not a contradiction:
  the two never measured the same thing. This pool does tens of GB of file IO,
  so the gap is routinely HALF the charge (measured 2026-08-20: 15.2G charged,
  7.36G anon, 7.27G reclaimable — 5.6G of it cold `inactive_file`). Every
  consumer therefore reads the charge NET of what the kernel reclaims unasked,
  via `scripts/cgroup-mem.py` — the i3 bar and `build-semaphore-controller.py`
  import it (as a store path: `@memlib@` in `scriptBins/default.nix`,
  `KX_CGROUP_MEM_LIB` in `cgroups.nix`), and `wt-cgroup-status.sh` mirrors it
  in awk with the two implementations asserted equal in
  `wt-cgroup-status.test.py`. Change one, change the other.
  - The correction is a DENYLIST (subtract `file` − `shmem` − `unevictable`,
    plus `slab_reclaimable`) so an unfamiliar kernel key stays counted as used
    and the pool reads FULLER than it is. No signal falls back to the raw
    charge for the same reason: tighten early, never late.
  - `memory.high` is NOT corrected to match — it is a limit on the raw charge,
    and inflating the ceiling would give back the optimism the numerator exists
    to remove.
  - **That uncorrected ceiling comes back as PSI.** The kernel enforces
    `memory.high` against the RAW charge, so a pool doing heavy file IO pins the
    charge at the ceiling and pays reclaim throttling — and that throttling IS
    memory pressure. Every FRACTION here is corrected for cache; PSI cannot be,
    because it is a MEASURED STALL rather than a computed ratio. The stall
    genuinely happened; it just says nothing about what builds hold. Measured
    2026-08-27: net in-use 4.9G of a 16G high (31%), desktop session at 0.00%
    pressure, 11.8G MemAvailable — while `memory.events:high` climbed in
    hundreds per tick and psi10 spiked to 39%. All 28 tightens in two hours were
    `psi10=`, the predictive signal never fired once, and `allowed` averaged
    3.25 while spending 29% of its time at 1–2: builds serialised to relieve
    pressure the ceiling was manufacturing against their own page cache. So
    `decide()` CROSS-CHECKS — a PSI tighten holding several jobs' worth of net
    pool headroom AND ample machine-wide `MemAvailable` is SELF-INFLICTED and
    may only reach `soft_floor`, never `floor`. Both terms are required (the
    pool-local one alone would dismiss real scarcity on a globally starved box,
    where global reclaim lands on the pool) and each reads no-signal as NOT
    self-inflicted, so an unreadable input keeps the full floor — tighten early,
    never late. It is deliberately NOT a suppression of `hot_psi`: with the
    signal off entirely, LOOSEN would ratchet to `ceil` straight through an
    episode of thrash, which PSI is the only signal positioned to catch. Log
    tag: `[self-inflicted, soft floor N]`.
  - **The LOOSEN gate needed the same exemption, and bounding only the descent
    fixes half a sawtooth.** `psi60` is the raw stall average too, so the same
    cache reclaim keeps it over `loosen_psi` for as long as the pool does file
    IO — and every recovery step is gated on it. Measured 2026-08-27 with the
    tighten half already shipped: minutes at `allowed=2` with `psi10` at 0.00%
    and 18 jobs queued, because `psi60` sat at 4.4% against a 3.0% gate while
    the pool was 40% full with 9.6G of headroom. So a self-inflicted window
    passes the gate as well (log tag `[self-inflicted]` on the LOOSEN line).
    Safe because `allowed` is a CAP, not an admission — every start is still
    gated tick-by-tick by the load test, which is deliberately NOT exempted —
    and self-limiting, because the exemption needs several jobs' worth of net
    headroom and so withdraws itself as builds genuinely fill the pool. The
    other loosen guards (`cap_saturated`, dwell, ceiling) are untouched and
    asserted against.
  - This is the same misreading commit d17dc8b fixed for the FLEET term, and it
    survived on the pool side because the argument that retired it there —
    subtracting the same bytes from usage and ceiling cancels — is true of the
    fleet and FALSE of cache, which appears on the usage side only. Uncorrected
    it published `healthy=0` and logged `HOLD free=0.2G<3.0G` at 0.00% memory
    pressure while `allowed` walked 5 → 1.
  - **`pool_mem` must stay exactly two elements wide.** `decide()` unpacks it
    (`pool_cur, pool_high = pool_mem`) and the policy suite builds it as a plain
    2-tuple, so `read_pool_mem` returns its third (cache) element for the LOG
    and `main()` splits it off. Widening the value that reaches `decide()`
    raises ValueError inside the tick thread — the control loop dies while the
    state file goes on publishing its last plausible value. Asserted in
    `build-semaphore-controller.test.py`.

- **Held-back ≠ in-use.** A slot the controller is withholding and a slot a job
  occupies are both just `flock` failures — indistinguishable from outside. Do
  NOT probe with `flock` and conclude anything; probing also corrupts a running
  controller, since a test-and-release reads as an admission and restarts its
  grant clock. Read the `allowed` file instead. Its field order is defined
  ONCE, by the `Semaphore.FIELDS` tuple in the controller
  (`allowed effective max_slots occupied target mark resident healthy`,
  append-only), and the fast suite asserts every reader's indices against it.
  `1 1 16 1 1 1 0 1` means capacity 1, one job running, no browsers, load test
  passing — a *healthy* saturated semaphore, not a stuck one. The file's
  mtime is a HEARTBEAT: the controller re-publishes every tick (unchanged or
  not — that is a contract, never optimize it to publish-on-change), and
  readers treat age beyond `KX_SEM_STALE_AFTER` (~3 ticks) as controller-dead
  — the client fails open instead of trusting a stale `healthy=0`, and
  i3status shows "off" instead of a dead controller rendering as "idle".
- **`allowed` is enforced by the CLIENT; withholding alone never worked.** The
  controller's only lever is locking slots as jobs return them, and it loses
  that race — it retries once per 5 s control interval while waiting clients
  retry every 0.2–0.5 s (`jitter_sleep`), roughly 14:1 against it, and under a
  queue of short jobs the handoffs never stop. Measured 2026-08-17: memory
  pressure took `allowed` 8 → 1 in seventeen seconds and `effective` sat at 8
  for ELEVEN MINUTES, admitting 87 typechecks eight-wide against a cap of one,
  draining only once the burst ended — the clamp took hold exactly when it was
  no longer needed. So `kx-build-slot` reads the published cap itself
  (`sem_over_cap`) and refuses a free slot at capacity. Consequences when
  reading this subsystem: a gap between `allowed` and `effective` is normal and
  is NOT evidence the cap is being ignored; and the test is `occupied >=
  allowed`, never `occupied - resident >= allowed` — `decide()` shifts every
  bound by the resident count so `allowed - resident` means "how many builds
  may run", which makes the resident terms cancel. Subtracting on one side only
  spends the resident quota twice and grants an extra build per open browser.
  A residual overshoot of up to one publish interval remains by construction
  (`occupied` is a published value); closing it needs the controller to win its
  reclaim race with a blocking acquire, not another client-side change.
- **Some slots are held by browsers, not builds.** `playwright-cli open` gates
  the launch *and* keeps the slot for as long as the browser lives, via a keeper
  subshell forked (never exec'd — fork shares the open file description and so
  inherits the lock without a re-acquire race). Those slots are marked in
  `$XDG_RUNTIME_DIR/kx-build-sem/resident/` (format: `keeper=<pid>`, parsed by
  `Semaphore.resident()`), and the controller raises its floor by that count so
  residents can never squeeze build admission to zero. Build capacity is
  therefore `allowed - resident`, not `allowed`.
- **A resident job waits on the load test, not just on a free slot** (`--resident`).
  The floor keeps one slot free whenever no *build* is running, and that slot is
  free regardless of memory. A browser that took it became resident, which raised
  the floor, which freed the next one — self-feeding. Measured 2026-08-07: twelve
  browsers admitted onto a pool at 15.5G/16G with `psi10=40%`, `allowed` pinned at
  1 throughout. Any future job that leaves something resident behind must pass
  `--resident`, or it will find the same open door.
- **Residency is capped** (`KX_SEM_MAX_RESIDENT`, default `max_slots - ceil`).
  The published `healthy` field is the load test AND the cap — only resident
  admissions read it, so at cap new browsers queue while builds are untouched.
  Without the cap, enough browsers make every slot keeper-held and every build
  runs ungated after its timeout.
- **A calm pool can mean an ESCAPED FLEET, not a quiet machine.** The cc-daemon
  decides the cgroup of every agent worker (a cgroup is inherited at fork), so
  if the daemon is misplaced the whole fleet is, and the pool then reads calm
  because it is EMPTY. Worst case it lands in `claude-ui.slice` —
  `CPUWeight=5000`, no `cpu.max` — where the fleet outranks the desktop 50:1
  and answers to no core cap; measured 2026-09-22 at 71 processes, load 73 on
  16 cores, while `worktrees.slice` sat under its 12-core cap doing almost
  nothing. Diagnose by reading `/proc/<pid>/cgroup` for the DAEMON, never from
  pool utilisation. Two traps that made this expensive:
  - **`claude-agents.sh` must wait for THIS TUI's daemon, not for any daemon.**
    A cc-daemon outlives its TUI, so a leftover from the previous session
    satisfies a bare "is a daemon up" test instantly — the reattach then fires
    against the already-correct old daemon and exits one second before the new
    one is forked. It matches on the `--spawned-by {...,"pid":N}` argv
    field (N = the TUI's pid, which is `$$` because both launch paths `exec`
    in place), falling back to a pre-launch daemon-pid snapshot diff, and
    reattaches unconditionally on timeout.
  - **Counting pids MIGRATED is not the same as asserting none ESCAPED.** The
    failing run logged `rc=0 ... 0 moved, 7 already in slice` — indistinguishable
    from success, which is why it ran 37 minutes. `claude-agents-reattach`
    re-scans afterwards and exits non-zero naming any daemon still outside the
    fleet leaf, and `wt-cgroup-i3status.py` shows `⚠ fleet escaped` from the
    same invariant.
- **The predictive tighten measures the BUILD BUDGET, not the pool.** The pool
  holds the agents fleet (`worktrees-agents.slice`, re-homed there by
  `claude-agents-reattach`) alongside the builds, and the fleet takes no slots
  — measured 2026-08-17 at 4.4–13.2G of an 18G pool. Tightening `allowed`
  cannot reclaim a byte of it, so `high_frac` subtracts the fleet from BOTH the
  usage and the ceiling: it asks "how much of the memory available to builds are
  builds using". Reading the logs: `build=NN% (fleet N.NG)` is that corrected
  fraction, `high=NN%` is the uncorrected whole-pool one and means
  `worktrees-agents.slice` was unreadable (`read_untracked_mem` → None, which
  falls back deliberately — it reads the pool as fuller, so it errs toward
  tightening early). The LOAD TEST is deliberately NOT corrected this way:
  its headroom is `high - current`, and subtracting the same bytes from both
  terms cancels. Free bytes are free bytes no matter who is not using them.
  That reasoning covers the FLEET only — both signals take a `current`
  that is already net of reclaimable page cache (see the `memory.current` trap
  above), because cache has no matching term in the ceiling to cancel against.
- **A `bg-spare` in an argv does NOT mean an idle process.** It says how the
  process started; the claim socket is unlinked once a session takes it, and
  the spare becomes a live agent session. On 2026-08-17 nine `bg-spare`
  processes held 2.85G and exactly ONE (95 MB) was unclaimed standby — the
  rest sat in worktrees with 233–1298s of CPU each. Counting them by argv
  reads ~2.7G of real work as reclaimable slack. Check `/proc/<pid>/cwd`: a
  genuine idle spare is still inside the cc-daemon's spare directory, while a
  claimed one has moved to the worktree it is working in.

- **Demand is invisible unless the waiting job says so.** A held slot is a lock
  in `/proc/locks`; a job WAITING for one touches nothing, because
  `kx-build-slot` polls with `flock -n` and sleeps. So do not try to read queue
  depth from the `->` rows in `/proc/locks` — the client never blocks in the
  kernel and never creates one (those rows exist only for a future caller using
  a blocking `flock`, and both readers skip them so a queue cannot inflate
  occupancy). A waiting job instead holds an exclusive flock on
  `$XDG_RUNTIME_DIR/kx-build-sem/waiting/<pid>` for exactly as long as it waits.
  THE LOCK IS THE CONTRACT, not the file: an unlocked marker is a job that was
  SIGKILLed mid-wait and counts for nothing, which is what makes the queue
  self-cleaning with no reaper (same argument as the slots themselves). Marker
  files are pid-named, so the litter is reused rather than accumulated, and
  nothing sweeps it. The marker is taken lazily (only once a job has actually
  failed a pass, so the common case pays nothing) and dropped BEFORE `run_child`
  and before every `exec "$@"` — fds survive fork and exec, so a marker left
  open would be inherited by the very build it was counting the wait for.
  Readers: the `⧗` field in `scriptBins/bins/wt-cgroup-i3status.py` and the SEM
  line in `scriptBins/bins/wt-cgroup-status.sh`. Unlike a slot, a MARKER is safe
  to probe with `flock` (it reserves nothing, so a test-and-release denies no
  job and restarts no grant clock) — which is why the bash reader may probe
  while the Python one reads `/proc/locks`.

Three files have to agree on residency — `kx-build-slot.sh` (keeper + marker),
`packages/playwright-cli/package.nix` (`--resident-probe`; its build ASSERTS
the probe's cliDaemon.js path still exists so a playwright bump can't silently
kill residency), and `build-semaphore-controller.py` (`Semaphore.resident()` +
the dynamic floor). Change one, check the other two.

Two standing traps when working on any of this:

- **Never identify processes with `pgrep -f`.** It matches the pattern against
  every process's full command line, so the probe matches *itself*, plus any
  grep or editor holding the string. Measured 6 daemons against 4 real ones on
  2026-08-07. Use `kx-proc-find` (glob per argv field, matched in order,
  self-excluding) — the lint check fails on any new `pgrep -f`.
- **Guards phrased against total occupancy silently die once browsers exist.**
  `if occupied == 0` never fires again while a session is open. The build-
  progress guard has to read `occupied - resident`. This is the same shape as
  the `compgen` and dead-actuator bugs: a test that can no longer be true,
  quietly disabling a safety property while the log still looks healthy.

Tests: `scripts/run-tests.sh` discovers and runs every `scripts/*.test.py`
suite (shared harness in `scripts/testlib.py` — `check`/`wait_for`/`summary`),
and ALL of them also run sandboxed under `nix flake check`. The semaphore
splits in two: `build-semaphore-policy.test.py` (the control law as
pure-`decide()` unit tests with injected clocks) and
`build-semaphore-controller.test.py` (the machinery — flock reconcile,
publish heartbeat, marker pruning, orphan-slot sweep — running the real
`main()` in a thread with a stepping sleep stub, so each tick is exact and
the suite finishes in well under a second). The machinery suite's genuinely
host-only checks (kernel signal delivery, flock drop on real process death)
run only under `KX_TEST_HOST_ONLY=1`, which run-tests.sh exports; in the
sandbox they SKIP loudly. The rest — `kx-build-slot.test.py` (client half +
the state-format and resident-marker contracts), `cgroup-governor.test.py`
(the extracted tick decision, detection functions AND actuator failure paths
against a synthetic pool), `kx-proc-find.test.py` (argv-matching semantics
against real fixture processes), `wt-cgroup-i3status.test.py`,
`cgroup-thaw-all.test.py`, `op-cached.test.py`, `claude-usage.test.py`,
`wt-reap.test.py` (real git repos and worktrees, not fixtures — every
decision the reaper makes is a git question) — are all sandboxed flake
checks too. Anything testable without a live control loop belongs in a unit
test, not a new integration harness.

## Disk Reclamation

The disk filled on 2026-08-10 with `nix.gc` working perfectly. Understand
why before touching any of this, because each piece covers a gap the others
structurally cannot:

- **`nix.gc` reclaims on a CLOCK, not on free space.** The morning of the
  fill it had run and freed 244.9 MiB, and its next run was 13 hours away.
  `nix.settings.min-free`/`max-free` (in `nixos.nix`) is the only mechanism
  that reacts to the disk actually filling: the daemon GCs mid-build and
  carries on. Never treat the timer as the safety net.
- **A GC can only free what is unreachable, and direnv makes almost nothing
  unreachable.** 457 indirect roots in `/nix/var/nix/gcroots/auto`, all
  `.direnv/flake-inputs` and `.direnv/flake-profile-*` inside agent
  worktrees, pinned a 6,575-path closure — essentially the whole live store.
  Roots are why a GC run "does nothing"; check them (`readlink` the auto
  dir) before concluding the store is genuinely all live.
- **No GC of any kind reclaims `node_modules`.** The store was never the
  bulk of it: ~2.5G of rush/pnpm install per worktree, ~80 worktrees.
  `wt-reap` (`scriptBins/bins/wt-reap.sh`) is the only thing that touches
  that, and removing the worktree is also what makes its direnv roots
  dangle — the store reclamation is a second-order effect of the same act.

Traps when working on the reaper:

- **Age is not a staleness signal here.** All 79 worktrees at the time of
  the fill had been touched inside 6 days. A `--delete-older-than`-shaped
  rule fires on nothing precisely when it is most needed; the criterion is
  git state (adds no commits to the integration ref, no modifications, no
  untracked files). Deletions do NOT veto — the ` D` removal of the
  `.quint/` tree is the normal dirty state, not work.
- **A missing integration ref must skip the repo, never reap it.** An
  unresolved base makes `$base..HEAD` empty for every branch, which scores
  the entire repo as disposable. This is the worst bug the script can have
  and it is asserted against.
- **A nested worktree is not dirt.** Worktrees nest three deep and every
  level registers against the same repo, so to `git status` in the parent a
  child is just `?? .claude/` — forever. `tree_is_clean` excludes registered
  descendants by pathspec; without it no worktree that ever hosted a child
  is reapable again. kawaka gitignores `.claude/worktrees`, which HIDES this
  — don't let that mask a regression.
- **A reapable parent holding a kept child must be kept.** Removing the
  parent unlinks the child's files regardless of what git thinks it is
  doing, and git reports nothing because from its side the child was merely
  pruned.

## Updating Custom Packages

Use `/weekly-update` to update all packages with UPDATE.md specs. Each package in `packages/*/UPDATE.md` defines its own version check command and update process. For manual updates, follow the instructions in the relevant UPDATE.md file, and verify with `nix build .#<flake_attr>` (the spec frontmatter's `flake_attr`, defaulting to its `name`) before switching.

Use `/repo-audit` for the periodic drift sweep (docs vs reality, dead code,
orphaned pins, repo weight, cross-file contracts).
