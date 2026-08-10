#!/usr/bin/env python3
"""Behavioural test for wt-reap.sh against real git repositories.

    python3 scripts/wt-reap.test.py

REAL GIT, NOT FIXTURES, and that is the point. Everything wt-reap decides is
a git question -- does this branch add commits to the integration ref, is the
working tree clean, which worktree does `worktree list` name first -- and a
hand-written fixture would be asserting my belief about git's output rather
than git's output. The repos here are tiny (one file, no network, a local
bare remote for origin/HEAD), so this stays fast and sandbox-safe.

The one thing that IS faked is /proc: the live-process guard is pointed at a
tempdir of cwd symlinks through WT_REAP_PROC, because the alternative is
parking a real process in a fixture worktree and betting on scheduling.

What earns a check here is anything whose failure is silent and destructive:

  - deletions do NOT veto a reap but modifications and untracked files DO
    (the .quint-removal shape is ~90% of the dirty worktrees in practice, so
    getting this backwards either reaps nothing or reaps real work);
  - a missing integration ref SKIPS the repo rather than reaping everything
    (an unresolved base would make `$base..HEAD` empty for every branch --
    the single worst bug this script could have);
  - the main worktree is never a candidate;
  - a reapable PARENT containing a kept CHILD is itself kept, because
    removing the parent unlinks the child's files no matter what git thinks
    it is doing;
  - --dry-run deletes nothing, which is the flag the plan is reviewed with.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scriptBins" / "bins" / "wt-reap.sh"
BASH = shutil.which("bash")
GIT = shutil.which("git")

sys.path.insert(0, str(Path(__file__).resolve().parent))
from testlib import check, summary  # noqa: E402

if GIT is None:
    print("SKIP  git unavailable")
    sys.exit(0)

TMP = Path(tempfile.mkdtemp(prefix="wt-reap-test."))

# Hermetic git: no user config, no global hooks, no signing, deterministic
# identity and default branch. Without this the suite inherits whatever the
# running user's ~/.gitconfig says -- including this repo's own SSH signing,
# which would make every fixture commit prompt for 1Password.
GITENV = {
    "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    "HOME": str(TMP / "fakehome"),
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_AUTHOR_NAME": "t",
    "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t",
    "GIT_COMMITTER_EMAIL": "t@example.invalid",
}
(TMP / "fakehome").mkdir(parents=True, exist_ok=True)


def git(repo, *args, check_rc=True):
    r = subprocess.run(
        [GIT, "-C", str(repo), *args], env=GITENV, capture_output=True, text=True
    )
    if check_rc and r.returncode != 0:
        raise AssertionError(f"git {args} in {repo} failed: {r.stderr}")
    return r.stdout.strip()


def run(*args, proc=None, env_extra=None, stdin=""):
    env = dict(GITENV)
    env["WT_REAP_PROC"] = str(proc if proc else TMP / "emptyproc")
    env["WT_REAP_ROOT"] = str(TMP / "noroot")
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        [BASH, "-o", "nounset", str(SCRIPT), *args],
        env=env,
        capture_output=True,
        text=True,
        input=stdin,
    )


(TMP / "emptyproc").mkdir(exist_ok=True)


def make_repo(name, with_remote=True):
    """A repo with one commit on master, optionally with a bare `origin` so
    origin/HEAD resolves the way it does on a real clone."""
    repo = TMP / name
    repo.mkdir(parents=True)
    git(repo, "init", "-q", "-b", "master")
    (repo / "file.txt").write_text("base\n")
    (repo / "doomed.txt").write_text("delete me\n")
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "initial")
    if with_remote:
        bare = TMP / f"{name}.git"
        subprocess.run(
            [GIT, "init", "-q", "--bare", "-b", "master", str(bare)],
            env=GITENV,
            capture_output=True,
        )
        git(repo, "remote", "add", "origin", str(bare))
        git(repo, "push", "-q", "origin", "master")
        git(repo, "remote", "set-head", "origin", "master")
    return repo


def add_worktree(repo, path, branch):
    git(repo, "worktree", "add", "-q", "-b", branch, str(path), "master")
    return Path(path)


# ===========================================================================
# The classification repo: one worktree per decision the script can make.
# ===========================================================================
repo = make_repo("repo")
wts = repo / ".claude" / "worktrees"

# Reapable: branched from master, nothing added.
w_clean = add_worktree(repo, wts / "clean", "b-clean")

# Reapable: only DELETIONS in the working tree. This is the .quint shape.
w_del = add_worktree(repo, wts / "deleted", "b-del")
(w_del / "doomed.txt").unlink()

# Kept: a real commit beyond origin/master.
w_commit = add_worktree(repo, wts / "commit", "b-commit")
(w_commit / "new.txt").write_text("work\n")
git(w_commit, "add", "-A")
git(w_commit, "commit", "-qm", "real work")

# Kept: uncommitted MODIFICATION.
w_mod = add_worktree(repo, wts / "modified", "b-mod")
(w_mod / "file.txt").write_text("changed\n")

# Kept: UNTRACKED new file.
w_new = add_worktree(repo, wts / "untracked", "b-new")
(w_new / "scratch.txt").write_text("unsaved\n")

# Kept: reapable on its own, but a process is cwd'd inside it.
w_busy = add_worktree(repo, wts / "busy", "b-busy")

# Containment: a reapable parent holding a child that must be kept.
w_parent = add_worktree(repo, wts / "parent", "b-parent")
w_child = add_worktree(repo, w_parent / ".claude" / "worktrees" / "child", "b-child")
(w_child / "new.txt").write_text("nested work\n")
git(w_child, "add", "-A")
git(w_child, "commit", "-qm", "nested real work")

# Containment: a reapable parent holding a reapable child. Both go.
#
# Note the fixture deliberately does NOT gitignore .claude/worktrees, though
# the real repo does. Un-ignored is the strictly harder case: the nested
# worktree shows up as `?? .claude/` in the parent, and if that counted as
# dirt no worktree that ever hosted a child could be reaped again.
w_rparent = add_worktree(repo, wts / "rparent", "b-rparent")
w_rchild = add_worktree(repo, w_rparent / ".claude" / "worktrees" / "rchild", "b-rchild")

# ...and the exclusion above must stay surgical. A genuine untracked file
# sitting BESIDE a nested worktree still vetoes the parent; a blanket "skip
# anything under a worktree that has children" would silently pass this.
w_hparent = add_worktree(repo, wts / "hparent", "b-hparent")
add_worktree(repo, w_hparent / ".claude" / "worktrees" / "hchild", "b-hchild")
(w_hparent / "unsaved.txt").write_text("real work, no commit\n")

# The fake /proc: one process sitting in w_busy.
fakeproc = TMP / "proc"
(fakeproc / "4242").mkdir(parents=True)
(fakeproc / "4242" / "cwd").symlink_to(w_busy)
# A non-numeric entry and a dangling cwd, both of which the real /proc has.
(fakeproc / "self").mkdir(parents=True)
(fakeproc / "999").mkdir(parents=True)
(fakeproc / "999" / "cwd").symlink_to(TMP / "gone")

r = run("--dry-run", "--no-size", str(repo), proc=fakeproc)
out = r.stdout
check("dry-run exits 0", r.returncode, 0)


def planned(p):
    return any(line.strip() == str(p) for line in out.splitlines())


check("clean worktree is reaped", planned(w_clean), True)
check("deletions-only worktree is reaped", planned(w_del), True)
check("worktree with a commit is kept", planned(w_commit), False)
check("worktree with a modification is kept", planned(w_mod), False)
check("worktree with an untracked file is kept", planned(w_new), False)
check("worktree in use by a live process is kept", planned(w_busy), False)
check("reapable parent of a kept child is kept", planned(w_parent), False)
check("kept child is kept", planned(w_child), False)
check("reapable parent of a reapable child is reaped", planned(w_rparent), True)
check("reapable child is reaped", planned(w_rchild), True)
check("nested worktree alone does not dirty its parent", planned(w_rparent), True)
check("untracked file beside a nested worktree still vetoes", planned(w_hparent), False)
check("main worktree is never a candidate", planned(repo), False)
check("plan counts 5", "5 worktree(s) to remove" in out, True)

# The plan is a report, not an action.
check("dry run deleted nothing", w_clean.is_dir(), True)
check("dry run says so", "dry run -- nothing deleted" in out, True)

# ===========================================================================
# A repo with no resolvable integration ref must be SKIPPED, not emptied.
# ===========================================================================
lone = TMP / "lone"
lone.mkdir()
git(lone, "init", "-q", "-b", "trunk")
(lone / "f").write_text("x\n")
git(lone, "add", "-A")
git(lone, "commit", "-qm", "only")
w_lone = lone / "wt"
git(lone, "worktree", "add", "-q", "-b", "side", str(w_lone), "trunk")

r = run("--dry-run", "--no-size", str(lone), proc=TMP / "emptyproc")
check("repo with no integration ref is skipped", "skipping" in r.stderr, True)
check("...and nothing is planned", str(w_lone) in r.stdout, False)
check("...and it exits 0", r.returncode, 0)

# `master`/`main` is accepted as a fallback when there is no remote at all,
# so a local-only repo is still serviceable rather than permanently skipped.
local = make_repo("local", with_remote=False)
w_local = add_worktree(local, local / "wt-local", "b-local")
r = run("--dry-run", "--no-size", str(local), proc=TMP / "emptyproc")
check("local-only repo falls back to master", str(w_local) in r.stdout, True)

# ===========================================================================
# The confirmation prompt, and the real removal.
# ===========================================================================
r = run("--no-size", str(repo), proc=fakeproc, stdin="n\n")
check("declining the prompt aborts", r.returncode, 1)
check("...and deletes nothing", w_clean.is_dir(), True)

r = run("--yes", "--no-size", str(repo), proc=fakeproc)
check("--yes exits 0", r.returncode, 0)
check("reaped clean worktree is gone", w_clean.exists(), False)
check("reaped deletions-only worktree is gone", w_del.exists(), False)
check("reaped nested pair is gone", w_rparent.exists(), False)
check("kept commit worktree survives", w_commit.is_dir(), True)
check("kept modified worktree survives", w_mod.is_dir(), True)
check("kept untracked worktree survives", w_new.is_dir(), True)
check("kept busy worktree survives", w_busy.is_dir(), True)
check("kept parent survives", w_parent.is_dir(), True)
check("kept nested child survives", w_child.is_dir(), True)
check("main worktree survives", (repo / "file.txt").is_file(), True)

# Registrations must match the filesystem afterwards, or the next run walks
# into paths that no longer exist.
listed = git(repo, "worktree", "list", "--porcelain")
registered = {ln[len("worktree ") :] for ln in listed.splitlines() if ln.startswith("worktree ")}
check("removed worktrees are deregistered", str(w_clean) in registered, False)
check("kept worktrees stay registered", str(w_commit) in registered, True)
check("no registration outlives its directory",
      sorted(p for p in registered if not Path(p).is_dir()), [])

# The commit that lived in a kept worktree is still reachable: the reaper
# must never be the reason work disappears.
check("kept branch still holds its commit",
      git(repo, "rev-list", "--count", "master..b-commit"), "1")

# A second run is a no-op -- everything reapable is already gone.
r = run("--yes", "--no-size", str(repo), proc=fakeproc)
check("second run finds nothing", "nothing to reap" in r.stdout, True)
check("second run exits 0", r.returncode, 0)

# ===========================================================================
# Argument handling.
# ===========================================================================
r = run("--help", proc=TMP / "emptyproc")
check("--help exits 0", r.returncode, 0)
check("--help describes the criterion", "add no commits" in r.stdout, True)

r = run("--bogus", proc=TMP / "emptyproc")
check("unknown option exits 2", r.returncode, 2)

# No repos anywhere: an empty root is a quiet success, not a failure. The
# timer runs this weekly on a box that may have no worktrees at all.
r = run(proc=TMP / "emptyproc")
check("empty root exits 0", r.returncode, 0)

summary(cleanup_dir=TMP)
