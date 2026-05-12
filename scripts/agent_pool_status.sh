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
source "$TK/lib/worktree_helpers.sh"
if [[ -f "$TK/lib/agent_status.sh" ]]; then
  source "$TK/lib/agent_status.sh"
else
  agent_status_read_latest() { return 1; }
fi

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
source "$TK/lib/dispatch_capacity.sh"

: "${DEFAULT_BRANCH:=main}"
: "${AGENT_POOL_GIT_TIMEOUT_SEC:=5}"
: "${AGENT_POOL_GH_TIMEOUT_SEC:=5}"
: "${AGENT_POOL_TMUX_TIMEOUT_SEC:=3}"
: "${AGENT_POOL_PR_LIMIT:=100}"
: "${AGENT_POOL_FETCH:=0}"
: "${AGENT_POOL_SINGLE_FLIGHT_TTL_SEC:=120}"
: "${AGENT_STATUS_STALE_AFTER_SEC:=900}"

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

agent_pool_signal_value() {
  local value=${1:-empty}
  [[ -n "$value" ]] || value="empty"
  value=${value//[^A-Za-z0-9_.@-]/_}
  printf '%s\n' "$value"
}

agent_pool_tsv_value() {
  printf '%s' "${1:-}" | tr '\t\r\n' '   '
}

agent_pool_declaration_snapshot() {
  local agent_id=${1:?usage: agent_pool_declaration_snapshot <agent-id>}
  local declaration_json timestamp age now state action wake_pending

  if ! declaration_json=$(agent_status_read_latest "$PROJECT" "$agent_id" 2>/dev/null); then
    jq -nc \
      '{state:"missing",status:"",reason:"",target:"",timestamp:"",age_sec:null,evidence:"",optional:{},wake_pending:0,required_action:"agent should emit status declaration"}'
    return 0
  fi

  timestamp=$(printf '%s' "$declaration_json" | jq -r '.timestamp // ""')
  now=$(agent_status_now_epoch)
  age=""
  if [[ -n "$timestamp" ]]; then
    age=$(agent_status_age_sec "$timestamp" "$now" 2>/dev/null || true)
  fi
  if [[ -n "$age" && "$age" =~ ^-?[0-9]+$ && "$age" -le "$AGENT_STATUS_STALE_AFTER_SEC" ]]; then
    state="fresh"
    action=""
  else
    state="stale"
    action="refresh declaration or inspect agent"
  fi
  wake_pending=$(agent_status_pending_event_count "$PROJECT" "$agent_id" 2>/dev/null || printf '0')

  printf '%s' "$declaration_json" | jq -c \
    --arg state "$state" \
    --arg action "$action" \
    --arg age "$age" \
    --arg wake_pending "$wake_pending" '
      {
        state: $state,
        status: (.status // ""),
        reason: (.reason // ""),
        target: (.target // ""),
        timestamp: (.timestamp // ""),
        age_sec: (($age | tonumber?) // null),
        evidence: (.evidence // ""),
        optional: (.optional // {}),
        wake_pending: (($wake_pending | tonumber?) // 0),
        required_action: $action
      }
    '
}

agent_pool_expected_git_identity_name() {
  local agent=${1:?usage: agent_pool_expected_git_identity_name <agent>}
  local entry entry_agent entry_name entry_extra

  if [[ -n "${AGENT_GIT_IDENTITIES+x}" && "${#AGENT_GIT_IDENTITIES[@]}" -gt 0 ]]; then
    for entry in "${AGENT_GIT_IDENTITIES[@]}"; do
      IFS='|' read -r entry_agent entry_name _ entry_extra <<< "$entry"
      [[ -z "$entry_extra" ]] || continue
      if [[ "$entry_agent" == "$agent" && -n "$entry_name" ]]; then
        printf '%s\n' "$entry_name"
        return 0
      fi
    done
  fi

  if [[ -n "${AGENT_GIT_IDENTITY_NAME_TEMPLATE:-}" ]]; then
    # shellcheck disable=SC2059
    printf "$AGENT_GIT_IDENTITY_NAME_TEMPLATE" "$agent"
    printf '\n'
    return 0
  fi

  return 1
}

agent_pool_ordo_soft_route_status_enabled() {
  [[ "${PROJECT:-}" == "ordo" ]] || return 1
  [[ "${AGENT_POOL_ORDO_SOFT_ROUTE_STATUS:-1}" != "0" ]]
}

agent_pool_assignment_reconcile_enabled() {
  worktree_enabled && return 0
  agent_pool_ordo_soft_route_status_enabled
}

agent_pool_soft_route_worktree_basename() {
  if [[ -n "${AGENT_POOL_SOFT_ROUTE_WORKTREE_BASENAME:-}" ]]; then
    printf '%s\n' "$AGENT_POOL_SOFT_ROUTE_WORKTREE_BASENAME"
    return 0
  fi
  if agent_pool_ordo_soft_route_status_enabled; then
    printf 'ORDO-worktrees\n'
    return 0
  fi
  return 1
}

agent_pool_prompt_mentions_workdir() {
  local prompt_file=${1:-}
  local assigned_workdir=${2:-}

  [[ -n "$prompt_file" && -n "$assigned_workdir" && -f "$prompt_file" ]] || return 1
  grep -F -- "$assigned_workdir" "$prompt_file" >/dev/null 2>&1
}

agent_pool_soft_routed_assignment_active() {
  local normalized_live=${1:-}
  local normalized_assigned=${2:-}
  local route_mode=${3:-}
  local proof_route=${4:-}
  local proof_live=${5:-}
  local prompt_file=${6:-}

  agent_pool_ordo_soft_route_status_enabled || return 1
  [[ -n "$normalized_live" && -n "$normalized_assigned" ]] || return 1
  [[ "$normalized_live" != "$normalized_assigned" ]] || return 1
  [[ "$route_mode" == "soft" || "$proof_route" == "soft-routed" ]] || return 1
  [[ "$proof_route" == "soft-routed" ]] || return 1

  proof_live="${proof_live%/}"
  [[ -n "$proof_live" && "$proof_live" == "$normalized_live" ]] || return 1
  agent_pool_prompt_mentions_workdir "$prompt_file" "$normalized_assigned"
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
  # #278 layers `capacity_class` on top so dispatch can read a single
  # structured class per agent (reserved/dispatched/local_work/...) from the
  # same row, instead of inferring capacity from `live_cwd_match` alone.
  printf 'label\tpane\talive\tcommand\tassigned_workdir\tlive_pane_cwd\tlive_cwd_match\tcapacity_class\tbranch\thead\tupstream\tahead\tbehind\tdirty\tbase_current\tpr\tpr_state\tpr_sha\texpected_login\texpected_git_identity\texpected_git_email\tobserved_git_identity\tobserved_git_email\tgit_identity_match\tgit_identity_repair\tsignals\tdeclared_status\tdeclaration_state\tdeclaration_age_sec\tdeclaration_required_action\tdeclaration_reason\tdeclaration_evidence\tdeclaration_wake_pending\n'
fi

while IFS='|' read -r label pane workdir; do
  [ -n "$label$pane$workdir" ] || continue

  alive=0
  command=""
  live_pane_cwd=""
  live_cwd_match=""
  assignment_workdir=""
  assignment_route_mode=""
  assignment_context_proof_route=""
  assignment_context_proof_live_workdir=""
  assignment_prompt_file=""
  live_workdir=""
  normalized_live=""
  normalized_assigned=""
  soft_routed_active=0
  if agent_pool_assignment_reconcile_enabled; then
    assignment_workdir=$(agent_assignment_workdir "$label" 2>/dev/null || true)
    if [[ -n "$assignment_workdir" ]]; then
      workdir="${assignment_workdir%/}"
      assignment_route_mode=$(agent_assignment_field "$label" route_mode 2>/dev/null || true)
      assignment_context_proof_route=$(agent_assignment_field "$label" context_proof_route 2>/dev/null || true)
      assignment_context_proof_live_workdir=$(agent_assignment_field "$label" context_proof_live_workdir 2>/dev/null || true)
      assignment_prompt_file=$(agent_assignment_field "$label" prompt_file 2>/dev/null || true)
    fi
  fi
  if [[ "$tmux_available" -eq 1 ]] && run_timeout "$AGENT_POOL_TMUX_TIMEOUT_SEC" tmux has-session -t "${pane%%:*}" >/dev/null 2>&1; then
    alive=1
    # Issue #322 + #295 + #278: one display-message round-trip retrieves
    # pane_current_command and pane_current_path. The path lands in
    # $live_pane_cwd, which feeds three consumers: pane-sanitation match
    # (#295), the dispatch-capacity classifier (#278), and the
    # `live_cwd_mismatch` signal below.
    tmux_pane_values_batch "$pane" command live_pane_cwd \
      "$AGENT_POOL_TMUX_TIMEOUT_SEC" 2>/dev/null || true
    if [[ -n "$live_pane_cwd" ]]; then
      # Trim trailing slash to avoid spurious mismatches between /a/b and /a/b/.
      normalized_live="${live_pane_cwd%/}"
      if worktree_enabled && [[ -z "$assignment_workdir" ]]; then
        live_workdir=$(worktree_live_agent_workdir "$label" "$normalized_live" 2>/dev/null || true)
      fi
      if [[ -z "$live_workdir" && -z "$assignment_workdir" ]] \
        && agent_pool_ordo_soft_route_status_enabled; then
        soft_route_root_name=$(agent_pool_soft_route_worktree_basename 2>/dev/null || true)
        if [[ -n "$soft_route_root_name" ]]; then
          live_workdir=$(worktree_live_agent_workdir_from_root_name \
            "$label" "$normalized_live" "$soft_route_root_name" 2>/dev/null || true)
        fi
      fi
      if [[ -n "$live_workdir" ]]; then
        workdir="$live_workdir"
      fi
      normalized_assigned="${workdir%/}"
      if [[ "$normalized_live" == "$normalized_assigned" ]]; then
        live_cwd_match=1
      else
        live_cwd_match=0
        if agent_pool_soft_routed_assignment_active \
          "$normalized_live" "$normalized_assigned" \
          "$assignment_route_mode" "$assignment_context_proof_route" \
          "$assignment_context_proof_live_workdir" "$assignment_prompt_file"; then
          soft_routed_active=1
        fi
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
  expected_login=""
  expected_git_identity=""
  expected_git_email=""
  observed_git_identity=""
  observed_git_email=""
  git_identity_match=""
  git_identity_repair=""
  git_identity_mismatch=0
  signals=("${scan_signals[@]}")
  if [ "$scan_partial" -eq 0 ] && [ -e "$workdir/.git" ]; then
    if [ "$AGENT_POOL_FETCH" = "1" ]; then
      git_quiet "$workdir" fetch origin "$DEFAULT_BRANCH" || true
    fi
    branch=$(git_value "$workdir" branch --show-current)
    head=$(git_value "$workdir" rev-parse --short HEAD)
    head_full=$(git_value "$workdir" rev-parse HEAD)
    upstream=$(git_value "$workdir" rev-parse --abbrev-ref --symbolic-full-name '@{u}')
    observed_git_identity=$(git_value "$workdir" config user.name)
    observed_git_email=$(git_value "$workdir" config user.email)
    if declare -F resolve_agent_github_login >/dev/null 2>&1; then
      expected_login=$(resolve_agent_github_login "$label" 2>/dev/null || true)
    fi
    identity_output=""
    identity_status=0
    identity_output=$(agent_git_identity "$label" 2>/dev/null) || identity_status=$?
    if [[ "$identity_status" -eq 0 ]]; then
      expected_git_identity=$(printf '%s\n' "$identity_output" | sed -n '1p')
      expected_git_email=$(printf '%s\n' "$identity_output" | sed -n '2p')
    else
      expected_git_identity=$(agent_pool_expected_git_identity_name "$label" 2>/dev/null || true)
    fi
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
  if [[ "$live_cwd_match" == "0" && "$soft_routed_active" -eq 1 ]]; then
    signals+=("soft_routed_active")
  elif [[ "$live_cwd_match" == "0" ]]; then
    signals+=("live_cwd_mismatch")
  fi
  if [[ -n "$live_pane_cwd" ]]; then
    occupied_assignment=""
    if occupied_assignment=$(worktree_active_assignment_for_path "$live_pane_cwd" 2>/dev/null); then
      IFS=$'\t' read -r occupied_project _ occupied_issue _ <<< "$occupied_assignment"
      signals+=("$(worktree_active_assignment_signal "$occupied_project" "$occupied_issue")")
    fi
  fi

  if [[ -n "$expected_git_identity" ]]; then
    if [[ "$observed_git_identity" == "$expected_git_identity" ]]; then
      git_identity_match=1
    else
      git_identity_match=0
      git_identity_mismatch=1
    fi
  elif [[ -n "$expected_login" && "$expected_login" != "$label" ]]; then
    if [[ "$observed_git_identity" == "$expected_login" ]] \
      || [[ "${observed_git_identity,,}" == *"${expected_login,,}"* ]]; then
      git_identity_match=1
    else
      git_identity_match=0
      git_identity_mismatch=1
    fi
  fi

  if [[ "$git_identity_mismatch" -eq 1 ]]; then
    expected_signal=$(agent_pool_signal_value "${expected_login:-${expected_git_identity:-unknown}}")
    observed_signal=$(agent_pool_signal_value "$observed_git_identity")
    signals+=("git_identity_mismatch:expected_login=${expected_signal}:observed=${observed_signal}")
    if [[ -n "$expected_git_identity" && -n "$expected_git_email" ]]; then
      git_identity_repair="set-git-identity"
    else
      git_identity_repair="configure-git-identity"
    fi
  fi

  workdir_is_git=0
  [ -e "$workdir/.git" ] && workdir_is_git=1
  capacity_class=$(dispatch_capacity_classify \
    "$label" "$alive" "$workdir" "$live_pane_cwd" "$branch" \
    "$DEFAULT_BRANCH" "${dirty:-0}" "$pr" "$workdir_is_git")
  if [[ "$soft_routed_active" -eq 1 \
    && ( "$capacity_class" == "available" || "$capacity_class" == "switch_required" ) ]]; then
    capacity_class="local_work"
  fi
  if [[ "$git_identity_mismatch" -eq 1 && "$capacity_class" == "available" ]]; then
    capacity_class="identity_mismatch"
  fi
  declaration_json=$(agent_pool_declaration_snapshot "$label")
  declaration_state=$(printf '%s' "$declaration_json" | jq -r '.state // ""')
  declared_status=$(printf '%s' "$declaration_json" | jq -r '.status // ""')
  declared_reason=$(printf '%s' "$declaration_json" | jq -r '.reason // ""')
  declaration_age_sec=$(printf '%s' "$declaration_json" | jq -r '.age_sec // ""')
  declaration_required_action=$(printf '%s' "$declaration_json" | jq -r '.required_action // ""')
  declaration_evidence=$(printf '%s' "$declaration_json" | jq -r '.evidence // ""')
  declaration_wake_pending=$(printf '%s' "$declaration_json" | jq -r '.wake_pending // 0')
  case "$declaration_state" in
    missing) signals+=("agent-declaration-missing") ;;
    stale) signals+=("agent-declaration-stale") ;;
  esac
  case "$declared_status" in
    blocked|waiting_for_operator|no_progress|handoff_ready|done)
      signals+=("agent-declaration-$declared_status")
      ;;
  esac

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
      --arg capacity_class "$capacity_class" \
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
      --arg expected_login "$expected_login" \
      --arg expected_git_identity "$expected_git_identity" \
      --arg expected_git_email "$expected_git_email" \
      --arg observed_git_identity "$observed_git_identity" \
      --arg observed_git_email "$observed_git_email" \
      --arg git_identity_match "$git_identity_match" \
      --arg git_identity_repair "$git_identity_repair" \
      --arg signals "$signal_text" \
      --argjson declaration "$declaration_json" \
      '{label:$agent_label,pane:$pane,alive:$alive,command:$command,assigned_workdir:$assigned_workdir,live_pane_cwd:$live_pane_cwd,live_cwd_match:$live_cwd_match,capacity_class:$capacity_class,branch:$branch,head:$head,upstream:$upstream,ahead:$ahead,behind:$behind,dirty:$dirty,base_current:$base_current,pr:$pr,pr_state:$pr_state,pr_sha:$pr_sha,expected_login:$expected_login,expected_git_identity:$expected_git_identity,expected_git_email:$expected_git_email,observed_git_identity:$observed_git_identity,observed_git_email:$observed_git_email,git_identity_match:$git_identity_match,git_identity_repair:$git_identity_repair,declaration:$declaration,signals:($signals | split(",") | map(select(length > 0)))}')")
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$label" "$pane" "$alive" "$command" \
      "$workdir" "$live_pane_cwd" "$live_cwd_match" \
      "$capacity_class" "$branch" "$head" \
      "$upstream" "$ahead" "$behind" "$dirty" "$base_current" "$pr" \
      "$pr_state" "$pr_sha" "$expected_login" "$expected_git_identity" \
      "$expected_git_email" "$observed_git_identity" "$observed_git_email" \
      "$git_identity_match" "$git_identity_repair" "$signal_text" \
      "$(agent_pool_tsv_value "$declared_status")" \
      "$(agent_pool_tsv_value "$declaration_state")" \
      "$(agent_pool_tsv_value "$declaration_age_sec")" \
      "$(agent_pool_tsv_value "$declaration_required_action")" \
      "$(agent_pool_tsv_value "$declared_reason")" \
      "$(agent_pool_tsv_value "$declaration_evidence")" \
      "$(agent_pool_tsv_value "$declaration_wake_pending")"
  fi
done < <(agent_inventory_entries)

if [ "$FORMAT" = "json" ]; then
  printf '%s\n' "${json_items[@]}" | jq -s '.'
fi
