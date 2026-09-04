# 2026-09-04 — the self-inflicted exemption outlived its premise

Twelve desktop stalls on 2026-09-04 by 15:55 (and the day was not over) —
the most since the pre-tuning era (08-17: 23, 08-18: 10; every day since has
run 1–6). Eleven were MEMORY, with `io_full_avg10` at 0.00% at almost every
trigger; the twelfth (10:03) was the IO read-storm and is a separate matter,
already diagnosed in `analysis-20260904-100334.md`.

Raw evidence: `snap-20260904-*.txt` / `analysis-20260904-*.md` in
`~/.local/state/cgroup-pressure` (not in the repo; it rotates).

| time  | desk mem full avg10 | desk io | pool net / raw | pool cache |
|-------|--------------------:|--------:|---------------:|-----------:|
| 10:51 | 15.72% | 0.00% |  8.5G / 15G | 42% |
| 12:04 | 24.03% (peak 47.96) | 0.00% | 11G / 16G | 31% |
| 12:48 | 17.86% (peak 40.55) | 0.00% |  8.8G / 15G | 40% |
| 12:55 | 16.20% | 0.00% | — | — |
| 13:13 | 24.88% | 0.00% | — | — |
| 15:15 | 33.83% | 0.00% |   14G / 16G | **16%** |
| 15:20 | 15.20% | 0.00% | — | — |
| 15:32 | 27.55% | 0.00% | — | — |
| 15:40 | 17.21% | 0.00% | — | — |
| 15:43 | 32.39% | 0.39% | — | — |

## The individual analyses are right and collectively wrong

Each memory analysis reaches the same verdict — desktop was collateral of
global reclaim, `memory.min` held, don't cut `memory.high` because the pool is
mostly page cache — and then recommends something different: add an `rbps`
cap (10:03), cut `nix --cores` (10:51), cut build concurrency to 3
(12:04, 12:48), raise `memory.min` to 10G (15:15).

The last would **fail the eval-time assertion** in `memory-policy.nix`:
16+10+2+3 = 31 > 29. It was proposed because the desktop's charge (8.2G) sat
barely above its 8.0G floor — a real observation with an unavailable remedy.

More importantly the shared premise expired during the day. Pool cache
fraction fell to **16–17%** (August ran 40–52%). The 15:15 analysis caught
this and said so explicitly — "only 16% cache … genuinely resident work" —
but still deferred to the standing "don't touch the ceiling" rule.

## The finding: the self-inflicted cross-check kept firing

The cross-check (added 2026-08-27, commit 67a7488) exists to stop the
controller throttling builds to relieve pressure the pool's own ceiling
manufactures against the pool's own page cache. With the pool at 17% cache,
that premise is gone and the stalls are genuine — but the exemption still
fired:

- the **LOOSEN exemption fired 42 times** of 112 loosens, at `psi60` up to
  **44.3%** against a 3.0% gate — 14× over
- 9 of 61 tightens were softened to `soft_floor`
- all 61 tightens were `psi10=`; the predictive `high_frac` signal never fired
  once, the same shape as 2026-08-27

The weight is on the LOOSEN side, and that is the half with teeth: a softened
tighten still tightens, whereas an exempted loosen re-opens admission into a
box with no room. Caught live at 15:43 — `TIGHTEN psi10=45.2% allowed 2 -> 1`,
then **fifteen seconds later** `LOOSEN psi60=26.1% [self-inflicted] allowed
1 -> 2`, with the pressure monitor logging a 32.39% desktop stall between the
two. The same shape at 15:32 (tighten to 2 at psi10=41.1%, exempted loosen
back to 3 at psi60=10.9%).

Two gaps, both now closed:

1. **The desktop term was never encoded.** The justifying comment cites
   "desktop session at 0.00% pressure" among its 2026-08-27 conditions, but
   `decide()` had no desktop input at all — `Inputs` carried pool headroom and
   `mem_available` only. So the exemption went on firing once the premise
   expired. At 12:48 it held `allowed` at the soft floor for two ticks while
   `psi10` went 40.6% → 48.6% and the desktop stalled at 40%; on the loosen
   side it re-opened admission 42 times.

2. **`MemAvailable ≥ 4 GiB` is too weak a proxy for "the machine has room".**
   At 12:04 the desktop sat at **47.96%** memory PSI with **6.5 GiB
   available** — comfortably past the gate. `MemAvailable` counts reclaimable
   page cache, and reclaiming that cache *is* the stall.

The pool-local headroom term is weak for a related reason: the partition
balances at **exact equality** (16+8+2+3 = 29), so "the pool has room under
its own ceiling" and "the machine has no room" are simultaneously true by
construction. Neither of the original two terms separates them.

Fix: a third term, `desktop_psi10 < desktop_quiet_psi` (5.0%), reading
no-signal as NOT self-inflicted like the other two. 5% sits above idle noise
and below the pressure monitor's own 15% stall threshold, so the exemption
withdraws *before* the desktop crosses into what that monitor calls a stall.

## The semaphore is structurally late regardless

`12:04:37 TIGHTEN psi10=56.1% allowed 2 -> 1 (occupied 8 … effective 8)` —
the cap reached 1 with eight jobs already resident. `allowed` gates
ADMISSION; it evicts nothing. The only tick that matters is the one that
admits job 8, which is why the exemption softening the early tightens costs
more than the raw numbers suggest. Not fixed here; noted because it bounds
how much any control-law change can buy.

## Correction: zram figures in the analyses are UNCOMPRESSED

Every analysis reads the `USED` column of `swapon --show` as a RAM cost —
15:15 says "5 G pushed into zram … the zram pages themselves are consuming
the RAM that is missing". That column is the **uncompressed** size. Measured
live the same day: 3.71 G uncompressed → **1.29 G physical** at 2.9×
compression (`/sys/block/zram0/mm_stat` field 3 is `mem_used`).

The snapshots capture only `swapon --show`, never `mm_stat`, so the error has
no way to self-correct from the archive. `memory-policy.nix`'s margin comment
inherited it ("zram0 held 0.7-4.9G, so those compressed pages are resident
RAM") — those are uncompressed figures too, overstating zram's real claim on
the margin by roughly 3×.
