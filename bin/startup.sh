#!/usr/bin/env bash
# Herdr startup hook: replace any poller for this server socket with a fresh one.
set -uo pipefail

# shellcheck source=bin/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
apm_load_config

# Herdr runs startup hooks directly, so our parent is the server. The daemon
# uses this to notice a crashed server even if its socket file is left behind.
if [ -z "${APM_SERVER_PID:-}" ] && [ -n "${HERDR_ENV:-}" ]; then
  export APM_SERVER_PID="$PPID"
fi

if [ ! -f "$APM_CONFIG_FILE" ] && [ -f "$APM_ROOT/config.example.env" ]; then
  cp "$APM_ROOT/config.example.env" "$APM_CONFIG_FILE" 2>/dev/null || true
fi

if pid="$(apm_daemon_pid)"; then
  apm_log "startup: stopping previous daemon (pid $pid)"
  apm_stop_daemon
fi

if apm_start_daemon; then
  echo "auto-pull-main daemon started (pid $(apm_daemon_pid)), interval $AUTO_PULL_INTERVAL"
  echo "config: $APM_CONFIG_FILE"
  echo "log:    $APM_LOG_FILE"
else
  echo "failed to start auto-pull-main daemon; see $APM_DAEMON_LOG" >&2
  exit 1
fi
