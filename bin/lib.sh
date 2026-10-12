#!/usr/bin/env bash
# Shared helpers for the Auto Pull Main Herdr plugin.
# Compatible with bash 3.2 (macOS default). No associative arrays, no mapfile.
# shellcheck disable=SC2034  # variables here are used by the sourcing scripts

APM_PLUGIN_ID="bring-shrubbery.auto-pull-main"
APM_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APM_ROOT="${HERDR_PLUGIN_ROOT:-$(cd "$APM_BIN_DIR/.." && pwd -P)}"
APM_HERDR="${HERDR_BIN_PATH:-herdr}"

# --- directories -------------------------------------------------------------

apm_default_config_dir() {
  if [ -n "${HERDR_PLUGIN_CONFIG_DIR:-}" ]; then
    printf '%s\n' "$HERDR_PLUGIN_CONFIG_DIR"
  elif [ -n "${APM_CONFIG_DIR_OVERRIDE:-}" ]; then
    printf '%s\n' "$APM_CONFIG_DIR_OVERRIDE"
  elif command -v "$APM_HERDR" >/dev/null 2>&1 && dir="$("$APM_HERDR" plugin config-dir "$APM_PLUGIN_ID" 2>/dev/null)" && [ -n "$dir" ]; then
    printf '%s\n' "$dir"
  else
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/herdr-auto-pull-main"
  fi
}

apm_default_state_dir() {
  if [ -n "${HERDR_PLUGIN_STATE_DIR:-}" ]; then
    printf '%s\n' "$HERDR_PLUGIN_STATE_DIR"
  elif [ -n "${APM_STATE_DIR_OVERRIDE:-}" ]; then
    printf '%s\n' "$APM_STATE_DIR_OVERRIDE"
  else
    printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/herdr-auto-pull-main"
  fi
}

APM_CONFIG_DIR="$(apm_default_config_dir)"
APM_STATE_DIR="$(apm_default_state_dir)"
mkdir -p "$APM_CONFIG_DIR" "$APM_STATE_DIR" 2>/dev/null || true

APM_CONFIG_FILE="$APM_CONFIG_DIR/config.env"
APM_LOG_FILE="$APM_STATE_DIR/auto-pull-main.log"
APM_DAEMON_LOG="$APM_STATE_DIR/daemon.log"
APM_LAST_RUN_FILE="$APM_STATE_DIR/last-run.txt"
APM_PAUSE_FILE="$APM_STATE_DIR/paused"
APM_POKE_FILE="$APM_STATE_DIR/poke"
APM_LOCK_DIR="$APM_STATE_DIR/tick.lock"

# One daemon per Herdr server socket (named sessions have their own sockets).
apm_socket_key() {
  printf '%s' "${HERDR_SOCKET_PATH:-default}" | cksum | awk '{print $1}'
}
APM_PID_FILE="$APM_STATE_DIR/daemon-$(apm_socket_key).pid"

# --- config ------------------------------------------------------------------

