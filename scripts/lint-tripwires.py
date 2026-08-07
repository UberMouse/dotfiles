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

if not Path("flake.nix").exists():
    sys.exit("lint-tripwires: run from the repo root (flake.nix not found in cwd)")

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


def code_of(line):
    """The line with any trailing comment stripped (good enough for both
    shell and python here; neither embeds '#' in load-bearing strings)."""
    return line.split("#", 1)[0]


# 1. pgrep/pkill -f ban. Matching the joined cmdline false-positives on the
#    probe itself and anything holding the string; kx-proc-find (argv-field
#    globs) is the sanctioned replacement. The regex catches combined flags
#    (-af, -9f), long form (--full), and pkill — which is the identical
#    self-matching hazard with a kill attached. Flag scan stops at a pipe or
#    command separator so a later command's -f can't false-positive.
for p in scripts_and_bins():
    for i, line in enumerate(p.read_text().splitlines(), 1):
        code = code_of(line)
        if re.search(r"\bp(?:grep|kill)\b[^|;&]*(\s-[a-zA-Z0-9]*f\b|\s--full\b)", code):
            failures.append(f"{p}:{i}: pgrep/pkill -f is banned; use kx-proc-find")

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
#    CGROUP PATH must sit within two lines of its KX_POOL/KX_SEM_POOL
#    override, so tests can retarget every tool and a slice rename is one
#    mechanical sweep instead of a hunt across three languages. Matching
#    "/worktrees.slice" (with the leading slash) targets path constructions
#    only — bare `worktrees.slice` unit names in systemctl calls are fine.
#    The old form matched the literal "service/worktrees.slice", which the
#    governor never contains (it composes the path from $USERAT), so the
#    largest consumer was silently outside the check.
for p in scripts_and_bins():
    lines = p.read_text().splitlines()
    for i, line in enumerate(lines):
        if "/worktrees.slice" not in code_of(line):
            continue
        window = "\n".join(lines[max(0, i - 2) : i + 1])
        if "KX_POOL" not in window and "KX_SEM_POOL" not in window:
            failures.append(
                f"{p}:{i + 1}: pool path hardcoded without a KX_POOL override nearby"
            )

# 4. Docs-liveness: every repo-relative path the standing docs name must
#    exist. (~-prefixed and absolute paths are external and skipped.) This is
#    the check that would have caught packages/tabby-terminal/package.nix
#    living on in the docs long after the package was deleted. Covers the
#    skills too — they instruct future runs, and a skill pointing at a moved
#    file fails exactly like stale CLAUDE.md prose.
doc_files = [Path("CLAUDE.md"), Path("README.md")]
doc_files += sorted(Path("docs").rglob("*.md"))
doc_files += sorted(Path(".claude/skills").rglob("SKILL.md"))
for doc in doc_files:
    for tok in re.findall(r"[\w~./-]+", doc.read_text()):
        if tok.startswith(("~", "/")) or "/" not in tok:
            continue
        if re.search(r"\.(nix|sh|py|md|json|conf|zsh)$", tok):
            if not os.path.exists(tok):
                failures.append(f"{doc} names a missing path: {tok}")
            continue
        # Bare directory references ("zsh-customizations/") used to slip
        # through the extension filter above — a deleted dir lived on in the
        # repo-audit skill for a full release cycle. Trailing-slash tokens are
        # unambiguous dir refs. Skipped: domain-shaped first segments
        # (github.com/...) and anything with an uppercase char (env-var path
        # fragments like $XDG_RUNTIME_DIR/kx-build-sem/, which the tokenizer
        # strips the $ from). Prose often names a subdir bare ("playwright/"
        # for packages/playwright/), so a dir counts as live if it exists at
        # the root OR one or two levels down.
        if (
            tok.endswith("/")
            and "." not in tok.split("/", 1)[0]
            and tok == tok.lower()
        ):
            rel = tok.rstrip("/")
            if not (
                os.path.isdir(rel)
                or list(Path(".").glob(f"*/{rel}"))
                or list(Path(".").glob(f"*/*/{rel}"))
            ):
                failures.append(f"{doc} names a missing directory: {tok}")

# 5. Guards phrased against TOTAL occupancy die the moment a browser holds a
#    slot: `occupied == 0` can never be true again while a session is open,
#    which silently disables whatever safety property it gated (the 2026-08-07
#    build-progress-guard bug). Build occupancy is `occupied - resident`; any
#    zero-comparison on bare `occupied` without `resident` on the line is the
#    bug shape itself.
for p in scripts_and_bins():
    for i, line in enumerate(p.read_text().splitlines(), 1):
        code = code_of(line)
        if re.search(r"\boccupied\b[\"']?\s*(==|!=|<=|>=|<|>|-eq|-ne|-le|-ge|-lt|-gt)\s*[\"']?0\b", code):
            if "resident" not in code:
                failures.append(
                    f"{p}:{i}: guard on total occupancy; build guards read occupied - resident"
                )

