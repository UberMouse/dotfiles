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
        occupied=0, resident=0, fleet=None, avail=None, desk=0.0, cache=None):
    """Inputs with pool sizes in GiB; pool=False means the pool is unreadable.

    NOTE the default `now` of 1000.0 against the default clocks of 0.0: dwell
    (60) and spacing (15) both read as long elapsed unless a test pins them.

    `fleet` is GiB held by pool tenants that take no slots, or None for "no
    signal" -- which is the default precisely so that every pre-existing case
    below still measures high_frac over the whole pool, as it was written to.

    `avail` is the MACHINE's MemAvailable in GiB, or None for "no signal" --
    the default, so that every case written before the self-inflicted test
    existed still gets the full floor, which is what those cases assert.

    `desk` is the DESKTOP scope's full-avg10 memory PSI, or None for "no
    signal". Unlike `avail` it defaults to 0.0 (quiet) rather than to None,
    because the self-inflicted cases predate this term and were all written
    under the 2026-08-27 scenario, whose stated conditions included "desktop
    session at 0.00% pressure". Defaulting it quiet preserves exactly what
    those cases were written to measure; the no-signal direction is asserted
    explicitly below instead of being carried by the default.

    `cache` is GiB of reclaimable page cache already subtracted from `cur`, or
    None for "no signal" -- the DEFAULT, and load-bearing: the build-share term
    needs it alongside `fleet`, so every case written before that term existed
    still reaches the floor on the headroom term alone, which is what those
    cases assert. Note `cur` is NET of this, so the raw charge the kernel
    throttles against is cur + cache.
    """
    pool_mem = (int(cur * GIB), int(high * GIB)) if pool else None
    untracked = None if fleet is None else int(fleet * GIB)
    mem_available = None if avail is None else int(avail * GIB)
    pool_cache = None if cache is None else int(cache * GIB)
    return bsc.Inputs(now, psi10, psi60, pool_mem, occupied, resident,
                      untracked, pool_cache=pool_cache,
                      mem_available=mem_available,
                      desktop_psi10=desk)


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

# --- SELF-INFLICTED STALLS: our own ceiling squeezing our own cache ---------
#
# memory.high is enforced against the RAW charge, cache included, while every
# figure here is net of reclaimable cache. A pool doing heavy file IO therefore
# pins the raw charge at the ceiling and pays reclaim throttling -- which IS
# memory PSI -- with the net charge nowhere near the limit. Measured 2026-08-27:
# psi10 spiking to 39% against net in-use of 4.9G in a 16G pool, desktop at
# 0.00% pressure, 12.6G MemAvailable; 28 of 28 tightens in two hours were psi10
# and `allowed` spent 29% of its time at 1-2 for nothing.
#
# Such a stall is demoted to the predictive signal's authority: still a tighten,
# but bounded by the soft floor.
d = bsc.decide(st(allowed=8), inp(psi10=50.0, occupied=8, avail=12.0), CFG)
check("self-inflicted psi still steps down", d.state.allowed, 6)
check("self-inflicted psi is still a tighten", tags(d), ["TIGHTEN"])
d = bsc.decide(st(allowed=5), inp(psi10=50.0, occupied=5, avail=12.0), CFG)
check("self-inflicted psi stops at the soft floor", d.state.allowed, 4)
check("self-inflicted reason says so",
      "[self-inflicted" in d.reasons[0].detail, True)
check("...and still reports the stall it is discounting",
      "psi10=50.0%" in d.reasons[0].detail, True)

# ALL THREE terms are load-bearing, and each failing alone must restore the
# full floor.
#
# A globally starved box: global reclaim lands on the pool and the PSI is not
# ours to dismiss, however roomy the pool's own net headroom looks.
d = bsc.decide(st(allowed=2), inp(psi10=50.0, occupied=2, avail=2.0), CFG)
check("a starved machine still reaches the floor", d.state.allowed, 1)

# A pool genuinely close to its own ceiling: 13/16G leaves 3G, under the 4-job
# (6G) bar, and 81% keeps the predictive signal out of it so psi is isolated.
d = bsc.decide(st(allowed=2),
               inp(psi10=50.0, cur=13.0, occupied=2, avail=12.0), CFG)
check("a genuinely tight pool still reaches the floor", d.state.allowed, 1)

