# Auto Pull Main for Herdr

A [Herdr](https://herdr.dev) plugin that keeps the main branch of every repo you
have open in Herdr fast-forwarded to its remote, on a timer. It never rewrites
history, never stashes, never merges: if the branch cannot be fast-forwarded
cleanly, it is skipped and the reason is logged.

Works with any layout:

- a session open on `main` plus feature worktrees (the branch is fast-forwarded
  in the `main` checkout when it is clean)
- everything in worktrees, `main` not checked out anywhere (the local `main` ref
  is fast-forwarded in place so new worktrees start from fresh code)
- bare repo + worktrees, detached HEADs, `master`/`trunk`/custom default branches

## Install

```sh
herdr plugin install bring-shrubbery/herdr-auto-pull-main
```

The background poller starts the next time a Herdr server starts (restart Herdr,
or run `herdr update --handoff` style handoff). To start it right away in the
current server:

```sh
herdr plugin action invoke bring-shrubbery.auto-pull-main.restart-daemon
```

Requirements: `bash` 3.2+, `git`, and either `jq` or `python3` (used to read
Herdr's JSON). macOS and Linux.

## How it works

1. A `[[startup]]` hook spawns one detached poller per Herdr server. It exits
   when the server does.
2. Every interval (default 5 minutes) the poller asks Herdr for the working
   directory of every pane, resolves each to a git repo, and de-duplicates by
   repository (worktrees of the same repo count once).
3. For each repo it runs `git fetch <remote> <branch>`, which is always safe,
   then decides:

| Situation | Result |
| --- | --- |
| Local branch equals the remote | up to date, nothing logged by default |
| Local is ahead of the remote (unpushed commits) | left alone |
| Local and remote have diverged | skipped, logged, resolve by hand |
| Branch checked out, clean, behind | `git merge --ff-only` in that checkout |
| Branch checked out but has uncommitted changes | skipped |
| Branch checked out but a merge/rebase/cherry-pick/bisect is in progress, or `index.lock` exists | skipped |
| Branch checked out and a Herdr-detected agent is `working` in that checkout | skipped |
| Branch not checked out in any worktree | local ref fast-forwarded with a compare-and-swap `update-ref` |
| No remote, remote branch missing, or no local branch | skipped |
| Fetch fails or hangs past the timeout | logged as an error, nothing changed |
| Untracked file would be overwritten | git refuses, logged as an error |

4. Newly opened workspaces and worktrees trigger a pass within seconds instead
   of waiting for the next interval.

Untracked files do not block a pull by default (git still refuses if one would
be overwritten). Set `AUTO_PULL_REQUIRE_CLEAN=all` to require a fully clean tree.

## Configuration

The config file is `config.env` in the plugin config directory. It is seeded
from `config.example.env` on first start, and changes apply on the next pass.

```sh
$EDITOR "$(herdr plugin config-dir bring-shrubbery.auto-pull-main)/config.env"
```

| Key | Default | Meaning |
| --- | --- | --- |
| `AUTO_PULL_INTERVAL` | `5m` | Poll interval: `300`, `90s`, `5m`, `1h`. Minimum 15s. |
| `AUTO_PULL_REMOTE` | `origin` | Remote to fetch from. |
| `AUTO_PULL_BRANCH` | empty | Branch to update. Empty auto-detects per repo: `origin/HEAD`, then `main`, `master`, `trunk`. |
| `AUTO_PULL_REQUIRE_CLEAN` | `tracked` | `tracked` (untracked files allowed), `all`, or `none`. |
| `AUTO_PULL_SKIP_WHILE_AGENT_WORKING` | `true` | Skip a checkout while Herdr reports a busy agent in it. |
| `AUTO_PULL_BUSY_AGENT_STATES` | `working` | Comma-separated Herdr agent states that count as busy. |
| `AUTO_PULL_UPDATE_UNCHECKED_BRANCH` | `true` | Fast-forward the local ref when the branch is not checked out anywhere. |
| `AUTO_PULL_SUBMODULES` | `false` | Run `git submodule update --init --recursive` after a fast-forward. |
| `AUTO_PULL_NOTIFY` | `updates` | Toasts for automatic passes: `none`, `updates`, `errors`, `all`. |
| `AUTO_PULL_NOTIFY_SOUND` | `none` | `none`, `done`, or `request`. |
| `AUTO_PULL_FETCH_TIMEOUT` | `60` | Seconds before a hung fetch is killed. |
| `AUTO_PULL_INCLUDE` | empty | Colon-separated globs; when set, only matching repo paths are processed. |
| `AUTO_PULL_EXCLUDE` | empty | Colon-separated globs of repo paths to skip. Wins over include. |
| `AUTO_PULL_STARTUP_DELAY` | `10` | Seconds to wait after server start before the first pass. |
| `AUTO_PULL_LOG_MAX_BYTES` | `1000000` | Log rotation threshold. |

### Per-repo overrides

Set these with `git config` inside a repo (they live in that repo's `.git/config`):

```sh
git config autoPullMain.enabled false     # opt this repo out
git config autoPullMain.branch develop    # pull a different branch here
git config autoPullMain.remote upstream   # fetch from a different remote here
git config autoPullMain.requireClean all  # stricter clean check here
```

## Actions and keybindings

| Action | What it does |
| --- | --- |
| `pull-now` | Pull every open repo immediately and show a summary toast. |
| `pull-here` | Pull only the repo behind the current pane. |
| `status` | Popup with daemon state, effective config, last run, recent log. |
| `pause` / `resume` / `toggle` | Pause or resume automatic passes (manual actions still work). |
| `restart-daemon` / `stop-daemon` | Control the background poller. |

Invoke from the CLI:

```sh
herdr plugin action invoke bring-shrubbery.auto-pull-main.pull-now
herdr plugin action invoke bring-shrubbery.auto-pull-main.status
```

Or bind keys in `config.toml`:

```toml
[[keys.command]]
key = "prefix+u"
type = "plugin_action"
command = "bring-shrubbery.auto-pull-main.pull-here"
description = "pull main here"

[[keys.command]]
key = "prefix+shift+u"
type = "plugin_action"
command = "bring-shrubbery.auto-pull-main.status"
description = "auto pull status"
```

## Files

- Config: `herdr plugin config-dir bring-shrubbery.auto-pull-main` (contains `config.env`)
- State and logs: `~/.local/state/herdr/plugins/bring-shrubbery.auto-pull-main/`
  (`auto-pull-main.log`, `last-run.txt`, `daemon-*.pid`)
- Herdr's own record of each hook run: `herdr plugin log list --plugin bring-shrubbery.auto-pull-main`

## Troubleshooting

- **Nothing happens**: check the `status` action. If the daemon is not running,
  invoke `restart-daemon`, then read `daemon.log` in the state directory.
- **A repo keeps being skipped**: the reason is in `last-run.txt` and the log.
  Dirty checkouts, diverged branches, and busy agents are skipped on purpose.
- **Credentials prompt**: fetches run with `GIT_TERMINAL_PROMPT=0`, so a remote
  that needs interactive auth fails fast and is logged as an error. Use an SSH
  agent or a credential helper.
- **Working from a local checkout**: `herdr plugin link /path/to/herdr-auto-pull-main`,
  then `restart-daemon`. Unlink before installing from GitHub.

## Development

```sh
bash tests/run.sh          # integration tests against throwaway repos, no Herdr needed
shellcheck -x bin/*.sh tests/run.sh
```

Scripts are bash 3.2 compatible (macOS default). The pull logic lives in
`bin/pull.sh` and can be run by hand: `bash bin/pull.sh --repo /path --manual --verbose`.

## License

MIT
