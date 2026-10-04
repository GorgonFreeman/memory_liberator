#!/usr/bin/env bash
# Watch macOS memory pressure and offer to quit Chrome Helper (Renderer) processes
# when pressure reaches warning/critical — the same signal behind the system
# "memory is low" state (kern.memorystatus_vm_pressure_level).
#
# Levels: 1 = normal, 2 = warning, 4 = critical
#
# Usage:
#   ./watch_memory.sh           # poll until Ctrl-C
#   ./watch_memory.sh --once    # single check (for launchd / cron)
#   ./watch_memory.sh --force   # show the dialog even if pressure is normal

set -euo pipefail

POLL_SECS="${POLL_SECS:-15}"
COOLDOWN_SECS="${COOLDOWN_SECS:-180}"
WARN_LEVEL="${WARN_LEVEL:-2}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/memory_liberator"
LAST_ALERT_FILE="${STATE_DIR}/last_alert"

ONCE=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --once) ONCE=1 ;;
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$STATE_DIR"

pressure_level() {
  sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null || echo 0
}

pressure_label() {
  case "$1" in
    1) echo normal ;;
    2) echo warning ;;
    4) echo critical ;;
    *) echo "level $1" ;;
  esac
}

renderer_pids() {
  # Match Activity Monitor's "Google Chrome Helper (Renderer)" only —
  # not GPU / Alerts / generic Helper processes.
  pgrep -f 'Google Chrome Helper \(Renderer\)' 2>/dev/null || true
}

renderer_count() {
  local pids
  pids="$(renderer_pids)"
  if [[ -z "$pids" ]]; then
    echo 0
  else
    echo "$pids" | wc -l | tr -d ' '
  fi
}

renderer_rss_mb() {
  local pids total_kb=0 rss
  pids="$(renderer_pids)"
  [[ -z "$pids" ]] && { echo 0; return; }
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
    [[ -n "$rss" ]] && total_kb=$(( total_kb + rss ))
  done <<< "$pids"
  echo $(( total_kb / 1024 ))
}

cooldown_ok() {
  [[ ! -f "$LAST_ALERT_FILE" ]] && return 0
  local last now
  last="$(cat "$LAST_ALERT_FILE" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  (( now - last >= COOLDOWN_SECS ))
}

mark_alerted() {
  date +%s > "$LAST_ALERT_FILE"
}

quit_chrome_renderers() {
  local pids
  pids="$(renderer_pids)"
  if [[ -z "$pids" ]]; then
    return 0
  fi
  # SIGTERM first (same idea as quitting helpers); Chrome respawns tabs as needed.
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    kill "$pid" 2>/dev/null || true
  done <<< "$pids"
}

offer_dialog() {
  local level label count rss_mb button
  level="$(pressure_level)"
  label="$(pressure_label "$level")"
  count="$(renderer_count)"
  rss_mb="$(renderer_rss_mb)"

  button="$(osascript <<EOF
try
  set dialogResult to display alert "Memory is low" ¬
    message "macOS memory pressure is ${label} (${level})." & return & return & ¬
      "Google Chrome Helper (Renderer): ${count} process(es), ~${rss_mb} MB." & return & return & ¬
      "Quit all Chrome renderer helpers? Open tabs may reload; Chrome itself stays running." ¬
    buttons {"No", "Yes"} ¬
    default button "Yes" ¬
    cancel button "No" ¬
    as critical
  return button returned of dialogResult
on error number -128
  return "No"
end try
EOF
)"

  if [[ "$button" == "Yes" ]]; then
    quit_chrome_renderers
    osascript -e "display notification \"Quit ${count} Chrome renderer helper(s).\" with title \"Memory liberator\"" >/dev/null 2>&1 || true
  fi
}

maybe_alert() {
  local level count
  level="$(pressure_level)"
  count="$(renderer_count)"

  if [[ "$FORCE" -eq 1 ]]; then
    offer_dialog
    mark_alerted
    return
  fi

  if (( level < WARN_LEVEL )); then
    return
  fi

  if (( count < 1 )); then
    return
  fi

  if ! cooldown_ok; then
    return
  fi

  offer_dialog
  mark_alerted
}

if [[ "$ONCE" -eq 1 ]]; then
  maybe_alert
  exit 0
fi

echo "Watching memory pressure (warn >= $WARN_LEVEL, poll ${POLL_SECS}s). Ctrl-C to stop."
while true; do
  maybe_alert
  sleep "$POLL_SECS"
done
