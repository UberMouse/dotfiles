# kx-proc-find -- list pids whose argv matches the given patterns, in order.
#
#   kx-proc-find PATTERN [PATTERN...]
#
# Each PATTERN is a shell glob matched against ONE argv field of every process
# (via /proc/<pid>/cmdline, NUL-split), and the patterns must match in argv
# order (not necessarily consecutively). Prints matching pids one per line.
#
#   kx-proc-find daemon run --origin        # exact fields, in order
#   kx-proc-find '*monorepo-jobs*' --daemon-run
#
# WHY THIS EXISTS: `pgrep -f` matches its pattern against the JOINED command
# line of every process, so the probe matches itself, plus any grep, editor or
# shell that happens to hold the string. Measured 2026-08-07: six "daemons"
# found against four real ones, the extras being the probe's own pipeline.
# Field-exact matching cannot false-positive that way: a `grep 'daemon run
# --origin'` holds the words as ONE argv field, which matches none of the three
# patterns. CLAUDE.md bans pgrep -f repo-wide; this is the replacement.
#
# The one self-match left is this script itself (its argv IS the pattern list),
# so any process with a kx-proc-find field is skipped -- which also covers
# concurrent invocations racing each other.

if [ "$#" -eq 0 ]; then
  echo "usage: kx-proc-find PATTERN [PATTERN...]  (globs, matched per argv field, in order)" >&2
  exit 2
fi

for c in /proc/[0-9]*/cmdline; do
  pid=${c#/proc/}
  pid=${pid%/cmdline}
  [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] && continue

  # NUL-split argv. A process can exit between glob and read; skip quietly.
  mapfile -d '' -t argv <"$c" 2>/dev/null || continue
  [ "${#argv[@]}" -gt 0 ] || continue

  self=0
  for f in "${argv[@]}"; do
    case "${f##*/}" in kx-proc-find) self=1 ;; esac
  done
  [ "$self" = 1 ] && continue

  i=0
  ok=1
  for pat in "$@"; do
    found=0
    while [ "$i" -lt "${#argv[@]}" ]; do
      # shellcheck disable=SC2254 # unquoted on purpose: glob semantics
      case "${argv[$i]}" in
        $pat)
          found=1
          i=$((i + 1))
          break
          ;;
      esac
      i=$((i + 1))
    done
    if [ "$found" = 0 ]; then
      ok=0
      break
    fi
  done
  [ "$ok" = 1 ] && printf '%s\n' "$pid"
done

exit 0
