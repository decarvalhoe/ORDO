#!/usr/bin/env bash
# scripts/agent_product_switch.sh - move or soft-route a clean/parked agent to another product.
#
# Usage:
#   agent_product_switch.sh <portfolio-config> <source-project> <agent> <target-project> [--target-agent <agent>] [--soft] [--reason <text>] [--no-brief] [--force] [--dry-run]
#
# The source repo must be clean. If it is on a non-default branch, that branch
# must already have an open PR unless --force is provided.
#
# Default hard mode respawns the physical pane into the target workdir. Soft
# mode keeps the pane where it is and sends a target_workdir brief; this is the
# safest universal mode for agents that can operate on absolute paths or `cd`
# inside a terminal without losing their current session context.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/portfolio_config.sh"
source "$TK/lib/process_safety.sh"
# Forge access goes through the provider adapter (#816): no direct gh call.
# shellcheck source=../lib/ordo_provider_adapter.sh
source "$TK/lib/ordo_provider_adapter.sh"


dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

PORTFOLIO_ARG=${1:?usage: agent_product_switch.sh <portfolio> <source-project> <agent> <target-project> [--dry-run]}
SOURCE_PROJECT=${2:?missing source project}
AGENT_SELECTOR=${3:?missing agent selector}
TARGET_PROJECT=${4:?missing target project}
shift 4

TARGET_AGENT=""
REASON="portfolio-rebalance"
SEND_BRIEF=1
FORCE=0
MODE="hard"
STRICT_CONTEXT=1
ALLOW_TARGET_BRANCH=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target-agent)
      TARGET_AGENT=${2:?missing value for --target-agent}
      shift 2
      ;;
    --reason)
      REASON=${2:?missing value for --reason}
      shift 2
      ;;
    --no-brief)
      SEND_BRIEF=0
      shift
      ;;
    --soft)
      MODE="soft"
      shift
      ;;
    --hard)
      MODE="hard"
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --no-strict-context)
      STRICT_CONTEXT=0
      shift
      ;;
    --allow-target-branch)
      ALLOW_TARGET_BRANCH=1
      shift
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

load_portfolio_config "$PORTFOLIO_ARG"
SOURCE_CFG=$(portfolio_find_project "$SOURCE_PROJECT")
TARGET_CFG=$(portfolio_find_project "$TARGET_PROJECT")
state_dir=$(portfolio_state_dir)
unblock_file="$state_dir/unblock_tasks.json"
unblock_task_list="$state_dir/ORCH_TASKS.md"
matrix_spec=$(portfolio_fleet_spec)
ensure_matrix="${PORTFOLIO_ENSURE_AGENT_MATRIX:-}"
if [[ -z "$ensure_matrix" ]]; then
  if [[ -n "$matrix_spec" ]]; then
    ensure_matrix=1
  else
    ensure_matrix=0
  fi
fi

inventory_entry_json() {
  local cfg=${1:?usage: inventory_entry_json <config> <selector>}
  local selector=${2:?usage: inventory_entry_json <config> <selector>}
  local matrix_spec=${3:-}
  local ensure_matrix=${4:-0}
  bash -c '
    set -euo pipefail
    tk=$1
    cfg=$2
    selector=$3
    matrix_spec=$4
    ensure_matrix=$5
    # shellcheck disable=SC1090
    source "$cfg"
    # shellcheck source=lib/agent_inventory.sh
    source "$tk/lib/agent_inventory.sh"
    # shellcheck source=lib/portfolio_config.sh
    source "$tk/lib/portfolio_config.sh"
    entry=$(agent_inventory_find "$selector" 2>/dev/null || true)
    if [[ -z "$entry" ]]; then
      entry=$(portfolio_matrix_entry_from_loaded_project "$selector" "$matrix_spec" "$ensure_matrix") || exit 4
    fi
    IFS="|" read -r label pane workdir <<< "$entry"
    jq -nc \
      --arg agent_label "$label" \
      --arg pane "$pane" \
      --arg workdir "$workdir" \
      --arg project "${PROJECT:-}" \
      --arg repo "${GH_REPO:-}" \
      --arg default_branch "${DEFAULT_BRANCH:-main}" \
      --arg config "$cfg" \
      "{label:\$agent_label,pane:\$pane,workdir:\$workdir,project:\$project,repo:\$repo,default_branch:\$default_branch,config:\$config}"
  ' _ "$TK" "$cfg" "$selector" "$matrix_spec" "$ensure_matrix"
}