# NO SIGNAL is not a licence to discount: an unreadable /proc/meminfo leaves the
# full floor available, the same tighten-early-never-late direction every other
# fallback in decide() takes. (This is the default `avail`, which is why every
# pre-existing case above keeps its meaning.)
d = bsc.decide(st(allowed=2), inp(psi10=50.0, occupied=2), CFG)
check("no MemAvailable signal still reaches the floor", d.state.allowed, 1)

# THE DESKTOP TERM (2026-09-04). A pool holding net headroom against its own
# ceiling on a box that still reports MemAvailable is EXACTLY the shape of a
# genuine machine-wide squeeze, because the partition in memory-policy.nix
# balances at exact equality (16+8+2+3 = 29): "room under the pool ceiling"
# and "no room on the machine" are simultaneously true, and MemAvailable does
# not separate them -- it counts the reclaimable cache whose reclaim IS the
# stall. Measured 2026-09-04 12:04: desktop at 47.96% memory PSI with 6.5G
# MemAvailable, comfortably past the 4G gate, while the pressure monitor
# logged its third desktop stall of the day.
d = bsc.decide(st(allowed=5),
               inp(psi10=50.0, occupied=5, avail=12.0, desk=33.8), CFG)
check("a stalling desktop defeats the exemption", d.state.allowed, 3)
check("...and the reason drops the self-inflicted tag",
      "[self-inflicted" in d.reasons[0].detail, False)

# The boundary is the threshold itself, not a hand-picked pair of values.
d = bsc.decide(st(allowed=5),
               inp(psi10=50.0, occupied=5, avail=12.0,
                   desk=CFG.desktop_quiet_psi - 0.1), CFG)
check("a desktop just under the bar is still quiet", d.state.allowed, 4)
d = bsc.decide(st(allowed=5),
               inp(psi10=50.0, occupied=5, avail=12.0,
                   desk=CFG.desktop_quiet_psi), CFG)
check("a desktop AT the bar is not quiet", d.state.allowed, 3)

# NO SIGNAL, same direction as the other two terms: an unresolvable session
# scope (no graphical session, or a display-manager restart mid-tick) must not
# hand out an exemption it cannot justify.
d = bsc.decide(st(allowed=2),
               inp(psi10=50.0, occupied=2, avail=12.0, desk=None), CFG)
check("no desktop signal still reaches the floor", d.state.allowed, 1)

# THE TIGHTEN-NEVER-RAISES min() again, on this path: PSI has already driven
# allowed to 1 and the stall now reads as self-inflicted, which lifts `limit` to
# the soft floor. max(4, -1) is 4, so without the outer min() this tick would
# RAISE 1 -> 4 -- the same loosen-wearing-a-TIGHTEN-label ring the predictive
# case above guards against, reached through a different door.
d = bsc.decide(st(allowed=1), inp(psi10=50.0, occupied=1, avail=12.0), CFG)
check("self-inflicted tighten never raises", d.state.allowed, 1)
check("self-inflicted no-op still records its branch", len(d.reasons), 1)
check("self-inflicted no-op span is flat", span(d.reasons[0]), (1, 1))

# A REAL stall on a roomy box must still be able to reach the floor once the
# machine's slack is gone -- the transition, not just the endpoints.
d = bsc.decide(st(allowed=4), inp(psi10=50.0, occupied=4, avail=12.0), CFG)
check("self-inflicted holds at the soft floor", d.state.allowed, 4)
d = bsc.decide(st(allowed=4), inp(psi10=50.0, occupied=4, avail=1.0), CFG)
check("...and drops through it the moment the box is genuinely short",
      d.state.allowed, 2)


