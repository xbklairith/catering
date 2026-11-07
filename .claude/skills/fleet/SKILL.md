---
name: fleet
description: Manage the AI agent fleet on this machine — Claude Code sessions, herdr workspaces/panes, and other coding agents (agy, codex, ...). Use when the user asks for agent/session status, what is blocked, to start an agent on a project (yolo, remote control), to restart sessions onto a new Claude Code version, to restart this manager session, to save the fleet before a reboot or bring it back after one (or after a herdr restart), to find stuck background loops, or why find/bfs is eating CPU.
---

# Fleet manager

Scripts are in `scripts/` under this skill's base directory (a link to the repo's
`scripts/`); call them by that full path.

**Local layer (gitignored, per machine):** `local/` under the base directory links to the
repo's `local/`. When it exists, read `local/notes.md` first — machine facts, policy
overrides, and the list of `local/scripts/*` with when to use each. Prefer a local script
over improvising when it covers the ask. New machine-specific knowledge or scripts go
there, never into committed files. All herdr output is JSON;
`agent_status` is `working | blocked | idle | done | unknown`.

## Two control channels

- **herdr** — terminal panes on this machine: list, read screen, start/prompt agents, send keys.
- **SendMessage / ListAgents** (Claude Code tools, may need loading via ToolSearch) — every
  Claude peer session, including Remote Control sessions on other machines that herdr
  cannot see. Use it to message a Claude session; use herdr to drive a terminal.

## Tasks

| Ask | Do |
|---|---|
| Status | `fleet-status.sh` (claude panes: pid, version, session id, remote link, flags) plus `herdr workspace list`; `ListAgents` for non-herdr peers |
| What's blocked | `blocked.sh` → apply the approval policy below |
| Start agent on project | `start-agent.sh <dir> [--yolo] [--rc] [--label NAME] [--kind agy] [--force]` (refuses a dir that already has agents) |
| Update sessions to new CLI | `restart-idle.sh --dry-run`, then `restart-idle.sh` (or list panes) |
| Restart this session | `restart-self.sh` — detached helper, waits for the turn to end; end the turn right after |
| Before a reboot | `save-fleet.sh` (snapshot: pane, dir, session id, launch flags; also Claude sessions outside herdr) |
| Save automatically | `autosave.sh install` (every 15 min: launchd on macOS, cron on Linux); `autosave.sh status` shows the newest snapshot and the log |
| After a reboot or herdr restart | `restore-fleet.sh --dry-run`, then `restore-fleet.sh`; it resumes or re-flags each agent. A `SELF` line means this session lacks its flags: run the printed `restart-self.sh` line and end the turn. Pass on its "resume by hand" lines to the user |
| Session won't restart | `stuck-loops.sh` → report dead waits; kill only with user OK |
| `find` eating CPU | `find-watch.sh 300` — prints the find/bfs command and its owning session |
| After install / pull | `selftest.sh` |

## Approval policy for blocked agents

Auto-approve read-only or safe actions: reads, search, tests, lint, type check, local build.
Ask the user first for anything that writes/deletes files, pushes, deploys, touches live
databases or secrets, spends money, or is a design/product question. Read the script a
prompt wants to run before classifying it. Report every auto-approval. Answer a menu with
`herdr pane send-keys <pane> ...`: read the screen first, move the `❯`/`>` cursor with
`up`/`down` to the option, press `enter`, then read the screen again to confirm. Pressing a
digit to pick an option is untested; do not rely on it.

Always ask before closing a workspace/pane or killing a process. `local/notes.md` may
override this policy for the machine.

## Gotchas

- **Session metadata:** `~/.claude/sessions/<pid>.json` has `sessionId`, `version`, `name`,
  `bridgeSessionId` (remote control), `status`. Map pane → pid with
  `herdr pane process-info --pane <id>`.
- **Restart = `/exit` + `claude <same flags> --resume <sessionId>`.** Remote-control links
  survive. herdr agent names may change (derived names); session ids do not.
- **Scheduled tasks on `/exit`.** Claude Code shows "Background work is running";
  `restart-idle.sh` presses `esc` and leaves the session. Restarting by hand with "Exit and
  stop tasks" + `--resume` brings session-only tasks back with the same ids: check `CronList`
  and never re-create them (that doubles every job). They expire 7 days after they were made,
  resumed or not.
- **herdr restores Claude without its flags.** After a reboot or server restart herdr
  relaunches each Claude pane as a bare `claude --resume <id>`: permission mode, `--add-dir`
  and the rest are gone. `restore-fleet.sh` puts them back from the newest `save-fleet.sh`
  snapshot; `save-fleet.sh` refuses to overwrite a snapshot with that flag-less state.
- **After a reboot, saving waits for the restore.** Until `restore-fleet.sh` has run (not
  `--dry-run`), `save-fleet.sh` and autosave exit 2 instead of saving a half-restored fleet.
  `save-fleet.sh --force` only when the user doesn't want the old fleet back.
- **A reboot loses** unsent input-box text, files in `/tmp` (Claude Code scratchpads live
  there), and every running process. Before a planned reboot, check `blocked.sh` and drafts.
- **"You have 1 unsent feedback draft" on `/exit`:** never press `esc` there, it discards the
  user's feedback. Leave the dialog open and tell the user.
- **Grey text after `❯` is Claude Code's suggested prompt, not a draft.** It is drawn dim
  (`ESC[2m`); `pane_draft` reads `--format ansi` and ignores dim text.
- **New folder → "trust this folder?" prompt.** `start-agent.sh` exits 2 and leaves it for
  you; read the pane, accept only for the user's own project folders.
- **Background shells block restarts.** `until grep -q pattern file; do sleep 5; done` can
  wait forever if the task crashed with a different word (`FileNotFoundError` ≠ `error`).
  `stuck-loops.sh` shows the waited-on output so you can tell.
- **An idle-looking session may have just started a background job** (e.g. an e2e run);
  `restart-idle.sh` checks for job shells right before acting.
- **`find` inside Claude Code shells runs as `bfs`** (`bfs -S dfs -regextype findutils-default`).
  Huge trees (vendored corpora, node_modules) make it CPU-heavy; prefer `rg`/`fd`.
- **macOS vs Linux:** macOS `ps` has no `etimes` (parse `etime`); macOS `pgrep` hides its
  own ancestors (`-a`), Linux `pgrep -a` prints command lines instead — use `child_pids`
  from `lib.sh`. In zsh a bare `=====` word is a command; quote separators. Expanding an
  array inside double quotes or a heredoc joins it unless the `@` flag is used.
- **Yolo + remote control** = anyone with the link runs anything on this machine. Say so
  whenever one is created.
