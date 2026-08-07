#!/usr/bin/env python3
"""The semaphore control law, as pure unit tests.

    python3 scripts/build-semaphore-policy.test.py

Every TIGHTEN/LOOSEN/HOLD/RECLAIM decision, the high-water mark, the burst
and absorbable clamps, the resident arithmetic -- all of it lives in
decide(), a pure function of (State, Inputs, cfg) with the clock injected as
`now`. These assertions are therefore instant, deterministic, and sandboxed
by `nix flake check` (this file needs no flock, no /proc, no subprocess).

The MACHINERY around decide() -- flock reconciliation, the published state
file, resident-marker pruning, SIGTERM behaviour -- genuinely involves the
kernel and a second process; that half lives in
build-semaphore-controller.test.py and runs via scripts/run-tests.sh.
"""

import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from testlib import check, summary  # noqa: E402

# The controller's filename has dashes, so spell the import out. Importing it
# has no side effects beyond path computation, which is what makes this safe.
spec = importlib.util.spec_from_file_location(
    "bsc", HERE / "build-semaphore-controller.py"
)
bsc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bsc)

GIB = 2**30

# A default Config, passed EXPLICITLY -- decide() never reads the module's
# CFG, which is the property that keeps these tests deterministic whatever
# env vars the machine happens to export. Config() takes the field defaults
# (max_resident derives to max_slots - ceil = 8), so a production default
# change is deliberately visible here as test churn.
CFG = bsc.Config(job_bytes=int(1.5 * GIB))


def st(allowed=4, mark=0, last_up=0.0, last_growth=0.0,
       was_resident_full=False):
    return bsc.State(allowed, mark, last_up, last_growth, was_resident_full)


def inp(now=1000.0, psi10=0.0, psi60=0.0, cur=1.0, high=16.0, pool=True,
        occupied=0, resident=0):
    """Inputs with pool sizes in GiB; pool=False means the pool is unreadable.

    NOTE the default `now` of 1000.0 against the default clocks of 0.0: dwell
    (60) and spacing (15) both read as long elapsed unless a test pins them.
    """
    pool_mem = (int(cur * GIB), int(high * GIB)) if pool else None
    return bsc.Inputs(now, psi10, psi60, pool_mem, occupied, resident)


def tags(d):
    return [r.tag for r in d.reasons]


def span(r):
    return (r.before, r.after)


# --- Tightening ------------------------------------------------------------

# Measured stalling (psi10 over the threshold) steps capacity down by
# step_down and may reach the absolute floor.
d = bsc.decide(st(allowed=8), inp(psi10=50.0, occupied=8), CFG)
check("psi tighten steps down", d.state.allowed, 6)
check("psi tighten reason tagged", tags(d), ["TIGHTEN"])

d = bsc.decide(st(allowed=2), inp(psi10=50.0, occupied=2), CFG)
check("psi tighten reaches the floor", d.state.allowed, 1)

# The predictive (memory.high fraction) signal is an early warning, not proof
# of harm: it may only drive capacity down to soft_floor, never further.
d = bsc.decide(st(allowed=8), inp(cur=15.0, occupied=8), CFG)  # 93.75% of high
check("predictive tighten steps down", d.state.allowed, 6)
d = bsc.decide(st(allowed=5), inp(cur=15.0, occupied=5), CFG)
check("predictive stops at the soft floor", d.state.allowed, 4)
check("predictive reason says so", "[predictive" in d.reasons[0].detail, True)

# THE TIGHTEN-NEVER-RAISES min(): once PSI has driven allowed below the soft
# floor, a predictive-only tick must NOT lift it back up -- that would be a
# loosen wearing a TIGHTEN label, skipping the dwell guard (the live
# 1->4->2->1 ring of 2026-08-03).
d = bsc.decide(st(allowed=1), inp(cur=15.0, occupied=1), CFG)
check("tighten never raises", d.state.allowed, 1)
check("no-op tighten still records its branch", len(d.reasons), 1)
check("no-op tighten span is flat", span(d.reasons[0]), (1, 1))

# --- Loosening -------------------------------------------------------------

# Saturated, calm on the long window, dwell elapsed: one additive step.
d = bsc.decide(st(allowed=4, mark=4), inp(now=100.0, occupied=4), CFG)
check("loosen when saturated+calm+dwelled", d.state.allowed, 5)
check("loosen restarts the dwell clock", d.state.last_up, 100.0)
check("loosen reason tagged", tags(d), ["LOOSEN"])

# The idle ratchet: quiet PSI on an idle box is the absence of evidence, not
# a licence to grow (occupied < allowed means the cap is not the constraint).
d = bsc.decide(st(allowed=4), inp(now=100.0, occupied=0), CFG)
check("no loosen while idle", d.state.allowed, 4)

