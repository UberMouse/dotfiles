# kx-build-slot -- take a slot from the machine-global build semaphore, run a
# command while holding it, and release it on exit.
#
#   kx-build-slot [--label NAME] [--timeout SECS] -- COMMAND [ARGS...]
#
# The semaphore is published by build-semaphore-controller.py (see that file for
# why admission control is the lever and why the loop is asymmetric). This is
# the client half: the thing every heavy job wraps itself in.
#
# WHY flock ON FILES rather than a daemon with leases. The callers here are
# build workers that genuinely get OOM-killed and frozen -- that is the entire
# problem being solved. A lease protocol would need expiry, heartbeats and a
# reaper to survive a caller dying mid-hold. flock gets all of that from the
# kernel: the lock is attached to the open file description, so it is released
# on process death no matter HOW the process died. Nothing can leak a slot.
#
# The second reason is reach. The jobs that need gating live in another repo and
# several languages -- a heft plugin, two Node shard runners, a nix shell wrapper
# -- and `flock` on a known path is implementable in about three lines of any of
# them. There is no protocol to reimplement and no version to keep in step.
#
# THREE FAIL-OPEN PATHS, all deliberate. A build that runs unthrottled is a
# nuisance; a build that never runs is a broken machine. So:
#
#   1. No semaphore directory (controller not running, or a machine that never
#      had one -- CI, a colleague's checkout) -> exec the command immediately.
#      This is what lets the kawaka side of this land unconditionally: on any
#      host without the controller it is exactly a no-op.
#   2. Already holding a slot ($KX_BUILD_SLOT_HELD set) -> exec immediately.
#      Without this, a gated job that spawns another gated job would wait on a
#      slot its own ancestor is holding, and at the floor of 1 that is a
#      guaranteed deadlock rather than a rare one.
#   3. Timed out waiting -> run anyway, and log it. A slot is a scheduling hint,
#      not a permission.
#
# Slots are scanned from the BOTTOM. The controller holds them back from the
# TOP. That is the whole coordination protocol -- the two never contend for the
# same file, so neither needs to know the other exists.

label=""
timeout_s="${KX_BUILD_SLOT_TIMEOUT:-600}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --label) label="${2:-}"; shift 2 ;;
    --label=*) label="${1#--label=}"; shift ;;
    --timeout) timeout_s="${2:-}"; shift 2 ;;
    --timeout=*) timeout_s="${1#--timeout=}"; shift ;;
    --) shift; break ;;
    -h|--help)
      awk 'NR==1{next} /^#/{f=1;sub(/^# ?/,"");print;next} f{exit}' "$0"
      exit 0 ;;
    *) break ;;
  esac
done

if [ "$#" -eq 0 ]; then
  echo "kx-build-slot: no command given (use -- COMMAND ARGS)" >&2
  exit 2
fi

SEM_DIR="${KX_BUILD_SEM_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/kx-build-sem}"
LOG_DIR="$HOME/.local/state/cgroup-pressure"
LOG="$LOG_DIR/build-semaphore.log"
[ -n "$label" ] || label="$(basename "${1:-job}")"

slotlog() {
  # Only ever called on the slow paths (waited, timed out), so this costs
  # nothing in the common case of a slot being free immediately.
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s  BUILDSEM|%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >> "$LOG" 2>/dev/null || true
}

# Fail-open 1 and 2: nothing to coordinate with, or we already hold a slot.
if [ ! -d "$SEM_DIR" ] || [ -n "${KX_BUILD_SLOT_HELD:-}" ]; then
  exec "$@"
fi

# Fail-open 1b: the directory exists but holds no slot files yet. This is the
# controller's startup window, and without this check the scan below would find
# nothing to lock and spin all the way to the timeout before giving up -- a
# 600 s stall on every job unlucky enough to start during a service restart.
# An empty semaphore is indistinguishable from no semaphore, so treat it as one.
# Plain glob rather than `compgen -G`. NIXPKGS BUILDS BASH WITHOUT PROGRAMMABLE
# COMPLETION, so `compgen` does not exist as a builtin on this system at all --
# `type -a compgen` reports "not found" and `shopt progcomp` reports "invalid
# shell option name". The call therefore exited 127, `! 127` evaluated TRUE, and
# every single job took the fail-open path: a semaphore that silently gated
# nothing. Caught on first deploy 2026-08-03, and worth remembering repo-wide --
# any script here reaching for compgen is broken the same way, silently.
#
# This is the same SHAPE of bug that made the governor's duties B and C dead
# code for three days in July (a test that could never be true quietly disabling
# the actuator, while the log kept reporting healthy). A literal glob depends on
# nothing and cannot fail this way.
_have_slot=0
for _slot in "$SEM_DIR"/slot.*; do
  if [ -e "$_slot" ]; then _have_slot=1; break; fi
done
if [ "$_have_slot" = 0 ]; then
  exec "$@"
fi

export KX_BUILD_SLOT_HELD=1

run_child() {
  # The lock lives on this shell's fd, so the command runs as a CHILD rather
  # than via exec -- the parent must stay alive to keep holding it. Signals are
  # forwarded so the wrapper is transparent to Ctrl-C and to systemd stopping a
  # build scope.
  "$@" &
  child=$!
  trap 'kill -TERM "$child" 2>/dev/null || true' TERM INT
  wait "$child"
  rc=$?
  trap - TERM INT
  return "$rc"
}

start=$(date +%s)
waited=0

while :; do
  for slot in "$SEM_DIR"/slot.*; do
    [ -e "$slot" ] || continue
    exec {fd}>"$slot" || continue
    if flock -n "$fd"; then
      [ "$waited" -gt 0 ] && slotlog "ACQUIRED $label after ${waited}s ($(basename "$slot"))"
      run_child "$@"
      rc=$?
      exec {fd}>&-
      exit "$rc"
    fi
    exec {fd}>&-
  done

  now=$(date +%s)
  waited=$((now - start))
  if [ "$waited" -ge "$timeout_s" ]; then
    # Fail-open 3.
    slotlog "TIMEOUT $label waited ${waited}s, running UNGATED"
    exec "$@"
  fi

  # Jittered poll. Jitter matters: without it a burst of jobs that arrived
  # together stays in lockstep and they all retry on the same tick forever,
  # which is the thundering herd this whole service exists to prevent.
  sleep "0.$(( (RANDOM % 4) + 2 ))"
done
