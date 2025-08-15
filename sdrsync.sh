#!/bin/bash
set -euo pipefail

# Load env
if [[ -f /etc/sdrsync/sdrsync.env ]]; then
  # shellcheck disable=SC1091
  . /etc/sdrsync/sdrsync.env
else
  echo "[sdrsync] ERROR: /etc/sdrsync/sdrsync.env not found" >&2
  exit 1
fi

: "${SDRSYNC_USER:?set in /etc/sdrsync/sdrsync.env}"
: "${SDRSYNC_DISPLAY:=:0}"
: "${WFVIEW_BIN:=/usr/local/bin/wfview}"
: "${RTL_TCP_BIN:=/usr/local/bin/rtl_tcp}"
: "${PYTHON_BIN:=/usr/bin/python3}"
: "${SYNC_PY:?set in /etc/sdrsync/sdrsync.env}"
: "${WF_PORT:=4533}"
: "${RTL_PORT:=14423}"
: "${RTL_TCP_EXTRA_ARGS:=-a 0.0.0.0}"

USER_UID=$(id -u "$SDRSYNC_USER")
export DISPLAY="$SDRSYNC_DISPLAY"
export XDG_RUNTIME_DIR="/run/user/${USER_UID}"
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus"

LOG="/var/log/sdrsync.log"
touch "$LOG" && chown "$SDRSYNC_USER:$SDRSYNC_USER" "$LOG" || true
exec > >(tee -a "$LOG") 2>&1

echo "[sdrsync] starting as $SDRSYNC_USER on DISPLAY=$DISPLAY"

as_user() {
  runuser -u "$SDRSYNC_USER" -- bash -lc "export DISPLAY='$DISPLAY'; \
    export XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR'; \
    export DBUS_SESSION_BUS_ADDRESS='$DBUS_SESSION_BUS_ADDRESS'; $*"
}

# Start wfview and rtl_tcp under the user session

echo "[sdrsync] starting wfview..."
as_user "'$WFVIEW_BIN'" &
WF_RUNUSER_PID=$!

echo "[sdrsync] starting rtl_tcp..."
as_user "'$RTL_TCP_BIN' -p $RTL_PORT $RTL_TCP_EXTRA_ARGS" &
RTL_RUNUSER_PID=$!

cleanup() {
  echo "[sdrsync] stopping children..."
  # try graceful by pattern match owned by the user
  as_user "pkill -TERM -f '^${WFVIEW_BIN}( |$)' || true"
  as_user "pkill -TERM -f '^${RTL_TCP_BIN}( |$)' || true"
  sleep 1
  as_user "pkill -KILL -f '^${WFVIEW_BIN}( |$)' || true"
  as_user "pkill -KILL -f '^${RTL_TCP_BIN}( |$)' || true"
}
trap cleanup EXIT INT TERM

# Wait for sockets
for i in {1..120}; do nc -z localhost "$WF_PORT" 2>/dev/null && break; sleep 0.5; done
for i in {1..120}; do nc -z localhost "$RTL_PORT" 2>/dev/null && break; sleep 0.5; done

# Run sync (foreground, no exec so trap runs)
echo "[sdrsync] starting sync: $PYTHON_BIN $SYNC_PY"
as_user "'$PYTHON_BIN' '$SYNC_PY'" &
SYNC_PID=$!
wait "$SYNC_PID"
echo "[sdrsync] sync.py exited"
