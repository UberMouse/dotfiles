# 2026-09-23 — desktop stalls from ungated agent test runs

Five desktop stalls in the first 40 minutes after a 09:28 boot (monitor
snapshots `snap-20260923-0944…1006`), escalating from 20% to 35% desktop
`mem full avg10`, 71% machine-wide at the worst (10:06). No OOM, no hung
tasks, balloon 0 throughout; the fleet was correctly placed (the 09-22
reattach fix held).

## What drove it

- Four node processes from three agent worktrees, ~9 GB RSS between them
  (the largest grew 2.9 → 4.6 GB over 25 minutes), all swept into
  `worktrees-agents.slice/transient`. They were run by agents directly, not
  through `kx-build-slot`: every one of the semaphore's 151 admissions that
  morning was a `typecheck` (plus one `package`). The semaphore's tightening
  throttled only typechecks.
- With the pool pinned at its 15 GB `memory.high`, free RAM sat at
  375–400 MiB against watermarks of min 256M / low 1.15G / high 2.05G
  (`/proc/zoneinfo`, `watermark_scale_factor=300`). The desktop, under its
  `memory.min`, stalled in direct reclaim for new allocations — the same
  mechanism as the 08-18 and 09-04 notes.

## Why the governor did not stop it

- **One `transient` leaf held every agent job,** so the duty-B cap (which
  counts freezable scopes against `MAXCONC`) never engaged: one leaf plus two
  mj scopes never exceeds three.
- **The brake froze, it did not free.** Four consecutive freeze → 5 s → thaw
  cycles (10:03–10:04, again 10:06) with the desktop at 23–35% throughout. A
  frozen cgroup keeps its pages; the thaw handed the shortage straight back.
  Two of the brake's own ticks overran to 10 s and 14 s under the pressure.
- **Duty A reclaim thrashed**: 256M asks against the agents slice moved the
  charge 0–4%, several times upward (12455M → 12654M).

## What changed

`cgroup-governor.sh`: `transient` became a parent with one leaf per worktree
(the cap now counts each agent's job); the brake freezes whole `transient`
parents and mj scopes, reclaims each victim while frozen, holds until the
desktop clears the stall line (MAX_FREEZE_SECS still the ceiling), and adds
the next-biggest candidate each tick it is still stalled; the cap releases
only after NORMAL has held `CGGOV_CLEAR_SECS`, because TIGHT↔NORMAL flapped
every 5–20 s. The pool ceiling was deliberately left at 15 GB (taylorl's call:
rely on the gating first).
