#!/usr/bin/env bash
# Integration tests for bin/pull.sh using throwaway git repos and a fake herdr.
# No running Herdr is needed. Usage: bash tests/run.sh [-v]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d "${TMPDIR:-/tmp}/apm-tests.XXXXXX")"
T="$(cd "$T" && pwd -P)"   # canonical path: macOS puts temp dirs behind a /var -> /private/var symlink
trap 'rm -rf "$T"' EXIT
[ "${1:-}" = "-v" ] && export APM_VERBOSE=1

export HOME="$T/home"
mkdir -p "$HOME" "$T/state" "$T/config" "$T/remotes" "$T/work"
export HERDR_PLUGIN_STATE_DIR="$T/state"
export HERDR_PLUGIN_CONFIG_DIR="$T/config"
export HERDR_BIN_PATH="$T/fake-herdr"
export HERDR_SOCKET_PATH="$T/fake.sock"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$T/gitconfig"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always

FAKE_PANES="$T/panes.json"
printf '{"result":{"panes":[]}}' >"$FAKE_PANES"
cat >"$HERDR_BIN_PATH" <<FAKE
#!/usr/bin/env bash
case "\$1 \$2" in
  "pane list") cat "$FAKE_PANES" ;;
  "notification show") printf '%s\n' "\$*" >>"$T/notifications" ;;
  "plugin config-dir") printf '%s\n' "$T/config" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$HERDR_BIN_PATH"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

# --- git fixtures ------------------------------------------------------------

make_remote() { # name [branch]
  local name="$1" branch="${2:-main}" tmp
  tmp="$T/work/seed-$name"
  git init -q --bare -b "$branch" "$T/remotes/$name.git"
  git init -q -b "$branch" "$tmp"
  echo "hello" >"$tmp/README.md"
  git -C "$tmp" add . && git -C "$tmp" commit -q -m "initial"
  git -C "$tmp" remote add origin "$T/remotes/$name.git"
  git -C "$tmp" push -q origin "$branch"
  rm -rf "$tmp"
}

push_remote() { # name branch msg  -> adds a commit to the remote branch
  local name="$1" branch="$2" msg="$3" tmp
  tmp="$T/work/push-$name-$RANDOM"
  git clone -q "$T/remotes/$name.git" "$tmp"
  git -C "$tmp" checkout -q "$branch"
  echo "$msg" >>"$tmp/CHANGES"
  git -C "$tmp" add . && git -C "$tmp" commit -q -m "$msg"
  git -C "$tmp" push -q origin "$branch"
  rm -rf "$tmp"
}

clone_repo() { # name -> path
  local name="$1" dst
  dst="$T/work/$name"
  git clone -q "$T/remotes/$name.git" "$dst"
  printf '%s\n' "$dst"
}

remote_sha() { git --git-dir="$T/remotes/$1.git" rev-parse "refs/heads/${2:-main}"; }

run_pull() { bash "$ROOT/bin/pull.sh" "$@"; }

result_status() { # name -> status column from last-run
  awk -v n="$1" '$2 == n { print $1; exit }' "$HERDR_PLUGIN_STATE_DIR/last-run.txt"
}

expect_status() { # testname repo-name expected
  local got
  got="$(result_status "$2")"
  if [ "$got" = "$3" ]; then pass "$1"; else fail "$1" "expected $3, got '${got:-<none>}' ($(grep " $2 " "$HERDR_PLUGIN_STATE_DIR/last-run.txt" | head -n1))"; fi
}

expect_true() { # testname cond...
  local name="$1"; shift
  if "$@"; then pass "$name"; else fail "$name"; fi
}

expect_eq() { # testname actual expected
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}

echo "duration parsing"
. "$ROOT/bin/lib.sh"
expect_eq "5m -> 300" "$(apm_parse_duration 5m)" 300
expect_eq "90s -> 90" "$(apm_parse_duration 90s)" 90
expect_eq "2h -> 7200" "$(apm_parse_duration 2h)" 7200
expect_eq "300 -> 300" "$(apm_parse_duration 300)" 300
if apm_parse_duration abc >/dev/null 2>&1; then fail "abc rejected"; else pass "abc rejected"; fi

echo "config loading"
printf 'AUTO_PULL_INTERVAL="7m"\nAUTO_PULL_NOTIFY=all\nPATH=/evil\n# comment\n' >"$HERDR_PLUGIN_CONFIG_DIR/config.env"
( apm_load_config; expect_eq "quoted interval read" "$AUTO_PULL_INTERVAL_SECONDS" 420; expect_eq "notify read" "$AUTO_PULL_NOTIFY" all; expect_eq "non AUTO_PULL keys ignored" "$PATH" "$PATH" )
rm -f "$HERDR_PLUGIN_CONFIG_DIR/config.env"

