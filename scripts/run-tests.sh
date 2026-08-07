#!/usr/bin/env bash
# Run both semaphore test suites and forward a combined exit code.
#
# All suites are deterministic since the 2026-08-07 decide() extraction: the
# controller's policy is unit-tested against a pure function with an injected
# clock, and its few remaining integration tests are convergence-polled rather
# than dwell-timed.
set -u
cd "$(dirname "$0")/.." || exit 1

rc=0
python3 scripts/kx-build-slot.test.py || rc=1
python3 scripts/wt-cgroup-i3status.test.py || rc=1
python3 scripts/cgroup-thaw-all.test.py || rc=1
python3 scripts/cgroup-governor.test.py || rc=1
python3 scripts/build-semaphore-controller.test.py || rc=1
exit "$rc"
