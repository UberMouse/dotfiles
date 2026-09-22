# Plan — fleet anon thrash: four fixes

Evidence: `docs/notes/2026-09-14-fleet-anon-thrash.md`. Scope decided
2026-09-14 by taylorl: cache premise gates LOOSEN only; Duty A gets an
effectiveness gate (not removal, not a standby leaf); fleet demand gets a
freezable-not-killable worker list plus residency for dev servers; zram is
measure-first. Implementation approved 2026-09-14 in the order below.

Phases are independent and ship as separate commits, in this order. Each
lists the tests that make it safe, since `scripts/run-tests.sh` and
`nix flake check` are the only gates.

## Status

- **Phase 1a — shipped and switched 2026-09-14.** Every TIGHTEN, LOOSEN and
  HOLD line carries `cache=NN%` (`cache=?` = no signal). No branch reads it.
  Calibrate 1b from:
  `grep -E 'BUILDSEM\|(TIGHTEN|LOOSEN|HOLD) .*cache=' ~/.local/state/cgroup-pressure/build-semaphore.log`
- **Phase 2 (log-only) — shipped and switched 2026-09-14.** The agents slice's
  `workingset_refault_anon`/`pgsteal` are sampled every tick; both RECLAIM
  call sites log `ratio=NN% refault=N steal=N` (`ratio=-` = not computable).
  `CGGOV_THRASH_PCT` defaults to 0, so the gate never skips yet. The memcg
  file has no `pgsteal_anon`, so the denominator is total `pgsteal` (file
  steals dilute toward "useful"). Enabling picks BOTH `CGGOV_THRASH_PCT` and
  `CGGOV_THRASH_MIN_STEAL` from:
  `grep -E 'CGGOV\|RECLAIM\|.*ratio=[0-9]' ~/.local/state/cgroup-pressure/governor.log`
- **Phase 3 — shipped 2026-09-14.** Drift resolved by anchoring nohang's bare
  `playwright` to the runner (`/playwright/cli\.js`), now also in `WORKER_RE`;
  the subset is asserted. `FREEZE_ONLY_RE` holds rush/pnpm install and
  `/entry/cliDaemon.js`. Install RSS measured 2026-09-14 before adding it:
  `pnpm install` worker 2449 MB peak, launcher 685 MB, `rush install` 238 MB.
- **Phase 4 — dotfiles half shipped and switched 2026-09-14; kawaka half on
  branch `mj-server-admission`, PR https://github.com/koordinates/kawaka/pull/9695.** Verified live against
  the real semaphore: resident 0 -> 1 -> 0, marker naming the wrapper. Kawaka
  prefixes only `spawnDevServer`/`spawnStorybook` (not the `spawnProcess`
  primitive its lifecycle tests drive); `MJ_SERVER_ADMISSION=0` opts out.
  Inert until that branch lands and a daemon restarts on it. The
  Phase B trap is real: `server-spawn.tsx` kills a server after 180 s of
  SILENCE (its idle timer), well inside the 600 s slot wait, so a queued
  wrapper heartbeats to stderr every `KX_BUILD_SLOT_HEARTBEAT` s (default 60).
  The daemon's transition watchdog (10 min ceiling, 3 min silence) is outlived
  by the 600 s wait and fed by the same heartbeat.

### Live testing 2026-09-15 (first loaded day)

- **Fields live.** All 56 cache-era controller decisions carry `cache=`; 25
  governor reclaims carry `ratio=`.
- **Phase 3.** 28 sweeps that morning, and the stall brake froze the swept
  leaf (a 5.1G node among it). `SWEEP` logs only a count, and no install or
  cliDaemon was running during inspection, so the `FREEZE_ONLY_RE` half is
  still unobserved live.
- **Phase 4.** #9695 merged 2026-09-15. Each mj daemon runs its own
  worktree's `dist-cjs`; only worktrees rebased past `b4b1203b88` carry it.
  taylorl: wait for natural use (a `RESIDENT-SELF` line), don't start one.
- **1b data, thin, still collecting (taylorl).** Of 13 `[self-inflicted]`
  loosens, 2 re-tightened within 120 s, at cache 14% and 17%; 11 held, at
  12–47%. The proposed 0.40 would have blocked 8 of the 11 that held, so the
  data points nearer 0.20. Re-run the pairing over more days before choosing.