source_entry=$(inventory_entry_json "$SOURCE_CFG" "$AGENT_SELECTOR" "$matrix_spec" "$ensure_matrix") || {
  echo "agent not found in source project: $AGENT_SELECTOR" >&2
  exit 3
}

target_selector=${TARGET_AGENT:-$AGENT_SELECTOR}
target_entry=$(inventory_entry_json "$TARGET_CFG" "$target_selector" "$matrix_spec" "$ensure_matrix" 2>/dev/null || true)
if [[ -z "$target_entry" ]]; then
  source_session=$(printf '%s' "$source_entry" | jq -r '.pane | split(":")[0]')
  target_entry=$(inventory_entry_json "$TARGET_CFG" "$source_session" "$matrix_spec" "$ensure_matrix" 2>/dev/null || true)
fi
if [[ -z "$target_entry" ]]; then
  echo "agent not found in target project: ${TARGET_AGENT:-$AGENT_SELECTOR}" >&2
  echo "hint: add an AGENT_PANES entry for the same physical pane or a PORTFOLIO_FLEET_AGENTS matrix entry" >&2
  exit 4
fi

source_pane=$(printf '%s' "$source_entry" | jq -r '.pane')
target_pane=$(printf '%s' "$target_entry" | jq -r '.pane')
source_workdir=$(printf '%s' "$source_entry" | jq -r '.workdir')
target_workdir=$(printf '%s' "$target_entry" | jq -r '.workdir')
source_default=$(printf '%s' "$source_entry" | jq -r '.default_branch')
source_repo=$(printf '%s' "$source_entry" | jq -r '.repo')
target_repo=$(printf '%s' "$target_entry" | jq -r '.repo')
target_default=$(printf '%s' "$target_entry" | jq -r '.default_branch')
source_session=${source_pane%%:*}
target_session=${target_pane%%:*}
brief_pane=$target_pane
brief_session=$target_session
if [[ "$MODE" == "soft" ]]; then
  brief_pane=$source_pane
  brief_session=$source_session
fi

: "${AGENT_SWITCH_GIT_TIMEOUT_SEC:=5}"
: "${AGENT_SWITCH_GH_TIMEOUT_SEC:=5}"
: "${AGENT_SWITCH_TMUX_TIMEOUT_SEC:=5}"
: "${AGENT_SWITCH_SINGLE_FLIGHT_TTL_SEC:=180}"
: "${AGENT_SWITCH_VERIFY_READY:=1}"
: "${AGENT_SWITCH_READY_RETRIES:=5}"
: "${AGENT_SWITCH_READY_DELAY_SEC:=1}"
SWITCH_GIT_DEGRADED=0

switch_git_value() {
  local repo=${1:?usage: switch_git_value <repo> <git-args...>}
  local output status
  shift
  set +e
  output=$(orch_run_timeout "$AGENT_SWITCH_GIT_TIMEOUT_SEC" git -C "$repo" "$@" 2>/dev/null)
  status=$?
  set -e
  if [[ "$status" -eq "$ORCH_TIMEOUT_EXIT_CODE" || "$status" -eq 137 ]]; then
    SWITCH_GIT_DEGRADED=1
  fi
  printf '%s' "$output"
  [[ -n "$output" ]] && printf '\n'
  return 0
}

switch_tmux_run() {
  orch_run_timeout "$AGENT_SWITCH_TMUX_TIMEOUT_SEC" tmux "$@"
}

