# claude-usage -- query Claude Code's server-side subscription usage
# windows (5-hour + weekly) from the same undocumented endpoint that powers
# the interactive `/usage` command, so you can watch or *gate* on your
# weekly cap from scripts.
#
#   claude-usage              human summary: weekly + 5h %, with reset times
#   claude-usage -w|--weekly  print JUST the weekly (7-day) utilisation %
#   claude-usage --5h         print JUST the 5-hour utilisation %
#   claude-usage --json       print the raw cached JSON (jq it yourself)
#   claude-usage --gate PCT   exit 0 if weekly < PCT, 1 if weekly >= PCT,
#                             2 if usage couldn't be determined. Prints the
#                             current weekly % on stdout regardless, so
#                             scripts can both branch on $? and log it.
#   claude-usage -f|--force   bypass the cache and re-fetch now
#
# Results are cached for 300s in $XDG_CACHE_HOME/claude-usage.json. The
# endpoint 429s aggressively when polled hard, so honour the cache -- do NOT
# --force in a tight loop. The claude-code/<version> User-Agent below is
# REQUIRED; without it the endpoint drops you into a punitive rate-limit
# bucket and returns persistent 429s.

CREDS="$HOME/.claude/.credentials.json"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-usage.json"
TTL=300
ENDPOINT="https://api.anthropic.com/api/oauth/usage"

# jq accessors, tolerant of shape drift: the oauth/usage endpoint returns
# top-level {five_hour,seven_day}; the statusline stdin nests them under
# .rate_limits; the percentage field has been seen as both `utilization`
# and `used_percentage`.
JQ_WK='((.seven_day // .rate_limits.seven_day) // {}) | (.utilization // .used_percentage // empty)'
JQ_5H='((.five_hour // .rate_limits.five_hour) // {}) | (.utilization // .used_percentage // empty)'
JQ_WKR='((.seven_day // .rate_limits.seven_day) // {}) | (.resets_at // .reset_at // empty)'
JQ_5HR='((.five_hour // .rate_limits.five_hour) // {}) | (.resets_at // .reset_at // empty)'

force=0; mode="summary"; thresh=""
while [ $# -gt 0 ]; do
  case "$1" in
    -w|--weekly)            mode="weekly" ;;
    --5h|--5hour|--five-hour) mode="5h" ;;
    --json)                 mode="json" ;;
    --gate)                 mode="gate"; thresh="${2:-}"; shift ;;
    -f|--force)             force=1 ;;
    -h|--help)              awk '/^# claude-usage /{f=1} f{if(!/^#/)exit; sub(/^# ?/,""); print}' "$0"; exit 0 ;;
    *) echo "claude-usage: unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

cache_age() {
  if [ -f "$CACHE" ]; then
    local m; m=$(stat -c %Y "$CACHE" 2>/dev/null || echo 0)
    echo "$(( $(date +%s) - m ))"
  else
    echo 999999
  fi
}