# --- Self-inflicted, ALTERNATE ROUTE: the BUILD SHARE of the charge ---------
#
# The headroom term asks "does the pool hold 4 jobs' worth of net room". That
# proxy decays as the FLEET grows: measured 2026-09-11 the fleet held 7.17G of
# a 15G pool, so net headroom clears the 6G bar only while the pool is under
# 60% net-full -- a window that is narrowest exactly when the fleet is largest,
# which is when interactive responsiveness matters most. Live consequence, three
# consecutive ticks:
#
#     TIGHTEN psi10=37.0%  allowed 6 -> 4
#     TIGHTEN psi10=47.3%  allowed 4 -> 2
#     TIGHTEN psi10=51.6%  allowed 2 -> 1
#
# untagged, because headroom was 4.02G (2.7 jobs) -- while net in-use was 73%
# of high and the RAW charge sat at 99.2%, pinned there by 3.90G of the pool's
# own reclaimable cache.
#
# So ask the question the actuator can answer: what share of the charge the
# kernel is throttling against do BUILDS hold? Builds held 3.81G of a 14.88G
# raw charge -- 25.6%. Tightening `allowed` to zero could not have removed the
# other three quarters, so the stall was not the builds' to relieve. Unlike the
# headroom bar this is fleet-size-adaptive: it says "a minority tenant cannot
# be blamed for the ceiling", which stays true whatever the fleet's size.
#
# It is an ALTERNATE route to the headroom term, never a replacement -- the two
# OR together, and the MemAvailable and desktop terms below remain mandatory on
# both routes.
SI = dict(psi10=50.0, avail=12.0)
d = bsc.decide(st(allowed=5),
               inp(cur=10.98, high=15.0, fleet=7.17, cache=3.90,
                   occupied=5, **SI), CFG)
check("a minority-build charge is self-inflicted", d.state.allowed, 4)
check("...and is tagged as such",
      "[self-inflicted" in d.reasons[0].detail, True)

# The same pool WITHOUT the new route: headroom 4.02G is under the 4-job bar,
# so before this term the identical situation descended to the floor.
d = bsc.decide(st(allowed=2),
               inp(cur=10.98, high=15.0, occupied=2, **SI), CFG)
check("no build-share signal keeps the old floor", d.state.allowed, 1)

# BOTH signals are required, and either missing reads as no-signal -> NOT
# self-inflicted, the same tighten-early-never-late direction as every other
# fallback in decide().
d = bsc.decide(st(allowed=2),
               inp(cur=10.98, high=15.0, fleet=7.17, occupied=2, **SI), CFG)
check("fleet without cache cannot compute a share", d.state.allowed, 1)
d = bsc.decide(st(allowed=2),
               inp(cur=10.98, high=15.0, cache=3.90, occupied=2, **SI), CFG)
check("cache without fleet cannot compute a share", d.state.allowed, 1)

# BUILDS IN THE MAJORITY are exactly what the exemption must not cover: same
# 15G pool and the same cache, but the fleet is small, so builds hold
# 9.0 - 1.0 = 8.0G of a 10.9G raw charge (73%). That is a stall tightening CAN
# move, and it must still reach the floor.
# (15G pool, 10G net -> 5G headroom, UNDER the 6G bar, so the headroom route
# is out and the share is the only thing under test.)
d = bsc.decide(st(allowed=2),
               inp(cur=10.0, high=15.0, fleet=1.0, cache=2.0,
                   occupied=2, **SI), CFG)
check("a majority-build charge still reaches the floor", d.state.allowed, 1)

# The boundary is the threshold itself, not a hand-picked pair. Raw charge is
# pinned to 10G so the share is exactly the knob: fleet carries the remainder.
def share_inp(share, allowed_occ=2):
    """cur/fleet/cache chosen so builds hold `share` of a 10G raw charge.

    high=12G keeps net headroom (4G) under the 4-job bar, so the headroom route
    cannot fire and the share is the only term deciding these two cases.
    """
    raw, cache = 10.0, 2.0
    cur = raw - cache
    return inp(cur=cur, high=12.0, fleet=cur - share * raw, cache=cache,
               occupied=allowed_occ, **SI)

d = bsc.decide(st(allowed=2), share_inp(CFG.self_inflicted_build_share - 0.02), CFG)
check("a share just under the bar is a minority", d.state.allowed, 2)
d = bsc.decide(st(allowed=2), share_inp(CFG.self_inflicted_build_share), CFG)
check("a share AT the bar is not a minority", d.state.allowed, 1)

# The mandatory terms still veto on this route: a starved machine and a
# stalling desktop each defeat it on their own, exactly as on the headroom one.
d = bsc.decide(st(allowed=2),
               inp(cur=10.98, high=15.0, fleet=7.17, cache=3.90,
                   occupied=2, psi10=50.0, avail=2.0), CFG)
check("a starved machine defeats the build-share route", d.state.allowed, 1)
d = bsc.decide(st(allowed=2),
               inp(cur=10.98, high=15.0, fleet=7.17, cache=3.90,
                   occupied=2, desk=33.8, **SI), CFG)