echo "fast-forward of a clean checked-out main"
make_remote clean; r="$(clone_repo clean)"; push_remote clean main "c1"; push_remote clean main "c2"
run_pull --repo "$r"
expect_status "status is pulled" clean pulled
expect_eq "HEAD moved to remote" "$(git -C "$r" rev-parse HEAD)" "$(remote_sha clean)"
run_pull --repo "$r"
expect_status "second run is up to date" clean uptodate

echo "dirty tracked file blocks the pull"
make_remote dirty; r="$(clone_repo dirty)"; before="$(git -C "$r" rev-parse HEAD)"; push_remote dirty main "c1"
echo "edit" >>"$r/README.md"
run_pull --repo "$r"
expect_status "status is skipped" dirty skipped
expect_eq "HEAD unchanged" "$(git -C "$r" rev-parse HEAD)" "$before"
expect_eq "remote-tracking ref still fetched" "$(git -C "$r" rev-parse origin/main)" "$(remote_sha dirty)"

echo "staged change blocks the pull"
git -C "$r" checkout -q -- README.md; echo new >"$r/new.txt"; git -C "$r" add new.txt
run_pull --repo "$r"
expect_status "status is skipped" dirty skipped
git -C "$r" reset -q

echo "untracked files: allowed with tracked, blocked with all"
make_remote untracked; r="$(clone_repo untracked)"; push_remote untracked main "c1"
echo scratch >"$r/scratch.txt"
AUTO_PULL_REQUIRE_CLEAN=all run_pull --repo "$r"
expect_status "REQUIRE_CLEAN=all skips" untracked skipped
run_pull --repo "$r"
expect_status "REQUIRE_CLEAN=tracked pulls" untracked pulled
expect_eq "HEAD moved" "$(git -C "$r" rev-parse HEAD)" "$(remote_sha untracked)"

echo "untracked file that would be overwritten is refused by git"
make_remote clobber; r="$(clone_repo clobber)"; before="$(git -C "$r" rev-parse HEAD)"; push_remote clobber main "c1"
echo mine >"$r/CHANGES"
run_pull --repo "$r"
expect_status "status is error (git refused)" clobber error
expect_eq "HEAD unchanged" "$(git -C "$r" rev-parse HEAD)" "$before"
expect_eq "local file kept" "$(cat "$r/CHANGES")" mine

echo "local commits ahead of remote"
make_remote ahead; r="$(clone_repo ahead)"
echo x >"$r/x"; git -C "$r" add x; git -C "$r" commit -q -m local; before="$(git -C "$r" rev-parse HEAD)"
run_pull --repo "$r"
expect_status "status is ahead" ahead ahead
expect_eq "HEAD unchanged" "$(git -C "$r" rev-parse HEAD)" "$before"

echo "diverged history"
push_remote ahead main "remote-side"
run_pull --repo "$r"
expect_status "status is skipped" ahead skipped
expect_eq "HEAD unchanged" "$(git -C "$r" rev-parse HEAD)" "$before"
expect_true "message mentions diverged" grep -q "diverged" "$HERDR_PLUGIN_STATE_DIR/last-run.txt"

echo "main not checked out: ref is fast-forwarded without touching the worktree"
make_remote unchecked; r="$(clone_repo unchecked)"
git -C "$r" checkout -q -b feature; echo wip >"$r/wip"; # dirty feature branch must not matter
push_remote unchecked main "c1"
run_pull --repo "$r"
expect_status "status is pulled" unchecked pulled
expect_eq "local main ref updated" "$(git -C "$r" rev-parse main)" "$(remote_sha unchecked)"
expect_eq "still on feature" "$(git -C "$r" rev-parse --abbrev-ref HEAD)" feature
expect_true "worktree untouched" [ -f "$r/wip" ]
push_remote unchecked main "c2"
AUTO_PULL_UPDATE_UNCHECKED_BRANCH=false run_pull --repo "$r"
expect_status "disabled ref update skips" unchecked skipped

echo "main not checked out and diverged: ref is left alone"
make_remote unchecked2; r="$(clone_repo unchecked2)"
echo x >"$r/x"; git -C "$r" add x; git -C "$r" commit -q -m local-main; local_main="$(git -C "$r" rev-parse main)"
git -C "$r" checkout -q -b feature
push_remote unchecked2 main "remote-main"
run_pull --repo "$r"
expect_status "status is skipped" unchecked2 skipped
expect_eq "local main unchanged" "$(git -C "$r" rev-parse main)" "$local_main"

