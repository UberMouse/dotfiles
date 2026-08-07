"""Shared harness for the script test suites.

Each suite previously copy-pasted its own check()/fails/passes/exit block,
and the five copies had already diverged (two repr'd values, three didn't;
two cleaned their tempdir, three leaked it). One copy, used by all.

wait_for() is the determinism tool: polling for an outcome asserts the same
thing a fixed sleep did, without betting on an upper bound that a loaded box
can lose (this machine's whole purpose is being memory-thrashed by builds).
"""

import shutil
import sys
import time

fails = []
passes = []


def check(name, got, want):
    ok = got == want
    (passes if ok else fails).append(name)
    print(f"{'PASS' if ok else 'FAIL'}  {name}: got {got!r}, want {want!r}")


def wait_for(cond, timeout=20.0, interval=0.1):
    """Poll until cond() is truthy or the timeout lapses; return the last
    value either way. Exceptions inside cond() read as falsy (the thing being
    polled for may not exist yet)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            v = cond()
        except Exception:
            v = None
        if v:
            return v
        time.sleep(interval)
    try:
        return cond()
    except Exception:
        return None


def summary(cleanup_dir=None, extra_on_fail=None):
    """Print the verdict and exit. cleanup_dir is removed only on success so
    a failure leaves the fixtures behind for inspection; extra_on_fail() runs
    before the failure list (e.g. dumping a subprocess log)."""
    if fails:
        if extra_on_fail is not None:
            try:
                extra_on_fail()
            except Exception:
                pass
        print("\nFAILURES:", fails)
    else:
        if cleanup_dir is not None:
            shutil.rmtree(cleanup_dir, ignore_errors=True)
        print(f"\nall {len(passes)} assertions passed")
    sys.exit(1 if fails else 0)