record_unblock_task() {
  local code=${1:?usage: record_unblock_task <code> <exit-code> <action> <detail>}
  local exit_code=${2:?usage: record_unblock_task <code> <exit-code> <action> <detail>}
  local action=${3:?usage: record_unblock_task <code> <exit-code> <action> <detail>}
  local detail=${4:?usage: record_unblock_task <code> <exit-code> <action> <detail>}
  local created_at id record tmp source_label target_label

  created_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  source_label=$(printf '%s' "$source_entry" | jq -r '.label // ""')
  target_label=$(printf '%s' "$target_entry" | jq -r '.label // ""')
  id=$(printf '%s' \
    "${SOURCE_PROJECT}|${source_label}|${source_workdir}|${source_branch:-}|${TARGET_PROJECT}|${target_label}|${target_workdir}|${target_branch:-}|${MODE}|${code}" \
    | sha256sum | awk '{print substr($1,1,16)}')

  record=$(jq -nc \
    --arg id "$id" \
    --arg created_at "$created_at" \
    --arg status "open" \
    --arg code "$code" \
    --argjson exit_code "$exit_code" \
    --arg action "$action" \
    --arg detail "$detail" \
    --arg mode "$MODE" \
    --arg reason "$REASON" \
    --arg source_project "$SOURCE_PROJECT" \
    --arg source_agent "$source_label" \
    --arg source_pane "$source_pane" \
    --arg source_workdir "$source_workdir" \
    --arg source_branch "${source_branch:-}" \
    --arg source_default "$source_default" \
    --arg source_pr "${source_pr:-}" \
    --arg source_pr_state "${source_pr_state:-}" \
    --arg target_project "$TARGET_PROJECT" \
    --arg target_agent "$target_label" \
    --arg target_pane "$target_pane" \
    --arg target_workdir "$target_workdir" \
    --arg target_branch "${target_branch:-}" \
    --arg target_default "$target_default" \
    '{
      id:$id,
      created_at:$created_at,
      status:$status,
      code:$code,
      exit_code:$exit_code,
      recommended_action:$action,
      detail:$detail,
      mode:$mode,
      reason:$reason,
      source_project:$source_project,
      source_agent:$source_agent,
      source_pane:$source_pane,
      source_workdir:$source_workdir,
      source_branch:$source_branch,
      source_default:$source_default,
      source_pr:(if $source_pr == "" then null else $source_pr end),
      source_pr_state:$source_pr_state,
      target_project:$target_project,
      target_agent:$target_agent,
      target_pane:$target_pane,
      target_workdir:$target_workdir,
      target_branch:$target_branch,
      target_default:$target_default
    }')

  if dry_run_enabled; then
    printf 'DRY-RUN: portfolio unblock task id=%s code=%s action=%s\n' "$id" "$code" "$action" >&2
    return 0
  fi

  mkdir -p "$state_dir"
  tmp="${unblock_file}.tmp.$$"
  if [[ -s "$unblock_file" ]]; then
    jq --arg id "$id" --argjson record "$record" \
      '.open[$id] = $record | .history = ((.history // []) + [$record])' \
      "$unblock_file" > "$tmp"
  else
    jq -nc --arg id "$id" --argjson record "$record" \
      '{open:{($id):$record},history:[$record]}' > "$tmp"
  fi
  mv "$tmp" "$unblock_file"

  if [[ ! -f "$unblock_task_list" ]]; then
    printf '# ORDO Portfolio Unblock Tasks\n\n' > "$unblock_task_list"
  fi
  if ! grep -q "id=$id" "$unblock_task_list" 2>/dev/null; then
    printf -- '- [ ] %s id=%s code=%s source=%s/%s target=%s/%s action=%s\n' \
      "$created_at" "$id" "$code" "$SOURCE_PROJECT" "${source_label:-unknown}" \
      "$TARGET_PROJECT" "${target_label:-unknown}" "$action" >> "$unblock_task_list"
  fi
}

switch_lock_name="agent_product_switch.${source_pane}.${SOURCE_PROJECT}.${TARGET_PROJECT}"
switch_lock_acquired=0
if orch_single_flight_enter "$switch_lock_name" "$AGENT_SWITCH_SINGLE_FLIGHT_TTL_SEC"; then
  switch_lock_acquired=1
else
  printf 'refusing switch: another switch is already in progress pane=%s owner_pid=%s age=%ss\n' \
    "$source_pane" "${ORCH_SINGLE_FLIGHT_OWNER_PID:-unknown}" "${ORCH_SINGLE_FLIGHT_OWNER_AGE:-unknown}" >&2
  record_unblock_task \
    "switch-in-progress" \
    11 \
    "Wait for the active switch to finish or clear a stale switch lock after verifying no switch process is alive." \
    "pane=$source_pane owner_pid=${ORCH_SINGLE_FLIGHT_OWNER_PID:-unknown} age=${ORCH_SINGLE_FLIGHT_OWNER_AGE:-unknown}"
  exit 11
