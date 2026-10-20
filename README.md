# catering

Scripts and a Claude Code skill for running one "manager" Claude Code session that looks
after all the other coding-agent sessions on a machine: Claude Code, plus anything else
running in [herdr](https://herdr.dev) panes (agy, codex, ...).

The manager can:

- show every agent's status, version, session ID and remote-control link
- show what each blocked agent is waiting on, and answer safe prompts for you
- open a project in a new herdr workspace and start an agent there (optionally with
  `--dangerously-skip-permissions` and `/remote-control`)
- restart idle sessions onto a newly installed Claude Code version, resuming the same
  session ID with the same flags, without touching busy ones
- restart itself the same way
- find stuck background loops, and catch CPU-heavy `find`/`bfs` runs and who started them

Works on macOS and Linux.

## Requirements

- [herdr](https://herdr.dev), with your agents running in herdr panes
- [Claude Code](https://claude.com/claude-code)
- `zsh`, `jq`, `pgrep`/`ps` (procps on Linux)

## Install

```bash
git clone https://github.com/xbklairith/catering.git ~/projects/catering
~/projects/catering/install.sh      # links the fleet skill into ~/.claude/skills
~/projects/catering/scripts/selftest.sh
```

Clone it next to your projects: the scripts treat the repo's parent directory as the
projects directory. Set `FLEET_PROJECTS=/path/to/projects` to override.

Then, inside herdr, start the manager:

```bash
cd ~/projects/catering && claude
```

and ask it things like "what's blocked?", "start claude in yolo mode with remote control on
myapp", or "restart idle sessions onto the new version".

## Scripts

| Script | What it does |
|---|---|
| `fleet-status.sh` | Claude panes: status, pid, version, session id, remote link, launch flags |
| `blocked.sh [lines]` | every blocked agent and the prompt on its screen |
| `start-agent.sh <dir> [--yolo] [--rc] [--label N] [--kind K] [--force]` | new herdr workspace + agent (+ remote-control link); refuses a dir that already has agents |
| `restart-idle.sh [--dry-run] [pane…]` | idle/done sessions → latest CLI, same session id |
| `restart-self.sh [extra flags]` | restart the calling session via a detached helper |
| `stuck-loops.sh [min]` | background shells under Claude sessions older than N minutes |
| `find-watch.sh [secs]` | catch find/bfs processes and the session that launched them |
| `selftest.sh` | syntax and unit checks (repo and `local/scripts`); needs only zsh and jq |

`restart-idle.sh` never restarts: its own pane, working/blocked agents, sessions with a
background shell, sessions with unsent text in the input box, or sessions with scheduled
tasks (it cancels the exit dialog and leaves them running).

## Local knowledge and scripts

Each machine keeps its own layer in `local/`, which is gitignored:

```
local/
  notes.md      # facts the manager should know here: quirks, cron sessions, policy overrides
  scripts/      # machine-specific scripts; list each one in notes.md
```

`install.sh` creates it from `local.example/` on first run. The skill and `CLAUDE.md` tell
the manager to read `local/notes.md` first and to use `local/scripts/` when they fit.
Local scripts can `source <repo>/scripts/lib.sh` for the shared helpers (see
`local.example/scripts/example.sh`). `selftest.sh` syntax-checks them too.

## Safety

A session started with `--yolo --rc` can be driven by anyone holding its remote-control
link, with no permission prompts. Treat those links like passwords.
