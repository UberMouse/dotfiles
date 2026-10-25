#!/usr/bin/env @python3@
"""ccusage -- the real ccusage (packages/ccusage) behind a cache of its
finished day rows, so a report over the whole history costs about what one
over the last two days does. Arguments are passed through untouched.

WHY: ccusage re-reads every transcript on every run, ~19G of JSONL here, and
does ~5us of work per usage entry, ~1M of them. A full `ccusage -b` took ~35s
even though ccusage is native Rust; a plain parallel `cat` of the same files
takes ~24s, because they don't fit in the page cache.

HOW: every usage entry falls on exactly one day, so a daily report's rows
partition by date, and a row for a CLOSED day (one that ended more than a
day ago) can never change. Those rows are cached; each run asks ccusage only
for the days after them (`daily --json --since <yesterday>`), and ccusage's
own mtime pruning then skips every file untouched since the day before that.
daily/weekly/monthly reports are rendered HERE from the combined day rows,
since weeks and months are sums of days. The first run, and any run after
the cache key changes, is one full ccusage run. Key: the ccusage store path
(a version bump recomputes everything), timezone, --mode, --offline,
CLAUDE_CONFIG_DIR, SCHEMA.

A slimmed mirror of the transcripts was tried as well and removed: it took a
warm run from ~2.6-6s to ~1.8s, at the cost of 3G of cache and a copy of
ccusage's line-parsing rules.

Anything this wrapper doesn't render itself (session, blocks, agent
subcommands, --jq, --by-agent, --sections, ...) execs the real ccusage, as
do --help/--version, `statusline`, --live, and anything at all with
CCUSAGE_NO_CACHE=1. A cache failure warns and falls back to it too.

`ccusage --verify-cache [--offline]` re-runs the real ccusage over the whole
history and compares every cached day (see packages/ccusage/UPDATE.md).
"""

import datetime as dt
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REAL = os.environ.get("CCUSAGE_REAL_BIN") or "@ccusage@"
# Bump when the cached row format or the closing rule changes: it is part of
# the cache key, so every day is recomputed.
SCHEMA = 3
UNCACHED = {"-h", "--help", "-v", "--version", "--live", "statusline"}
REPORTS = ("daily", "weekly", "monthly")
TOKENS = ("inputTokens", "outputTokens", "cacheCreationTokens", "cacheReadTokens")


def atomic_write(path: Path, obj) -> None:
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(obj))
    os.replace(tmp, path)


# ----- the day cache -------------------------------------------------------


def parse_date(s: str) -> str | None:
    for fmt in ("%Y-%m-%d", "%Y%m%d"):
        try:
            return dt.datetime.strptime(s, fmt).date().isoformat()
        except ValueError:
            pass
    return None


VALUE_FLAGS = {
    "-s": "since",
    "--since": "since",
    "-u": "until",
    "--until": "until",
    "-z": "tz",
    "--timezone": "tz",
    "-m": "mode",
    "--mode": "mode",
    "-o": "order",
    "--order": "order",
    "--last": "last",
}
BOOL_FLAGS = {
    "-b": ("breakdown", True),
    "--breakdown": ("breakdown", True),
    "-j": ("json", True),
    "--json": ("json", True),
    "-O": ("offline", True),
    "--offline": ("offline", True),
    "--no-offline": ("offline", False),
    "--color": ("color", True),
    "--no-color": ("color", False),
    "--compact": ("compact", True),
    "--no-cost": ("no_cost", True),
    "--all": ("all", True),
}


def parse_report(args: list[str]) -> dict | None:
    """The options of a report this wrapper renders itself, or None if the
    real ccusage has to handle it."""
    args = list(args)
    report = "daily"
    if args and not args[0].startswith("-"):
        report = args.pop(0)
        if report not in REPORTS:
            return None
    o = {
        "report": report,
        "since": None,
        "until": None,
        "tz": None,
        "mode": "auto",
        "order": "asc",
        "last": None,
        "breakdown": False,
        "json": False,
        "offline": False,
        "color": None,
        "compact": False,
        "no_cost": False,
    }
    while args:
        a = args.pop(0)
        flag, eq, val = a.partition("=")
        if flag in VALUE_FLAGS:
            if not eq:
                if not args:
                    return None
                val = args.pop(0)
            o[VALUE_FLAGS[flag]] = val
        elif a in BOOL_FLAGS:
            k, v = BOOL_FLAGS[a]
            o[k] = v
        else:
            return None
    for k in ("since", "until"):
        if o[k] is not None:
            o[k] = parse_date(o[k])
            if o[k] is None:
                return None
    if o["mode"] not in ("auto", "calculate", "display"):
        return None
    if o["order"] not in ("asc", "desc"):
        return None
    if o["last"] is not None:
        if not o["last"].isdigit() or int(o["last"]) < 1:
            return None
        o["last"] = int(o["last"])
    # ccusage's --no-cost JSON shape is not reproduced here.
    if o["json"] and o["no_cost"]:
        return None
    return o


