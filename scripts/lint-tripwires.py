#!/usr/bin/env python3
"""Repo-specific lint tripwires, run from `nix flake check`'s lint derivation.

Each check mechanically enforces a rule this repo has already paid for once by
breaking it silently — the class of failure CLAUDE.md calls "a test that can no
longer be true, quietly disabling a safety property". Run from the repo root.
"""
import os
import re
import sys
from pathlib import Path

failures = []


def scripts_and_bins():
    # Test suites and this checker hold forbidden strings as DATA (fixtures
    # and assertions about the ban), so they are exempt from string checks.
    for d in ("scripts", "scriptBins/bins"):
        for p in Path(d).iterdir():
            if p.suffix not in (".sh", ".py") or not p.is_file():
                continue
            if p.name.endswith(".test.py") or p.name == "lint-tripwires.py":
                continue
            yield p


# 1. pgrep -f ban. Matching the joined cmdline false-positives on the probe
#    itself and anything holding the string; kx-proc-find (argv-field globs)
#    is the sanctioned replacement. Comment lines discussing the ban are fine.
for p in scripts_and_bins():
    for i, line in enumerate(p.read_text().splitlines(), 1):
        if "pgrep -f" in line and not line.lstrip().startswith("#"):
            failures.append(f"{p}:{i}: pgrep -f is banned; use kx-proc-find")

# 2. /home/taylorl literals in nix files. home.homeDirectory is the single
#    allowed definition; everything else derives from it (or uses $HOME).
for p in Path(".").rglob("*.nix"):
    if ".git" in p.parts:
        continue
    for i, line in enumerate(p.read_text().splitlines(), 1):
        if "/home/taylorl" not in line or line.lstrip().startswith("#"):
            continue
        if 'homeDirectory = "/home/taylorl"' in line:
            continue
        failures.append(
            f"{p}:{i}: hardcoded /home/taylorl (use config.home.homeDirectory or $HOME)"
        )

# 3. Pool-path override tripwire. Every construction of the worktrees.slice
#    cgroup path must sit within two lines of its KX_POOL/KX_SEM_POOL override,
#    so tests can retarget every tool and a slice rename is one mechanical
#    sweep instead of a hunt across three languages.
for p in scripts_and_bins():
    lines = p.read_text().splitlines()
    for i, line in enumerate(lines):
        if "service/worktrees.slice" not in line or line.lstrip().startswith("#"):
            continue
        window = "\n".join(lines[max(0, i - 2) : i + 1])
        if "KX_POOL" not in window and "KX_SEM_POOL" not in window:
            failures.append(
                f"{p}:{i + 1}: pool path hardcoded without a KX_POOL override nearby"
            )

# 4. Docs-liveness: every repo-relative path CLAUDE.md names must exist.
#    (~-prefixed and absolute paths are external and skipped.) This is the
#    check that would have caught packages/tabby-terminal/package.nix living
#    on in the docs long after the package was deleted.
for tok in re.findall(r"[\w~./-]+", Path("CLAUDE.md").read_text()):
    if tok.startswith(("~", "/")) or "/" not in tok:
        continue
    if not re.search(r"\.(nix|sh|py|md|json|conf|zsh)$", tok):
        continue
    if not os.path.exists(tok):
        failures.append(f"CLAUDE.md names a missing path: {tok}")

if failures:
    print("\n".join(failures))
    sys.exit(1)
print("lint-tripwires: all clear")
