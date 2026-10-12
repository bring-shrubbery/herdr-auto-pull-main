#!/usr/bin/env bash
# Dispatcher for manifest actions and event hooks.
set -uo pipefail

# shellcheck source=bin/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
apm_load_config

cmd="${1:-status}"
if apm_is_true "${AUTO_PULL_DEBUG:-}"; then
  apm_log "action $cmd: workspace=${HERDR_WORKSPACE_ID:-} pane=${HERDR_PANE_ID:-} context=${HERDR_PLUGIN_CONTEXT_JSON:-}"
fi

# Working directory of the pane that triggered the action, best effort.
context_cwd() {
  local cwd=""
  if [ -n "${HERDR_PLUGIN_CONTEXT_JSON:-}" ]; then
    for key in focused_pane_cwd pane_cwd workspace_cwd worktree_path cwd focused_pane.cwd pane.cwd workspace.cwd; do
      cwd="$(printf '%s' "$HERDR_PLUGIN_CONTEXT_JSON" | apm_json_get "$key")"
      [ -n "$cwd" ] && break
    done
  fi
  if [ -z "$cwd" ] && apm_herdr_available; then
    local pane="${HERDR_PANE_ID:-}" ws="${HERDR_WORKSPACE_ID:-}"
    cwd="$(apm_herdr_panes_tsv 2>/dev/null | awk -F'\t' -v ws="$ws" -v pane="$pane" '
      ws != "" && $4 == ws && $1 != "" { print $1; exit }
      ws == "" && $1 != "" { print $1; exit }')"
  fi
  [ -n "$cwd" ] || cwd="$PWD"
  printf '%s\n' "$cwd"
}

case "$cmd" in
  pull-now)
    exec bash "$APM_BIN_DIR/pull.sh" --manual
    ;;
  pull-here)
    cwd="$(context_cwd)"
    exec bash "$APM_BIN_DIR/pull.sh" --manual --repo "$cwd"
    ;;
  poke)
    touch "$APM_POKE_FILE"
    ;;
  pause)
    touch "$APM_PAUSE_FILE"
    apm_log "paused by user"
    apm_notify "Auto Pull Main" "Automatic pulls paused"
    ;;
  resume)
    rm -f "$APM_PAUSE_FILE"
    touch "$APM_POKE_FILE"
    apm_log "resumed by user"
    apm_notify "Auto Pull Main" "Automatic pulls resumed"
    ;;
  toggle)
    if [ -e "$APM_PAUSE_FILE" ]; then
      exec bash "$0" resume
    else
      exec bash "$0" pause
    fi
    ;;
  restart)
    apm_stop_daemon
    if apm_start_daemon; then
      apm_notify "Auto Pull Main" "Background poller restarted (pid $(apm_daemon_pid))"
    else
      apm_notify "Auto Pull Main" "Failed to start background poller; see $APM_DAEMON_LOG"
      exit 1
    fi
    ;;
  stop)
    if apm_stop_daemon; then
      apm_log "daemon stopped by user"
      apm_notify "Auto Pull Main" "Background poller stopped"
    else
      apm_notify "Auto Pull Main" "Background poller was not running"
    fi
    ;;
  status)
    if apm_herdr_available; then
      exec "$APM_HERDR" plugin pane open --plugin "$APM_PLUGIN_ID" --entrypoint status --placement popup --focus
    else
      exec bash "$APM_BIN_DIR/status.sh" --no-wait
    fi
    ;;
  *)
    printf 'unknown action: %s\n' "$cmd" >&2
    exit 2
    ;;
esac
