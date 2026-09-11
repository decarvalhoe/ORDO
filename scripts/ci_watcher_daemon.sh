#!/usr/bin/env bash
# ci_watcher_daemon.sh — long-running daemon that polls GitHub CI runs and notifies the orch on new failures.
# Usage: ci_watcher_daemon.sh <config_short_or_path>
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
source "$TK/lib/config_resolver.sh"

CFG_ARG=${1:?usage: ci_watcher_daemon.sh <project_short|config_path>}
load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"
source "$TK/lib/state_persist.sh"
# Forge access goes through the provider adapter (#816): no direct gh call.
# shellcheck source=../lib/ordo_provider_adapter.sh
source "$TK/lib/ordo_provider_adapter.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${DEFAULT_BRANCH:=main}" "${AGENT_SESSION_PREFIX:=}"
: "${CI_WATCHER_INTERVAL_SEC:=180}" "${CI_WATCHER_LOOKBACK:=5}"

# Orch pane resolution (3 levels of override, most specific wins):
#   1. CI_WATCHER_ORCH_PANE (explicit env, fully universal)
#   2. ORCH_PANE_NAME       (per-config override of the suffix used after the prefix)
#   3. ${AGENT_SESSION_PREFIX}orchestrator, or "orch" when prefix is empty (legacy)
if [ -n "${CI_WATCHER_ORCH_PANE:-}" ]; then
  ORCH_PANE="$CI_WATCHER_ORCH_PANE"
  ORCH_PANE_SOURCE="explicit"
elif [ -n "${ORCH_PANE_NAME:-}" ]; then
  ORCH_PANE="${AGENT_SESSION_PREFIX}${ORCH_PANE_NAME}"
  ORCH_PANE_SOURCE="config"
elif [ -z "$AGENT_SESSION_PREFIX" ]; then
  ORCH_PANE="orch"
  ORCH_PANE_SOURCE="legacy-default"
else
  ORCH_PANE="${AGENT_SESSION_PREFIX}orchestrator"
  ORCH_PANE_SOURCE="prefix-default"
fi

WATCHER_STATE_FILE="$(state_dir)/ci_watcher_seen.txt"
INCOMING_LOG="${AUDIT_LOG_FILE:-/tmp/orch-$PROJECT.log}"
INCOMING_LOG="${INCOMING_LOG%.log}-incoming-alerts.log"
mkdir -p "$(dirname "$INCOMING_LOG")" 2>/dev/null
touch "$WATCHER_STATE_FILE"

normalize_tmux_target() {
  local target=${1:?usage: normalize_tmux_target <target>}
  if [[ "$target" == *:* ]]; then
    printf '%s\n' "$target"
  else
    printf '%s:0\n' "$target"
  fi
}

ORCH_TMUX_TARGET="$(normalize_tmux_target "$ORCH_PANE")"

same_path_text() {
  local left=${1:-}
  local right=${2:-}
  [[ -n "$left" && -n "$right" ]] || return 1
  [[ "${left%/}" == "${right%/}" ]]
}

probe_tmux_target_cwd() {
  local target=${1:?usage: probe_tmux_target_cwd <target> <output-var>}
  local output_var=${2:?usage: probe_tmux_target_cwd <target> <output-var>}
  local target_cwd
  local -n output_ref="$output_var"
  target_cwd=$(tmux display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null) || return 1
  # shellcheck disable=SC2034 # nameref writes through to the caller's variable.
  output_ref="$target_cwd"
}

legacy_default_target_allowed() {
  local live_cwd=${1:-}
  local candidate expected_list has_expected

  [[ "$ORCH_PANE_SOURCE" == "legacy-default" ]] || return 0

  expected_list=""
  has_expected=0
  for candidate in "${ORCH_SUPERVISOR_WORKDIR:-}" "${SUPERVISOR_REPO:-}" "${PROJECT_REPO_ROOT:-}"; do
    [[ -n "$candidate" ]] || continue
    has_expected=1
    expected_list="${expected_list:+$expected_list,}$candidate"
    if same_path_text "$live_cwd" "$candidate"; then
      return 0
    fi
  done

  if [[ "$has_expected" -eq 0 ]]; then
    audit "CI WATCHER WARN: default orch target refused target=$ORCH_TMUX_TARGET reason=missing-supervisor-workdir set CI_WATCHER_ORCH_PANE"
  else
    audit "CI WATCHER WARN: default orch target refused target=$ORCH_TMUX_TARGET live_cwd=${live_cwd:-unknown} expected_supervisor=$expected_list set CI_WATCHER_ORCH_PANE"
  fi
  return 1
}

audit "CI WATCHER start project=$PROJECT branch=$DEFAULT_BRANCH interval=${CI_WATCHER_INTERVAL_SEC}s target=$ORCH_TMUX_TARGET source=$ORCH_PANE_SOURCE"

notify_orch() {
  local msg=$1
  local ts live_cwd
  ts=$(date -u +%H:%M:%SZ)
  echo "[$ts] $msg" >> "$INCOMING_LOG"
  audit "CI WATCHER NOTIFY $msg"
  # Send to orch pane (intrusive: even if orch is mid-task)
  if probe_tmux_target_cwd "$ORCH_TMUX_TARGET" live_cwd; then
    if ! legacy_default_target_allowed "$live_cwd"; then
      return 0
    fi
    tmux send-keys -t "$ORCH_TMUX_TARGET" C-u 2>/dev/null || true
    sleep 0.3
    tmux send-keys -t "$ORCH_TMUX_TARGET" "🚨 CI ALERT: $msg. Run \$TK/scripts/check_ci_health.sh and remediate." 2>/dev/null || true
    sleep 0.5
    tmux send-keys -t "$ORCH_TMUX_TARGET" Enter 2>/dev/null || true
    audit "CI WATCHER notification sent to $ORCH_TMUX_TARGET"
  else
    audit "CI WATCHER WARN: orch target $ORCH_TMUX_TARGET not found, only logged"
  fi
}

while true; do
  # Fetch recent runs on default branch
  runs=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" ordo_provider run_list --repo "$GH_REPO" --branch "$DEFAULT_BRANCH" --limit "$CI_WATCHER_LOOKBACK" 2>/dev/null \
    | jq -c '[.items[]? | {databaseId: .id, name, conclusion: (.conclusion // ""), status, headSha: (.head_sha // "")}]' 2>/dev/null || echo "[]")

  # Extract failures (completed + failure/timed_out only).
  # `cancelled` is excluded for parity with check_ci_health.sh: GH Actions
  # cancels older queued runs when a newer commit lands on the same branch
  # (concurrency dedup), and that's not actionable. Operator-initiated
  # cancellations during incidents are visible directly in the runs list.
  echo "$runs" | jq -r '.[] | select(.status=="completed" and (.conclusion=="failure" or .conclusion=="timed_out")) | "\(.databaseId)|\(.name)|\(.conclusion)|\(.headSha[0:7])"' 2>/dev/null | while IFS="|" read -r run_id name conclusion sha; do
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