echo "linked worktree holds main, primary is on a feature branch"
make_remote wt; r="$(clone_repo wt)"
git -C "$r" checkout -q -b feature
git -C "$r" worktree add -q "$T/work/wt-main" main
push_remote wt main "c1"
run_pull --repo "$T/work/wt-main/"
expect_status "status is pulled" wt pulled
expect_eq "worktree HEAD moved" "$(git -C "$T/work/wt-main" rev-parse HEAD)" "$(remote_sha wt)"
expect_eq "primary HEAD untouched" "$(git -C "$r" rev-parse --abbrev-ref HEAD)" feature
push_remote wt main "c2"
echo edit >>"$T/work/wt-main/README.md"
run_pull --repo "$r"   # discovered via the primary, but the main checkout is dirty
expect_status "dirty linked worktree skips" wt skipped

echo "primary on detached HEAD, main in a linked worktree"
make_remote detached; r="$(clone_repo detached)"
git -C "$r" checkout -q --detach
git -C "$r" worktree add -q "$T/work/detached-main" main
push_remote detached main "c1"
run_pull --repo "$r"
expect_status "status is pulled" detached pulled
expect_eq "linked worktree moved" "$(git -C "$T/work/detached-main" rev-parse HEAD)" "$(remote_sha detached)"

echo "bare primary with a linked worktree on main"
make_remote bare
git clone -q --bare "$T/remotes/bare.git" "$T/work/bare-primary.git"
git -C "$T/work/bare-primary.git" worktree add -q "$T/work/bare-main" main
git -C "$T/work/bare-main" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
push_remote bare main "c1"
run_pull --repo "$T/work/bare-main"
expect_status "status is pulled" bare-primary pulled
expect_eq "worktree moved" "$(git -C "$T/work/bare-main" rev-parse HEAD)" "$(remote_sha bare)"

echo "merge in progress blocks the pull"
make_remote inprog; r="$(clone_repo inprog)"; before="$(git -C "$r" rev-parse HEAD)"; push_remote inprog main "c1"
git -C "$r" rev-parse HEAD >"$r/.git/MERGE_HEAD"
run_pull --repo "$r"
expect_status "status is skipped" inprog skipped
expect_true "message names MERGE_HEAD" grep -q "MERGE_HEAD" "$HERDR_PLUGIN_STATE_DIR/last-run.txt"
rm -f "$r/.git/MERGE_HEAD"
touch "$r/.git/index.lock"
run_pull --repo "$r"
expect_status "index.lock skips" inprog skipped
rm -f "$r/.git/index.lock"
expect_eq "HEAD unchanged" "$(git -C "$r" rev-parse HEAD)" "$before"

echo "no remote"
git init -q "$T/work/noremote"; git -C "$T/work/noremote" commit -q --allow-empty -m init
run_pull --repo "$T/work/noremote"
expect_status "status is skipped" noremote skipped

echo "not a git repo"
mkdir -p "$T/work/plain"
run_pull --repo "$T/work/plain"
expect_true "reported" grep -q "not inside a git repository" "$HERDR_PLUGIN_STATE_DIR/last-run.txt"

echo "fetch failure"
make_remote broken; r="$(clone_repo broken)"; before="$(git -C "$r" rev-parse HEAD)"
git -C "$r" remote set-url origin "$T/remotes/does-not-exist.git"
run_pull --repo "$r"
expect_status "status is error" broken error
expect_eq "HEAD unchanged" "$(git -C "$r" rev-parse HEAD)" "$before"

echo "per-repo opt out via git config"
make_remote optout; r="$(clone_repo optout)"; push_remote optout main "c1"; before="$(git -C "$r" rev-parse HEAD)"
git -C "$r" config autoPullMain.enabled false
run_pull --repo "$r"
expect_status "status is skipped" optout skipped
expect_eq "HEAD unchanged" "$(git -C "$r" rev-parse HEAD)" "$before"
git -C "$r" config --unset autoPullMain.enabled

