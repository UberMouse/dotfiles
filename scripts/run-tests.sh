#!/usr/bin/env bash
# Run both semaphore test suites and forward a combined exit code.
#
# The client suite (kx-build-slot.test.py) is deterministic and also runs in
# the sandbox as a flake check. The controller suite drives a real control loop
# through real dwell intervals: it is wall-clock timed and can flake on a
# loaded box — re-run on a quiet machine before believing a failure in its
# ramp/dwell tests (see CLAUDE.md).
set -u
cd "$(dirname "$0")/.." || exit 1

rc=0
python3 scripts/kx-build-slot.test.py || rc=1
python3 scripts/build-semaphore-controller.test.py || rc=1
exit "$rc"
