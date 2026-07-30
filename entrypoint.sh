#!/bin/sh
# Entrypoint contract: docs/image-contract.md (env names are load-bearing —
# the installer's quadlet sets them and its check-image-contract.sh greps
# this file; rename nothing without bumping both repos).
#
# One supervised process per container, chosen by CMD:
#   svxlink (default) | remotetrx | svxreflector — managed below
#   anything else                                — exec'd verbatim (debug shell)
# Crash semantics: the process IS the container; systemd Restart= supervises.
# (f4hlv's multi-process supervisor kept the container "up" after svxlink
# crashed — that flaw is removed structurally, not patched.)
set -eu

PROG="${1:-svxlink}"
[ "$#" -gt 0 ] && shift

case "$PROG" in
  svxlink|remotetrx|svxreflector) ;;
  *) exec "$PROG" "$@" ;;
esac

# Per-program default so `podman run ... remotetrx` picks remotetrx.conf;
# SVXLINK_CONF (set by the quadlet) overrides for the managed svxlink node.
CONF="${SVXLINK_CONF:-/etc/svxlink/${PROG}.conf}"
if [ ! -r "$CONF" ]; then
  echo "ERROR: config not readable: $CONF — bind-mount your config dir at /etc/svxlink" >&2
  echo "       (the installer seeds ~/.svxlink/etc from this image's pristine /etc/svxlink)" >&2
  exit 1
fi

# --- stdout-only mode (SVXLINK_LOGFILE empty): pure container-native logging.
# Deliberately NO --logfile flag: svxlink's logfile writer mishandles
# /dev/stdout when it is a pipe (conmon) — every line vanishes, verified
# 2026-07-30 on 26.05.1. Bare stdout streams fine (journald stamps times).
if [ -z "${SVXLINK_LOGFILE:-}" ]; then
  exec "$PROG" --config="$CONF" "$@"
fi

# --- file mode: svxlink writes a real log file (the CN8VX dashboard tails
# and greps it), the entrypoint mirrors it to stdout and rotates it.
mkdir -p "$(dirname "$SVXLINK_LOGFILE")"
touch "$SVXLINK_LOGFILE"

# tail is started BEFORE the program to minimize the attach race on the
# startup banner (-n0 skips anything written before tail has the file open —
# svxlink parses its config first, so in practice nothing is lost), and -F
# follows by NAME with retry so the mirror survives the rotation mv below.
tail -n0 -F "$SVXLINK_LOGFILE" &
TAILPID=$!

"$PROG" --config="$CONF" --logfile="$SVXLINK_LOGFILE" "$@" &
MAIN=$!

# Size-only rotation: mv to exactly one ".1" sibling (the dashboard reads
# LOGFILE and LOGFILE.1, nothing older), then SIGHUP — svxlink reopens its
# logfile on HUP (the classic logrotate contract). No calendar rotation: an
# idle repeater would just collect empty rotations.
(
  while kill -0 "$MAIN" 2>/dev/null; do
    sleep 60
    size="$(stat -c%s "$SVXLINK_LOGFILE" 2>/dev/null || echo 0)"
    [ "$size" -ge "${SVXLINK_LOG_MAXSIZE:-10485760}" ] || continue
    mv -f "$SVXLINK_LOGFILE" "${SVXLINK_LOGFILE}.1"
    kill -HUP "$MAIN" 2>/dev/null || true
  done
) &
ROTPID=$!

# Forward TERM/INT to svxlink for a clean EchoLink logoff. A signal makes the
# blocked `wait` return early (128+sig) BEFORE the child is gone, hence the
# loop: keep waiting until the child actually exited. rc is assigned
# UNCONDITIONALLY each pass — a `wait || rc=$?` guard kept the interrupted
# wait's 143 forever because the later successful wait never overwrote it
# (verified 2026-07-30: podman stop exited 143 despite svxlink's clean
# shutdown). systemd SIGKILLs the cgroup at TimeoutStopSec if svxlink hangs —
# that bound lives in the quadlet, not here.
got_term=0
trap 'got_term=1; kill -TERM "$MAIN" 2>/dev/null || true' TERM INT

rc=0
while kill -0 "$MAIN" 2>/dev/null; do
  if wait "$MAIN"; then rc=0; else rc=$?; fi
done
# An operator stop is not a failure: when we forwarded TERM and the last
# observed status is the interruption/signal-death code, report success so
# systemd counts the stop as clean.
if [ "$got_term" -eq 1 ] && [ "$rc" -eq 143 ]; then rc=0; fi

kill "$TAILPID" "$ROTPID" 2>/dev/null || true
exit "$rc"
