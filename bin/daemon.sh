#!/usr/bin/env bash
# Background poller. Started detached by startup.sh; one per Herdr server socket.
# Exits when: the Herdr socket disappears, its pid file is replaced by another
# daemon, or a stop file is written.
set -uo pipefail

# shellcheck source=bin/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"

printf '%s\n' "$$" >"$APM_PID_FILE"
STOP_FILE="$APM_PID_FILE.stop"
rm -f "$STOP_FILE"

apm_load_config
apm_log "daemon: started (pid $$, interval ${AUTO_PULL_INTERVAL}, socket ${HERDR_SOCKET_PATH:-default})"

on_exit() {
  apm_log "daemon: exiting (pid $$)"
  if [ "$(cat "$APM_PID_FILE" 2>/dev/null | tr -d ' \n')" = "$$" ]; then
    rm -f "$APM_PID_FILE"
  fi
}
trap on_exit EXIT
trap 'exit 0' TERM INT HUP

server_gone() {
  # The server socket vanished, or the server process that started us is gone.
  if [ -n "${HERDR_SOCKET_PATH:-}" ] && [ ! -S "$HERDR_SOCKET_PATH" ]; then
    return 0
  fi
  if [ -n "${APM_SERVER_PID:-}" ] && ! kill -0 "$APM_SERVER_PID" 2>/dev/null; then
    return 0
  fi
  return 1
}

should_exit() {
  if [ -e "$STOP_FILE" ]; then
    rm -f "$STOP_FILE"; return 0
  fi
  if [ "$(cat "$APM_PID_FILE" 2>/dev/null | tr -d ' \n')" != "$$" ]; then
    apm_log "daemon: pid file taken over by another daemon; exiting"
    return 0
  fi
  if server_gone; then
    apm_log "daemon: Herdr socket is gone; exiting"
    return 0
  fi
  return 1
}

consecutive_failures=0
first=1
while :; do
  should_exit && exit 0
  apm_load_config

  if [ -e "$APM_PAUSE_FILE" ]; then
    :
  else
    rm -f "$APM_POKE_FILE"
    if [ "$first" = 1 ]; then
      # Let the server finish restoring panes before the first discovery.
      sleep "${AUTO_PULL_STARTUP_DELAY:-10}"
      first=0
    fi
    if apm_herdr_available && "$APM_HERDR" pane list >/dev/null 2>&1; then
      consecutive_failures=0
      bash "$APM_BIN_DIR/pull.sh" || apm_log "daemon: pull pass exited with status $?"
    else
      consecutive_failures=$((consecutive_failures + 1))
      apm_log "daemon: Herdr is not answering (attempt $consecutive_failures)"
      if [ "$consecutive_failures" -ge 5 ]; then
        apm_log "daemon: giving up after $consecutive_failures failed attempts"
        exit 0
      fi
    fi
  fi

  # Sleep in short slices so pokes, pauses, and shutdowns are picked up quickly.
  remaining="$AUTO_PULL_INTERVAL_SECONDS"
  while [ "$remaining" -gt 0 ]; do
    slice=5
    [ "$remaining" -lt 5 ] && slice="$remaining"
    sleep "$slice"
    remaining=$((remaining - slice))
    should_exit && exit 0
    if [ -e "$APM_POKE_FILE" ] && [ ! -e "$APM_PAUSE_FILE" ]; then
      apm_log "daemon: poked, running early"
      break
    fi
  done
done