fi
cleanup_switch_lock() {
  if [[ "$switch_lock_acquired" -eq 1 ]]; then
    orch_single_flight_release "$(orch_lock_path "$switch_lock_name")"
  fi
}
trap cleanup_switch_lock EXIT

if [[ "$MODE" == "hard" && "$source_session" != "$target_session" ]]; then
  echo "refusing cross-pane switch: source pane=$source_pane target pane=$target_pane" >&2
  echo "hint: use --soft for subrepo/workspace routing without respawning the pane" >&2
  record_unblock_task \
    "hard-cross-pane-mapping" \
    5 \
    "Use --soft or add a matching physical pane mapping to the target project config." \
    "source_pane=$source_pane target_pane=$target_pane"
  exit 5
fi

if [[ ! -d "$source_workdir/.git" ]]; then
  echo "source workdir is not a git repo: $source_workdir" >&2
  record_unblock_task \
    "source-missing-git-repo" \
    6 \
    "Clone or repair the source workdir before switching this agent." \
    "source_workdir=$source_workdir"
  exit 6
fi
if [[ ! -d "$target_workdir/.git" ]]; then
  echo "target workdir is not a git repo: $target_workdir" >&2
  record_unblock_task \
    "target-missing-git-repo" \
    6 \
    "Clone or repair the target workdir before dispatching this agent there." \
    "target_workdir=$target_workdir"
  exit 6
fi

source_branch=$(switch_git_value "$source_workdir" branch --show-current)
source_head=$(switch_git_value "$source_workdir" rev-parse --short HEAD)
source_head_full=$(switch_git_value "$source_workdir" rev-parse HEAD)
dirty_count=$(switch_git_value "$source_workdir" status --porcelain | wc -l | tr -d ' ')
if [[ "$SWITCH_GIT_DEGRADED" -eq 1 ]]; then
  echo "refusing switch: git status checks timed out for source workdir: $source_workdir" >&2
  record_unblock_task \
    "source-git-timeout" \
    12 \
    "Inspect the source clone manually; ORDO refused to infer clean/parkable state from timed-out git commands." \
    "source_workdir=$source_workdir timeout=${AGENT_SWITCH_GIT_TIMEOUT_SEC}s"
  exit 12
fi
source_pr=""
source_pr_state=""
source_pr_head=""
if [[ -n "$source_repo" && -n "$source_branch" ]] && ordo_provider_backend_available; then
  pr_json=$(ORDO_PROVIDER_TIMEOUT_SEC="$AGENT_SWITCH_GH_TIMEOUT_SEC" GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" ordo_provider pr_list \
    --repo "$source_repo" \
    --state open \
    --head "$source_branch" \
    --limit 1 2>/dev/null | jq -c '.items' 2>/dev/null || printf '[]')
  source_pr=$(printf '%s' "$pr_json" | jq -r '.[0].number // ""')
  source_pr_state=$(printf '%s' "$pr_json" | jq -r '.[0].merge_state // "" | ascii_upcase')
  source_pr_head=$(printf '%s' "$pr_json" | jq -r '.[0].head.sha // ""')
fi

safe_state="free"
unsafe_reason=""
if [[ "${dirty_count:-0}" != "0" ]]; then
  safe_state="unsafe"
  unsafe_reason="dirty-worktree"
elif [[ "$source_branch" != "$source_default" ]]; then
  if [[ -z "$source_pr" ]]; then
    safe_state="unsafe"
    unsafe_reason="branch-without-open-pr"
  elif [[ "$source_pr_state" == "DIRTY" || "$source_pr_state" == "BEHIND" ]]; then
    safe_state="unsafe"
    unsafe_reason="pr-needs-human-action"
  elif [[ -n "$source_pr_head" && -n "$source_head_full" && "$source_pr_head" != "$source_head_full" ]]; then
    safe_state="parked-pr-stale"
  else
    safe_state="parked-pr"
  fi
fi

if [[ "$safe_state" == "unsafe" && "$FORCE" -ne 1 ]]; then
  printf 'refusing switch: %s branch=%s dirty=%s pr=%s pr_state=%s\n' \
    "$unsafe_reason" "$source_branch" "$dirty_count" "${source_pr:-none}" "${source_pr_state:-none}" >&2
  case "$unsafe_reason" in
    dirty-worktree)
      record_unblock_task \
        "source-dirty-worktree" \
        7 \
        "Review, commit, stash, or clean the source workdir before switching." \
        "source_workdir=$source_workdir dirty=$dirty_count"
      ;;
    branch-without-open-pr)
      record_unblock_task \
        "source-branch-without-pr" \
        7 \
        "Open a PR for the source branch or return the clone to the default branch after preserving work." \
        "source_branch=$source_branch default=$source_default"
      ;;
    pr-needs-human-action)
      record_unblock_task \
        "source-pr-needs-human-action" \
        7 \
        "Rebase or resolve the source PR blocker before parking this agent." \
        "source_pr=$source_pr pr_state=$source_pr_state"
      ;;
  esac
  exit 7