def system_tz() -> str | None:
    """The IANA name ccusage would default to, or None if there isn't one."""
    tz = os.environ.get("TZ", "").lstrip(":")
    target = tz if tz.startswith("/") or not tz else None
    if tz and target is None:
        return tz
    try:
        target = os.path.realpath(target or "/etc/localtime")
    except OSError:
        return None
    i = target.find("zoneinfo/")
    return target[i + len("zoneinfo/") :] if i >= 0 else None


def today_in(tz: str) -> dt.date:
    from zoneinfo import ZoneInfo

    return dt.datetime.now(ZoneInfo(tz)).date()


def monday(d: dt.date) -> dt.date:
    return d - dt.timedelta(days=d.weekday())


def last_closed_day(today: dt.date) -> dt.date:
    """The latest day that ended more than a day ago. The day's grace is for
    entries written just after midnight with the previous day's timestamp (a
    response streaming across it)."""
    return today - dt.timedelta(days=2)


def run_daily(key, since=None) -> list[dict]:
    cmd = [REAL, "daily", "--json", "-z", key["tz"], "-m", key["mode"]]
    if key["offline"]:
        cmd.append("--offline")
    if since:
        cmd += ["--since", since]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} exited {p.returncode}: {p.stderr.strip()}")
    return json.loads(p.stdout)["daily"]


def day_rows(cache: Path, o, tz, today) -> list[dict]:
    """Every day row, from the cache plus one ccusage run for the days after
    it. Caches each newly closed day on the way."""
    key = {
        "schema": SCHEMA,
        "bin": REAL,
        "tz": tz,
        "mode": o["mode"],
        "offline": o["offline"],
        "sources": os.environ.get("CLAUDE_CONFIG_DIR"),
    }
    digest = hashlib.sha256(json.dumps(key, sort_keys=True).encode()).hexdigest()
    path = cache / f"{digest[:16]}.json"
    try:
        stored = json.loads(path.read_text())
        if stored["key"] != key:
            raise ValueError("key")
        through, rows = stored["through"], stored["rows"]
    except (OSError, ValueError, KeyError, TypeError):
        through, rows = None, {}
    since = None
    if through:
        since = (dt.date.fromisoformat(through) + dt.timedelta(days=1)).isoformat()
    else:
        print("ccusage: building the day cache (one full run)", file=sys.stderr)
    fresh = {r["period"]: r for r in run_daily(key, since)}
    closed = last_closed_day(today).isoformat()
    if through is None or closed > through:
        rows.update((p, r) for p, r in fresh.items() if p <= closed)
        path.parent.mkdir(parents=True, exist_ok=True)
        atomic_write(path, {"key": key, "through": closed, "rows": rows})
    return sorted({**rows, **fresh}.values(), key=lambda r: r["period"])


# ----- rendering -----------------------------------------------------------


def period_of(report: str, day: str) -> str:
    if report == "weekly":
        return monday(dt.date.fromisoformat(day)).isoformat()
    if report == "monthly":
        return day[:7]
    return day


def last_start(report: str, n: int, today: dt.date) -> str:
    """The first day of the Nth most recent period (1 = the current one)."""
    if report == "weekly":
        return (monday(today) - dt.timedelta(weeks=n - 1)).isoformat()
    if report == "monthly":
        y, m = divmod(today.year * 12 + today.month - 1 - (n - 1), 12)
        return dt.date(y, m + 1, 1).isoformat()
    return (today - dt.timedelta(days=n - 1)).isoformat()


