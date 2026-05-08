#!/usr/bin/env bash
# scripts/agent_pool_status.sh — compact, universal status for an agent fleet.
#
# Usage:
#   agent_pool_status.sh <project_short|config_path> [--tsv|--json]
#
# Works with both AGENT_PANES universal fleets and legacy AGENTS configs.
# It avoids pane captures by design; tmux is used only for metadata.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/config_resolver.sh"
source "$TK/lib/process_safety.sh"
# Issue #322: tmux_helpers exposes `tmux_pane_values_batch` so we
# retrieve pane_current_command and pane_current_path in one
# display-message call instead of N round-trips per agent.
source "$TK/lib/tmux_helpers.sh"

CFG_ARG=${1:?usage: agent_pool_status.sh <project> [--tsv|--json]}
FORMAT="tsv"
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tsv) FORMAT="tsv" ;;
    --json) FORMAT="json" ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

load_project_config "$CFG_ARG"
source "$TK/lib/agent_inventory.sh"

: "${DEFAULT_BRANCH:=main}"
: "${AGENT_POOL_GIT_TIMEOUT_SEC:=5}"
: "${AGENT_POOL_GH_TIMEOUT_SEC:=5}"
: "${AGENT_POOL_TMUX_TIMEOUT_SEC:=3}"
: "${AGENT_POOL_PR_LIMIT:=100}"
: "${AGENT_POOL_FETCH:=0}"
: "${AGENT_POOL_SINGLE_FLIGHT_TTL_SEC:=120}"

run_timeout() {
  local seconds=$1
  shift
  orch_run_timeout "$seconds" "$@"
}

git_value() {
  local repo=$1
  shift
  run_timeout "$AGENT_POOL_GIT_TIMEOUT_SEC" git -C "$repo" "$@" 2>/dev/null || true
}

git_quiet() {
  local repo=$1
  shift
  run_timeout "$AGENT_POOL_GIT_TIMEOUT_SEC" git -C "$repo" "$@" >/dev/null 2>&1
}

pane_value() {
  local pane=$1 format=$2
  run_timeout "$AGENT_POOL_TMUX_TIMEOUT_SEC" tmux display-message -p -t "$pane" "$format" 2>/dev/null || true
}

scan_partial=0
tmux_available=1
scan_signals=()
lock_name="agent_pool_status.${PROJECT:-unknown}"
lock_acquired=0
if orch_single_flight_enter "$lock_name" "$AGENT_POOL_SINGLE_FLIGHT_TTL_SEC"; then
  lock_acquired=1
else
  scan_partial=1
  scan_signals+=("process_budget_degraded" "fork_risk")
  printf 'agent_pool_status degraded: overlapping scan owner_pid=%s age=%ss\n' \
    "${ORCH_SINGLE_FLIGHT_OWNER_PID:-unknown}" "${ORCH_SINGLE_FLIGHT_OWNER_AGE:-unknown}" >&2
fi
cleanup_agent_pool_lock() {
  if [[ "$lock_acquired" -eq 1 ]]; then
    orch_single_flight_release "$(orch_lock_path "$lock_name")"
  fi
}
trap cleanup_agent_pool_lock EXIT

budget_signal=$(orch_process_budget_signal || true)
if [[ -n "$budget_signal" ]]; then
  orch_signal_list_add_csv "$budget_signal" scan_signals
  if [[ "$budget_signal" == *fork_risk* ]]; then
    scan_partial=1
  fi
fi

if [[ "$scan_partial" -eq 0 ]]; then
  if ! orch_tmux_probe; then
    tmux_available=0
    scan_signals+=("tmux_degraded")
    printf 'agent_pool_status degraded: %s\n' "${ORCH_TMUX_DEGRADED_REASON:-tmux probe failed}" >&2
  fi
else
  tmux_available=0
fi