# 6. compgen ban, repo-wide. nixpkgs builds bash WITHOUT programmable
#    completion, so compgen exits 127 and `! compgen` guards are silently
#    always-true (this gated nothing on first semaphore deploy, and the same
#    check previously lived — oddly — in the governor's test suite, covering
#    only two files).
for p in scripts_and_bins():
    for i, line in enumerate(p.read_text().splitlines(), 1):
        if re.search(r"\bcompgen\b", code_of(line)):
            failures.append(
                f"{p}:{i}: compgen is not compiled into nixpkgs bash; use a literal glob"
            )

# 7. New-package contract: every packages/<dir>/ carries an UPDATE.md (a pin
#    with no owner never gets asked about), and any spec still carrying an
#    explicit hash command must pair it with the derivation's fetcher —
#    `fetchzip` wants the --unpack NAR hash, `fetchurl` the flat file hash. A
#    mismatch silently freezes the package: every weekly run fails its hash
#    step and skips it (this happened for 3 months once).
for d in sorted(Path("packages").iterdir()):
    if not d.is_dir():
        continue
    spec = d / "UPDATE.md"
    pkg = d / "package.nix"
    if not spec.exists():
        failures.append(f"{d}: package directory without an UPDATE.md (unowned pin)")
        continue
    if not pkg.exists():
        continue
    spec_text = spec.read_text()
    pkg_text = pkg.read_text()
    if "nix-prefetch-url --unpack" in spec_text and "fetchzip" not in pkg_text:
        failures.append(f"{spec}: --unpack NAR hash command but package.nix has no fetchzip")
    if "nix store prefetch-file" in spec_text and "fetchurl" not in pkg_text:
        failures.append(f"{spec}: flat prefetch-file command but package.nix has no fetchurl")

# 8. op-shim roster: every `--as <name>` an op-cached consumer passes must
#    have a matching shim in scriptBins/default.nix's opShimCallers, or the
#    caller silently falls through to the shared "unknown" shim — an
#    unattributed 1Password grant, the exact thing the per-caller shims exist
#    to prevent (and visible only under OP_CACHED_DEBUG).
roster_m = re.search(
    r"opShimCallers\s*=\s*\[(.*?)\]", Path("scriptBins/default.nix").read_text(), re.S
)
roster = set(re.findall(r'"(\w+)"', roster_m.group(1))) if roster_m else set()
if not roster:
    failures.append("scriptBins/default.nix: opShimCallers list not found by lint")
for p in Path("scriptBins/bins").glob("*.sh"):
    for i, line in enumerate(p.read_text().splitlines(), 1):
        for name in re.findall(r"--as\s+(\w+)", code_of(line)):
            if name not in roster:
                failures.append(
                    f"{p}:{i}: --as {name} has no opShimCallers entry (falls through to 'unknown')"
                )

# 9. kernfs size-test ban. cgroup.procs (and every kernfs seq_file) stats as
#    size 0, so `[ -s .../cgroup.procs ]` is unconditionally false — this shape
#    silently disabled the governor's freeze duties for three days (2026-07-28..
#    31, the dead-actuator incident). Read a pid from the file instead. The
#    check used to live inside the governor's own test suite, covering exactly
#    one file; here it covers every script.
for p in scripts_and_bins():
    for i, line in enumerate(p.read_text().splitlines(), 1):
        if re.search(r"-s\s+\S*cgroup\.(procs|threads)", code_of(line)):
            failures.append(
                f"{p}:{i}: [ -s ] on a kernfs file is always false; read a pid instead"
            )

# 10. Residency pairing. A job that gates with --resident-probe leaves
#     something living behind, so it must also pass --resident, or it waits on
#     a free slot instead of the load test and finds the self-feeding open
#     door CLAUDE.md documents (twelve browsers onto a saturated pool,
#     2026-08-07). Enforced here because the invariant otherwise lives only
#     inside playwright-cli's package.nix.
resident_files = [p for p in scripts_and_bins() if p.name != "kx-build-slot.sh"]
resident_files += sorted(Path("packages").glob("*/package.nix"))
for p in resident_files:
    lines = p.read_text().splitlines()
    for i, line in enumerate(lines):
        if "--resident-probe" not in code_of(line):
            continue
        window = "\n".join(lines[max(0, i - 2) : i + 3])
        if not re.search(r"--resident(?!-probe)\b", window):
            failures.append(
                f"{p}:{i + 1}: --resident-probe without --resident (resident job must gate on the load test)"
            )

# 11. Semaphore-dir override tripwire — same contract as the pool-path check
#     above: every construction of the kx-build-sem runtime dir must sit
#     within two lines of its KX_BUILD_SEM_DIR override, so tests can retarget
#     every reader and a rename is a mechanical sweep.
for p in scripts_and_bins():
    lines = p.read_text().splitlines()
    for i, line in enumerate(lines):
        if "kx-build-sem" not in code_of(line):
            continue
        window = "\n".join(lines[max(0, i - 2) : i + 1])
        if "KX_BUILD_SEM_DIR" not in window:
            failures.append(
                f"{p}:{i + 1}: kx-build-sem path hardcoded without a KX_BUILD_SEM_DIR override nearby"
            )

if failures:
    print("\n".join(failures))
    sys.exit(1)
print("lint-tripwires: all clear")