check("a stalling desktop defeats the build-share route", d.state.allowed, 1)

# A fleet that has grown past the ceiling makes the build share negative by a
# hair on two live reads; it must clamp to a minority, not wrap.
d = bsc.decide(st(allowed=5),
               inp(cur=10.0, high=15.0, fleet=11.0, cache=2.0,
                   occupied=5, **SI), CFG)
check("an over-ceiling fleet clamps the share", d.state.allowed, 4)


# --- The FUTILITY BRAKE ----------------------------------------------------
#
# The backstop that needs no threshold to be right. `allowed` is a CAP, so
# cutting it removes nothing until the running set drains -- which means PSI
# staying flat after a tighten is the lever's LATENCY, not its futility, and
# must never trip a brake. PSI CLIMBING across consecutive tightens is the
# other thing entirely: measured 2026-09-11, psi10 went 37.0 -> 47.3 -> 51.6
# while allowed was cut 6 -> 4 -> 2 -> 1. Three steps, each making the
# measurement worse. Further descent is not indicated.
#
# So the brake counts CONSECUTIVE psi tightens on which psi10 ROSE, and clamps
# at the soft floor -- it never removes the floor, so a misfire still tightens.
REF = 37.0
first = bsc.decide(st(allowed=6), inp(psi10=REF, occupied=6), CFG)
check("first tighten is unbraked", first.state.allowed, 4)
check("...and records the psi it acted on", first.state.tighten_ref, REF)
check("...as a streak of one", first.state.tighten_streak, 1)

# Second consecutive tighten with psi RISEN past the bar: brake engages and
# clamps at soft_floor (4), so allowed does not fall to 2.
risen = REF + CFG.futile_psi_rise + 0.1
second = bsc.decide(first.state, inp(psi10=risen, occupied=6), CFG)
check("a rising second tighten is braked", second.state.allowed, 4)
check("...and says so", "[futile" in second.reasons[0].detail, True)
check("...and counts the streak", second.state.tighten_streak, 2)

# THE REFERENCE IS THE RUN'S ORIGIN. A third tick that rises only a little from
# the SECOND -- under the bar on a per-tick reading -- is still far above where
# the run began, and must keep the brake on. This is the real 2026-09-11 tail:
# 37.0 -> 47.3 -> 51.6, whose last step is +4.3 and would have released a
# per-tick brake at exactly the point psi was 14 points worse than at the start.
third = bsc.decide(second.state, inp(psi10=51.6, occupied=6), CFG)
check("a decelerating but still-risen tighten stays braked",
      third.state.allowed, 4)
check("...and the origin is still the one the run began at",
      third.state.tighten_ref, REF)
check("...with the streak still climbing", third.state.tighten_streak, 3)

# The run resets only when psi comes back to where it started.
back = bsc.decide(second.state, inp(psi10=REF, occupied=6), CFG)
check("psi back at the origin resets the run", back.state.tighten_streak, 1)
check("...and unbrakes the descent", back.state.allowed, 2)

# LATENCY, not futility: psi flat (or barely moved) after a tighten must NOT
# brake -- the running set has not drained yet and the cut is still pending.
flat = bsc.decide(first.state, inp(psi10=REF, occupied=6), CFG)
check("a flat second tighten is not braked", flat.state.allowed, 2)
check("...and resets the streak", flat.state.tighten_streak, 1)

# Improvement obviously does not brake.
better = bsc.decide(first.state, inp(psi10=20.0, occupied=6), CFG)
check("an improving second tighten is not braked", better.state.allowed, 2)

# The brake CLAMPS, it does not remove the floor: a braked tick still tightens
# when allowed is above the soft floor.
high_state = first.state._replace(allowed=8)
d = bsc.decide(high_state, inp(psi10=risen, occupied=8), CFG)
check("a braked tighten still tightens toward the soft floor",
      d.state.allowed, 6)

# A tick that does NOT psi-tighten clears the trail, so the brake only ever
# reads a CONSECUTIVE run. A calm tick is the reset.
calm = bsc.decide(first.state, inp(psi10=0.0, psi60=0.0, occupied=1), CFG)
check("a calm tick clears the tighten ref", calm.state.tighten_ref, None)
check("...and zeroes the streak", calm.state.tighten_streak, 0)

