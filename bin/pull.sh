#!/usr/bin/env bash
# One pull pass. Discovers repos from Herdr panes (or takes --repo PATH), fetches
# the default branch from its remote, and fast-forwards it when that is safe.
#
# usage: pull.sh [--repo PATH]... [--manual] [--verbose]
#   --repo PATH   only process the repo containing PATH (repeatable); skips Herdr discovery
#   --manual      user-triggered: always notify with a summary, log every result
#   --verbose     echo log lines to stderr
set -uo pipefail

# shellcheck source=bin/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"
apm_load_config

MANUAL=0
REPO_ARGS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) shift; REPO_ARGS="$REPO_ARGS$1"$'\n' ;;
    --manual) MANUAL=1 ;;
    --verbose) APM_VERBOSE=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# --- lock --------------------------------------------------------------------

apm_acquire_lock() {
  local pid
  for _ in 1 2 3; do
    if mkdir "$APM_LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" >"$APM_LOCK_DIR/pid"
      return 0
    fi
    pid="$(cat "$APM_LOCK_DIR/pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    rm -rf "$APM_LOCK_DIR"
  done
  return 1
}

if ! apm_acquire_lock; then
  apm_log "skip tick: another pull pass is already running (pid $(cat "$APM_LOCK_DIR/pid" 2>/dev/null || echo '?'))"
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/herdr-auto-pull-main.XXXXXX")"
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  rm -rf "$APM_LOCK_DIR" "$TMP"
}
trap cleanup EXIT INT TERM

PANES_TSV="$TMP/panes.tsv"      # cwd \t foreground_cwd \t agent_status \t workspace_id
CHECKOUTS_TSV="$TMP/checkouts.tsv"  # common_dir \t toplevel \t agent_status
RESULTS_TSV="$TMP/results.tsv"  # status \t name \t message \t path
: >"$PANES_TSV"; : >"$CHECKOUTS_TSV"; : >"$RESULTS_TSV"

# --- discovery ---------------------------------------------------------------

add_checkout() {
  # $1 path, $2 agent status
  local id common top
  id="$(apm_repo_identity "$1")" || return 0
  common="${id%%	*}"
  top="${id#*	}"
  printf '%s\t%s\t%s\n' "$common" "$top" "$2" >>"$CHECKOUTS_TSV"
}

if [ -n "$REPO_ARGS" ]; then
  printf '%s' "$REPO_ARGS" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    add_checkout "$p" "manual"
  done
else
  if ! apm_herdr_panes_tsv >"$PANES_TSV"; then
    apm_log "error: could not list Herdr panes (is the server running, is jq or python3 installed?)"
    exit 0
  fi
  # Collect unique cwds first so each path is resolved once.
  cut -f1,2 "$PANES_TSV" | tr '\t' '\n' | awk 'NF && !seen[$0]++' | while IFS= read -r cwd; do
    # Busy if any pane rooted in this cwd has a busy agent state.
    status="idle"
    busy_states="$(printf '%s' "${AUTO_PULL_BUSY_AGENT_STATES:-working}" | tr ',' ' ')"
    while IFS=$'\t' read -r pcwd pfcwd pstatus _; do
      if [ "$pcwd" = "$cwd" ] || [ "$pfcwd" = "$cwd" ]; then
        for s in $busy_states; do
          [ "$pstatus" = "$s" ] && status="working"
        done
      fi
    done <"$PANES_TSV"
    add_checkout "$cwd" "$status"
  done
fi

REPOS="$(cut -f1 "$CHECKOUTS_TSV" | sort -u)"

# --- helpers -----------------------------------------------------------------

record() {
  # $1 status (pulled|uptodate|ahead|skipped|error), $2 name, $3 message, $4 path
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$RESULTS_TSV"
  if [ "$1" != "uptodate" ] || [ "$MANUAL" = 1 ] || [ -n "${APM_VERBOSE:-}" ]; then
    apm_log "$2: $1: $3"
  fi
}

# Prints TSV rows "path \t branch_ref \t kind" where kind is bare|detached|branch.
parse_worktrees() {
  awk '
    function flush() {
      if (path != "") printf "%s\t%s\t%s\n", path, branch, kind
      path = ""; branch = ""; kind = "branch"
    }
    /^worktree / { flush(); path = substr($0, 10) }
    /^branch /   { branch = substr($0, 8) }
    /^bare$/     { kind = "bare" }
    /^detached$/ { kind = "detached" }
    END { flush() }
  '
}

