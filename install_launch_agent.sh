#!/usr/bin/env bash
# Install a LaunchAgent that runs watch_memory.sh --once every minute.
# Survives reboots; stays silent until memory pressure is elevated.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCH_SCRIPT="${SCRIPT_DIR}/watch_memory.sh"
LABEL="com.manuscanis.memory_liberator"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/memory_liberator"

chmod +x "$WATCH_SCRIPT" \
  "${SCRIPT_DIR}/uninstall_launch_agent.sh" \
  "${SCRIPT_DIR}/install_launch_agent.sh"
mkdir -p "$LOG_DIR" "$(dirname "$PLIST")"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${WATCH_SCRIPT}</string>
    <string>--once</string>
  </array>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/${LABEL}"

echo "Installed $PLIST"
echo "Checks every 60s after login/reboot. Dialog only when pressure is high and Chrome renderers exist."
echo "Test now: $WATCH_SCRIPT --force"
echo "Uninstall: ${SCRIPT_DIR}/uninstall_launch_agent.sh"
