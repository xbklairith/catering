# catering

Run one Claude Code session that manages all the other coding agents on your machine.

If you keep many agents open at once — several Claude Code sessions, plus agy, codex or
others in [herdr](https://herdr.dev) panes — you end up switching panes just to find out
which one is stuck on a permission prompt, which one finished, and which ones are still on
an old Claude Code version. `catering` gives a "manager" session the scripts and the skill
to do that for you:

- **See the fleet:** status, Claude Code version, session ID and remote-control link of every agent.
- **Unblock agents:** show what each blocked agent is waiting on, approve the safe prompts,
  and bring the rest to you.
- **Start agents:** open a project in a new herdr workspace with an agent in it, optionally
  in `--dangerously-skip-permissions` mode with `/remote-control` on.
- **Update without disruption:** restart idle sessions onto a newly installed Claude Code
  version, resuming the same session with the same flags, and leave busy ones alone.
- **Diagnose:** find stuck background loops, and catch CPU-heavy `find` runs and the
  session that started them.

Works on macOS and Linux.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Scripts](#scripts)
- [Local knowledge and scripts](#local-knowledge-and-scripts)
- [Safety](#safety)
- [Troubleshooting](#troubleshooting)
- [Development](#development)

## Requirements

| Tool | Why |
|---|---|
| [herdr](https://herdr.dev) | terminal workspaces for agents; the scripts drive panes through its CLI |
| [Claude Code](https://claude.com/claude-code) | runs the manager session and most of the managed agents |
| `zsh` | all scripts are zsh |
| `jq` | herdr and Claude Code session metadata are JSON |
| `pgrep`, `ps` | process checks (`procps` on Linux) |

The manager session must run **inside a herdr pane** (herdr sets `HERDR_PANE_ID`).

## Install

Clone the repo next to your projects. The scripts treat the repo's parent directory as the
projects directory.

```bash
git clone https://github.com/xbklairith/catering.git ~/projects/catering
~/projects/catering/install.sh
~/projects/catering/scripts/selftest.sh
```

`install.sh`:

- checks that `zsh`, `jq`, `pgrep` and `ps` exist, and warns if `herdr` or `claude` are missing
- links the `fleet` skill into `~/.claude/skills/fleet`, so sessions started in any
  directory can use it (re-running it is safe)
- creates `local/` from `local.example/` on first run (see [below](#local-knowledge-and-scripts))

If your projects live elsewhere, set `FLEET_PROJECTS`:

```bash
export FLEET_PROJECTS=~/code
```

## Quick start

In a herdr pane, start Claude Code in the repo:

```bash
cd ~/projects/catering && claude
```

Then ask in plain language. The `fleet` skill maps requests to the scripts:

| You say | The manager does |
|---|---|
| "status" / "which agents are busy?" | `fleet-status.sh` plus `herdr workspace list` |
| "what's blocked?" | `blocked.sh`, then approves safe prompts and asks you about the rest |
| "start claude in yolo mode with remote control on myapp" | `start-agent.sh ~/projects/myapp --yolo --rc` and gives you the link |
| "update the sessions to the new Claude Code" | `restart-idle.sh --dry-run`, then `restart-idle.sh` |
| "restart yourself" | `restart-self.sh` |
| "why won't that session restart?" | `stuck-loops.sh` |
| "why is find eating my CPU?" | `find-watch.sh` |

You can also run any script directly from a shell.

## How it works

The manager has two ways to reach other sessions:

- **herdr** for anything in a terminal pane on this machine: list agents and their state
  (`working`, `blocked`, `idle`, `done`, `unknown`), read a pane's screen, start an agent,
  submit a prompt, send keys.
- **Claude Code's peer messaging** (`ListAgents` / `SendMessage`) to reach Claude sessions
  herdr can't see, including Remote Control sessions on other machines.

Claude Code keeps per-process metadata in `~/.claude/sessions/<pid>.json` (session ID,
version, name, remote-control bridge, status). The scripts map a herdr pane to its
`claude` process and read that file. Restarting a session means sending `/exit`, then
starting `claude <same flags> --resume <same session id>` in the same pane. The
conversation, permission mode and remote-control link all carry over.

### Approval policy for blocked agents

The manager auto-approves prompts for read-only or safe actions: reading files, search,
tests, lint, type checks, and local builds. It asks you first before approving anything that
writes or deletes files, pushes, deploys, touches secrets or live databases, spends money,
or answers a design or product question. It reports every approval it makes. Change the
policy in `CLAUDE.md`, or override it for one machine in `local/notes.md`.

## Scripts

All scripts are in `scripts/` and print their usage in the header comment.

### `fleet-status.sh`

One row per Claude Code pane: pane, status, PID, version, session ID, name,
remote-control session, launch flags. The first line shows the latest installed version.

### `blocked.sh [lines]`

For every blocked agent, the bottom of its screen (default 25 lines): the permission
prompt or question it's waiting on.

### `start-agent.sh <dir> [options] [-- agent args]`

Creates a herdr workspace in `<dir>` and starts an agent in it.

| Option | Effect |
|---|---|
| `--yolo` | Claude Code with `--dangerously-skip-permissions` |
| `--rc` | runs `/remote-control` and prints the claude.ai link |
| `--label NAME` | workspace label and agent name (default: directory name) |
| `--kind KIND` | any herdr agent kind: `claude` (default), `agy`, `codex`, ... |
| `--force` | create a workspace even if agents already run in `<dir>` |

If the agent stops at a startup prompt (Claude Code asks whether to trust a new folder),
the script exits with code 2 and names the pane, so you can answer it.

```bash
scripts/start-agent.sh ~/projects/myapp --yolo --rc
```

### `restart-idle.sh [--dry-run] [pane...]`

Restarts idle or finished Claude Code sessions that are behind the installed version (or
only the panes you name), resuming each one's session ID with its original flags, then
checks that the same session came back. Always try `--dry-run` first.

It **skips**:

- its own pane
- agents that are working, blocked or unknown (it checks again right before acting)
- sessions with a background shell (`run_in_background` jobs, monitors)
- sessions with unsent text in the input box, or whose input box can't be read
- sessions with scheduled tasks: Claude Code shows "Background work is running" on
  `/exit`; the script presses Esc and leaves the session running
- sessions whose `/exit` asks about an unsent feedback draft: Esc would discard it, so the
  script leaves that dialog open and reports `NEEDS YOU`

Grey suggested-prompt text in the input box is not counted as unsent input.

### `restart-self.sh [extra claude flags]`

Restarts the session that calls it, through a detached helper. The helper waits for the
current turn to end, sends `/exit`, and relaunches with the same flags and session ID. It
gives up rather than interrupting if the session isn't idle within 20 minutes or has unsent
input. Logs go to `logs/`.

### `stuck-loops.sh [minutes]`

Background shells under Claude Code sessions older than N minutes (default 30), oldest
first. When a shell is waiting on a task's output file, it shows that file's last lines.
That's how you spot a dead wait, such as a loop polling for `error` when the task crashed
with `FileNotFoundError`.

### `find-watch.sh [seconds]`

Watches for `find` processes for N seconds (default 300, `0` = forever) and prints each
command with the Claude Code session that launched it. Inside Claude Code shells `find`
runs as the bundled `bfs`, so both names are matched.

### `selftest.sh`

Syntax-checks every script (including `local/scripts/`) and unit-tests the shared helpers.
Needs only `zsh` and `jq`, and starts or stops nothing. Run it after installing, after
pulling, and after editing a script.

### `lib.sh`

Shared helpers, sourced by the other scripts:

| Name | Purpose |
|---|---|
| `FLEET_HOME`, `FLEET_PROJECTS`, `FLEET_LOCAL` | repo root, projects directory, local layer |
| `require cmd...` | exit with a clear message if a command is missing |
| `agent_name text` | turn text into a valid herdr agent name |
| `pane_claude_pid pane`, `pane_claude_args pane` | the `claude` process in a pane and its argv |
| `strip_resume array args...` | args without `--resume`/`-r <id>`/`--continue`/`-c` |
| `child_pids pid`, `job_shells pid` | child processes; background shells of a session |
| `pane_draft pane` | unsent text in a Claude Code input box |
| `exit_blocker pane` | which dialog kept `/exit` from exiting: `scheduled`, `feedback` or empty |

## Local knowledge and scripts

Every machine is different: which sessions run cron jobs, which projects spawn extra
agents, which directories make `find` crawl. Keep that in `local/`, which is gitignored:

```
local/
  notes.md      # facts and policy overrides for this machine
  scripts/      # scripts that only make sense here
```

`install.sh` creates it from [`local.example/`](local.example/). The manager reads
`local/notes.md` before acting and uses a `local/scripts/` script when one fits. List each
local script in `notes.md`, with when to use it. Local scripts can use the shared helpers:

```zsh
source ${0:A:h:h:h}/scripts/lib.sh
require herdr jq
```

Nothing machine-specific — paths, project or session names, hosts — belongs in committed
files.

## Safety

- **`--yolo --rc` gives full control to anyone holding the link.** A session started with
  both runs any command with no permission prompts, driven from the remote-control link.
  Treat those links like passwords. The manager tells you whenever it creates one.
- **Restarts end a process.** The conversation survives because it's resumed, but anything
  that lived only in that process does not. `restart-idle.sh` skips sessions with visible
  work in flight, but run `--dry-run` and read the list first.
- **The manager asks before destructive steps.** It won't close a workspace, close a pane
  or kill a process without your OK.

## Troubleshooting

**`missing required command(s): herdr claude`**: the script needs them on `PATH`. In a
cron job or a fresh shell, check `PATH`.

**`restart-idle.sh` skips a session with "background shell running"**: run
`stuck-loops.sh 0` to see the shell. If its task already finished, the shell is a dead wait;
stop it, then rerun.

**A session stays on the old version**: it has scheduled tasks. Restarting would delete
them, so the script leaves it. Recreate the tasks after a manual restart, or wait until
they are no longer needed.

**`restart-self.sh` did nothing**: read the newest `logs/restart-self-*.log`. It aborts if
the session never went idle or the input box had text.

**Every pane is skipped with "unsent input"**: please open an issue with the output of
`herdr pane read <pane>` for one of them; the input-box detection may not match your
Claude Code version.

## Development

- Scripts are zsh, `set -uo pipefail` or stricter, sourcing `lib.sh` for anything shared.
- Keep them portable: test on macOS and on Linux. The Linux run can be a container:

  ```bash
  docker run --rm -v "$PWD":/repo:ro debian:stable-slim bash -c \
    'apt-get update -qq && apt-get install -y -qq zsh jq procps >/dev/null && cp -a /repo /c && /c/scripts/selftest.sh'
  ```

- Run `scripts/selftest.sh` before committing.

No license has been chosen yet, so by default all rights are reserved. Open an issue if you
want to reuse the code.