fi

if [[ "$safe_state" == "parked-pr-stale" ]]; then
  record_unblock_task \
    "source-remote-rebased-local-stale" \
    0 \
    "Keep agent parked while PR is open; on release run: cd $source_workdir && git fetch origin && git checkout $source_default && git pull --ff-only. Avoid destructive reset on the parked branch unless the PR is closed or merged." \
    "source_branch=$source_branch local_head=${source_head_full:-} pr_head=${source_pr_head:-}"
fi

target_branch=$(switch_git_value "$target_workdir" branch --show-current)
target_head=$(switch_git_value "$target_workdir" rev-parse --short HEAD)
target_dirty_count=$(switch_git_value "$target_workdir" status --porcelain | wc -l | tr -d ' ')
if [[ "$SWITCH_GIT_DEGRADED" -eq 1 ]]; then
  echo "refusing switch: git status checks timed out for target workdir: $target_workdir" >&2
  record_unblock_task \
    "target-git-timeout" \
    12 \
    "Inspect the target clone manually; ORDO refused to dispatch into a clone whose git state timed out." \
    "target_workdir=$target_workdir timeout=${AGENT_SWITCH_GIT_TIMEOUT_SEC}s"
  exit 12
fi
if [[ "$MODE" == "soft" && "$STRICT_CONTEXT" -eq 1 ]]; then
  if [[ "${target_dirty_count:-0}" != "0" && "$FORCE" -ne 1 ]]; then
    printf 'refusing soft switch: target workdir dirty target=%s dirty=%s\n' "$target_workdir" "$target_dirty_count" >&2
    record_unblock_task \
      "target-dirty-worktree" \
      9 \
      "Review, commit, stash, or clean the target workdir before soft dispatch." \
      "target_workdir=$target_workdir dirty=$target_dirty_count"
    exit 9
  fi
  if [[ "$target_branch" != "$target_default" && "$ALLOW_TARGET_BRANCH" -ne 1 && "$FORCE" -ne 1 ]]; then
    printf 'refusing soft switch: target branch is not default target=%s branch=%s default=%s\n' "$target_workdir" "$target_branch" "$target_default" >&2
    record_unblock_task \
      "target-non-default-branch" \
      10 \
      "Finish, PR, merge, or checkout the target default branch; use --allow-target-branch only when intentional." \
      "target_workdir=$target_workdir branch=$target_branch default=$target_default"
    exit 10
  fi
fi

switched_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
state_file="$state_dir/switches.json"
contract_file="$state_dir/contracts/${source_pane//[:.\/]/_}.json"
target_label=$(printf '%s' "$target_entry" | jq -r '.label')