- **Phase 2 data, thin, still collecting.** Clean reclaims: steal 6k–127k
  pages at ratio 0–5%. Thrash signatures (charge flat or rising): steal 805
  at 128%, steal 840 at 35%. So the thrash cluster is LOW steal: a
  `MIN_STEAL` of 1000 would wave exactly those through as "useful". Expect
  the floor well below 800 and the ratio bar near 30%; two samples do not
  place either. Charge rises at ratio 7–8% with steal 1–11k were fleet
  growth during the window, not thrash.
- **The hang had a cause outside this plan: the VMware balloon, and it is
  DELIBERATE.** taylorl lowered this VM's memory reservation in VMware so the
  host has RAM for gaming. A balloon here is that trade-off working as set,
  not a host misconfiguration to escalate. `Balloon:` in meminfo held 4.5G of
  the 29G guest, inflated since that morning's boot and barely deflated. It is charged to no cgroup, so the pool ceiling and
  desktop floor were sized against RAM the guest no longer had. The desktop
  stalled at up to 48% `mem_full` with the pool 10G under its ceiling. The
  pressure monitor's 10:56 analysis called 9–10 GB "unattributed". taylorl
  chose log-and-explain, no policy change: the governor carries `balloon=` on
  STATE/STALL, and the monitor's prompt and snapshot name the balloon.
  The balloon log showed it is NOT a fixed squeeze. From 13:44 the host ran a
  ~5-minute sawtooth: inflate to a steady 4.36–4.47G, then deflate ~3.5G
  (down to 0.8–1.7G) inside a minute. MemAvailable swung 5.5G–15.4G each
  cycle. Logging every fixed-step move wrote ~70 lines/h at 256M and ~100/h at
  512M, so taylorl chose TURNING POINTS: `CGGOV|BALLOON|peak NM` / `trough NM`,
  logged once the balloon reverses `CGGOV_BALLOON_STEP_MB` (512) from its
  running extreme. That is ~2 lines a cycle, plus a first-reading line at start.
- **14:40:59: a desktop stall with memory FREE.**
  - The desktop hit `mem_full` 21.94% for 10 s while pool pressure was 0.00%,
    8.8G was free and the balloon sat at its ~4.4G peak.
  - In the two minutes before, the pool charge fell from 14.6G to 7.7G.
  - Kernel counters since boot, read at 14:43:
    - balloon churn: `balloon_inflate` 11.6M pages and `balloon_deflate`
      10.5M (~44G in, ~40G out);
    - `balloon_migrate` 2.88M (65k at 11:30);
    - compaction: `compact_stall` 2614, `compact_isolated` 38M.
  - `vmwballoon_shrinker_enable=N`.
  - Compaction migrating balloon pages would fit a stall with memory free, but
    this is unproven: the 10 s window closed before perf could run.
  - The first balloon-aware monitor diagnosis (analysis-20260915-144101)
    subtracted the balloon correctly and recommended a full memory reservation
    for this VM on the host. That reservation is the setting taylorl lowered on
    purpose for host gaming, so it is a trade-off to weigh, not a fix to push.
    taylorl declined further instrumentation (compaction counters, unattended
    perf) once the cause was known.
- **Phase 5.** A watcher on `CGGOV|STALL|desktop` triggers the perf record
  (perf prefetched as `nixpkgs#perf`).
  It fired at the 15:13:02 stall, but the stall had ended (15:13:18) before
  the sudo-approved record began (15:13:35). The profile caught only the
  aftermath: V8 scavenger GC, anon page-fault spinlock contention, futex IPIs.
  No zram/zstd, compaction or balloon symbols. Inconclusive, because 10–16 s
  stalls are shorter than a sudo approval. The watcher expired and was not
  re-armed.

### Live testing 2026-09-17 (balloon held all morning)

- **The hangs tracked the balloon INFLATING.** The box booted at 09:33 with
  the balloon at 0M. It reached 4.36G by 09:45, dropped to 0 at 10:04 and was
  back at 4.56G by 10:07. All six stall onsets from 09:45 to 10:13 fall in
  that window: desktop `mem_full` up to 42.7% and pool up to 62.8%, with free
  RAM down to 365M.
  - Counters for the two hours since boot: `balloon_inflate` 2.72M pages,
    `balloon_migrate` 614k, `compact_stall` 4200, `allocstall_*` 13.6k.
  - After that the balloon stayed flat at ~4.57G (no sawtooth). The partition
    (15+8+2+4 = 29G) ran ~4.5G over: 69 NORMAL→TIGHT flips, each with free RAM
    near 1G, and one more desktop-only stall at 11:35 with the pool at 0.02%.
