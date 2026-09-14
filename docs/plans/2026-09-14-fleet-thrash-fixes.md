# Plan — fleet anon thrash: four fixes

Evidence: `docs/notes/2026-09-14-fleet-anon-thrash.md`. Scope decided
2026-09-14 by taylorl: cache premise gates LOOSEN only; Duty A gets an
effectiveness gate (not removal, not a standby leaf); fleet demand gets a
freezable-not-killable worker list plus residency for dev servers; zram is
measure-first. Nothing here is approved for implementation yet.

Phases are independent and ship as separate commits, in this order. Each
lists the tests that make it safe, since `scripts/run-tests.sh` and
`nix flake check` are the only gates.

---

## Phase 1 — the LOOSEN exemption must require a cache-heavy pool

`scripts/build-semaphore-controller.py`, `decide()`.

**Why.** The exemption exists because of a premise, stated in 67a7488: the
stall is the pool's ceiling squeezing its own page cache. None of
`self_inflicted`'s three terms measures cache. On 2026-09-14, `minority_builds`
held during fleet-anon thrash at 19–34% cache, and the LOOSEN exemption
re-opened admission 9 times. This is the second time the premise expired
with nothing to notice it (09-04 was the first).

**Split, don't widen.** The TIGHTEN softening stays exactly as it is. Its
justification since 7399d05 is the *lever* ("builds cannot free this
charge"), and that holds whatever the charge is made of. Only the LOOSEN gate
takes the new term, because an exempted loosen re-opens admission; a
softened tighten still tightens.

**Change.**
- New cfg field `self_inflicted_cache_frac: float = 0.40`, with a rationale
  comment. The regime where the premise held ran at ~48% reclaimable
  (2026-08-20). Stall snapshots since 08-26 read 8–34% on most days.
- `cache_heavy = pool_mem and pool_cache are both readable, raw > 0, and
  pool_cache / (pool_mem[0] + pool_cache) >= cfg.self_inflicted_cache_frac`.
  Read no-signal as NOT cache-heavy, the same direction as every other
  fallback. `pool_mem` stays a 2-tuple (see CLAUDE.md).
- LOOSEN gate: `psi60 < cfg.loosen_psi or (self_inflicted and cache_heavy)`.
- The LOOSEN tag carries the fraction: `[self-inflicted, cache NN%]`. Rewrite
  the stale "self-limiting: requires several jobs' worth of net headroom"
  comment, which stopped being the whole truth when `minority_builds` became
  an alternate route.

**Calibrate before trusting 0.40.** Commit 1a adds only the cache fraction
to every TIGHTEN, LOOSEN and HOLD line, with no behaviour change. Run it
across a few working days, then check the distribution around exempted
loosens that were followed by a re-tighten against those that weren't. Adjust
the default in commit 1b if the data disagrees.

**Tests** (`scripts/build-semaphore-policy.test.py`):
- today's case: minority builds, desktop quiet, MemAvailable over the gate,
  cache 19%, psi60 7% → **no loosen**
- the 08-27 case restated with cache 48% → loosen still passes, tagged
- cache unreadable → no exemption
- cache 19% with a hot psi10 → TIGHTEN still stops at the soft floor (asserts
  the split)
- exactly at the bar → cache-heavy (pin the inequality)
- The existing "self-inflicted psi60 does not block recovery" fixture must
  now state its cache explicitly. Otherwise it silently tests the no-signal
  path.

---

## Phase 2 — Duty A backs off when reclaim is feeding thrash

`scripts/cgroup-governor.sh`, the TIGHT branch's `reclaim_from "$FLEET"`.

**Why.** The duty's header assumes idle `bg-spare` heaps are the coldest pages
in the agents slice. That was 2.9G on 07-28; on 09-14 it was 0.65G. Three of
the five sampled reclaims left the charge at or above where it started, while
the governor spent a core of sys time on them.

**Signal: refault ratio over the tick, pool-scoped.** When most anon pages
being stolen are refaulted almost immediately, evicting more anon only feeds
the loop. Both counters are in the agents slice's own `memory.stat`
(`workingset_refault_anon`, `pgsteal`), read with builtins like
`read_meminfo`. No new forks.

**Change.**
- A pure function in the `classify_state`/`brake_step` style:
  `reclaim_useful prev_refault prev_steal cur_refault cur_steal ->
  RECLAIM_USEFUL`. It returns not-useful when `steal_delta` is at least a
  floor AND `refault_delta * 100 >= steal_delta * CGGOV_THRASH_PCT`. A
  missing or short read, or counter reset, returns **useful**, so an
  unreadable signal keeps today's behaviour.
- Gate only Duty A. The STALL path's `reclaim-arm` stays ungated: it is the
  desktop's emergency path, and being late there is the worse failure. It
  logs the ratio anyway.
- Log the gate: `RECLAIM|SKIPPED-THRASH refault=N steal=N (NN%)`, plus
  `ratio=NN%` on every RECLAIM line.
- Rollout: default `CGGOV_THRASH_PCT` off (log-only) for the first commit.
  Pick the threshold from the logged ratios, then enable. Today's samples
  ran ~100%; a working reclaim of genuinely cold pages should read far lower.
  That still needs to be measured.

**Tests** (`scripts/cgroup-governor.test.py`, sourcing the script like the
existing `classify_state` cases): thrash → skip; cold reclaim → proceed;
counter reset (cur < prev) → proceed; zero steal → proceed; missing
`memory.stat` → proceed; STALL path unaffected.

---

## Phase 3 — freezable is not killable: split the worker lists

`scripts/cgroup-governor.sh` (`WORKER_RE`), `nohang/nohang.conf`.

**Why.** The two lists are "kept in step" by comment only, so adding an
install to the freeze set would also make nohang prefer killing it. They
have **already drifted**: nohang targets bare `playwright` (200), and
`WORKER_RE` has only `ms-playwright`.

**Change.**
- Make the contract "nohang's kill set ⊆ the governor's freeze set", and
  assert it in a test. The test parses nohang.conf's positive
  `@BADNESS_ADJ_RE_CMDLINE` lines and checks that each pattern appears in
  `WORKER_RE`. Resolve the existing `playwright` drift as part of this
  commit: either add it to `WORKER_RE`, or narrow nohang to `ms-playwright`.
  Decide when implementing, after checking what bare `playwright` matches.
- New freeze-only alternation (e.g. `FREEZE_ONLY_RE`) matched in addition to
  `WORKER_RE` inside `sweep_transient`:
  - `rush install` / `pnpm install`, anchored on argv (the `/rush` or
    `/pnpm` script path followed by an `install` field), never a bare
    substring. Verify first that a live install's RSS clears
    `CGGOV_WORKER_MIN_MB`; otherwise it never migrates and the entry is
    decoration.
  - playwright's `/entry/cliDaemon.js` (it owns the headless chromium, which
    is already on the list).
