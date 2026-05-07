#!/usr/bin/env bash
# ensure_alive.sh — generic tmux watchdog (3-tier inspired by Overstory).
#
# Usage:
#   bash ensure_alive.sh <session> <window> "<start_cmd>" [match_pattern]
#
# Tier 0 (mechanical) — checks every 15s if the matching process is running.
# If not, runs respawn-pane with the start_cmd.
#
# Example: keep ci_watcher_daemon.sh alive in demo-ciwatch:0
#   bash ensure_alive.sh demo-ciwatch 0 "bash $TK/scripts/ci_watcher_daemon.sh demo"

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=lib/log_bounds.sh
source "$TK/lib/log_bounds.sh"

SESSION=${1:?usage: ensure_alive.sh <session> <window> <cmd> [match_pattern]}
WINDOW=${2:?usage: ensure_alive.sh <session> <window> <cmd> [match_pattern]}
START_CMD=${3:?usage: ensure_alive.sh <session> <window> <cmd> [match_pattern]}
MATCH_PATTERN=${4:-$START_CMD}

TARGET="$SESSION:$WINDOW"
LOG="/var/log/orch/watchdog-$SESSION.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null

log() {
  orch_log_rotate_if_needed "$LOG"
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG"
  orch_log_rotate_if_needed "$LOG"
}

ensure_session_exists() {
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" "$START_CMD"
    log "created tmux session $SESSION and started: $START_CMD"
    return
  fi
  if ! tmux list-windows -t "$SESSION" -F '#I' 2>/dev/null | grep -qx "$WINDOW"; then
    tmux new-window -d -t "$TARGET" "$START_CMD"
    log "created tmux window $TARGET"
  fi
}

is_running() {
  pgrep -af "$MATCH_PATTERN" >/dev/null 2>&1
}

start_it() {
  ensure_session_exists
  tmux respawn-pane -k -t "$TARGET" "$START_CMD"
  sleep 2
  log "respawned: $START_CMD in $TARGET"
}

log "watchdog started for $TARGET (match=$MATCH_PATTERN)"

while true; do
  ensure_session_exists
  if ! is_running; then
    start_it
  fi
  sleep 15
done