# The brake must not defeat a GENUINE descent: real scarcity relieves as builds
# drain, so psi falls and the streak resets every time -- the floor stays
# reachable across a long real episode.
stt = st(allowed=8)
for psi in (50.0, 40.0, 30.0, 20.0):
    stt = bsc.decide(stt, inp(psi10=psi, occupied=8), CFG).state
check("a falling-psi episode still reaches the floor", stt.allowed, 1)


# --- The BUILD BUDGET: untracked tenants must not read as build pressure ----
#
# The whole point of subtracting the fleet: `allowed` actuates builds only, so
# the predictive signal has to be about builds only. Same 15/16G pool as the
# case above -- 93.75% and firmly hot -- but 11G of it is the agents fleet, so
# builds hold 4G of the 5G available to them. That is 80%, under the 90%
# threshold, and tightening would reclaim nothing a build owns.
d = bsc.decide(st(allowed=8), inp(cur=15.0, occupied=8, fleet=11.0), CFG)
check("fleet memory does not trigger a predictive tighten",
      d.state.allowed, 8)
check("...and records no tighten at all", tags(d), [])

# The correction must not blind the signal: with a small fleet, builds really
# are the ones filling the pool, and the tighten still fires.
d = bsc.decide(st(allowed=8), inp(cur=15.0, occupied=8, fleet=1.0), CFG)
check("builds filling the pool still tighten", d.state.allowed, 6)
check("the log line names the build fraction and the fleet",
      "build=93%" in d.reasons[0].detail
      and "fleet 1.0G" in d.reasons[0].detail, True)

# A fleet at or over memory.high leaves builds no budget whatever. That is the
# hottest possible reading -- NOT a divide-by-zero, and NOT a negative
# denominator quietly producing a reassuring small fraction.
d = bsc.decide(st(allowed=8), inp(cur=17.0, high=16.0, occupied=8, fleet=16.0),
               CFG)
check("fleet at the ceiling reads as maximally hot", d.state.allowed, 6)
d = bsc.decide(st(allowed=8), inp(cur=20.0, high=16.0, occupied=8, fleet=18.0),
               CFG)
check("fleet over the ceiling reads as maximally hot too", d.state.allowed, 6)

# Sampling skew: memory.current and the fleet's memory.current are two reads of
# a live tree, so a shrinking fleet can make the difference negative. Clamp to
# 0 rather than letting a negative fraction wander below the loosen threshold.
d = bsc.decide(st(allowed=8), inp(cur=5.0, high=16.0, occupied=8, fleet=6.0),
               CFG)
check("negative build usage clamps to 0, not a nonsense fraction",
      tags(d), [])

# No signal (worktrees-agents.slice unreadable) must restore the old whole-pool
# behaviour exactly -- the safe direction, since it reads the pool as fuller.
d = bsc.decide(st(allowed=8), inp(cur=15.0, occupied=8, fleet=None), CFG)
check("no fleet signal falls back to the whole-pool fraction",
      d.state.allowed, 6)
check("...and logs the whole-pool label", "high=94%" in d.reasons[0].detail,
      True)

# THE LOAD TEST IS UNCHANGED BY ANY OF THIS. Subtracting the same bytes from
# both terms of (high - current) cancels, so free bytes stay free bytes no
# matter who is not using them. A pool with 1G free fails the 2-job headroom
# test whether or not the fleet is what filled it.
big, small = inp(cur=15.0, occupied=1, fleet=11.0), inp(cur=15.0, occupied=1)
check("headroom verdict ignores the fleet correction",
      bsc.decide(st(allowed=4), big, CFG).healthy,
      bsc.decide(st(allowed=4), small, CFG).healthy)
check("...and that shared verdict is 'not healthy' at 1G free",
      bsc.decide(st(allowed=4), big, CFG).healthy, False)

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

# ...unless that busy long window is the pool's OWN cache reclaim. psi60 is
# the raw stall average, so the throttling described in the self-inflicted
# block above keeps it elevated for as long as the pool does file IO -- and
# every recovery step is gated on it. Bounding the descent while leaving the
# ascent blocked by the same uncorrected signal fixes half a sawtooth:
# measured 2026-08-27, minutes at allowed=2 with psi10 at 0.00% and 18 jobs
# queued, psi60 stuck at 4.4% against the 3.0% gate while the pool was 40%
# full and the machine had 9.9G available.
d = bsc.decide(st(allowed=4, mark=4),
               inp(now=100.0, psi60=5.0, occupied=4, avail=12.0), CFG)
