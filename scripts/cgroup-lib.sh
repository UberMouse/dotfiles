# cgroup-lib -- the helpers cgroup-governor.sh and cgroup-pressure-monitor.sh
# used to carry as byte-identical copies. SOURCED, never executed.
#
# The consumers are systemd units whose ExecStart interpolates a SINGLE FILE
# into the store (`${pkgs.bash}/bin/bash ${./scripts/x.sh}`), so `dirname
# "$0"` does not land next to this file in production -- cgroups.nix passes
# CGLIB=<store path of this file> in each unit's Environment, and the
# consumers fall back to the sibling path for local runs and the test suites:
#
#   . "${CGLIB:-$(dirname "$0")/cgroup-lib.sh}" || exit 1
#
# Everything here obeys the governor's FORK BUDGET (see its header): no
# command substitution, no external tools on the detection path; helpers set
# GLOBALS instead of echoing.
# shellcheck disable=SC2034  # the globals are consumed by the sourcing scripts The duplication this file removes was real
# risk, not tidiness -- the PSI parser encodes the 10# octal trap, and the
# governor test suite used to run BOTH copies through the same fixtures
# purely to detect a one-sided fix.

# Uid-derived cgroup paths, as globals. One construction site for the pool
# path repo-wide (with its KX_POOL override on the same line, per the lint
# tripwire); a slice rename is an edit here, not a hunt across two scripts.
kx_cgroup_paths() {
  U=$(id -u)
  UNAME=$(id -un)
  USERSLICE="/sys/fs/cgroup/user.slice/user-$U.slice"
  USERAT="$USERSLICE/user@$U.service"
  POOL="${KX_POOL:-$USERAT/worktrees.slice}"
}

# Reads "full ... avg10=NN.NN ..." from a PSI file into two globals:
#   PSI_TEXT  -- the value exactly as the kernel printed it, for log lines
#   PSI_CENTI -- the same number in integer hundredths, for comparisons
# Sets globals rather than echoing because `x=$(fn)` forks a subshell even
# for a builtin, and this runs two or three times per tick on the detection
# path of both consumers.
PSI_TEXT=0
PSI_CENTI=0
psi_full_avg10() {
  local line tok i f
  PSI_TEXT=0; PSI_CENTI=0
  while read -r line; do
    case "$line" in full\ *) ;; *) continue ;; esac
    for tok in $line; do
      case "$tok" in
        avg10=*)
          PSI_TEXT="${tok#avg10=}"
          i="${PSI_TEXT%%.*}"; [ -n "$i" ] || i=0
          f="${PSI_TEXT#*.}"; [ "$f" = "$PSI_TEXT" ] && f=00
          f="${f}00"; f="${f:0:2}"
          # 10# forces base 10: PSI prints "08" and "09", which are invalid octal.
          PSI_CENTI=$(( 10#$i * 100 + 10#$f ))
          return 0
          ;;
      esac
    done
  done < "$1" 2>/dev/null
  return 0
}

# Resolve the DESKTOP graphical session scope (x11/wayland) for this user,
# into $DESKTOP. The desktop lives OUTSIDE the pool; its OWN PSI is the "is
# the user stalling" signal. Cached in $DESKTOP; re-resolves if the cached
# scope disappears (the session can change across logout/login).
#
# $1 is the readability probe file, because the two consumers genuinely
# differ there: the governor reads the desktop's memory.pressure, the
# monitor its io.pressure, and each should require exactly the file it will
# go on to read.
#
# Called every tick, but the cached fast path on the first line is two
# builtin tests -- fork-free -- so it costs the per-tick budget nothing. The
# forking loginctl/awk walk below runs only while the cache is cold
# (startup, logout/login), which is why it keeps its plain style.
DESKTOP=""
resolve_desktop() {
  local probe="${1:-memory.pressure}"
  [ -n "$DESKTOP" ] && [ -r "$DESKTOP/$probe" ] && return 0
  DESKTOP=""
  local sid ty sc
  if command -v loginctl >/dev/null 2>&1; then
    while read -r sid; do
      [ -n "$sid" ] || continue
      ty=$(loginctl show-session "$sid" -p Type --value 2>/dev/null)
      case "$ty" in x11|wayland) ;; *) continue ;; esac
      sc="$USERSLICE/session-$sid.scope"
      [ -r "$sc/$probe" ] && { DESKTOP="$sc"; return 0; }
    done < <(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$UNAME" '$3==u{print $1}')
  fi
  # Fallback (no loginctl): the session-*.scope with the most PIDs is the
  # graphical one (browser + tabs dwarf a headless login shell).
  local d n best="" bestn=0
  for d in "$USERSLICE"/session-*.scope; do
    [ -r "$d/cgroup.procs" ] || continue
    n=$(wc -l < "$d/cgroup.procs" 2>/dev/null); n=${n:-0}
    if [ "$n" -gt "$bestn" ] 2>/dev/null; then bestn=$n; best="$d"; fi
  done
  [ -n "$best" ] && { DESKTOP="$best"; return 0; }
  return 1
}