- **The monitor recommended `vm.watermark_scale_factor=200` twice.** The box
  already runs 300: the prompt never saw live sysctls. Fixed: `vm_tuning` puts
  the live values in both the prompt and the snapshot.
- **The balloon-aware pool ceiling** (taylorl chose it over accepting the
  trade-off or logging first).
  - The governor sets the pool's `memory.high` to MemoryHigh minus the
    balloon, rounded down to 512M steps and never below `poolHighFloorG`.
    - The floor is 12G, taylorl's pick over 11G and no floor.
    - `memory.max` is left alone.
  - Lowering is immediate. The write is backgrounded, because the kernel
    reclaims synchronously in the writer. A raise waits until the target has
    stayed higher for `CGGOV_CEILING_DWELL` (60 s).
  - Each step works from the LIVE value, so a systemd reload that reasserts
    15G is lowered again on the next tick. On exit the governor restores the
    configured ceiling.
  - The semaphore controller reads `memory.high` live, so build admission
    follows the ceiling without any change of its own.
  - Logged as `CGGOV|CEILING|`. Judge the floor from those lines against build
    throughput.

## Next session — handover (written 2026-09-14, for 2026-09-15 testing)

Read this first; the phases below are the design. The brief's decisions still
hold and are not to be reopened: the cache term gates LOOSEN only (the
TIGHTEN softening stays); Duty A gets a gate, not removal or a standby leaf;
the STALL reclaim stays ungated; installs and cliDaemon are freeze-only; zram
is measure-only; http-server stays off every list.

**State at handover.**
- dotfiles `master`: everything committed and switched through b3b0bc6.
  NOT pushed (ahead of origin, including commits that predate this work).
- kawaka: PR https://github.com/koordinates/kawaka/pull/9695
  (`mj-server-admission`) MERGED 2026-09-15 (see Live testing above for which
  daemons carry it).
- Nothing has been observed under REAL pressure: the box stayed idle after
  each switch. The deployed code was proven against a synthetic pool instead
  (recipe below).

**Tomorrow's testing, in order.**
1. Under real load, confirm the new fields appear in the live logs:
   `grep -E 'BUILDSEM\|(TIGHTEN|LOOSEN|HOLD) .*cache=|CGGOV\|RECLAIM\|.*ratio=' ~/.local/state/cgroup-pressure/{build-semaphore,governor}.log`
2. Phase 3: during a TIGHT spell, `CGGOV|SWEEP|migrated` should now take
   installs, cliDaemon and the playwright runner. Identify the pids through
   `/proc/<pid>/cmdline` or `kx-proc-find`, never `pgrep -f`.
3. Phase 4 end to end, once #9695 is merged (or checked out) and the mj daemon
   restarted on it: start a dev server through `mj`, then expect:
   - `BUILDSEM|RESIDENT-SELF server:dev:<pkg>` in the log;
   - the `allowed` file's resident field +1 for the server's life;
   - the marker gone after stop.

   Queue case: while `healthy=0`, the server's own log should show
   `kx-build-slot: server:dev:<pkg> waiting for a build slot` about every 60 s,
   and the server must NOT be killed at 180 s.
4. Collect data for the two thresholds. Do not guess them, and confirm both
   with taylorl before committing.
   - **1b `self_inflicted_cache_frac`** (0.40 proposed). For each
     `LOOSEN … [self-inflicted]` line, note its `cache=` and whether a TIGHTEN
     followed within ~2 min. The bar belongs between the re-tightened cluster
     and the held one.
   - **Phase 2 `CGGOV_THRASH_PCT` + `CGGOV_THRASH_MIN_STEAL`**. Pair each
     RECLAIM line's `ratio=` with its own `before -> after` charge. High ratios
     that left the charge flat or rising are the thrash cluster; clean drops are
     cold reclaim. MIN_STEAL goes above the steal counts of quiet ticks.
   - **Data collected 2026-09-23** (morning storm; see
     `docs/notes/2026-09-23-transient-desktop-stalls.md`). 1b: self-inflicted
     LOOSENs at cache 23–24% re-tightened after 31, 34, 97 and 115 s; the one
     at 42% held for over 9 minutes — consistent with 0.40, but only one point
     above the bar. Phase 2: the 10:00–10:07 RECLAIM lines are the clearest
     thrash cluster so far (`ratio=0% steal=25857` with the charge rising
     12455M → 12654M; `ratio=700% steal=221`). Neither threshold confirmed
     with taylorl yet.
