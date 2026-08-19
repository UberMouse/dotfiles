# 2026-08-18/19 — desktop memory stalls: the partition invariant omits a term

Ten desktop stalls on 2026-08-18 (one more 09:41 on 08-19). Every one was
MEMORY; `io_full_avg10` was 0.00–0.17% at every trigger and system `cpu full`
was 0.00 throughout despite loadavg 41–110. The io.max / io.latency
protections held in all eleven snapshots — this note is only about memory.

Raw evidence: `snap-20260818-*.txt` / `analysis-20260818-*.md` in
`~/.local/state/cgroup-pressure` (not in the repo; it rotates).

## What the snapshots show

| time  | desk mem full avg10 | pool | pool high evts | user@ total | escape | avail |
|-------|--------------------:|-----:|---------------:|------------:|-------:|------:|
| 10:44 | 45.81% | 16GB | 0    | 19GB | 3GB | 6.0Gi |
| 11:11 | 20.93% | 18GB | 0    | 18GB | 0GB | 3.3Gi |
| 16:49 | 23.34% | 16GB | 4323 | 17GB | 1GB | 3.6Gi |
| 17:17 | 39.96% | 18GB | 4323 | 19GB | 1GB | 3.2Gi |
| 17:30 | 26.25% | 14GB | 4323 | 19GB | 5GB | 4.2Gi |
| 17:42 | 50.50% | 18GB | 4323 | 18GB | 0GB | 2.2Gi |
| 17:52 | 15.73% | 13GB | 4323 | 16GB | 3GB | 5.4Gi |
| 18:01 | 19.17% | 13GB | 4323 | 17GB | 4GB | 5.1Gi |
| 09:41 | 21.03% | 17GB | 208  | 21GB | 4GB | 6.4Gi |

"escape" = `user@1000.service` total minus `worktrees.slice` — memory under the
user manager that **no pool cap applies to**.

Two facts kill the obvious reading:

1. **The pool ceiling now fires.** `memory.events high` went 0 (11:11) → 4323
   (16:49). The comment in `memory-policy.nix` saying a ceiling on this box
   never fires is stale — it was measured at 20G in July; at 18G it throttles.
2. **The pool was innocent in a third of the stalls.** At 17:30, 17:52 and
   18:01 the pool sat 4–5GB *under* its high and the desktop stalled anyway.
   In exactly those samples escape was 3–5GB. Lowering the pool ceiling would
   not have prevented them.

## Root cause

`memory-policy.nix` asserts:

    poolHigh + desktopMin + margin <= memTotal
    18      + 8          + 3      <= 29        (exactly at the boundary)

The invariant has no term for anything that is neither the pool nor the desktop
session scope. Measured across these eleven snapshots that omitted demand is
**1–5GB**: `app.slice`, `claude.slice`, and — the big one — bare
`tmux-spawn-*.scope` build work. At 18:01 a single `node eslint.js` sat at
**2497MB / 184% CPU** in `tmux-spawn-4830974a-….scope`, outside the pool, under
no memory.high, no io.max and no CPU quota.

So a 3G margin is asked to absorb a demand measured up to 5G, *plus* zram's
physical footprint and kernel slab. When it cannot, the box runs out before the
pool's throttle is the binding constraint — the same failure the July notes
describe for a 20G ceiling, reached by a different route.

`memory.min=8G` on the desktop is not the fix and never was: the desktop's
`memory.current` was 4.1–5.4GB at every single trigger, i.e. always *below* its
guarantee. `memory.min` exempts pages you already hold from reclaim; it does
nothing to stop the desktop's own *allocations* entering global direct reclaim
when the machine has 372Mi free. The desktop is collateral, not a target.

Swap is zram-only under load (`/dev/dm-0` stayed at 0B; zram0 held 0.7–4.9G).
The stalls are compress/decompress + refault latency, not disk paging — which
is why memory PSI is high while io PSI is flat zero.

## The auto-diagnoses got the mechanism right and the fix wrong