# Issue #305: in hard mode, resolve the target launch command (preferring an
# AGENT_LAUNCH_CONTRACTS entry from the target profile) and verify that it
# carries the per-agent identity flags expected by the original fleet. Surface
# any drift as an unblock task so a hard switch never silently respawns the
# pane with only model/effort flags. Resolution is done in a subshell so
# sourcing TARGET_CFG does not pollute the calling shell.
launch_cmd=""
launch_cli=""
launch_cmd_missing_identity=""
if [[ "$MODE" == "hard" ]]; then
  launch_resolution=$(
    set +e
    # shellcheck disable=SC1090
    source "$TARGET_CFG"
    # shellcheck source=lib/worktree_helpers.sh
    source "$TK/lib/worktree_helpers.sh"
    cmd=$(agent_launch_command "$target_pane" "$target_label" 2>/dev/null) || cmd=""
    # Derive the CLI from the resolved command first (most reliable: works in
    # test environments where tmux capture-pane is unavailable). Fall back to
    # live pane detection, then to the session-name heuristic.
    cli=""
    if [[ -n "$cmd" ]]; then
      trimmed=${cmd#exec }
      first=${trimmed%% *}
      first=${first##*/}
      case "$first" in
        claude|codex) cli=$first ;;
      esac
    fi
    if [[ -z "$cli" ]]; then
      cli=$(detect_agent_cli "$target_pane" 2>/dev/null || true)
    fi
    if [[ -z "$cli" || "$cli" == "unknown" ]]; then
      session_logical=${target_pane%%:*}
      cli=${session_logical##*-}
    fi
    missing=""
    if [[ -n "$cmd" ]]; then
      missing=$(agent_launch_command_missing_identity_tokens "$cmd" "$cli" 2>/dev/null | paste -sd ',' -)
    fi
    printf '%s\n%s\n%s\n' "$cmd" "$cli" "$missing"
  )
  launch_cmd=$(printf '%s' "$launch_resolution" | awk 'NR==1')
  launch_cli=$(printf '%s' "$launch_resolution" | awk 'NR==2')
  launch_cmd_missing_identity=$(printf '%s' "$launch_resolution" | awk 'NR==3')
fi
switch_record=$(jq -nc \
  --arg pane "$source_pane" \
  --arg mode "$MODE" \
  --arg brief_pane "$brief_pane" \
  --arg source_project "$SOURCE_PROJECT" \
  --arg source_agent "$(printf '%s' "$source_entry" | jq -r '.label')" \
  --arg source_workdir "$source_workdir" \
  --arg source_branch "$source_branch" \
  --arg source_head "$source_head" \
  --arg source_pr "$source_pr" \
  --arg source_pr_state "$source_pr_state" \
  --arg source_pr_head "$source_pr_head" \
  --arg target_project "$TARGET_PROJECT" \
  --arg target_agent "$(printf '%s' "$target_entry" | jq -r '.label')" \
  --arg target_pane "$target_pane" \
  --arg target_workdir "$target_workdir" \
  --arg target_repo "$target_repo" \
  --arg target_branch "$target_branch" \
  --arg target_head "$target_head" \
  --arg target_default "$target_default" \
  --arg target_dirty "$target_dirty_count" \
  --arg safe_state "$safe_state" \
  --arg reason "$REASON" \
  --arg switched_at "$switched_at" \
  --argjson strict_context "$STRICT_CONTEXT" \
  --argjson allow_target_branch "$ALLOW_TARGET_BRANCH" \
  '{
    pane:$pane,
    mode:$mode,
    brief_pane:$brief_pane,
    source_project:$source_project,
    source_agent:$source_agent,
    source_workdir:$source_workdir,
    source_branch:$source_branch,
    source_head:$source_head,
    source_pr:(if $source_pr == "" then null else ($source_pr | tonumber) end),
    source_pr_state:$source_pr_state,
    source_pr_head:(if $source_pr_head == "" then null else $source_pr_head end),
    target_project:$target_project,
    target_agent:$target_agent,
    target_pane:$target_pane,
    target_workdir:$target_workdir,
    target_repo:$target_repo,
    target_branch:$target_branch,
    target_head:$target_head,
    target_default:$target_default,
    target_dirty:($target_dirty | tonumber),
    safe_state:$safe_state,
    reason:$reason,
    switched_at:$switched_at,
    strict_context:$strict_context,
    allow_target_branch:$allow_target_branch
  }')

if dry_run_enabled; then
  printf 'DRY-RUN: switch mode=%s pane=%s source=%s/%s state=%s target=%s/%s workdir=%s\n' \
    "$MODE" \
    "$source_pane" "$SOURCE_PROJECT" "$source_branch" "$safe_state" "$TARGET_PROJECT" \
    "$(printf '%s' "$target_entry" | jq -r '.label')" "$target_workdir"
  if [[ "$MODE" == "hard" ]]; then
    printf 'DRY-RUN: tmux respawn-pane -k -t %s -c %s <detected-agent-cli>\n' "$target_pane" "$target_workdir"
    printf 'DRY-RUN: launch_cmd cli=%s cmd=%s\n' "${launch_cli:-unknown}" "${launch_cmd:-<unresolved>}"
    if [[ -n "$launch_cmd_missing_identity" ]]; then
      printf 'DRY-RUN: switch-launch-contract-missing target_pane=%s target_agent=%s missing=%s\n' \
        "$target_pane" "$target_label" "$launch_cmd_missing_identity" >&2
      record_unblock_task \
        "switch-launch-contract-missing" \
        0 \
        "Configure AGENT_LAUNCH_CONTRACTS for ${target_label} in the target project profile (or set AGENT_LAUNCH_COMMAND to include the missing identity flags) so the hard respawn preserves --name, debug log, and posture prompt." \
        "target_pane=$target_pane target_agent=${target_label} cli=${launch_cli:-unknown} missing=${launch_cmd_missing_identity}"
    fi
    if [[ "$AGENT_SWITCH_VERIFY_READY" == "1" ]]; then
      printf 'DRY-RUN: agent_pane_ready %s %s retries=%s delay=%ss\n' \
        "$target_pane" "$target_workdir" "$AGENT_SWITCH_READY_RETRIES" "$AGENT_SWITCH_READY_DELAY_SEC"
    fi
  else
    printf 'DRY-RUN: soft workspace keeps pane=%s and targets workdir=%s\n' "$source_pane" "$target_workdir"
  fi
  if [[ "$SEND_BRIEF" -eq 1 ]]; then
    printf 'DRY-RUN: send context brief to %s\n' "$brief_pane"
  fi
  if [[ "$MODE" == "soft" ]]; then
    printf 'DRY-RUN: write workspace contract %s\n' "$contract_file"
  fi
  printf '%s\n' "$switch_record"
  exit 0
fi

if ! orch_tmux_probe; then
  echo "refusing switch: ${ORCH_TMUX_DEGRADED_REASON:-tmux probe failed}" >&2
  record_unblock_task \
    "tmux-degraded" \
    13 \
    "Pause tmux-dependent switching and route via GitHub-only orchestration until tmux list-panes responds within threshold." \
    "pane=$brief_pane timeout=${ORCH_TMUX_LIST_PANES_TIMEOUT_SEC}s"
  exit 13
fi

switch_tmux_run has-session -t "$brief_session" 2>/dev/null || {
  echo "tmux session not found: $brief_session" >&2
  exit 8
}

if [[ "$MODE" == "hard" ]]; then
  # shellcheck disable=SC1090
  source "$TARGET_CFG"
  source "$TK/lib/tmux_helpers.sh"
  source "$TK/lib/worktree_helpers.sh"
  # Issue #305: re-resolve in the live shell so the actual respawn uses the
  # same command that the dry-run / launch-contract pre-check inspected.
  if [[ -z "$launch_cmd" ]]; then
    launch_cmd=$(agent_launch_command "$target_pane" "$target_label")
  fi
  if [[ -n "$launch_cmd_missing_identity" ]]; then
    printf 'switch launch contract incomplete: target_pane=%s target_agent=%s cli=%s missing=%s\n' \
      "$target_pane" "$target_label" "${launch_cli:-unknown}" "$launch_cmd_missing_identity" >&2
    record_unblock_task \
      "switch-launch-contract-missing" \
      0 \
      "Configure AGENT_LAUNCH_CONTRACTS for ${target_label} in the target project profile (or set AGENT_LAUNCH_COMMAND to include the missing identity flags) so the hard respawn preserves --name, debug log, and posture prompt." \
      "target_pane=$target_pane target_agent=${target_label} cli=${launch_cli:-unknown} missing=${launch_cmd_missing_identity}"
  fi
  switch_tmux_run respawn-pane -k -t "$target_pane" -c "$target_workdir" "$launch_cmd" || {
    echo "tmux respawn-pane timed out or failed for pane=$target_pane" >&2
    record_unblock_task \
      "switch-respawn-timeout" \
      14 \
      "Inspect the pane and target workdir, then retry the switch after tmux is responsive." \
      "target_pane=$target_pane target_workdir=$target_workdir timeout=${AGENT_SWITCH_TMUX_TIMEOUT_SEC}s"
    exit 14
  }

  # Issue #123: verify the post-respawn pane is ready to receive a
  # dispatch (claude CLI alive, pane responsive, workdir correct) before
  # any send-keys runs. Previous incidents (issue #89 comment 19:34Z)
  # delivered briefs into a still-booting shell and silently lost work.
  if [[ "$AGENT_SWITCH_VERIFY_READY" == "1" ]]; then
    if ! agent_pane_ready "$target_pane" "$target_workdir" \
      "$AGENT_SWITCH_READY_RETRIES" "$AGENT_SWITCH_READY_DELAY_SEC"; then
      printf 'switch ready handshake failed: pane=%s reason=%s detail=%s\n' \
        "$target_pane" "${AGENT_READY_REASON:-unknown}" "${AGENT_READY_DETAIL:-}" >&2
      record_unblock_task \
        "switch-pane-not-ready" \
        15 \
        "Inspect the pane: confirm the agent CLI launched in $target_workdir, then retry the switch. Do not trust dispatch delivery until the readiness handshake passes." \
        "pane=$target_pane reason=${AGENT_READY_REASON:-unknown} detail=${AGENT_READY_DETAIL:-} retries=${AGENT_SWITCH_READY_RETRIES} delay=${AGENT_SWITCH_READY_DELAY_SEC}s"
      exit 15
    fi
  fi
fi

mkdir -p "$state_dir"
tmp="${state_file}.tmp.$$"
if [[ -s "$state_file" ]]; then
  jq --arg pane "$source_pane" --argjson record "$switch_record" \
    '.active[$pane] = $record | .history = ((.history // []) + [$record])' \
    "$state_file" > "$tmp"
else
  jq -nc --arg pane "$source_pane" --argjson record "$switch_record" \
    '{active:{($pane):$record},history:[$record]}' > "$tmp"
fi
mv "$tmp" "$state_file"

if [[ "$MODE" == "soft" ]]; then
  mkdir -p "$(dirname "$contract_file")"
  printf '%s\n' "$switch_record" > "$contract_file"
fi

if [[ "$SEND_BRIEF" -eq 1 ]]; then
  if [[ "$MODE" == "hard" ]]; then
    sleep 2
    brief="You are now on project ${TARGET_PROJECT} (${target_repo}) in ${target_workdir}. Read local project instructions before accepting work. Previous project ${SOURCE_PROJECT} is parked on ${source_branch:-unknown}${source_pr:+ PR #$source_pr}. Report ready status only."
  else
    brief="Soft workspace assignment: keep this pane/session, but execute the next work in ${target_workdir} for project ${TARGET_PROJECT} (${target_repo}). Workspace contract: ${contract_file}. Before any mutation run: pwd; git -C ${target_workdir} status --short --branch; git -C ${target_workdir} remote -v; git -C ${target_workdir} rev-parse --verify origin/${target_default}; git -C ${target_workdir} rev-parse HEAD. Use cd ${target_workdir} or git -C ${target_workdir} for every command. Do not mutate ${source_workdir}. Previous project ${SOURCE_PROJECT} is parked on ${source_branch:-unknown}${source_pr:+ PR #$source_pr}. If the active repo does not match the target, stop and report context-mismatch."
  fi
  switch_tmux_run send-keys -t "$brief_pane" "$brief" || {
    echo "tmux send-keys timed out or failed for pane=$brief_pane" >&2
    record_unblock_task \
      "switch-brief-timeout" \
      14 \
      "Inspect the pane and retry the switch brief after tmux is responsive." \
      "brief_pane=$brief_pane timeout=${AGENT_SWITCH_TMUX_TIMEOUT_SEC}s"
    exit 14
  }
  sleep 0.3
  switch_tmux_run send-keys -t "$brief_pane" Enter || {
    echo "tmux send-keys Enter timed out or failed for pane=$brief_pane" >&2
    record_unblock_task \
      "switch-brief-submit-timeout" \
      14 \
      "Inspect the pane and retry the switch brief after tmux is responsive." \
      "brief_pane=$brief_pane timeout=${AGENT_SWITCH_TMUX_TIMEOUT_SEC}s"
    exit 14
  }
fi

printf 'switched mode=%s pane=%s source=%s target=%s workdir=%s state=%s\n' \
  "$MODE" "$source_pane" "$SOURCE_PROJECT" "$TARGET_PROJECT" "$target_workdir" "$safe_state"
