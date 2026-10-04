#!/usr/bin/env bash
# Watch macOS memory pressure / swap and offer to quit Chrome Helper (Renderer)
# processes when the system is close to the native "out of application memory"
# dialog — roughly 80% of the way there, not on mere yellow pressure.
#
# Pressure levels: 1 = normal, 2 = warning, 4 = critical
# Native Force Quit UI tends to appear after recovery fails and paging/swap is
# exhausted. We fire earlier on:
#   - critical pressure, or
#   - warning+ pressure with swap nearly full
# after that condition holds for a short streak, then wait out a long cooldown.
#
# Usage:
#   ./watch_memory.sh           # poll until Ctrl-C
#   ./watch_memory.sh --once    # single check (for launchd / cron)
#   ./watch_memory.sh --force   # show the dialog even if pressure is normal

set -euo pipefail

POLL_SECS="${POLL_SECS:-15}"
COOLDOWN_SECS="${COOLDOWN_SECS:-1800}"
# Critical pressure; warning alone is not enough (see SWAP_PCT_FLOOR).
CRITICAL_LEVEL="${CRITICAL_LEVEL:-4}"
WARN_LEVEL="${WARN_LEVEL:-2}"
# Fire when swap is this full (%) and pressure is at least WARN_LEVEL.
SWAP_PCT_FLOOR="${SWAP_PCT_FLOOR:-85}"
# Consecutive bad checks required before alerting (LaunchAgent is ~60s apart).
STREAK_NEEDED="${STREAK_NEEDED:-2}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/memory_liberator"
LAST_ALERT_FILE="${STATE_DIR}/last_alert"
STREAK_FILE="${STATE_DIR}/bad_streak"

ONCE=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --once) ONCE=1 ;;
    --force) FORCE=1 ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
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

# Prints: used_mb total_mb pct (integers). pct is 0 if swap is unset/unavailable.
swap_stats() {
  local line used total
  line="$(sysctl -n vm.swapusage 2>/dev/null || true)"
  # e.g. "total = 24576.00M  used = 23285.56M  free = 1290.44M  (encrypted)"
  used="$(printf '%s' "$line" | sed -n 's/.*used = \([0-9.][0-9.]*\)M.*/\1/p')"
  total="$(printf '%s' "$line" | sed -n 's/.*total = \([0-9.][0-9.]*\)M.*/\1/p')"
  if [[ -z "$used" || -z "$total" ]]; then
    echo "0 0 0"
    return
  fi
  awk -v used="$used" -v total="$total" 'BEGIN {
    u = int(used + 0.5)
    t = int(total + 0.5)
    p = (t > 0) ? int((used * 100) / total + 0.5) : 0
    printf "%d %d %d\n", u, t, p
  }'
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
  echo 0 > "$STREAK_FILE"
}

reset_streak() {
  echo 0 > "$STREAK_FILE"
}

bump_streak() {
  local streak
  streak="$(cat "$STREAK_FILE" 2>/dev/null || echo 0)"
  streak=$(( streak + 1 ))
  echo "$streak" > "$STREAK_FILE"
  echo "$streak"
}

# Exit 0 if we are close to the native out-of-memory path.
near_native_threshold() {
  local level swap_used swap_total swap_pct
  level="$(pressure_level)"
  read -r swap_used swap_total swap_pct <<< "$(swap_stats)"

  if (( level >= CRITICAL_LEVEL )); then
    return 0
  fi
  if (( level >= WARN_LEVEL && swap_pct >= SWAP_PCT_FLOOR )); then
    return 0
  fi
  return 1
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
  local level label count rss_mb button swap_used swap_total swap_pct
  level="$(pressure_level)"
  label="$(pressure_label "$level")"
  count="$(renderer_count)"
  rss_mb="$(renderer_rss_mb)"
  read -r swap_used swap_total swap_pct <<< "$(swap_stats)"

  button="$(osascript <<EOF
try
  set dialogResult to display alert "Memory is low" ¬
    message "System is near out-of-application-memory." & return & return & ¬
      "Pressure: ${label} (${level}). Swap: ${swap_pct}% used (${swap_used}/${swap_total} MB)." & return & return & ¬
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
  local level count streak
  level="$(pressure_level)"
  count="$(renderer_count)"

  if [[ "$FORCE" -eq 1 ]]; then
    offer_dialog
    mark_alerted
    return
  fi

  if ! near_native_threshold; then
    reset_streak
    return
  fi

  if (( count < 1 )); then
    reset_streak
    return
  fi

  streak="$(bump_streak)"
  if (( streak < STREAK_NEEDED )); then
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

echo "Watching near-native memory stress (critical>=${CRITICAL_LEVEL} or warn+swap>=${SWAP_PCT_FLOOR}%; streak ${STREAK_NEEDED}; cooldown ${COOLDOWN_SECS}s). Ctrl-C to stop."
while true; do
  maybe_alert
  sleep "$POLL_SECS"
done
