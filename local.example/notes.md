# Machine notes (copy of local.example/; local/ is gitignored)

Facts about this machine the fleet manager should know. Examples:

- Projects live in: `~/projects/<name>` (if not the repo's parent, also set FLEET_PROJECTS)
- Sessions with scheduled tasks that must not be restarted: `<session name>` (why)
- Projects that spawn extra agent processes or heavy background jobs: `<project>` (what)
- Large directories that make `find` slow: `<path>`
- Remote Control peers on other machines and what they are for
- Policy overrides for this machine (e.g. stricter approval rules)