check("self-inflicted psi60 does not block recovery", d.state.allowed, 5)
check("self-inflicted loosen is tagged",
      "[self-inflicted]" in d.reasons[0].detail, True)
check("...and still reports the window it is discounting",
      "psi60=5.0%" in d.reasons[0].detail, True)

# A loosen on a genuinely quiet window must NOT wear the tag -- it did not use
# the exemption, and a reader has to be able to tell the two apart.
d = bsc.decide(st(allowed=4, mark=4), inp(now=100.0, occupied=4, avail=12.0),
               CFG)
check("a quiet loosen carries no tag",
      "[self-inflicted]" in d.reasons[0].detail, False)

# ...and the DESKTOP term withdraws the loosen exemption too. This is the half
# with real teeth: a tighten that stops at the soft floor still tightens,
# whereas an exempted LOOSEN re-opens admission into a box that has no room.
# Measured 2026-09-04, the exemption fired on 42 of 112 loosens at psi60 up to
# 44.3% against the 3.0% gate -- 14x over -- across a day in which the desktop
# stalled twelve times, the most since the pre-tuning era. At 15:43 a tighten
# to allowed=1 at psi10=45.2% was undone fifteen seconds later by an exempted
# loosen at psi60=26.1%, with a 32.39% desktop stall logged between them.
d = bsc.decide(st(allowed=4, mark=4),
               inp(now=100.0, psi60=5.0, occupied=4, avail=12.0, desk=33.8),
               CFG)
check("a stalling desktop blocks the exempted loosen", d.state.allowed, 4)
check("...and no LOOSEN is recorded at all", tags(d), [])

# The exemption relaxes ONLY the psi60 gate. Every other guard on the loosen
# still stands, and each is asserted here because the whole risk of this
# change is that it becomes a licence to grow.
d = bsc.decide(st(allowed=4), inp(now=100.0, psi60=5.0, occupied=0,
                                  avail=12.0), CFG)
check("self-inflicted does not defeat the idle ratchet", d.state.allowed, 4)
d = bsc.decide(st(allowed=4, mark=4, last_up=90.0),
               inp(now=100.0, psi60=5.0, occupied=4, avail=12.0), CFG)
check("self-inflicted does not defeat dwell", d.state.allowed, 4)
d = bsc.decide(st(allowed=8, mark=8),
               inp(now=100.0, psi60=5.0, occupied=8, avail=12.0), CFG)
check("self-inflicted does not defeat the ceiling", d.state.allowed, 8)

# A REAL busy window on a genuinely full pool still blocks recovery: 13/16G
# leaves 3G, under the 4-job (6G) bar, so the exemption withdraws itself
# exactly as builds fill the pool. This is what makes the change self-limiting.
d = bsc.decide(st(allowed=4, mark=4),
               inp(now=100.0, psi60=5.0, cur=13.0, occupied=4, avail=12.0),
               CFG)
check("a genuinely full pool still blocks recovery", d.state.allowed, 4)
d = bsc.decide(st(allowed=4, mark=4),
               inp(now=100.0, psi60=5.0, occupied=4, avail=1.0), CFG)
check("a starved machine still blocks recovery", d.state.allowed, 4)

# At the ceiling there is nothing left to grant.
d = bsc.decide(st(allowed=8, mark=8), inp(now=100.0, occupied=8), CFG)
check("no loosen past the ceiling", d.state.allowed, 8)

# --- The CACHE FRACTION on every decision line (observation only) ----------
#
# The LOOSEN exemption rests on a premise none of its terms measures: that the
# stall is the pool's ceiling squeezing its OWN page cache (67a7488). On
# 2026-09-14 it re-opened admission 9 times into fleet-anon thrash with the
# pool at 19% cache. Before any branch reads the fraction, every TIGHTEN, LOOSEN
# and HOLD line carries it, so the bar is picked from the log rather than
# guessed. `cur` is NET of cache, so the fraction is cache / (cur + cache).
d = bsc.decide(st(allowed=8),
               inp(psi10=50.0, cur=11.34, high=15.0, cache=2.66, occupied=8),
               CFG)
check("TIGHTEN line carries the cache fraction",
      "cache=19%" in d.reasons[0].detail, True)