# Never twice inside dwell.
d = bsc.decide(st(allowed=4, mark=4, last_up=90.0),
               inp(now=100.0, occupied=4), CFG)
check("no loosen inside dwell", d.state.allowed, 4)
d = bsc.decide(st(allowed=4, mark=4), inp(now=100.0, occupied=4), CFG)
d = bsc.decide(d.state, inp(now=105.0, occupied=5), CFG)
check("no second loosen inside dwell", d.state.allowed, 5)

# Long window not quiet: no growth however saturated.
d = bsc.decide(st(allowed=4, mark=4), inp(now=100.0, psi60=5.0, occupied=4),
               CFG)
check("no loosen while psi60 busy", d.state.allowed, 4)

# Saturation is judged against `allowed`, not the target in effect: a closed
# load test makes occupied >= target trivially true and must not grow the cap
# (psi10 here is above grant_psi but below tighten_psi, so the gate is shut
# without any tighten firing).
d = bsc.decide(st(allowed=2, mark=2), inp(now=100.0, psi10=10.0, occupied=1),
               CFG)
check("no loosen behind a closed gate", d.state.allowed, 2)

# At the ceiling there is nothing left to grant.
d = bsc.decide(st(allowed=8, mark=8), inp(now=100.0, occupied=8), CFG)
check("no loosen past the ceiling", d.state.allowed, 8)

# --- The high-water mark and the growth clock ------------------------------

# Occupancy above the mark while healthy is demonstrated concurrency: the
# mark follows it up and the spacing clock restarts.
d = bsc.decide(st(allowed=8, mark=2, last_growth=50.0),
               inp(now=100.0, occupied=3), CFG)
check("mark follows demonstrated occupancy", d.state.mark, 3)
check("growth restarts the spacing clock", d.state.last_growth, 100.0)

# A replacement (occupancy at the mark) leaves the clock alone -- under
# steady churn a per-admission reset would freeze concurrency forever.
d = bsc.decide(st(allowed=8, mark=3, last_growth=50.0),
               inp(now=100.0, occupied=3), CFG)
check("replacement leaves the spacing clock", d.state.last_growth, 50.0)

# The mark falls whenever the load test fails, so a level the box can no
# longer sustain stops counting as demonstrated.
d = bsc.decide(st(allowed=8, mark=6), inp(psi10=10.0, occupied=2), CFG)
check("mark falls when unhealthy", d.state.mark, 2)

# Growth waits out grant_every; a replacement-level target does not.
d = bsc.decide(st(allowed=8, mark=3, last_growth=95.0),
               inp(now=100.0, occupied=3), CFG)
check("no grant before its time", d.target, 3)
d = bsc.decide(st(allowed=8, mark=3, last_growth=80.0),
               inp(now=100.0, occupied=3), CFG)
check("one grow step once spacing elapses", d.target, 4)

# --- The free-slot cap (the drain) -----------------------------------------

# THE DRAIN: the mark remembers the peak, but availability must track the
# RUNNING SET -- occupied + burst -- or seven slots stand free at exactly the
# moment the next burst arrives (measured 2026-08-06 as occupied=1 target=8).
# The mark must survive untouched: the fix is the cap doing its job, not the
# mark quietly decaying.
d = bsc.decide(st(allowed=8, mark=8, last_growth=100.0),
               inp(now=100.0, occupied=1), CFG)
check("drain does not reopen the window", d.target, 3)
check("mark survives the drain", d.state.mark, 8)
check("no hold line when healthy", d.hold, None)

# --- Absorbable: batches sized to memory -----------------------------------

# A replacement batch is offered only as fast as the CURRENT headroom can
# absorb it, keeping one job's worth of slack in hand. Tight pool (3.0G free,
# 1.5G jobs): one beyond occupancy. Roomy pool, same slots: the burst pair.
d = bsc.decide(st(allowed=8, mark=4), inp(cur=13.0, occupied=2), CFG)
check("batch capped by headroom", d.target, 3)
d = bsc.decide(st(allowed=8, mark=4), inp(cur=4.0, occupied=2), CFG)
check("batch opens up when roomy", d.target, 4)

# --- The load test ---------------------------------------------------------

# Memory half: room for ONE job is not enough -- two is the bar, so admission
# stops one job short of the wall (2.5G free < 2 x 1.5G).
d = bsc.decide(st(allowed=4, mark=2), inp(cur=13.5, occupied=2), CFG)
check("held below two jobs of headroom", d.target, 2)
check("memory half reports unhealthy", d.healthy, False)
check("hold line names memory", "free=" in (d.hold or ""), True)