apm_load_config() {
  # Defaults. Every key can be overridden in $APM_CONFIG_FILE (KEY=VALUE lines)
  # or in the environment of the process that starts the daemon.
  : "${AUTO_PULL_INTERVAL:=5m}"
  : "${AUTO_PULL_REMOTE:=origin}"
  : "${AUTO_PULL_BRANCH:=}"
  : "${AUTO_PULL_REQUIRE_CLEAN:=tracked}"
  : "${AUTO_PULL_SKIP_WHILE_AGENT_WORKING:=true}"
  : "${AUTO_PULL_UPDATE_UNCHECKED_BRANCH:=true}"
  : "${AUTO_PULL_SUBMODULES:=false}"
  : "${AUTO_PULL_NOTIFY:=updates}"
  : "${AUTO_PULL_NOTIFY_SOUND:=none}"
  : "${AUTO_PULL_FETCH_TIMEOUT:=60}"
  : "${AUTO_PULL_EXCLUDE:=}"
  : "${AUTO_PULL_INCLUDE:=}"
  : "${AUTO_PULL_LOG_MAX_BYTES:=1000000}"

  if [ -f "$APM_CONFIG_FILE" ]; then
    # Only accept simple KEY=VALUE lines for AUTO_PULL_* keys; everything else is ignored.
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        AUTO_PULL_[A-Z_]*=*) ;;
        *) continue ;;
      esac
      key="${line%%=*}"
      value="${line#*=}"
      # strip surrounding quotes
      case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
      esac
      eval "$key=\"\$value\""
    done <"$APM_CONFIG_FILE"
  fi

  AUTO_PULL_INTERVAL_SECONDS="$(apm_parse_duration "$AUTO_PULL_INTERVAL")" || AUTO_PULL_INTERVAL_SECONDS=300
  if [ "$AUTO_PULL_INTERVAL_SECONDS" -lt 15 ]; then
    AUTO_PULL_INTERVAL_SECONDS=15
  fi
  export AUTO_PULL_INTERVAL AUTO_PULL_REMOTE AUTO_PULL_BRANCH AUTO_PULL_REQUIRE_CLEAN \
    AUTO_PULL_SKIP_WHILE_AGENT_WORKING AUTO_PULL_UPDATE_UNCHECKED_BRANCH AUTO_PULL_SUBMODULES \
    AUTO_PULL_NOTIFY AUTO_PULL_NOTIFY_SOUND AUTO_PULL_FETCH_TIMEOUT AUTO_PULL_EXCLUDE \
    AUTO_PULL_INCLUDE AUTO_PULL_LOG_MAX_BYTES AUTO_PULL_INTERVAL_SECONDS
}

# "5m" -> 300, "90s" -> 90, "1h" -> 3600, "300" -> 300. Prints seconds.
apm_parse_duration() {
  local v="$1" n unit
  v="$(printf '%s' "$v" | tr -d ' ')"
  case "$v" in
    *[!0-9smhd]*|"") return 1 ;;
  esac
  unit="${v##*[0-9]}"
  n="${v%"$unit"}"
  [ -n "$n" ] || return 1
  case "$unit" in
    ""|s) printf '%s\n' "$n" ;;
    m) printf '%s\n' $((n * 60)) ;;
    h) printf '%s\n' $((n * 3600)) ;;
    d) printf '%s\n' $((n * 86400)) ;;
    *) return 1 ;;
  esac
}

apm_is_true() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# --- logging -----------------------------------------------------------------

apm_now() { date '+%Y-%m-%d %H:%M:%S'; }

apm_rotate_log() {
  local f="$1" max="${AUTO_PULL_LOG_MAX_BYTES:-1000000}" size
  [ -f "$f" ] || return 0
  size="$(wc -c <"$f" 2>/dev/null | tr -d ' ')"
  [ -n "$size" ] && [ "$size" -gt "$max" ] || return 0
  mv -f "$f" "$f.1" 2>/dev/null || true
}

apm_log() {
  apm_rotate_log "$APM_LOG_FILE"
  printf '%s %s\n' "$(apm_now)" "$*" >>"$APM_LOG_FILE" 2>/dev/null || true
  if [ -n "${APM_VERBOSE:-}" ]; then
    printf '%s\n' "$*" >&2
  fi
}

# --- Herdr -------------------------------------------------------------------

apm_herdr_available() {
  command -v "$APM_HERDR" >/dev/null 2>&1
}

apm_notify() {
  # $1 title, $2 body
  apm_herdr_available || return 0
  "$APM_HERDR" notification show "$1" --body "$2" --sound "${AUTO_PULL_NOTIFY_SOUND:-none}" >/dev/null 2>&1 || true
}

# Prints TSV: cwd <TAB> foreground_cwd <TAB> agent_status <TAB> workspace_id
apm_herdr_panes_tsv() {
  local json
  json="$("$APM_HERDR" pane list 2>/dev/null)" || return 1
  printf '%s' "$json" | apm_json_panes_tsv
}

