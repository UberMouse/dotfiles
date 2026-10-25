#!/usr/bin/env python3
"""Exercise the ccusage caching wrapper (scriptBins/bins/ccusage.py).

    python3 scripts/ccusage.test.py

No real ccusage runs here (the sandbox has none). The pure parts -- the
day-closing rule, the report merging, which arguments are ours -- are unit
tests against the imported module. The day cache runs for real against a
FAKE ccusage that serves fixture day rows, honours --since the way the real
one does, and logs every argv. The assertions that matter are on that log:
a warm run must ask ccusage only for the days after the cache, and a key
change must recompute everything.

What this cannot check is that real ccusage's rows still partition by day;
`ccusage --verify-cache` does that against live data, and the UPDATE.md for
packages/ccusage runs it on every bump.
"""

import datetime as dt
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from testlib import check, summary

HERE = Path(__file__).resolve().parent
WRAPPER = HERE.parent / "scriptBins" / "bins" / "ccusage.py"
spec = importlib.util.spec_from_file_location("ccusage_wrapper", WRAPPER)
cc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cc)

tmp = Path(tempfile.mkdtemp(prefix="ccusage-test-"))


# ----- 1. day closing and report building ---------------------------------

D = dt.date.fromisoformat
for today, want in [
    ("2026-10-25", "2026-10-23"),  # yesterday ended less than a day ago
    ("2026-11-01", "2026-10-30"),
    ("2026-03-01", "2026-02-27"),
]:
    check(f"last closed day on {today}", cc.last_closed_day(D(today)).isoformat(), want)


def row(day, opus=0, haiku=0):
    mbs = []
    for name, n in (("claude-opus-5-5", opus), ("claude-haiku-5-5", haiku)):
        if n:
            mbs.append({"modelName": name, "inputTokens": n, "outputTokens": n, "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": float(n)})
    t = opus + haiku
    return {
        "agent": "all",
        "period": day,
        "inputTokens": t,
        "outputTokens": t,
        "cacheCreationTokens": 0,
        "cacheReadTokens": 0,
        "totalTokens": 2 * t,
        "totalCost": float(t),
        "modelsUsed": sorted(m["modelName"] for m in mbs),
        "modelBreakdowns": mbs,
        "metadata": {"agents": ["claude"]},
    }


ROWS = [row("2026-09-30", opus=1), row("2026-10-04", opus=2, haiku=1), row("2026-10-05", haiku=4), row("2026-10-25", opus=8)]
o = cc.parse_report(["weekly", "--json"])
wk = cc.build(ROWS, o, D("2026-10-25"))
check("weekly periods are Mondays", [r["period"] for r in wk], ["2026-09-28", "2026-10-05", "2026-10-19"])
check("weekly sums its days", wk[0]["totalTokens"], 8)
check("weekly merges model breakdowns", {m["modelName"]: m["inputTokens"] for m in wk[0]["modelBreakdowns"]}, {"claude-opus-5-5": 3, "claude-haiku-5-5": 1})
mo = cc.build(ROWS, cc.parse_report(["monthly"]), D("2026-10-25"))
check("monthly periods", [r["period"] for r in mo], ["2026-09", "2026-10"])
check("monthly sums its days", mo[1]["totalCost"], 15.0)
check("--since filters days before grouping", [r["period"] for r in cc.build(ROWS, cc.parse_report(["--since", "20261004"]), D("2026-10-25"))], ["2026-10-04", "2026-10-05", "2026-10-25"])
check("--last 1 weekly is this week", [r["period"] for r in cc.build(ROWS, cc.parse_report(["weekly", "--last", "1"]), D("2026-10-25"))], ["2026-10-19"])
check("--order desc", [r["period"] for r in cc.build(ROWS, cc.parse_report(["-o", "desc"]), D("2026-10-25"))][0], "2026-10-25")

check("plain -b is ours", cc.parse_report(["-b"]) is not None, True)
check("--since=VALUE form is ours", cc.parse_report(["--since=2026-10-01"])["since"], "2026-10-01")
for args in (["session"], ["blocks"], ["claude", "daily"], ["daily", "--jq", ".x"], ["daily", "--by-agent"], ["--since", "bogus"], ["--json", "--no-cost"]):
    check(f"{args} goes to the real ccusage", cc.parse_report(args), None)


