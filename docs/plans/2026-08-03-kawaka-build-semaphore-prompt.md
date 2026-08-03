# Prompt: wire kawaka into the machine-global build semaphore

Paste everything below the line into an agent working in `~/code/kawaka`.
The dotfiles half is already built, committed and running (`2a738ef`).

---

## Task

Gate this repo's heavy build/test work behind a machine-global admission
semaphore that already exists on this host. Your job is the **kawaka side only**
— the semaphore itself, its controller and its CLI client are already built,
deployed and running. Do not build a semaphore; consume the one that is there.

## Why (measured, not guessed)

This is a 12-core / 27 GiB VMware guest. Sampling `worktrees.slice` every 10 s
for 95 minutes (498 samples) gave:

```
pool_mem   p50=12.76G  p90=15.12G  max=16.00G  mean=12.12G   (73% of a 16G budget)
pool_mPSI  p50= 0.00%  p90=19.32%  p99=69.85%  max=81.08%
pool >14G for 28% of samples;  anon refaults 25,452/min;  high-breach 168/min
```

**Median memory pressure is zero.** The machine is not short of RAM on average —
it is short of RAM for the ~10% of the time when independent worktrees burst at
the same instant. That is a queueing problem, so the fix is a queue. More RAM
would only raise the ceiling the same bursts slam into.

The hog is **`heft typecheck`**, measured at 0.6–2.3 GB RSS per process (largest
single observation: 2312 MB, `packages/embeds/map-viewer/core`). Demand is
roughly `N_active_worktrees × RUSH_PARALLELISM(4) × ~1.5 GB`, and there are
currently **78 worktrees** on disk — 58 under `.claude/worktrees/` plus 20
*nested inside other worktrees*, because agents spawn their own sub-worktrees.
Nothing bounds N.

Note `RUSH_PARALLELISM` is **not** a usable lever here and you should not reach
for it: its minimum is 1, so even at the floor N worktrees still produce N
concurrent builds, and the test phase's workers belong to Jest, which Rush never
sees.

## What must be gated

1. **`heft typecheck`** — the main prize. Everything else is secondary.
2. **jest shards** — `packages/rush/rig/profiles/web/config/shard/run-jest-shard.js`
3. **integration test shards** — `.../shard/run-playwright-shard.js`
4. **storybook test shards** — driven via `@rushstack/heft-storybook-plugin`
   from `packages/rush/rig/profiles/web/config/heft.json`

`packages/rush/rig` is `workspace:*`, so every package's `config/heft.json`
resolves through it. That makes the rig the natural single chokepoint covering
all 78 worktrees, present and future. It already contains a custom plugin
(`heft-tsconfig-replace-paths-plugin.js`), so there is a precedent to follow.

(`playwright-cli` is gated already, on the dotfiles side. Ignore it.)

## The semaphore protocol

Everything lives on the filesystem. There is no daemon protocol, no IPC, no
version to keep in step.

- **Directory**: `$KX_BUILD_SEM_DIR`, else `${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/kx-build-sem`
- **Slots**: files named `slot.00` … `slot.15` in that directory
- **Acquire**: `flock(LOCK_EX | LOCK_NB)` on each slot in **ascending** order;
  first success wins. Hold it for the lifetime of the job. Release by closing
  the fd.
- **Never scan from the top.** The controller reduces capacity by holding slots
  from the *highest* index downward. Jobs take from the *bottom*. That is the
  entire coordination protocol — the two never contend for the same file, and
  neither needs to know the other exists.
- **Capacity is not yours to read or honour.** Do not parse the `allowed` file
  to decide whether to run. Just try to take a slot; if none is free, wait. The
  controller varies capacity by making slots unavailable.
- `flock` is deliberate rather than a lease/daemon design: the callers here
  genuinely get OOM-killed and frozen, and the kernel drops a flock on process
  death. Nothing can leak a slot, and no reaper is needed.

### Strongly preferred implementation: shell out to `kx-build-slot`

A CLI client already exists on `PATH` and implements the whole protocol,
including every fail-open path:

```
kx-build-slot [--label NAME] [--timeout SECS] -- COMMAND [ARGS...]
```

If you can arrange for the heavy work to be *spawned as a subprocess*, prefer
wrapping that spawn with `kx-build-slot` over reimplementing anything. Node has
no built-in `flock`, so an in-process implementation needs either a native
dependency or a spawned `flock(1)` — both worse than delegating to the client
that already exists and is already tested. One implementation, one place to fix.

If you genuinely cannot spawn a subprocess at the point you need to block (e.g.
a heft plugin that must gate an in-process phase), say so explicitly in your
writeup and explain the constraint before adding any locking dependency.

## Fail-open is a hard requirement

This repo is built on CI, on colleagues' machines, and in containers where none
of this exists. **The gate must be completely invisible there.** Fail open on
every one of these:

1. Semaphore directory does not exist
2. Directory exists but contains no `slot.*` files (controller mid-restart)
3. `KX_BUILD_SLOT_HELD` is set in the environment — a slot is already held
   further up the process tree. **This one is not optional**: without it, a
   gated job that spawns another gated job waits on a slot its own ancestor
   holds, which at capacity 1 is a guaranteed deadlock. `kx-build-slot` sets
   this variable for its children; if you implement any gating yourself, you
   must both honour it and set it.
4. Wait timeout exceeded — run the command anyway and log it

A slot is a scheduling hint, never a permission. A build that runs unthrottled
is a nuisance; a build that never runs is a broken machine.

## A specific hazard, learned the hard way

The first cut of the dotfiles client used `compgen -G` to test whether any slot
files existed. **nixpkgs builds bash without programmable completion**, so
`compgen` does not exist as a builtin at all — the call exited 127, the `!`
negation was therefore always true, and every job took the fail-open path. The
semaphore gated *nothing* while the controller happily logged healthy tightening
decisions. It looked completely fine from the logs.

This is the third time this codebase has been bitten by the same shape of bug
(an always-false test silently disabling an actuator while logs stay green — the
`[ -s cgroup.procs ]` bug did it to `cgroup-governor` for three days in July).

So: **prove the gate actually gates.** A test that merely observes a job
succeeding proves nothing, because fail-open also produces a succeeding job. The
only observation that distinguishes a working gate from a silent no-op is that a
job *blocks* when no slot is available. Hold all 16 slots from an external
process, then confirm your gated path waits.

## Deliverables

1. Gating for the four call sites above.
2. A test demonstrating a gated job **blocks** when slots are exhausted, and a
   test demonstrating it **runs immediately** when the semaphore is absent.
3. A short writeup of where you put the gate and why, plus anything you could
   not cover and the reason.

Do not change `RUSH_PARALLELISM`, cgroup settings, or anything under
`~/dotfiles`. If you believe the right fix lies outside this repo, say so rather
than reaching for it.

## Verifying against the live system

```bash
cat /run/user/1000/kx-build-sem/allowed    # "allowed effective max"
systemctl --user status build-semaphore-controller.service
grep -oP 'BUILDSEM\|.*' ~/.local/state/cgroup-pressure/build-semaphore.log | tail -20
```

The controller's decisions are logged with every tunable recorded at `START`, so
any `TIGHTEN`/`LOOSEN` line is interpretable on its own.
