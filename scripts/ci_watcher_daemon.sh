#!/usr/bin/env bash
# ci_watcher_daemon.sh — long-running daemon that polls GitHub CI runs and notifies the orch on new failures.
# Usage: ci_watcher_daemon.sh <config_short_or_path>   # e.g. nomos, rbok, wp, /path/to/custom.config.sh
# Run inside a dedicated tmux session: tmux new -d -s <project>-ciwatch "ci_watcher_daemon.sh <project>"
#
# Behavior:
#   - Polls every $CI_WATCHER_INTERVAL_SEC (default 180s) the last $CI_WATCHER_LOOKBACK runs on $DEFAULT_BRANCH.
#   - Tracks seen SHAs in $WATCHER_STATE_FILE so the same failure isn't re-notified.
#   - On NEW failure:
#       1. Append to /var/log/orch/<project>-incoming-alerts.log
#       2. Update ~/.local/share/orch-state/<project>/CI_ALERT.md
#       3. Send a short prompt to the orch pane via tmux send-keys (intrusive: even if orch is busy).
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

CFG_ARG=${1:?usage: ci_watcher_daemon.sh <project_short|config_path>}
case "$CFG_ARG" in
  wp|realisons-wp)   CFG="$TK/examples/realisons-wp.config.sh" ;;
  nomos)             CFG="$TK/examples/nomos.config.sh" ;;
  rbok)              CFG="$TK/examples/rbok.config.sh" ;;
  42t|42-training)   CFG="$TK/examples/42t.config.sh" ;;
  *)                 CFG="$CFG_ARG" ;;
esac
[ -f "$CFG" ] || { echo "config not found: $CFG" >&2; exit 1; }
source "$CFG"

source "$TK/lib/audit_log.sh"
source "$TK/lib/state_persist.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${DEFAULT_BRANCH:=main}" "${AGENT_SESSION_PREFIX:=}"
: "${CI_WATCHER_INTERVAL_SEC:=180}" "${CI_WATCHER_LOOKBACK:=5}"

# Orch pane: same convention as bootstrap_orch.sh
ORCH_PANE="${AGENT_SESSION_PREFIX}orchestrator"
[ "$AGENT_SESSION_PREFIX" = "" ] && ORCH_PANE="orch"

WATCHER_STATE_FILE="$(state_dir)/ci_watcher_seen.txt"
INCOMING_LOG="${AUDIT_LOG_FILE:-/tmp/orch-$PROJECT.log}"
INCOMING_LOG="${INCOMING_LOG%.log}-incoming-alerts.log"
mkdir -p "$(dirname "$INCOMING_LOG")" 2>/dev/null
touch "$WATCHER_STATE_FILE"

audit "CI WATCHER start project=$PROJECT branch=$DEFAULT_BRANCH interval=${CI_WATCHER_INTERVAL_SEC}s pane=$ORCH_PANE"

notify_orch() {
  local msg=$1
  local ts
  ts=$(date -u +%H:%M:%SZ)
  echo "[$ts] $msg" >> "$INCOMING_LOG"
  audit "CI WATCHER NOTIFY $msg"
  # Send to orch pane (intrusive: even if orch is mid-task)
  if tmux has-session -t "$ORCH_PANE" 2>/dev/null; then
    tmux send-keys -t "${ORCH_PANE}:0" C-u 2>/dev/null || true
    sleep 0.3
    tmux send-keys -t "${ORCH_PANE}:0" "🚨 CI ALERT: $msg. Run \$TK/scripts/check_ci_health.sh and remediate." 2>/dev/null || true
    sleep 0.5
    tmux send-keys -t "${ORCH_PANE}:0" Enter 2>/dev/null || true
    audit "CI WATCHER notification sent to $ORCH_PANE"
  else
    audit "CI WATCHER WARN: orch pane $ORCH_PANE not found, only logged"
  fi
}

while true; do
  # Fetch recent runs on default branch
  runs=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh run list --repo "$GH_REPO" --branch "$DEFAULT_BRANCH" --limit "$CI_WATCHER_LOOKBACK" --json databaseId,name,conclusion,status,headSha 2>/dev/null || echo "[]")

  # Extract failures (completed + failure/timed_out/cancelled)
  echo "$runs" | jq -r '.[] | select(.status=="completed" and (.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="cancelled")) | "\(.databaseId)|\(.name)|\(.conclusion)|\(.headSha[0:7])"' 2>/dev/null | while IFS="|" read -r run_id name conclusion sha; do
    [ -z "$run_id" ] && continue
    # Have we already notified for this run_id?
    if grep -q "^${run_id}$" "$WATCHER_STATE_FILE"; then
      continue
    fi
    # New failure — notify
    notify_orch "$name [$conclusion] sha=$sha run=$run_id"
    echo "$run_id" >> "$WATCHER_STATE_FILE"
  done

  # Trim state file to last 200 lines (avoid unbounded growth)
  tail -200 "$WATCHER_STATE_FILE" > "${WATCHER_STATE_FILE}.tmp" && mv "${WATCHER_STATE_FILE}.tmp" "$WATCHER_STATE_FILE"

  sleep "$CI_WATCHER_INTERVAL_SEC"
done