# ----- 2. the day cache, against a fake ccusage ----------------------------

fake = tmp / "fake-ccusage"
log = tmp / "fake.log"
rows_file = tmp / "rows.json"
fake.write_text(
    f"#!{sys.executable}\n"
    + """import json, os, sys
a = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(json.dumps(a) + "\\n")
if a[:2] == ["daily", "--json"]:
    since = a[a.index("--since") + 1] if "--since" in a else ""
    rows = [r for r in json.load(open(os.environ["FAKE_ROWS"])) if r["period"] >= since]
    print(json.dumps({"daily": rows, "totals": {}}))
else:
    print(json.dumps({"argv": a, "CLAUDE_CONFIG_DIR": os.environ.get("CLAUDE_CONFIG_DIR")}))
"""
)
fake.chmod(0o755)
rows_file.write_text(json.dumps(ROWS))
os.environ.update(FAKE_LOG=str(log), FAKE_ROWS=str(rows_file))
cc.REAL = str(fake)


def calls():
    return [json.loads(x) for x in log.read_text().splitlines()] if log.exists() else []


cache = tmp / "cache"
o = cc.parse_report(["-b"])
today = D("2026-10-25")
got = cc.day_rows(cache, o, "Pacific/Auckland", today)
check("cold run asks for everything", "--since" in calls()[-1], False)
check("cold run passes the timezone", calls()[-1][calls()[-1].index("-z") + 1], "Pacific/Auckland")
check("cold run returns every row", [r["period"] for r in got], [r["period"] for r in ROWS])

# Change a closed day underneath: a warm run must not re-ask for it.
rows_file.write_text(json.dumps([row("2026-09-30", opus=100), *ROWS[1:]]))
got = cc.day_rows(cache, o, "Pacific/Auckland", today)
check("warm run asks only after the cache", calls()[-1][calls()[-1].index("--since") + 1], "2026-10-24")
check("warm run serves closed days from the cache", got[0]["totalTokens"], 2)

got = cc.day_rows(cache, o, "Pacific/Auckland", D("2026-10-27"))
check("newly closed days move the window", calls()[-1][calls()[-1].index("--since") + 1], "2026-10-24")
cc.day_rows(cache, o, "Pacific/Auckland", D("2026-10-27"))
check("...and are cached from then on", calls()[-1][calls()[-1].index("--since") + 1], "2026-10-26")

cc.day_rows(cache, cc.parse_report(["-b", "--offline"]), "Pacific/Auckland", today)
check("a different key recomputes everything", "--since" in calls()[-1], False)
check("--offline reaches ccusage", "--offline" in calls()[-1], True)


# ----- 3. end to end -------------------------------------------------------

rows_file.write_text(json.dumps(ROWS))
env = {
    **os.environ,
    "HOME": str(tmp / "home"),
    "XDG_CACHE_HOME": str(tmp / "xdg-cache"),
    "XDG_CONFIG_HOME": str(tmp / "xdg-config"),
    "CCUSAGE_REAL_BIN": str(fake),
    "TZ": "Pacific/Auckland",
}
env.pop("CLAUDE_CONFIG_DIR", None)


def run(*args):
    return subprocess.run([sys.executable, str(WRAPPER), *args], env=env, capture_output=True, text=True)


p = run("weekly", "--json")
check("weekly --json exits 0", p.returncode, 0)
check("weekly --json totals", json.loads(p.stdout)["totals"]["totalTokens"], 32)
p = run("-b", "--no-color")
check("table has a Total row", "│ Total" in p.stdout, True)
check("table breakdown strips claude-", "└ opus-5-5" in p.stdout, True)
check("the cache lives in XDG_CACHE_HOME", any((tmp / "xdg-cache" / "ccusage-days").glob("*.json")), True)
check("session passes through untouched", json.loads(run("session").stdout)["argv"], ["session"])
check("--live passes through untouched", json.loads(run("blocks", "--live").stdout)["argv"], ["blocks", "--live"])
p = subprocess.run([sys.executable, str(WRAPPER), "-b"], env={**env, "CCUSAGE_NO_CACHE": "1"}, capture_output=True, text=True)
check("CCUSAGE_NO_CACHE runs ccusage itself", json.loads(p.stdout)["argv"], ["-b"])

summary(cleanup_dir=tmp)