def merge(period: str, rows: list[dict]) -> dict:
    out = {k: 0 for k in TOKENS}
    out.update(totalTokens=0, totalCost=0.0)
    models, used, agents = {}, set(), set()
    for r in rows:
        for k in (*TOKENS, "totalTokens", "totalCost"):
            out[k] += r.get(k, 0)
        used.update(r.get("modelsUsed", []))
        agents.update((r.get("metadata") or {}).get("agents", []))
        for mb in r.get("modelBreakdowns", []):
            m = models.setdefault(
                mb["modelName"],
                {"modelName": mb["modelName"], "cost": 0.0, **dict.fromkeys(TOKENS, 0)},
            )
            for k in (*TOKENS, "cost"):
                m[k] += mb.get(k, 0)
    out.update(
        agent="all",
        period=period,
        metadata={"agents": sorted(agents)},
        modelsUsed=sorted(used),
        modelBreakdowns=sorted(models.values(), key=lambda m: -m["cost"]),
    )
    return out


def build(rows: list[dict], o: dict, today: dt.date) -> list[dict]:
    lo = o["since"]
    if o["last"]:
        start = last_start(o["report"], o["last"], today)
        lo = max(lo, start) if lo else start
    rows = [
        r
        for r in rows
        if (lo is None or r["period"] >= lo)
        and (o["until"] is None or r["period"] <= o["until"])
    ]
    if o["report"] != "daily":
        groups = {}
        for r in rows:
            groups.setdefault(period_of(o["report"], r["period"]), []).append(r)
        rows = [merge(p, g) for p, g in sorted(groups.items())]
    return rows if o["order"] == "asc" else rows[::-1]


def totals(rows: list[dict]) -> dict:
    t = {k: sum(r.get(k, 0) for r in rows) for k in (*TOKENS, "totalTokens")}
    t["totalCost"] = sum(r.get("totalCost", 0) for r in rows)
    return t


def short_model(name: str) -> str:
    # Not just a prefix: other agents' rows read "[pi] claude-opus-...".
    return name.replace("claude-", "")


def render_table(rows: list[dict], o: dict) -> str:
    color = o["color"]
    if color is None:
        color = (
            bool(os.environ.get("FORCE_COLOR"))
            or (sys.stdout.isatty() and not os.environ.get("NO_COLOR"))
        )

    def paint(s, code):
        return f"\033[{code}m{s}\033[0m" if color else s

    label = {"daily": "Date", "weekly": "Week", "monthly": "Month"}[o["report"]]
    show_models = not (o["breakdown"] or o["compact"])
    head = [label, *(["Models"] if show_models else [])]
    head += ["Input", "Output", "Cache Create", "Cache Read", "Total Tokens"]
    head += [] if o["no_cost"] else ["Cost (USD)"]

    def nums(r, cost_key):
        cells = [f"{r.get(k, 0):,}" for k in TOKENS]
        cells.append(f"{sum(r.get(k, 0) for k in TOKENS):,}")
        if not o["no_cost"]:
            cells.append(f"${r.get(cost_key, 0):,.2f}")
        return cells

    # (cells, style, rule-before)
    lines = []
    for r in rows:
        models = ", ".join(map(short_model, r.get("modelsUsed", [])))
        cells = [r["period"], *([models] if show_models else []), *nums(r, "totalCost")]
        lines.append((cells, None, o["breakdown"] and bool(lines)))
        if o["breakdown"]:
            for mb in r.get("modelBreakdowns", []):
                cells = [f"  └ {short_model(mb['modelName'])}", *nums(mb, "cost")]
                lines.append((cells, "2", False))
    t = totals(rows)
    lines.append(
        (["Total", *([""] if show_models else []), *nums(t, "totalCost")], "1;33", True)
    )

    widths = [len(h) for h in head]
    for cells, _, _ in lines:
        widths = [max(w, len(c)) for w, c in zip(widths, cells)]
    if show_models:
        # The one free-text column gives way to the terminal.
        cols = shutil.get_terminal_size((200, 24)).columns
        spare = cols - (sum(widths) + 3 * len(widths) + 1)
        widths[1] = max(len("Models"), widths[1] + min(0, spare))

    def fit(c, w):
        return c if len(c) <= w else c[: w - 1] + "…"

    left = 2 if show_models else 1  # text columns; the numbers align right

    def row(cells, style=None):
        parts = []
        for i, (c, w) in enumerate(zip(cells, widths)):
            c = fit(c, w)
            parts.append(c.ljust(w) if i < left else c.rjust(w))
        s = "│ " + " │ ".join(parts) + " │"
        return paint(s, style) if style else s

    def rule(left_end, mid, right_end):
        return left_end + mid.join("─" * (w + 2) for w in widths) + right_end

    out = [rule("┌", "┬", "┐"), row(head, "1;36"), rule("├", "┼", "┤")]
    for cells, style, before in lines:
        if before:
            out.append(rule("├", "┼", "┤"))
        out.append(row(cells, style))
    out.append(rule("└", "┴", "┘"))
    return "\n".join(out)