All four `analysis-*.md` correctly identified memory, correctly cleared io/cpu,
and correctly explained why `memory.min` did not help. But every one of them
recommended reaping the agents fleet as "~6.7GB of idle bg-spares".

That is the trap CLAUDE.md documents. Checked live on 08-19, of 14 `bg-spare`
processes: **7 genuinely idle** in the daemon's spare dir totalling ~571MB, and
**5 claimed sessions doing real work** in worktrees (243/476/488/520/549MB,
~2.3GB). The reclaimable slack is ~0.5GB, not 6.7GB. The diagnosis prompt runs
tool-less by design, so it cannot `readlink /proc/<pid>/cwd` and cannot tell the
two apart — it reads ~2.3GB of live agent sessions as free memory.

Do not act on the fleet recommendation in those files without the cwd check.

## Where the leverage actually is

- **Cap the escape.** A bare `tmux-spawn-*.scope` is outside every budget.
  `claude-agents-reattach` re-homes the fleet at launch, but a build started by
  hand in a tmux pane is covered by nothing. This is the only finding that
  explains the stalls where the pool was under its high.
- **Add the escape term to the invariant.** `poolHigh + desktopMin + margin`
  omits `app.slice` + `claude.slice` + escapes; the assertion passes at exact
  equality (29 <= 29) while the real demand overruns it.
- **`desktopMin` is over-reserved in the arithmetic.** It reserves 8G for a
  scope observed at 4.1–5.4GB under pressure. Lowering it weakens protection,
  so this is a trade, not a free win — but the arithmetic currently spends 8G
  of a 29G budget on something that never exceeded 5.4G.

Not recommended: lowering `poolHigh` alone. It is already throttling (4323
events) and was under its high in a third of the stalls.

## What changed (2026-08-19)

`memory-policy.nix` now carries a `userOtherG` term (4G) for the escape, so the
partition is stated honestly instead of hiding that demand in the margin:

    poolHigh 14 + desktopMin 8 + userOther 4 + margin 3 = 29 <= 29

The desktop floor stays at 8G, so the cost lands on the pool: `poolHigh` 18→14,
`poolMax` 20→16 (same +2 throttle band), and `KX_SEM_CEIL`, which derives from
`poolHighG`, follows 10→7 concurrent build slots. A third assertion now requires
`poolMax + desktopMin <= memTotal` — without it the hard bound could still reach
a size that starves the floor the throttle band exists to protect.

The stall-diagnosis prompt in `scripts/cgroup-pressure-monitor.sh` now carries
the bg-spare/cwd caveat, so future auto-analyses stop reporting the fleet's
whole RSS as reclaimable.

Deliberately NOT done: capping the bare `tmux-spawn-*.scope` escape. Budgeting
for it is not the same as bounding it — the reservation is one the invariant
respects, but nothing stops a hand-started build exceeding it. If stalls recur
with the pool under its high, that is the next lever.

## Revision, same day: the ceiling was cut too hard, and why

The 14G ceiling stopped the stalls and then cost more than it should have. By
11:30 the pool sat pinned at its high with `memory.pressure full avg10=60.12`
while the desktop was at **0.00** — the stall had been moved, not removed — and
the semaphore was at `allowed=1 healthy=0`, refusing new builds outright.

Two separate mistakes, both now fixed.

**1. `userOtherG` was sized off the wrong sample.** 4G came from the 1–5G
spread of the eleven stall snapshots, but those sample only the worst moments
of the day. 438 samples at 15s across 2026-08-19 put the escape at p50 1.8G,
p90 2.1G, p95 2.2G, p99 3.5G, max 4.6G. The term now carries the steady state
(2G) and the margin carries the excursions, which is the division of labour it
was always meant to have. `poolHigh` 14→16, `poolMax` 16→18, `KX_SEM_CEIL` 7→8.

