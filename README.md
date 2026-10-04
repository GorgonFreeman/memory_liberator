# memory_liberator

macOS helper that watches system memory pressure and offers a native Yes/No dialog to quit Google Chrome Helper (Renderer) processes when memory is low.

Silent when pressure is normal. No accounts, API keys, or other secrets — machine-local paths only appear in the LaunchAgent plist written under `~/Library/LaunchAgents/` at install time.

## Setup (dormant, survives restarts)

```bash
./install_launch_agent.sh
```

This installs a LaunchAgent that:

- starts at login and after reboots
- checks once per minute
- does nothing unless memory pressure is warning/critical **and** Chrome renderer helpers are running
- then shows a native alert: **Yes** quits those helpers, **No** dismisses

Uninstall:

```bash
./uninstall_launch_agent.sh
```

## Manual use

```bash
./watch_memory.sh           # keep watching in the foreground
./watch_memory.sh --once    # single check
./watch_memory.sh --force   # show the dialog now (for testing)
```

Optional env overrides: `POLL_SECS`, `COOLDOWN_SECS`, `WARN_LEVEL` (default `2` = warning).