prs_json="[]"
if [ "$scan_partial" -eq 0 ] && [ -n "${GH_REPO:-}" ] && command -v gh >/dev/null 2>&1; then
  if ! prs_json=$(run_timeout "$AGENT_POOL_GH_TIMEOUT_SEC" env GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" gh pr list \
    --repo "$GH_REPO" \
    --base "$DEFAULT_BRANCH" \
    --state open \
    --limit "$AGENT_POOL_PR_LIMIT" \
    --json number,headRefName,headRefOid,mergeStateStatus,isDraft,updatedAt,title 2>/dev/null); then
    prs_json="[]"
    scan_signals+=("process_budget_degraded")
  fi
fi

json_items=()
if [ "$FORMAT" = "tsv" ]; then
  # #295: split the historical `workdir` column into `assigned_workdir`
  # (configured per project profile) and `live_pane_cwd` (read from tmux
  # `#{pane_current_path}` for the agent's pane). `live_cwd_match` is 1 when
  # the two are equal, 0 when they differ, empty when the pane is not alive
  # or tmux is unavailable. The pre-#295 `workdir` column conflated the two
  # and could imply pane sanitation when only the assigned value was known.
  printf 'label\tpane\talive\tcommand\tassigned_workdir\tlive_pane_cwd\tlive_cwd_match\tbranch\thead\tupstream\tahead\tbehind\tdirty\tbase_current\tpr\tpr_state\tpr_sha\tsignals\n'
fi

while IFS='|' read -r label pane workdir; do
  [ -n "$label$pane$workdir" ] || continue

  alive=0
  command=""
  live_pane_cwd=""
  live_cwd_match=""
  if [[ "$tmux_available" -eq 1 ]] && run_timeout "$AGENT_POOL_TMUX_TIMEOUT_SEC" tmux has-session -t "${pane%%:*}" >/dev/null 2>&1; then
    alive=1
    tmux_pane_values_batch "$pane" command live_pane_cwd "$AGENT_POOL_TMUX_TIMEOUT_SEC" || true
    if [[ -n "$live_pane_cwd" ]]; then
      # Trim trailing slash to avoid spurious mismatches between /a/b and /a/b/.
      normalized_live="${live_pane_cwd%/}"
      normalized_assigned="${workdir%/}"
      if [[ "$normalized_live" == "$normalized_assigned" ]]; then
        live_cwd_match=1
      else
        live_cwd_match=0
      fi
    fi
  fi

  branch=""
  head=""
  head_full=""
  upstream=""
  ahead=""
  behind=""
  dirty=""
  base_current=""
  needs_rebase_pending=0
  signals=("${scan_signals[@]}")
  if [ "$scan_partial" -eq 0 ] && [ -d "$workdir/.git" ]; then
    if [ "$AGENT_POOL_FETCH" = "1" ]; then
      git_quiet "$workdir" fetch origin "$DEFAULT_BRANCH" || true
    fi
    branch=$(git_value "$workdir" branch --show-current)
    head=$(git_value "$workdir" rev-parse --short HEAD)
    head_full=$(git_value "$workdir" rev-parse HEAD)
    upstream=$(git_value "$workdir" rev-parse --abbrev-ref --symbolic-full-name '@{u}')
    dirty=$(git_value "$workdir" status --porcelain | wc -l | tr -d ' ')
    [ "${dirty:-0}" != "0" ] && signals+=("dirty")
    if [ -n "$upstream" ]; then
      counts=$(git_value "$workdir" rev-list --left-right --count "$upstream...HEAD")
      behind=${counts%%[[:space:]]*}
      ahead=${counts##*[[:space:]]}
      [ "${behind:-0}" != "0" ] && signals+=("behind-upstream")
    fi
    if [ -n "$branch" ] && [ "$branch" != "$DEFAULT_BRANCH" ]; then
      base_ref="origin/$DEFAULT_BRANCH"
      if git_quiet "$workdir" rev-parse --verify "$base_ref"; then
        if git_quiet "$workdir" merge-base --is-ancestor "$base_ref" HEAD; then
          base_current=1
        else
          base_current=0
          needs_rebase_pending=1
        fi
      fi
    fi
  fi

  pr_json=$(printf '%s' "$prs_json" | jq -c --arg branch "$branch" '
    map(select(.headRefName == $branch)) | first // {}
  ')
  pr=$(printf '%s' "$pr_json" | jq -r '.number // ""')
  pr_state=$(printf '%s' "$pr_json" | jq -r '.mergeStateStatus // ""')
  pr_head_full=$(printf '%s' "$pr_json" | jq -r '.headRefOid // ""')
  pr_sha=${pr_head_full:0:8}
  if [ "${dirty:-0}" != "0" ]; then
    dirty_after_pr=0
    if [ -n "$pr" ]; then
      dirty_after_pr=1
    elif [ -n "$branch" ] \
      && [ "$branch" != "$DEFAULT_BRANCH" ] \
      && [ -n "$upstream" ] \
      && [ "${ahead:-}" = "0" ] \
      && [ "${behind:-}" = "0" ]; then
      dirty_after_pr=1
    fi
    if [ "$dirty_after_pr" = "1" ]; then
      signals+=("dirty_after_pr")
    fi
  fi
  if [ "$needs_rebase_pending" = "1" ]; then
    if [ -n "$pr_head_full" ] && [ -n "$head_full" ] && [ "$pr_head_full" != "$head_full" ]; then
      signals+=("remote-rebased-local-stale")
    else
      signals+=("needs-rebase")
    fi
  fi
  case "$pr_state" in
    BEHIND) signals+=("pr-behind") ;;
    DIRTY) signals+=("conflict") ;;
  esac
  if [[ "$live_cwd_match" == "0" ]]; then
    signals+=("live_cwd_mismatch")
  fi
  signal_text=$(orch_signal_list_unique_csv "${signals[@]}")

  if [ "$FORMAT" = "json" ]; then
    json_items+=("$(jq -nc \
      --arg agent_label "$label" \
      --arg pane "$pane" \
      --argjson alive "$alive" \
      --arg command "$command" \
      --arg assigned_workdir "$workdir" \
      --arg live_pane_cwd "$live_pane_cwd" \
      --arg live_cwd_match "$live_cwd_match" \
      --arg branch "$branch" \
      --arg head "$head" \
      --arg upstream "$upstream" \
      --arg ahead "$ahead" \
      --arg behind "$behind" \
      --arg dirty "$dirty" \
      --arg base_current "$base_current" \
      --arg pr "$pr" \
      --arg pr_state "$pr_state" \
      --arg pr_sha "$pr_sha" \
      --arg signals "$signal_text" \
      '{label:$agent_label,pane:$pane,alive:$alive,command:$command,assigned_workdir:$assigned_workdir,live_pane_cwd:$live_pane_cwd,live_cwd_match:$live_cwd_match,branch:$branch,head:$head,upstream:$upstream,ahead:$ahead,behind:$behind,dirty:$dirty,base_current:$base_current,pr:$pr,pr_state:$pr_state,pr_sha:$pr_sha,signals:($signals | split(",") | map(select(length > 0)))}')")
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$label" "$pane" "$alive" "$command" \
      "$workdir" "$live_pane_cwd" "$live_cwd_match" \
      "$branch" "$head" \
      "$upstream" "$ahead" "$behind" "$dirty" "$base_current" "$pr" \
      "$pr_state" "$pr_sha" "$signal_text"
  fi
done < <(agent_inventory_entries)

if [ "$FORMAT" = "json" ]; then
  printf '%s\n' "${json_items[@]}" | jq -s '.'
fi