fetch() {
  # Refresh $CACHE from the endpoint. 0 on success, 1 on failure.
  if [ ! -f "$CREDS" ]; then
    echo "claude-usage: no credentials file at $CREDS" >&2
    echo "  (a keyring-backed claude login stores no file there; this tool only supports file-based credentials)" >&2
    return 1
  fi
  local token ver ua tmp http
  token=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS" 2>/dev/null)
  if [ -z "$token" ]; then
    echo "claude-usage: couldn't read .claudeAiOauth.accessToken from $CREDS" >&2
    return 1
  fi
  ver=$(claude --version 2>/dev/null | grep -oE -m1 '[0-9]+\.[0-9]+\.[0-9]+')
  if [ -z "$ver" ]; then
    # A wrong UA is exactly the punitive-rate-limit trap the header warns
    # about, so falling back must not be silent: say so, every time, or the
    # first symptom is unexplained persistent 429s.
    echo "claude-usage: could not parse 'claude --version'; sending UA claude-code/latest (risks the punitive rate-limit bucket)" >&2
    ver="latest"
  fi
  ua="claude-code/$ver"
  mkdir -p "$(dirname "$CACHE")"
  tmp="$CACHE.tmp.$$"
  # The bearer token must NEVER be an argv element: /proc/<pid>/cmdline is
  # world-readable for the whole life of the curl process, so a plain
  # -H "Authorization: Bearer ..." leaks a live OAuth token to any `ps` on the
  # box. `--header @-` (curl >= 7.55) reads extra headers from stdin instead;
  # only the secret header goes that way, the boring ones stay on argv.
  http=$(printf 'Authorization: Bearer %s\n' "$token" \
    | curl -sS -o "$tmp" -w '%{http_code}' \
      --header @- \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: $ua" \
      "$ENDPOINT" 2>/dev/null)
  if [ "$http" = "200" ] && jq -e . "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$CACHE"
    return 0
  fi
  rm -f "$tmp"
  echo "claude-usage: fetch failed (HTTP $http)" >&2
  return 1
}

ensure_fresh() {
  # Guarantee usable data in $CACHE (fresh, or stale as a last resort).
  # 0 if $CACHE holds something usable, 1 if we have nothing at all.
  local age; age=$(cache_age)
  if [ "$force" = "1" ] || [ "$age" -ge "$TTL" ]; then
    if fetch; then return 0; fi
    if [ -f "$CACHE" ]; then
      echo "claude-usage: fetch failed; using stale cache (${age}s old)" >&2
      return 0
    fi
    return 1
  fi
  return 0
}

fmt_reset() {
  local raw="$1" epoch now secs d h m when out
  if [ -z "$raw" ] || [ "$raw" = "null" ]; then echo ""; return; fi
  if printf '%s' "$raw" | grep -qE '^[0-9]+$'; then
    epoch="$raw"
  else
    epoch=$(date -d "$raw" +%s 2>/dev/null) || epoch=""
  fi
  if [ -z "$epoch" ]; then printf 'resets %s' "$raw"; return; fi
  now=$(date +%s)
  secs=$(( epoch - now )); [ "$secs" -lt 0 ] && secs=0
  d=$(( secs / 86400 )); h=$(( (secs % 86400) / 3600 )); m=$(( (secs % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then out="${d}d${h}h"; else out="${h}h${m}m"; fi
  when=$(date -d @"$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "$raw")
  printf 'resets %s (in %s)' "$when" "$out"
}

case "$mode" in
  json)
    ensure_fresh || { echo "claude-usage: no usage data available" >&2; exit 2; }
    cat "$CACHE"
    ;;
  weekly|5h)
    ensure_fresh || { echo "claude-usage: could not determine usage" >&2; exit 2; }
    if [ "$mode" = "weekly" ]; then val=$(jq -r "$JQ_WK" "$CACHE" 2>/dev/null)
    else                            val=$(jq -r "$JQ_5H" "$CACHE" 2>/dev/null); fi
    if [ -z "$val" ] || [ "$val" = "null" ]; then
      echo "claude-usage: $mode usage not present in response (try --json)" >&2; exit 2
    fi
    echo "$val"
    ;;
  gate)
    if [ -z "$thresh" ] || ! printf '%s' "$thresh" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
      echo "claude-usage: --gate needs a numeric percentage, e.g. --gate 85" >&2; exit 2
    fi
    ensure_fresh || { echo "claude-usage: could not determine usage" >&2; exit 2; }
    wk=$(jq -r "$JQ_WK" "$CACHE" 2>/dev/null)
    if [ -z "$wk" ] || [ "$wk" = "null" ]; then
      echo "claude-usage: weekly usage not present in response (try --json)" >&2; exit 2
    fi
    echo "$wk"
    # over/at threshold -> exit 1 (stop); under -> exit 0 (keep going).
    if awk -v v="$wk" -v t="$thresh" 'BEGIN{exit !(v+0 >= t+0)}'; then exit 1; else exit 0; fi
    ;;
  summary)
    ensure_fresh || { echo "claude-usage: no usage data available" >&2; exit 2; }
    wk=$(jq -r "$JQ_WK" "$CACHE" 2>/dev/null)
    fh=$(jq -r "$JQ_5H" "$CACHE" 2>/dev/null)
    wkr=$(jq -r "$JQ_WKR" "$CACHE" 2>/dev/null)
    fhr=$(jq -r "$JQ_5HR" "$CACHE" 2>/dev/null)
    printf 'weekly:  %5s%%   %s\n' "${wk:-?}" "$(fmt_reset "$wkr")"
    printf '5-hour:  %5s%%   %s\n' "${fh:-?}" "$(fmt_reset "$fhr")"
    ;;
esac