echo "per-repo branch override and master auto-detect"
make_remote legacy master; r="$(clone_repo legacy)"; push_remote legacy master "c1"
run_pull --repo "$r"
expect_status "master detected from origin/HEAD" legacy pulled
make_remote dev; r="$(clone_repo dev)"
git -C "$r" checkout -q -b develop; git -C "$r" push -q -u origin develop; git -C "$r" checkout -q main
push_remote dev develop "d1"
git -C "$r" config autoPullMain.branch develop
run_pull --repo "$r"
expect_status "configured branch develop pulled" dev pulled
expect_eq "develop ref moved (not checked out)" "$(git -C "$r" rev-parse develop)" "$(remote_sha dev develop)"
expect_eq "main untouched" "$(git -C "$r" rev-parse main)" "$(remote_sha dev main)"

echo "exclude and include lists"
make_remote excl; r="$(clone_repo excl)"; push_remote excl main "c1"
AUTO_PULL_EXCLUDE="*/nothing:$r" run_pull --repo "$r"
expect_status "excluded" excl skipped
AUTO_PULL_INCLUDE="$T/work/other*" run_pull --repo "$r"
expect_status "not included" excl skipped
AUTO_PULL_INCLUDE="$T/work/*" run_pull --repo "$r"
expect_status "included glob pulls" excl pulled

echo "herdr discovery and busy-agent skipping"
make_remote disc; r="$(clone_repo disc)"; push_remote disc main "c1"; before="$(git -C "$r" rev-parse HEAD)"
mkdir -p "$r/src"
cat >"$FAKE_PANES" <<JSON
{"result":{"panes":[
 {"pane_id":"w1:p1","workspace_id":"w1","cwd":"$r/src","foreground_cwd":"$r","agent_status":"working"},
 {"pane_id":"w1:p2","workspace_id":"w1","cwd":"$r","agent_status":"idle"},
 {"pane_id":"w2:p1","workspace_id":"w2","cwd":"$T/work/plain","agent_status":"idle"},
 {"pane_id":"w3:p1","workspace_id":"w3","cwd":"/does/not/exist","agent_status":"idle"}
]}}
JSON
run_pull
expect_status "working agent skips" disc skipped
expect_eq "HEAD unchanged" "$(git -C "$r" rev-parse HEAD)" "$before"
expect_eq "only one repo discovered" "$(grep -c -E '^(pulled|uptodate|ahead|skipped|error) ' "$HERDR_PLUGIN_STATE_DIR/last-run.txt")" 1
AUTO_PULL_SKIP_WHILE_AGENT_WORKING=false run_pull
expect_status "busy check disabled pulls" disc pulled
push_remote disc main "c2"
sed -i.bak 's/"working"/"idle"/' "$FAKE_PANES"
run_pull
expect_status "idle agent pulls" disc pulled

echo "worktree discovered through a pane inside the linked worktree only"
make_remote disc2; r="$(clone_repo disc2)"
git -C "$r" checkout -q -b feature
git -C "$r" worktree add -q "$T/work/disc2-main" main
push_remote disc2 main "c1"
cat >"$FAKE_PANES" <<JSON
{"result":{"panes":[{"pane_id":"w1:p1","workspace_id":"w1","cwd":"$r","agent_status":"working"}]}}
JSON
run_pull
expect_status "busy primary on feature does not block main worktree" disc2 pulled
expect_eq "main worktree moved" "$(git -C "$T/work/disc2-main" rev-parse HEAD)" "$(remote_sha disc2)"

echo "notifications"
rm -f "$T/notifications"
make_remote notif; r="$(clone_repo notif)"; push_remote notif main "c1"
AUTO_PULL_NOTIFY=none run_pull --repo "$r"
expect_true "none: no toast" [ ! -e "$T/notifications" ]
push_remote notif main "c2"
run_pull --repo "$r"
expect_true "updates: toast on pull" grep -q "pulled 1 repo" "$T/notifications" 2>/dev/null
rm -f "$T/notifications"
run_pull --repo "$r"
expect_true "updates: silent when up to date" [ ! -e "$T/notifications" ]
run_pull --repo "$r" --manual
expect_true "manual: always summarises" grep -q "up to date" "$T/notifications" 2>/dev/null

echo "lock prevents overlapping passes"
mkdir -p "$HERDR_PLUGIN_STATE_DIR/tick.lock"; printf '%s\n' "$$" >"$HERDR_PLUGIN_STATE_DIR/tick.lock/pid"
push_remote notif main "c3"; before="$(git -C "$r" rev-parse HEAD)"
run_pull --repo "$r"
expect_eq "locked run does nothing" "$(git -C "$r" rev-parse HEAD)" "$before"
printf '999999\n' >"$HERDR_PLUGIN_STATE_DIR/tick.lock/pid"
run_pull --repo "$r"
expect_status "stale lock is reclaimed" notif pulled

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