apm_json_panes_tsv() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.result.panes[]? | [(.cwd // ""), (.foreground_cwd // ""), (.agent_status // "unknown"), (.workspace_id // "")] | @tsv'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for p in (d.get("result", {}) or {}).get("panes", []) or []:
    row = [p.get("cwd") or "", p.get("foreground_cwd") or "", p.get("agent_status") or "unknown", p.get("workspace_id") or ""]
    print("\t".join(str(x).replace("\t", " ") for x in row))
'
  else
    return 2
  fi
}

# Extract a string value from JSON on stdin by a dotted path (e.g. "pane.cwd").
apm_json_get() {
  local path="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg p "$path" '[getpath($p | split("."))] | map(select(. != null and . != "")) | .[0] // empty' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
path = sys.argv[1].split(".")
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for k in path:
    if isinstance(d, dict) and k in d:
        d = d[k]
    else:
        sys.exit(0)
if isinstance(d, (str, int)) and str(d) != "":
    print(d)
' "$path"
  fi
}

# --- process helpers ---------------------------------------------------------

# apm_run_timeout SECONDS cmd args...   (uses perl alarm when available)
apm_run_timeout() {
  local secs="$1"; shift
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
    return $?
  fi
  "$@" &
  local pid=$! rc
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
  local watchdog=$!
  wait "$pid"; rc=$?
  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  return "$rc"
}

apm_pid_alive() {
  [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

apm_pid_is_daemon() {
  local pid="$1" cmd
  apm_pid_alive "$pid" || return 1
  cmd="$(ps -o command= -p "$pid" 2>/dev/null || ps -o args= -p "$pid" 2>/dev/null || true)"
  case "$cmd" in
    *daemon.sh*) return 0 ;;
    *) return 1 ;;
  esac
}

apm_daemon_pid() {
  [ -f "$APM_PID_FILE" ] || return 1
  local pid
  pid="$(tr -d ' \n' <"$APM_PID_FILE")"
  apm_pid_is_daemon "$pid" || return 1
  printf '%s\n' "$pid"
}

apm_stop_daemon() {
  local pid
  pid="$(apm_daemon_pid)" || { rm -f "$APM_PID_FILE"; return 1; }
  kill -TERM "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    apm_pid_alive "$pid" || break
    sleep 0.2
  done
  apm_pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null
  rm -f "$APM_PID_FILE"
  return 0
}

apm_start_daemon() {
  local log="$APM_DAEMON_LOG"
  apm_rotate_log "$log"
  if command -v setsid >/dev/null 2>&1; then
    setsid bash "$APM_BIN_DIR/daemon.sh" </dev/null >>"$log" 2>&1 &
  elif command -v perl >/dev/null 2>&1; then
    perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' bash "$APM_BIN_DIR/daemon.sh" </dev/null >>"$log" 2>&1 &
  else
    nohup bash "$APM_BIN_DIR/daemon.sh" </dev/null >>"$log" 2>&1 &
  fi
  disown 2>/dev/null || true
  # Give it a moment to write its pid file.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    apm_daemon_pid >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  apm_daemon_pid >/dev/null 2>&1
}

# --- git helpers -------------------------------------------------------------

apm_git() {
  GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 git "$@"
}

# Resolve a path to its canonical absolute form (follows symlinks).
apm_realpath() {
  (cd "$1" 2>/dev/null && pwd -P)
}

# Prints "<common_git_dir>\t<worktree_toplevel>" for a path inside a git checkout.
apm_repo_identity() {
  local cwd="$1" top common
  [ -d "$cwd" ] || return 1
  top="$(apm_git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || return 1
  common="$(apm_git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in
    /*) ;;
    *) common="$cwd/$common" ;;
  esac
  common="$(apm_realpath "$common")" || return 1
  top="$(apm_realpath "$top")" || return 1
  printf '%s\t%s\n' "$common" "$top"
}