blind = bsc.decide(st(allowed=8),
                   inp(psi10=50.0, cur=11.34, high=15.0, occupied=8), CFG)
check("...and the fraction changes no decision",
      (d.state, d.target, d.healthy),
      (blind.state, blind.target, blind.healthy))
check("no cache signal prints cache=?, never a fabricated 0%",
      "cache=?" in blind.reasons[0].detail, True)

# Both reads are required: a zero raw charge and an unreadable pool are no
# signal, exactly like a missing cache read.
d = bsc.decide(st(allowed=2),
               inp(psi10=50.0, cur=0.0, cache=0.0, occupied=2), CFG)
check("a zero raw charge is no cache signal",
      "cache=?" in d.reasons[0].detail, True)
d = bsc.decide(st(allowed=2),
               inp(psi10=50.0, pool=False, cache=1.0, occupied=2), CFG)
check("cache without a pool read is no cache signal",
      "cache=?" in d.reasons[0].detail, True)

# The exempted LOOSEN carries it too -- the line calibration will be read from.
# A cache-POOR pool still passes the exemption here; withdrawing that is the
# follow-up this logging exists to calibrate, locked so the change is a decision.
d = bsc.decide(st(allowed=4, mark=4),
               inp(now=100.0, psi60=5.0, cur=1.0, cache=0.2, occupied=4,
                   avail=12.0), CFG)
check("LOOSEN line carries the cache fraction",
      "cache=17%" in d.reasons[0].detail, True)
check("...alongside the exemption tag (no behaviour change yet)",
      (d.state.allowed, "[self-inflicted]" in d.reasons[0].detail), (5, True))
d = bsc.decide(st(allowed=4, mark=4), inp(now=100.0, occupied=4), CFG)
check("a quiet LOOSEN with no cache read prints cache=?",
      "cache=?" in d.reasons[0].detail, True)

# HOLD: next to, not instead of, the absolute "(cache NG excl)" figure.
d = bsc.decide(st(allowed=4, mark=2),
               inp(cur=13.5, cache=1.5, occupied=2), CFG)
check("HOLD line carries the cache fraction beside the excluded bytes",
      ("cache=10%" in d.hold, "(cache 1.5G excl)" in d.hold), (True, True))
d = bsc.decide(st(allowed=4, mark=2), inp(psi10=10.0, occupied=2), CFG)
check("a psi HOLD with no cache read prints cache=?", "cache=?" in d.hold, True)

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

# --- Config.from_env -------------------------------------------------------
# Previously untested, and it carried a live bug for exactly that reason:
# `f.type == "float"` compared the EVALUATED annotation object against a
# string (this module has no `from __future__ import annotations`), so every
# float tunable went through _int and any fractional override -- a perfectly
# valid "0.2" or "90.5" -- silently fell back to the field default. The
# machinery suite's own KX_SEM_INTERVAL=0.2 never took effect; it passed only
# because wait_for polls.
import os  # noqa: E402


def with_env(env, fn):
    saved = {k: os.environ.get(k) for k in env}
    os.environ.update(env)
    try:
        return fn()
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


c = with_env({"KX_SEM_DWELL": "90.5", "KX_SEM_INTERVAL": "0.2"},
             bsc.Config.from_env)
check("fractional float override survives (dwell)", c.dwell, 90.5)
check("fractional float override survives (interval)", c.interval, 0.2)

c = with_env({"KX_SEM_GRANT_EVERY": "0.0"}, bsc.Config.from_env)
check("float-typed zero stays zero (the machinery suite's time gate)",
      c.grant_every, 0.0)

c = with_env({"KX_SEM_CEIL": "6", "KX_SEM_DWELL": "garbage"},
             bsc.Config.from_env)
check("int override still lands", c.ceil, 6)
check("garbage still degrades to the default (no crash-loop)",
      c.dwell, 60.0)

# The ceil/max_slots invariant: the Nix side derives KX_SEM_CEIL from
# poolHighG and cannot see max_slots, so the clamp lives in __post_init__.
c = with_env({"KX_SEM_CEIL": "99"}, bsc.Config.from_env)
check("derived ceil clamps to max_slots", c.ceil, 16)
check("raw value remembered for the START log",
      getattr(c, "ceil_clamped_from", None), 99)
check("max_resident derives from the CLAMPED ceil", c.max_resident, 1)

summary()