- **Excluded, with reasons:** `http-server`. Measured at 51M RSS with most
  of it swapped. That is under the migration floor, and freezing a swapped-out
  server frees nothing: a freeze pauses CPU and allocation, it does not
  reclaim.
- Freezing an install briefly holds the rush lock for that worktree. That is
  acceptable: `MAX_FREEZE_SECS` bounds it. Note it in the comment.

**Tests:** subset assertion; `sweep_transient` migrates a fixture install
process; the shell guard still wins over an install string in argv (the
`zsh -c "... rush install ..."` case).

---

## Phase 4 — dev servers hold a resident slot for their lifetime

Two repos. Dotfiles: `scriptBins/bins/kx-build-slot.sh`, the controller's
`Semaphore.resident()`, `scripts/kx-build-slot.test.py`. Kawaka:
`~/code/kawaka/packages/tools/monorepo-jobs/src/server-spawn.tsx`.

**Why.** A `heft start` (3.3G + 0.6G swap) ran outside all admission. The
existing residency path (`--resident-probe`) models a command that *returns*
and leaves a daemon behind. `spawnProcess` instead runs the server in the
foreground for its whole life, so there is nothing for a probe to diff.

**Change.**
- New `kx-build-slot` mode, say `--resident-self`. It acquires the slot
  through the `--resident` admission path (load test AND resident cap, per
  CLAUDE.md's "a resident job waits on the load test" trap). It writes the
  resident marker naming the wrapper's own pid (`keeper=<pid>`, the existing
  format, so `Semaphore.resident()` needs no parser change), runs the command
  as a child, and holds the slot until it exits. Signals must reach the
  child: `spawnProcess` uses `detached: true` + `killGroup`, so the wrapper
  and server share a process group and a group kill takes both. Assert that
  in a test.
- Fail-open paths unchanged: no semaphore dir → exec; timeout → run
  unmarked, and log it.
- Kawaka: `spawnProcess` prefixes `kx-build-slot --resident-self --label
  server:<name> --` when `kx-build-slot` is on PATH. Its fail-open design is
  what makes that a no-op on other machines. The port-discovery watchdog
  must tolerate the extra wait for a slot. Check its Phase B timeout before
  landing, or it will force-kill a server that is merely queued.
- **Residency counts slots, not bytes.** One slot for a 3.3G server
  under-counts it against a typecheck's `job_bytes`. Accept this for now
  (it's still strictly better than zero); a size-weighted residency is a
  separate change.
- Out of scope: agent-launched `npm exec http-server` / storybook that do
  not go through monorepo-jobs.

**Tests** (`scripts/kx-build-slot.test.py`): marker written with own pid and
removed on exit; SIGKILL leaves an unlocked marker that counts for nothing;
group SIGTERM reaches the child; resident cap queues a second server;
fail-open with no semaphore dir.

Three files must agree on residency (CLAUDE.md). Phase 4 touches two of them
and must re-check `packages/playwright-cli/package.nix`'s probe path
assertion still holds.

---

## Phase 5 — zram: measure whether the codec is the cost

No config change in this plan.

**The question** is whether the 65–82% sys time is spent in zstd
compress/decompress, or in reclaim itself (LRU scanning, lock contention).
Only the first is fixable with a codec.

**Measurement.**
- During the next thrash episode, run
  `sudo nix shell nixpkgs#perf -c perf record -a -g -- sleep 20` and then
  `perf report --sort symbol`. Compare the share of `zstd_*` /
  `ZSTD_*` symbols against `shrink_*`, `lru_*`, `_raw_spin_lock`, and
  `folio_*`.
- If the codec is a large share, trial lz4 as the primary with zstd as the
  secondary recompression codec for idle pages (`recomp_algorithm` is
  present on this kernel, currently unset). That keeps hot refaults cheap
  without giving up most of the 4.3× ratio on cold pages. Then it gets its
  own plan, including how to change `comp_algorithm`, which requires
  resetting a device that is in use.
- If reclaim dominates, drop the codec idea and record that in the note.

---

## Order and gates

1. Phase 1a (logging) and Phase 2 (log-only) together: both are
   observation-only.
2. Phase 3.
3. Phase 1b and Phase 2 enablement, once the logged data picks the
   thresholds.
4. Phase 4, dotfiles half first (the mode is inert until kawaka calls it).
5. Phase 5 whenever a thrash episode is live.

Each phase must pass `scripts/run-tests.sh` and `nix flake check`, and each
behaviour change is followed by a `hms` switch. Delete this plan when the
last phase ships.
