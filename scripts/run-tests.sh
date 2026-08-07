#!/usr/bin/env bash
# Run every script test suite plus the lint tripwires; forward a combined
# exit code. This is the fast local loop -- `nix flake check` runs the same
# deterministic suites in the sandbox, plus the nix-level lints.
#
# Suites are DISCOVERED (scripts/*.test.py), not listed: a hardcoded list is
# how a new suite silently never runs, and a stated count in prose is how the
# docs rot (CLAUDE.md deliberately doesn't give one).
#
# All suites are deterministic: policy is unit-tested against pure decide()
# with an injected clock, blocking is asserted from log lines rather than
# elapsed time, and everything slow-converging is polled via testlib.wait_for
# instead of fixed sleeps.
set -u
cd "$(dirname "$0")/.." || exit 1

# The suites exec_module() the controller; without this every local run
# leaves a scripts/__pycache__/ behind (gitignored, but noise).
export PYTHONDONTWRITEBYTECODE=1

rc=0
for t in scripts/*.test.py; do
  echo "== ${t}"
  python3 "$t" || rc=1
done
echo "== scripts/lint-tripwires.py"
python3 scripts/lint-tripwires.py || rc=1
exit "$rc"
