# 2026-09-14 — the pool thrashed on the fleet's anon, and no lever reaches it

Afternoon-long slowdown, investigated live 15:58–16:20. Unlike the 09-04
stalls this one never reached the desktop: `session-2.scope` memory PSI read
**0.00%** in every sample and its CPU pressure ~7%. `memory.min` held. What
collapsed was everything running inside `worktrees.slice`.

Raw evidence: `governor.log`, `build-semaphore.log` in
`~/.local/state/cgroup-pressure` (not in the repo; it rotates). No stall
snapshot was taken — the pressure monitor is desktop-scoped, and the desktop
never stalled.

## What it looked like

| reading | value |
|---|---|
| load average (12 cores) | 26–39; vmstat `r` 46–117 |
| CPU split | **65–82% sys**, 3–14% user |
| root memory PSI full avg10 | 31–63% |
| pool memory PSI full avg10 | 46–61% |
| pool `memory.events high` | 32,093 at 13:11 → 88,389 at 16:06 → **105,282** at 16:20 |
| swap-ins | peaks 23,700/s; 90s sample routinely 10–30k anon refaults/s |

The 1s sampler itself lost 7s and 13s twice — the box was stalling its own
measurement.

## Mechanism: working set over the ceiling, not cache

Pool at 16:20: **14.1G charged, 10.0G anon, 2.7G file (19% cache)**, plus
4.4G of anon already in zram (uncompressed). The anon working set alone sits
at the 15G `memory.high`. August pools ran 40–52% cache; 09-04 fell to 16–17%.
This is the second day the "the pool is mostly cache" premise has been false.

With the ceiling enforced on the raw charge and `vm.swappiness=180`, every
allocating task in the pool reclaims inline (pool `pgscan_direct` 16k/s,
`pgsteal_direct` 14k/s) and the reclaim takes anon, which goes to zstd zram.
In the 90s sample **`workingset_refault_anon` tracked `pgsteal_anon` almost
exactly, second by second** (32,175 / 32,180; 51,636 / 51,894) — every page
evicted was faulted back in the same second, and the storms coincided with
`high` events. That is textbook thrash, and the compress/decompress plus
reclaim is where the sys time went: it showed up as kernel time on ordinary
pool tasks (a claimed `bg-spare` at 108% sys, heft typechecks 65–89%, even
waiting `kx-build-slot` clients 57–66%).

## Who holds it: the fleet, which takes no slots

`worktrees-agents.slice` held **12.0G of the pool plus 2.4G in zram**; the
build scopes the semaphore governs held ~1–2G. Fleet inventory at 16:05:

| kind | n | RSS | swap |
|---|---:|---:|---:|
| `heft start` dev server (mv-fullbrowser-css-flip) | 1 | 3.33G | 0.51G |
| other node | 26 | 2.24G | 0.23G |
| `bg-spare` CLAIMED (cwd in a worktree) | 9 | 2.17G | 0.57G |
| heft (agent-run typecheck/test) | 8 | 1.95G | 0.04G |
| playwright / chrome | 12 | 1.19G | 0.37G |
| claude sessions | 5 | 0.84G | 0.32G |
| `bg-spare` IDLE (cwd in cc-daemon spare dir) | 9 | 0.65G | 0.24G |
| monorepo-jobs daemons | 12 | 0.45G | 0.23G |
| storybook `http-server` (up 4h) | 3 | 0.11G | 0.24G |

Plus, ungated and in `fleet`: a worktree-setup `rush install` →
`pnpm install` at 127% sys (spawned by
`~/code/kawaka/.claude/hooks/worktree-setup.sh`, which calls `rush install`
bare), and an agent's ad-hoc `rushx test` jest run.

Sampled at 16:05 and 16:20, not over the whole afternoon, so the table shows
what was running during the thrash, not what caused its onset.

## Why no control loop acted

### 1. The semaphore's lever is the minority tenant

`decide()` labelled every tighten `[self-inflicted, soft floor 5]`, correctly
under its own rules: builds were well under `self_inflicted_build_share` of
the raw charge (the `minority_builds` route from 7399d05). Tightening builds
could not have freed the fleet's anon, so holding at the soft floor is the
right call *for that lever*. The consequence is that nothing exercised any
demand-side control over the 12G that mattered.

### 2. The LOOSEN exemption re-opened admission into genuine thrash — again

Between 15:37 and 15:54 the `[self-inflicted]` LOOSEN fired **9 times**,
including `psi60=21.9%` at 15:47:04, over the 15% level at which the same
controller tightens. Seven of the nine were followed within ~2 minutes by a
re-tighten. This is the 09-04 shape. The desktop term added then did not
withdraw it because the desktop was genuinely quiet: `desktop_psi10 <
desktop_quiet_psi` tests whether the squeeze reached the desktop, not
whether the pool's pressure is cache reclaim.

The exemption's founding premise (67a7488) is "the stall is our ceiling
squeezing our own **page cache**". None of its three terms measures the cache
fraction. `minority_builds` answers a different question ("do builds own this
charge?") and is true for fleet-anon thrash just as much as for cache
reclaim.

### 3. Governor Duty A reclaims, and it nets nothing

Duty A's header justifies reclaiming `worktrees-agents.slice` on the grounds
that idle `bg-spare` heaps are the coldest pages there (2.9G of spares,
measured 07-28). Today idle spares were **0.65G RSS**; the rest of the slice
is active agents and their children. In the 90s window, 5 RECLAIMs of 256M:

| time | agents charge before → after |
|---|---|
| 16:16:41 | 10450M → 10758M |
| 16:17:29 | 12084M → 11925M |
| 16:17:49 | 12001M → 11845M |
| 16:18:37 | 11891M → 11893M |
| 16:19:16 | 11929M → 12941M |

Three of five left the charge at or above where it started. Only 16:16:41 lines
up cleanly with a large swap burst (19.7k in/s the two seconds before it
logged); the others show no distinct signature against the `memory.high`
storm around them. So the finding is **ineffective, not causal**: the governor
spends a core of sys time (its bash at 106% sys, since `memory.reclaim` runs
synchronously in the writer) to push active pages that come straight back.
Its FREEZE path fired 38 times 14:30–15:00 and then stopped.

### 4. `WORKER_RE` cannot see most of the long-lived load

`jest-worker|/jest|--headless|ms-playwright|/eslint|/heft|/bin/tsc|/esbuild|/vitest`
catches `heft start` (it was swept into `transient`) but not `pnpm`/`rush
install`, `http-server`, or playwright's `cliDaemon.js`. Those are
unfreezable by construction, and residency (the semaphore's other demand
lever) only covers `playwright-cli open`.

## Escalation

Semaphore TIGHTENs per hour: 13:00 → 3, 14:00 → 16, 15:00 → 22. Memory
availability per earlyoom: 10.0G (13:35), 5.5G (14:35), 10.0G (15:35),
5.0–8.7G through the sampled window. The trend followed fleet activity, not
build admission.

## Open questions before any change

- Whether the anon working set is *legitimately* 14G+ (the fleet simply
  outgrew a 15G pool) or is inflated by long-lived services nobody is using
  (a 4h storybook server, a 3.5h playwright daemon, a dev server). The first
  is a partition problem; the second is demand.
- zstd vs lz4 for zram under anon-dominant churn: zstd compressed 4.3× here
  (6.72G → 1.55G), and the sys time is partly its decompress cost. Not
  measured in isolation; do not change on this note alone.
