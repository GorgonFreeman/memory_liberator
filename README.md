# memory_liberator

macOS helper that watches for near–out-of-application-memory conditions and offers a native Yes/No dialog to quit Google Chrome Helper (Renderer) processes.

Silent most of the time. No accounts, API keys, or other secrets — machine-local paths only appear in the LaunchAgent plist written under `~/Library/LaunchAgents/` at install time.

## When it fires

Aimed at ~80% of the way to the native Force Quit / “out of application memory” dialog — not ordinary yellow pressure:

- **critical** memory pressure (`kern.memorystatus_vm_pressure_level` ≥ 4), or
- **warning+** pressure **and** swap ≥ **85%** used

That condition must hold for **2 consecutive checks**, then there is a **30 minute** cooldown between dialogs.

## Setup (dormant, survives restarts)

```bash
./install_launch_agent.sh
```

This installs a LaunchAgent that:

- starts at login and after reboots
- checks once per minute
- does nothing unless the threshold above is met **and** Chrome renderer helpers are running
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

Optional env overrides: `POLL_SECS`, `COOLDOWN_SECS` (default `1800`), `CRITICAL_LEVEL` (default `4`), `WARN_LEVEL` (default `2`), `SWAP_PCT_FLOOR` (default `85`), `STREAK_NEEDED` (default `2`).