5. Phase 5, only while a thrash episode is live:
   `sudo nix shell nixpkgs#perf -c perf record -a -g -- sleep 20`.

**Implementing 1b.** Follow Phase 1's "split, don't widen". `cache_frac` is
already computed in `decide()` next to `build_share`, from the same `raw`;
reuse it. Change the LOOSEN tag to `[self-inflicted, cache NN%]`. Two tests
must change:
- The fixture "self-inflicted psi60 does not block recovery" must pass
  `cache=` explicitly; otherwise it silently tests the no-signal path.
- The 1a check "…alongside the exemption tag (no behaviour change yet)" locks
  today's cache-poor-loosen-passes behaviour on purpose, and should flip.

**Enabling Phase 2.** Only the defaults move: `THRASH_PCT`/`THRASH_MIN_STEAL`
in cgroup-governor.sh (or `CGGOV_*` in cgroups.nix). `reclaim_useful`,
`duty_a_step` and their tests already exist; the §6 shape tests in
cgroup-governor.test.py pin that STALL stays ungated and that a skip never
touches `last_reclaim`.

**Proving deployed code without real pressure** (what worked on 09-14).
- Take the store paths and env from
  `systemctl --user show <unit> -p ExecStart -p Environment`.
- Run them against a synthetic tree made with `mktemp -d` under
  `$CLAUDE_JOB_DIR/tmp`. Keep `rm -rf` out of the command; that call was
  permission-denied.
- Controller: `KX_SEM_POOL`, `KX_SEM_DESKTOP`, `KX_BUILD_SEM_DIR`,
  `KX_SEM_STATE_DIR`, `KX_CGROUP_MEM_LIB`.
- Governor: `KX_POOL`, `CGGOV_OUTDIR`, `CGLIB`, plus a fake
  `worktrees-agents.slice/memory.stat` whose counters a side loop bumps.

**Traps learned on 09-14** (beyond CLAUDE.md).
- An `exec` with no command makes EVERY redirect on its line permanent:
  `exec {fd}>f 2>/dev/null` silenced kx-build-slot's stderr for the rest of
  its run (fixed in 9b191e2). Scope it: `{ exec {fd}>f; } 2>/dev/null`.
- A /proc scan matching argv TEXT finds the agent's own tool shell, whose
  `zsh -c` carries the pattern: the pgrep -f trap again, in Python. Match
  argv[0] or compare start times.
- Fixtures running `bash -c 'sleep …'` orphan the sleep on a plain kill, and
  it holds any inherited pipe open (a 1 s suite took 120 s piped). Spawn with
  `start_new_session=True` and DEVNULL stdio, and kill by group.
- The script-tests sandbox sees only `scripts/`, `scriptBins/bins/` and
  (since 43b8477) `nohang/nohang.conf`. A test reading any other repo file
  needs a `cp` in flake.nix.
- Committing part of a file without `git add -p`: build the intended file in
  tmp, run `git hash-object -w`, then
  `git update-index --cacheinfo <mode>,<blob>,<path>`. Copy the mode from
  `git ls-tree HEAD`; a guessed 100755 got committed once and had to be
  amended.
- kawaka commits run lint-staged plus rush autoinstallers (slow and noisy,
  but fine). The package gate is `node_modules/.bin/heft test` in
  packages/tools/monorepo-jobs.

Regex for all logging added in this rollout (the heartbeat lands in the
server's own log, not the state dir):
`BUILDSEM\|((TIGHTEN|LOOSEN|HOLD) .*cache=|RESIDENT-SELF )|CGGOV\|(RECLAIM\|(SKIPPED-THRASH|.*ratio=)|START\|.*thrash_gate=|BALLOON\||CEILING\||(STATE|STALL)\|.*balloon=)|kx-build-slot: .* waiting for a build slot`

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