# Stall half: plenty of memory but psi10 above grant_psi (and below the
# tighten threshold) shuts the gate without moving `allowed`.
d = bsc.decide(st(allowed=4, mark=2), inp(psi10=10.0, occupied=2), CFG)
check("held while stalling", d.target, 2)
check("stall gate does not tighten", d.state.allowed, 4)
check("hold line names psi", "psi10=" in (d.hold or ""), True)

# Both halves pass again: the grant resumes (as growth -- the mark fell while
# the gate was shut).
d = bsc.decide(st(allowed=4, mark=2), inp(now=100.0, occupied=2), CFG)
check("grant resumes when healthy", d.target, 3)

# An unreadable pool is NO SIGNAL, not a refusal.
d = bsc.decide(st(allowed=4, mark=2),
               inp(now=100.0, psi10=None, psi60=None, pool=False, occupied=2),
               CFG)
check("missing pool reads as calm", d.healthy, True)
check("missing pool does not tighten", d.state.allowed, 4)

# --- Fail-open on missing occupancy ----------------------------------------

# /proc/locks unreadable: fail open to pre-gate behaviour; `allowed` alone
# still bounds things and no burst/absorbable clamp applies.
d = bsc.decide(st(allowed=6, mark=2), inp(psi60=None, occupied=None), CFG)
check("no occupancy signal fails open to allowed", d.target, 6)
check("no occupancy leaves the mark", d.state.mark, 2)
# cap_saturated fails open too, so a calm dwelled box still loosens. This is
# the current, deliberate semantics -- locked here so a change is a decision.
d = bsc.decide(st(allowed=6, mark=2), inp(now=100.0, occupied=None), CFG)
check("no occupancy still dwell-loosens", d.state.allowed, 7)

# --- Residents shift the bounds --------------------------------------------

# THE FLOOR GUARD IS PHRASED AGAINST BUILD OCCUPANCY (occupied - resident),
# not total occupancy. Two residents and no builds: occupied is 2 and never
# 0, so the naive `occupied == 0` guard would silently die and an idle box
# with a browser on it would admit nothing at all. Hostile pool, so the floor
# is the ONLY thing that can open a slot -- and it must open exactly one
# build's worth above the residents (floor_dyn = 1 + 2).
d = bsc.decide(st(allowed=1, mark=0),
               inp(cur=15.2, psi10=20.0, occupied=2, resident=2), CFG)
check("resident floor still admits one build", d.target, 3)

# Once a build holds that slot, build occupancy is positive and the guard
# stands down.
d = bsc.decide(st(allowed=1, mark=0),
               inp(cur=15.2, psi10=20.0, occupied=3, resident=2), CFG)
check("floor guard stands down once a build runs", d.target, 1)

# --- RECLAIM: a closing browser takes its capacity with it -----------------

d = bsc.decide(st(allowed=10, mark=0), inp(occupied=0, resident=0), CFG)
check("reclaim clamps to the bare ceiling", d.state.allowed, 8)
check("reclaim reason tagged", tags(d), ["RECLAIM"])
check("reclaim span", span(d.reasons[0]), (10, 8))

# THE ACCUMULATION FIX: a RECLAIM clamp and a TIGHTEN on the same tick each
# keep their own (before, after) transition. The old single `reason` variable
# let the tighten overwrite the reclaim, which then never reached the log.
d = bsc.decide(st(allowed=12, mark=8), inp(psi10=50.0, occupied=8,
                                           resident=0), CFG)
check("reclaim survives a same-tick tighten", tags(d), ["RECLAIM", "TIGHTEN"])
check("reclaim keeps its own span", span(d.reasons[0]), (12, 8))
check("tighten keeps its own span", span(d.reasons[1]), (8, 6))
check("net allowed composes both", d.state.allowed, 6)

# --- The resident cap ------------------------------------------------------

# At cap the PUBLISHED bit goes unhealthy so NEW resident admissions queue,
# while the raw verdict stays healthy for every build decision -- the mark
# still rises to 8 here, which only the raw-healthy path does.
d = bsc.decide(st(allowed=8, mark=4), inp(occupied=8, resident=8), CFG)
check("resident cap zeroes published health", d.published_healthy, False)
check("raw health unaffected by the cap", d.healthy, True)
check("internal decisions still use raw health", d.state.mark, 8)
check("cap engagement noted once",
      d.notes, ["RESIDENT-CAP engaged resident=8 cap=8"])
check("cap state remembered", d.state.was_resident_full, True)

# Same conditions next tick: the edge already logged, no repeat note.
d2 = bsc.decide(d.state, inp(occupied=8, resident=8), CFG)
check("cap note not repeated", d2.notes, [])

# A browser closes: released note, published health restored.
d3 = bsc.decide(d2.state, inp(occupied=7, resident=7), CFG)
check("cap release noted",
      d3.notes, ["RESIDENT-CAP released resident=7 cap=8"])
check("published health restored below cap", d3.published_healthy, True)

summary()
