#!/usr/bin/env bash
# Status popup: daemon state, effective config, last run, recent log lines.
set -uo pipefail

# shellcheck source=bin/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
apm_load_config

wait_for_key=1
[ "${1:-}" = "--no-wait" ] && wait_for_key=0

bold() { printf '\033[1m%s\033[0m\n' "$*"; }

bold "Auto Pull Main"
echo
if pid="$(apm_daemon_pid)"; then
  printf 'daemon:    running (pid %s)\n' "$pid"
else
  printf 'daemon:    not running (invoke the restart-daemon action)\n'
fi
if [ -e "$APM_PAUSE_FILE" ]; then
  printf 'state:     PAUSED (invoke the resume action)\n'
else
  printf 'state:     active, every %s\n' "$AUTO_PULL_INTERVAL"
fi
printf 'remote:    %s   branch: %s\n' "$AUTO_PULL_REMOTE" "${AUTO_PULL_BRANCH:-auto (origin/HEAD, main, master, trunk)}"
printf 'clean:     %s   skip busy agents: %s   notify: %s\n' "$AUTO_PULL_REQUIRE_CLEAN" "$AUTO_PULL_SKIP_WHILE_AGENT_WORKING" "$AUTO_PULL_NOTIFY"
printf 'config:    %s\n' "$APM_CONFIG_FILE"
printf 'log:       %s\n' "$APM_LOG_FILE"
echo

if [ -f "$APM_LAST_RUN_FILE" ]; then
  bold "Last run"
  cat "$APM_LAST_RUN_FILE"
else
  echo "No pull pass has run yet."
fi
echo

bold "Recent log"
if [ -f "$APM_LOG_FILE" ]; then
  tail -n 25 "$APM_LOG_FILE"
else
  echo "(empty)"
fi

if [ "$wait_for_key" = 1 ]; then
  echo
  printf 'press enter to close...'
  read -r _ || true
fi
