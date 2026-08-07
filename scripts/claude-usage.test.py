#!/usr/bin/env python3
"""Fixture tests for claude-usage's three undocumented scraped surfaces.

    python3 scripts/claude-usage.test.py

claude-usage scrapes three things nobody has promised to keep stable: the
~/.claude/.credentials.json shape, the oauth/usage endpoint's response (seen
both top-level and nested under .rate_limits, with the percentage field as
both `utilization` and `used_percentage`), and `claude --version`'s output.
Any of them can drift without a compile error, so the REAL script runs here
against fixtures: HOME points at a fixture dir, and fake `curl` / `claude`
binaries sit first on PATH. The fake curl records its argv and stdin, which
is also how the token-hygiene property is asserted: the OAuth bearer token
must arrive on curl's STDIN (via --header @-), never on its argv, because
/proc/<pid>/cmdline is world-readable while curl runs.

Everything else network-shaped is canned, so the suite is deterministic and
finishes in a couple of seconds.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from testlib import check, summary  # noqa: E402

# The nix-flake-check sandbox carries only a small toolset; the script under
# test needs more (jq above all). A missing tool is a sandbox-configuration
# gap, not a code failure, so skip loudly rather than fail confusingly --
# and on any normal host these all resolve, so the suite really runs.
REQUIRED = ["bash", "jq", "grep", "awk", "stat", "date", "mkdir", "dirname",
            "cat", "mv", "rm"]
missing = [t for t in REQUIRED if shutil.which(t) is None]
if missing:
    print(f"SKIP claude-usage.test.py: required tool(s) not on PATH: "
          f"{', '.join(missing)} -- add to the flake-check sandbox toolset")
    sys.exit(0)

SCRIPT = HERE.parent / "scriptBins" / "bins" / "claude-usage.sh"
# Resolve bash at runtime rather than via `#!/usr/bin/env bash`: the nix build
# sandbox (where this runs as a flake check) has no /usr/bin/env.
BASH = shutil.which("bash")

BASE = Path(tempfile.mkdtemp(prefix="claude-usage-test."))
HOME = BASE / "home"
EMPTYHOME = BASE / "emptyhome"          # no credentials file at all
CACHEDIR = BASE / "cache"
FAKEBIN = BASE / "bin"
CURLDIR = BASE / "curl"                 # fake curl's argv/stdin recordings
BODYFILE = BASE / "body.json"
for d in (HOME / ".claude", EMPTYHOME, CACHEDIR, FAKEBIN, CURLDIR):
    d.mkdir(parents=True)
CACHE = CACHEDIR / "claude-usage.json"

TOKEN = "sk-ant-oat01-SECRET-FIXTURE-TOKEN-do-not-appear-in-argv"
(HOME / ".claude" / ".credentials.json").write_text(
    json.dumps({"claudeAiOauth": {"accessToken": TOKEN}})
)

# Fake curl: records argv and stdin, then plays back a canned body + HTTP
# code. It honours exactly the interface the script uses: -o <file> for the
# body, -w '%{http_code}' via printing the code on stdout, --header @- by
# consuming stdin. FAKE_CURL_MODE=fail simulates a network-level failure.
(FAKEBIN / "curl").write_text(f"""#!{BASH}
{{
  echo "--CALL--"
  printf '%s\\n' "$@"
}} >> "$FAKE_CURL_DIR/argv.log"
cat >> "$FAKE_CURL_DIR/stdin.log" 2>/dev/null || true
if [ "${{FAKE_CURL_MODE:-ok}}" = "fail" ]; then exit 7; fi
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
[ -n "$out" ] && cat "${{FAKE_CURL_BODY:?}}" > "$out"
printf '%s' "${{FAKE_CURL_HTTP:-200}}"
""")
(FAKEBIN / "claude").write_text(f"""#!{BASH}
printf '%s\\n' "${{FAKE_CLAUDE_OUT:-1.0.128 (Claude Code)}}"
""")
for f in (FAKEBIN / "curl", FAKEBIN / "claude"):
    f.chmod(0o755)


def run(*args, body=None, http="200", curl_mode="ok", claude_out=None,
        home=HOME):
    if body is not None:
        BODYFILE.write_text(body)
    env = dict(os.environ)
    env.update(
        HOME=str(home),
        XDG_CACHE_HOME=str(CACHEDIR),
        PATH=f"{FAKEBIN}:{env.get('PATH', '')}",
        TZ="UTC",
        FAKE_CURL_DIR=str(CURLDIR),
        FAKE_CURL_BODY=str(BODYFILE),
        FAKE_CURL_HTTP=http,
        FAKE_CURL_MODE=curl_mode,
    )
    if claude_out is not None:
        env["FAKE_CLAUDE_OUT"] = claude_out
    # -o nounset matches the built writeShellApplication wrapper's bashOptions
    # (scriptBins/default.nix) so the script runs under production options.
    return subprocess.run([BASH, "-o", "nounset", str(SCRIPT), *args],
                          env=env, capture_output=True, text=True)


def clear_cache():
    CACHE.unlink(missing_ok=True)


def curl_argv():
    try:
        return (CURLDIR / "argv.log").read_text()
    except OSError:
        return ""


def curl_stdin():
    try:
        return (CURLDIR / "stdin.log").read_text()
    except OSError:
        return ""


def curl_calls():
    return curl_argv().count("--CALL--")


def shape_toplevel(wk=42, fh=12.5, wk_reset=None, fh_reset=None):
    d = {"five_hour": {"utilization": fh}, "seven_day": {"utilization": wk}}
    if wk_reset is not None:
        d["seven_day"]["resets_at"] = wk_reset
    if fh_reset is not None:
        d["five_hour"]["resets_at"] = fh_reset
    return json.dumps(d)


def shape_nested(wk=77, fh=5, wk_reset=None):
    d = {"rate_limits": {"five_hour": {"used_percentage": fh},
                         "seven_day": {"used_percentage": wk}}}
    if wk_reset is not None:
        d["rate_limits"]["seven_day"]["reset_at"] = wk_reset
    return json.dumps(d)


# 1. RESPONSE SHAPE A: top-level five_hour/seven_day with `utilization` (what
#    the oauth/usage endpoint returns today).
clear_cache()
p = run("--weekly", "-f", body=shape_toplevel())
check("weekly from top-level shape", (p.returncode, p.stdout.strip()),
      (0, "42"))
clear_cache()
p = run("--5h", "-f", body=shape_toplevel())
check("5h from top-level shape", (p.returncode, p.stdout.strip()),
      (0, "12.5"))

# 2. RESPONSE SHAPE B: nested under .rate_limits with `used_percentage` (the
#    statusline-stdin shape the accessors also tolerate).
clear_cache()
p = run("--weekly", "-f", body=shape_nested())
check("weekly from rate_limits shape", (p.returncode, p.stdout.strip()),
      (0, "77"))
clear_cache()
p = run("--5h", "-f", body=shape_nested())
check("5h from rate_limits shape", (p.returncode, p.stdout.strip()), (0, "5"))

# 3. TOKEN HYGIENE. The bearer token travels to curl on stdin (--header @-),
#    NEVER as an argv element -- /proc/<pid>/cmdline is world-readable for the
#    life of the curl process. The fake curl recorded both channels above.
argv, stdin = curl_argv(), curl_stdin()
check("token never appears in curl argv", TOKEN in argv, False)
check("no Authorization header on argv", "Authorization" in argv, False)
check("token arrives via stdin header",
      f"Authorization: Bearer {TOKEN}" in stdin, True)
check("argv asks for headers from stdin",
      "--header\n@-" in argv or "-H\n@-" in argv, True)

# 4. USER-AGENT from `claude --version`. The endpoint punishes a wrong UA
#    with a persistent-429 bucket, so both the parse and its loud fallback
#    matter.
check("UA parsed from claude --version",
      "User-Agent: claude-code/1.0.128" in argv, True)
clear_cache()
p = run("--weekly", "-f", body=shape_toplevel(),
        claude_out="not a version at all")
check("unparseable claude --version still succeeds", p.returncode, 0)
check("unparseable version warns on stderr",
      "could not parse 'claude --version'" in p.stderr, True)
check("unparseable version falls back to UA claude-code/latest",
      "User-Agent: claude-code/latest" in curl_argv(), True)

# 5. fmt_reset BRANCHES via the summary view: epoch, ISO-8601, garbage, and
#    absent. The epoch offset sits mid-hour (1d2h30m) so scheduler drift of
#    many minutes cannot flip the printed bucket.
clear_cache()
epoch = int(time.time()) + 86400 + 2 * 3600 + 1800
p = run("-f", body=shape_toplevel(wk_reset=epoch))
check("summary shows both windows",
      "weekly:" in p.stdout and "5-hour:" in p.stdout, True)
check("epoch reset renders a countdown", "(in 1d2h)" in p.stdout, True)

clear_cache()
p = run("-f", body=shape_toplevel(wk_reset="2030-01-05T12:00:00Z"))
check("ISO reset renders as local (TZ=UTC) wall time",
      "resets 2030-01-05 12:00" in p.stdout, True)

clear_cache()
p = run("-f", body=shape_toplevel(wk_reset="soonish"))
check("unparseable reset is echoed verbatim", "resets soonish" in p.stdout,
      True)

clear_cache()
p = run("-f", body=shape_toplevel())
check("absent reset field prints no reset clause", "resets" in p.stdout,
      False)

# 6. --gate ARITHMETIC. Under threshold -> 0 (keep going); at or over -> 1
#    (stop); junk threshold -> 2. The current weekly % prints regardless so
#    callers can both branch and log.
clear_cache()
p = run("--gate", "50", "-f", body=shape_toplevel(wk=42))
check("gate under threshold passes", (p.returncode, p.stdout.strip()),
      (0, "42"))
p = run("--gate", "42", body=shape_toplevel(wk=42))
check("gate at threshold blocks", (p.returncode, p.stdout.strip()), (1, "42"))
p = run("--gate", "30", body=shape_toplevel(wk=42))
check("gate over threshold blocks", p.returncode, 1)
p = run("--gate", "42.5", body=shape_toplevel(wk=42))
check("gate compares decimals numerically, not lexically", p.returncode, 0)
p = run("--gate", "lots", body=shape_toplevel(wk=42))
check("non-numeric threshold is a usage error", p.returncode, 2)
p = run("--gate")
check("missing threshold is a usage error", p.returncode, 2)

# 7. CACHE. A fresh cache short-circuits curl entirely; a stale one is used
#    as a last resort when the fetch fails (with a stderr note), and a failed
#    fetch with NO cache at all is a hard 2.
clear_cache()
run("--weekly", "-f", body=shape_toplevel(wk=42))
before = curl_calls()
p = run("--weekly", body=shape_toplevel(wk=99))
check("fresh cache answers without refetching",
      (p.stdout.strip(), curl_calls()), ("42", before))

old = time.time() - 400  # TTL is 300s
os.utime(CACHE, (old, old))
p = run("--weekly", curl_mode="fail")
check("stale cache survives a failed refetch",
      (p.returncode, p.stdout.strip()), (0, "42"))
check("stale fallback says so on stderr", "using stale cache" in p.stderr,
      True)

clear_cache()
p = run("--weekly", curl_mode="fail")
check("failed fetch with no cache exits 2", p.returncode, 2)
check("failed fetch names the failure", "fetch failed" in p.stderr, True)

clear_cache()
p = run("--weekly", "-f", body=shape_toplevel(), http="500")
check("non-200 with a body is still a failure", p.returncode, 2)

# 8. CREDENTIALS SURFACE. No file, and a file without the expected key, are
#    both hard errors that name the problem.
clear_cache()
p = run("--weekly", home=EMPTYHOME)
check("missing credentials file exits 2", p.returncode, 2)
check("missing credentials names the path", "no credentials file" in p.stderr,
      True)

badhome = BASE / "badhome"
(badhome / ".claude").mkdir(parents=True)
(badhome / ".claude" / ".credentials.json").write_text('{"other": true}')
clear_cache()
p = run("--weekly", home=badhome)
check("credentials without accessToken exits 2", p.returncode, 2)
check("credentials without accessToken names the key",
      ".claudeAiOauth.accessToken" in p.stderr, True)

# 9. --json emits the raw cached response verbatim.
clear_cache()
body = shape_toplevel(wk_reset="2030-01-05T12:00:00Z")
p = run("--json", "-f", body=body)
check("--json round-trips the cached response",
      json.loads(p.stdout), json.loads(body))

p = run("--frobnicate")
check("unknown argument is a usage error", p.returncode, 2)

summary(cleanup_dir=BASE)