def render(rows: list[dict], o: dict) -> str:
    if o["json"]:
        return json.dumps({o["report"]: rows, "totals": totals(rows)}, indent=2, sort_keys=True)
    if not rows:
        return "No usage data found."
    return render_table(rows, o)


# ----- verification --------------------------------------------------------


def verify(cache: Path, args) -> int:
    """Compare every cached day against one full run of the real ccusage.
    Tokens must match exactly; costs to float-summation noise."""
    o = parse_report(["daily", *args])
    tz = (o or {}).get("tz") or system_tz()
    if o is None or tz is None:
        print("ccusage: --verify-cache takes only report flags", file=sys.stderr)
        return 2
    rows = day_rows(cache, o, tz, today_in(tz))
    closed = last_closed_day(today_in(tz)).isoformat()
    cached = {r["period"]: r for r in rows if r["period"] <= closed}
    key = {"tz": tz, "mode": o["mode"], "offline": o["offline"]}
    print(f"ccusage: re-running ccusage over the whole history for {len(cached)} cached days", file=sys.stderr)
    raw = {r["period"]: r for r in run_daily(key) if r["period"] <= closed}

    def norm(r):
        if r is None:
            return None
        mbs = {m["modelName"]: m for m in r.get("modelBreakdowns", [])}
        return (
            tuple(r.get(k, 0) for k in (*TOKENS, "totalTokens")),
            r.get("totalCost", 0),
            {n: (tuple(m.get(k, 0) for k in TOKENS), m.get("cost", 0)) for n, m in mbs.items()},
        )

    def close(a, b):
        return abs(a - b) <= 1e-9 * max(1.0, abs(a), abs(b))

    bad = 0
    for p in sorted(set(cached) | set(raw)):
        a, b = norm(cached.get(p)), norm(raw.get(p))
        if a is None or b is None:
            same_tokens = same_cost = False
        else:
            same_tokens = a[0] == b[0] and {n: v[0] for n, v in a[2].items()} == {n: v[0] for n, v in b[2].items()}
            same_cost = close(a[1], b[1]) and a[2].keys() == b[2].keys() and all(close(a[2][n][1], b[2][n][1]) for n in a[2])
        if not (same_tokens and same_cost):
            bad += 1
            what = "tokens" if not same_tokens else "cost only (pricing drift since it was cached?)"
            print(f"MISMATCH {p}: {what}\n  cached {a}\n  raw    {b}")
    print(f"{len(cached)} cached days checked, {bad} mismatched")
    return 1 if bad else 0


# ----- main ----------------------------------------------------------------


def main() -> None:
    args = sys.argv[1:]
    o = None if os.environ.get("CCUSAGE_NO_CACHE") == "1" or UNCACHED & set(args) else parse_report(args)
    tz = o and (o["tz"] or system_tz())
    cache = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "ccusage-days"

    def locked():
        cache.mkdir(parents=True, exist_ok=True)
        # Serialises concurrent wrappers' cache updates.
        lock = os.open(cache / "lock", os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        return lock

    if args[:1] == ["--verify-cache"]:
        locked()
        sys.exit(verify(cache, args[1:]))
    if o is not None and tz is not None:
        try:
            lock = locked()
            today = today_in(tz)
            rows = day_rows(cache, o, tz, today)
            os.close(lock)
        except Exception as e:  # noqa: BLE001 -- any failure falls back to ccusage
            print(f"ccusage: day cache failed ({e!r}); running ccusage directly", file=sys.stderr)
        else:
            print(render(build(rows, o, today), o))
            return
    os.execv(REAL, [REAL, *args])


if __name__ == "__main__":
    main()