**2. `read_untracked_mem()` charged page cache to the fleet.** It read the
fleet's `memory.current`; measured here, that was 12.2G of which only 4.7G was
anon — 6.7G was page cache, 5.7G of it inactive. Its docstring justified the
subtraction on the grounds that the fleet "never call[s] kx-build-slot, so no
amount of tightening persuades them to give a byte back", which is true of anon
and false of cache: the kernel reclaims it without asking the fleet for
anything. The pool was thrashing that cache against its ceiling, which is what
the 60% PSI was measuring. It now sums `anon + shmem` from `memory.stat`
(shmem is accounted under `file` in cgroup v2 but is not droppable either), and
returns None rather than 0 on a stat with neither key, so a malformed read still
reads the pool as fuller rather than emptier. Covered by four new assertions in
`scripts/build-semaphore-controller.test.py`.

Effect, measured immediately after the switch: build budget 1.80G → 11.48G,
`allowed` 1 → 4, `healthy` 0 → 1, pool `full avg10` 60.12 → 0.00, desktop
unchanged at 0.00.

**Which fix did what — the two are easy to conflate and were, at first.** The
`allowed=1 healthy=0` refusal came from the LOAD TEST, whose headroom is
`memory.high - memory.current` on the WHOLE pool: 14 − 12.5 = 1.5G against a
3.0G need. That expression never consults `untracked` at all, so raising the
ceiling is what unblocked builds; the accounting fix contributed nothing to it.
What the accounting fix changes is `high_frac`, and — measured under load at
14:48 — it moves it UP, not down: with the fleet's whole `memory.current`
subtracted from both terms the ratio collapsed to **2.9% while the pool was
80% full**, which is a signal that can never fire; against anon it reads
**70.9%**. So the correction makes the predictive tighten MORE willing to act,
not less. Do not credit it with the throughput recovery.

**A limit of the correction, visible in the same measurement.** `untracked`
assumes `worktrees-agents.slice` holds only tenants that take no slots. That
holds when monorepo jobs run in their own `mj-*.scope` (the 2026-08-18 shape),
and fails when the agents themselves do the building (the 2026-08-19 shape,
where the pool had exactly ONE child and it was the agents slice). In that
shape both the numerator's build memory and the fleet's live in the same slice,
so no subtraction separates them, and `high_frac`'s numerator is then mostly
page cache — droppable bytes counted as build usage against a 90% tighten
threshold. Anon-vs-anon would be the consistent measure. Not attempted here;
noted because the current reading is honest about fullness but not about what
is filling it.

## `memory.current` is not a memory budget

The same mistake turned up a third time, in the escape sampling that set
`userOtherG` — so it is worth stating as a rule rather than as three bugs.

`memory.current` sums anonymous pages, tmpfs, kernel slab AND page cache. Only
the first two can starve the box: cache yields to reclaim without anyone's
cooperation. Every number in this subsystem that is meant to answer "can the
machine run out?" must therefore be read from `memory.stat` as `anon + shmem`,
never from `memory.current`. Measured 2026-08-19 at 15:03:

| quantity | by `memory.current` | by `anon + shmem` |
|---|---|---|
| escape (user@ minus pool) | 5.35G | **0.92G** |
| fleet inside the pool | 12.82G | **5.40G** |

The 5.35G escape was one `tmux-spawn-*.scope` holding **3.63G of page cache and
0.01G of anon** — a single 38MB `gitstatusd`. Read as `memory.current` that is
an uncapped 3.7G tenant about to reproduce the 18:01 stall; read as anon it is
nothing at all. The genuinely dangerous escape, yesterday's 2497MB `eslint`,
was anon — which is exactly why the distinction is the whole finding and not a
technicality.

So `userOtherG = 2` is now known to be conservative rather than tight: the
unreclaimable escape measures under 1G. It is left at 2 deliberately, because
the term exists to cover an anon spike like yesterday's eslint, not today's
cache.

The three instances shared one shape: a number that was easy to read stood in
for the number that was meant. Related but distinct is how `userOtherG` got its
first value — sized from the eleven stall snapshots, a sample that by
construction only exists during incidents, so bursts read as the baseline. Both
failures produce a plausible number that answers a question adjacent to the one
being asked.