path_matches_list() {
  # $1 path, $2 colon-separated glob list. Matches the path as reported by git
  # and its symlink-resolved form, so /tmp-style symlinks do not matter.
  local p="$1" list="$2" pat real old_ifs
  [ -n "$list" ] || return 1
  real="$(apm_realpath "$p" 2>/dev/null || printf '%s' "$p")"
  old_ifs="$IFS"
  IFS=':'
  for pat in $list; do
    IFS="$old_ifs"
    [ -n "$pat" ] || continue
    pat="${pat%/}"
    # shellcheck disable=SC2254
    case "$p" in
      $pat|$pat/*) return 0 ;;
    esac
    # shellcheck disable=SC2254
    case "$real" in
      $pat|$pat/*) return 0 ;;
    esac
  done
  IFS="$old_ifs"
  return 1
}

checkout_is_busy() {
  awk -F'\t' -v t="$1" '$2 == t && $3 == "working" { found = 1 } END { exit found ? 0 : 1 }' "$CHECKOUTS_TSV"
}

short() { printf '%s' "$1" | cut -c1-7; }

# Absolute path of a file inside the checkout's git dir (handles linked worktrees).
git_path_in() {
  local p
  p="$(apm_git -C "$1" rev-parse --git-path "$2" 2>/dev/null || true)"
  [ -n "$p" ] || { printf '%s\n' "$1/.git/$2"; return; }
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    *) printf '%s\n' "$1/$p" ;;
  esac
}

# --- per-repo logic ----------------------------------------------------------

pull_repo() {
  local common="$1"
  local wts primary name kind remote branch enabled
  local fetch_out fetch_rc local_sha remote_sha behind ahead checkout
  local n_files st out require_clean f p

  wts="$(apm_git --git-dir="$common" worktree list --porcelain 2>/dev/null | parse_worktrees)"
  if [ -z "$wts" ]; then
    record error "$(basename "$common")" "git worktree list failed" "$common"
    return
  fi
  primary="$(printf '%s\n' "$wts" | head -n1 | cut -f1)"
  kind="$(printf '%s\n' "$wts" | head -n1 | cut -f3)"
  name="$(basename "$primary")"
  [ "$kind" = "bare" ] && name="${name%.git}"

  # include / exclude lists (match against the primary checkout path)
  if [ -n "$AUTO_PULL_INCLUDE" ] && ! path_matches_list "$primary" "$AUTO_PULL_INCLUDE"; then
    record skipped "$name" "not in AUTO_PULL_INCLUDE" "$primary"
    return
  fi
  # shellcheck disable=SC2153
  if path_matches_list "$primary" "$AUTO_PULL_EXCLUDE"; then
    record skipped "$name" "matched AUTO_PULL_EXCLUDE" "$primary"
    return
  fi

  # per-repo opt out / overrides via git config
  enabled="$(apm_git --git-dir="$common" config --get autoPullMain.enabled 2>/dev/null || true)"
  if [ -n "$enabled" ] && ! apm_is_true "$enabled"; then
    record skipped "$name" "disabled by git config autoPullMain.enabled" "$primary"
    return
  fi
  remote="$(apm_git --git-dir="$common" config --get autoPullMain.remote 2>/dev/null || true)"
  [ -n "$remote" ] || remote="$AUTO_PULL_REMOTE"
  branch="$(apm_git --git-dir="$common" config --get autoPullMain.branch 2>/dev/null || true)"
  [ -n "$branch" ] || branch="$AUTO_PULL_BRANCH"
  require_clean="$(apm_git --git-dir="$common" config --get autoPullMain.requireClean 2>/dev/null || true)"
  [ -n "$require_clean" ] || require_clean="$AUTO_PULL_REQUIRE_CLEAN"

  if ! apm_git --git-dir="$common" config --get "remote.$remote.url" >/dev/null 2>&1; then
    record skipped "$name" "no remote named '$remote'" "$primary"
    return
  fi

  # resolve the default branch
  if [ -z "$branch" ]; then
    branch="$(apm_git --git-dir="$common" symbolic-ref -q --short "refs/remotes/$remote/HEAD" 2>/dev/null || true)"
    branch="${branch#"$remote/"}"
  fi
  if [ -z "$branch" ]; then
    for cand in main master trunk; do
      if apm_git --git-dir="$common" rev-parse -q --verify "refs/heads/$cand" >/dev/null 2>&1 \
        || apm_git --git-dir="$common" rev-parse -q --verify "refs/remotes/$remote/$cand" >/dev/null 2>&1; then
        branch="$cand"; break
      fi
    done
  fi
  if [ -z "$branch" ]; then
    record skipped "$name" "could not determine the default branch (set AUTO_PULL_BRANCH or git config autoPullMain.branch)" "$primary"
    return
  fi

  # fetch (always safe; never touches the working tree)
  fetch_out="$(GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 apm_run_timeout "$AUTO_PULL_FETCH_TIMEOUT" \
    git --git-dir="$common" fetch --quiet "$remote" "+refs/heads/$branch:refs/remotes/$remote/$branch" 2>&1)"
  fetch_rc=$?
  if [ "$fetch_rc" -ne 0 ]; then
    if [ "$fetch_rc" -eq 142 ] || [ "$fetch_rc" -eq 143 ]; then
      record error "$name" "fetch timed out after ${AUTO_PULL_FETCH_TIMEOUT}s" "$primary"
    else
      record error "$name" "fetch failed: $(printf '%s' "$fetch_out" | tr '\n' ' ' | cut -c1-200)" "$primary"
    fi
    return
  fi

  remote_sha="$(apm_git --git-dir="$common" rev-parse -q --verify "refs/remotes/$remote/$branch^{commit}" 2>/dev/null || true)"
  if [ -z "$remote_sha" ]; then
    record skipped "$name" "branch '$branch' not found on remote '$remote'" "$primary"
    return
  fi
  local_sha="$(apm_git --git-dir="$common" rev-parse -q --verify "refs/heads/$branch^{commit}" 2>/dev/null || true)"
  if [ -z "$local_sha" ]; then
    record skipped "$name" "no local branch '$branch'" "$primary"
    return
  fi

  if [ "$local_sha" = "$remote_sha" ]; then
    record uptodate "$name" "$branch is up to date ($(short "$local_sha"))" "$primary"
    return
  fi
  if apm_git --git-dir="$common" merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null; then
    ahead="$(apm_git --git-dir="$common" rev-list --count "$remote_sha..$local_sha" 2>/dev/null || echo '?')"
    record ahead "$name" "$branch is $ahead commit(s) ahead of $remote/$branch; nothing to pull" "$primary"
    return
  fi
  if ! apm_git --git-dir="$common" merge-base --is-ancestor "$local_sha" "$remote_sha" 2>/dev/null; then
    ahead="$(apm_git --git-dir="$common" rev-list --count "$remote_sha..$local_sha" 2>/dev/null || echo '?')"
    behind="$(apm_git --git-dir="$common" rev-list --count "$local_sha..$remote_sha" 2>/dev/null || echo '?')"
    record skipped "$name" "$branch has diverged from $remote/$branch ($ahead local, $behind remote commits); resolve manually" "$primary"
    return
  fi
  behind="$(apm_git --git-dir="$common" rev-list --count "$local_sha..$remote_sha" 2>/dev/null || echo '?')"

  # Where is the branch checked out?
  checkout="$(printf '%s\n' "$wts" | awk -F'\t' -v b="refs/heads/$branch" '$2 == b && $3 == "branch" { print $1; exit }')"

  if [ -z "$checkout" ]; then
    if ! apm_is_true "$AUTO_PULL_UPDATE_UNCHECKED_BRANCH"; then
      record skipped "$name" "$branch is not checked out and AUTO_PULL_UPDATE_UNCHECKED_BRANCH is off" "$primary"
      return
    fi
    # Compare-and-swap so a concurrent commit on the branch can never be lost.
    if out="$(apm_git --git-dir="$common" update-ref -m "herdr-auto-pull-main: fast-forward to $remote/$branch" \
        "refs/heads/$branch" "$remote_sha" "$local_sha" 2>&1)"; then
      record pulled "$name" "fast-forwarded $branch $(short "$local_sha")..$(short "$remote_sha") ($behind commits; branch not checked out)" "$primary"
    else
      record error "$name" "update-ref failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" "$primary"
    fi
    return
  fi

  if [ ! -d "$checkout" ]; then
    record skipped "$name" "checkout of $branch is missing on disk: $checkout" "$primary"
    return
  fi

  if apm_is_true "$AUTO_PULL_SKIP_WHILE_AGENT_WORKING" && checkout_is_busy "$(apm_realpath "$checkout")"; then
    record skipped "$name" "an agent is working in $checkout" "$checkout"
    return
  fi

  for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG rebase-merge rebase-apply; do
    if [ -e "$(git_path_in "$checkout" "$f")" ]; then
      record skipped "$name" "a git operation is in progress in $checkout ($f)" "$checkout"
      return
    fi
  done

  if [ -e "$(git_path_in "$checkout" index.lock)" ]; then
    record skipped "$name" "index.lock present in $checkout (another git process is running)" "$checkout"
    return
  fi

  case "$require_clean" in
    all|untracked) st="$(apm_git -C "$checkout" status --porcelain --untracked-files=normal 2>&1)" ;;
    none) st="" ;;
    *) st="$(apm_git -C "$checkout" status --porcelain --untracked-files=no 2>&1)" ;;
  esac
  if [ -n "$st" ]; then
    n_files="$(printf '%s\n' "$st" | wc -l | tr -d ' ')"
    record skipped "$name" "uncommitted changes in $checkout ($n_files path(s))" "$checkout"
    return
  fi

  if out="$(apm_git -C "$checkout" merge --ff-only --no-edit --quiet "refs/remotes/$remote/$branch" 2>&1)"; then
    record pulled "$name" "fast-forwarded $branch $(short "$local_sha")..$(short "$remote_sha") ($behind commits) in $checkout" "$checkout"
    if apm_is_true "$AUTO_PULL_SUBMODULES"; then
      if ! out="$(GIT_TERMINAL_PROMPT=0 apm_run_timeout "$AUTO_PULL_FETCH_TIMEOUT" git -C "$checkout" submodule update --init --recursive --quiet 2>&1)"; then
        apm_log "$name: warning: submodule update failed: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
      fi
    fi
  else
    record error "$name" "fast-forward merge failed in $checkout: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)" "$checkout"
  fi
}

# --- run ---------------------------------------------------------------------

if [ -z "$REPOS" ]; then
  if [ -n "$REPO_ARGS" ]; then
    record skipped "$(printf '%s' "$REPO_ARGS" | head -n1)" "not inside a git repository" ""
  else
    apm_log "tick: no git repositories found in open Herdr panes"
  fi
fi

printf '%s\n' "$REPOS" | while IFS= read -r common; do
  [ -n "$common" ] || continue
  pull_repo "$common"
done

# --- summary, last-run file, notifications -----------------------------------

count() { awk -F'\t' -v s="$1" '$1 == s { n++ } END { print n + 0 }' "$RESULTS_TSV"; }
n_total="$(wc -l <"$RESULTS_TSV" | tr -d ' ')"
n_pulled="$(count pulled)"; n_up="$(count uptodate)"; n_ahead="$(count ahead)"
n_skipped="$(count skipped)"; n_error="$(count error)"

summary="$n_total repo(s): $n_pulled pulled, $n_up up to date, $n_ahead ahead, $n_skipped skipped, $n_error error(s)"
apm_log "tick: $summary"

{
  printf 'last run: %s%s\n' "$(apm_now)" "$([ "$MANUAL" = 1 ] && printf ' (manual)')"
  printf 'summary:  %s\n\n' "$summary"
  awk -F'\t' '{ printf "%-9s %-28s %s\n", $1, $2, $3 }' "$RESULTS_TSV"
} >"$APM_LAST_RUN_FILE.tmp" && mv -f "$APM_LAST_RUN_FILE.tmp" "$APM_LAST_RUN_FILE"

lines_for() {
  awk -F'\t' -v s="$1" '$1 == s { printf "%s: %s\n", $2, $3 }' "$RESULTS_TSV"
}

body=""
mode="$(printf '%s' "$AUTO_PULL_NOTIFY" | tr '[:upper:]' '[:lower:]')"
if [ "$MANUAL" = 1 ]; then
  body="$summary"
  for s in pulled skipped error ahead; do
    l="$(lines_for "$s")"; [ -n "$l" ] && body="$body"$'\n'"$l"
  done
else
  case "$mode" in
    none|off|false) ;;
    updates) [ "$n_pulled" -gt 0 ] && body="$(lines_for pulled)" ;;
    errors) [ "$n_error" -gt 0 ] && body="$(lines_for error)" ;;
    all)
      for s in pulled skipped error; do
        l="$(lines_for "$s")"; [ -n "$l" ] && body="${body:+$body"$'\n'"}$l"
      done ;;
    *) [ "$n_pulled" -gt 0 ] && body="$(lines_for pulled)" ;;
  esac
fi

if [ -n "$body" ]; then
  if [ "$n_pulled" -gt 0 ]; then title="Auto Pull Main: pulled $n_pulled repo(s)"
  elif [ "$n_error" -gt 0 ]; then title="Auto Pull Main: $n_error error(s)"
  else title="Auto Pull Main"; fi
  apm_notify "$title" "$(printf '%s' "$body" | head -n 8)"
fi

exit 0
