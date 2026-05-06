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
      --arg label "$label" \
      --arg pane "$pane" \
      --arg workdir "$workdir" \
      --arg project "${PROJECT:-}" \
      --arg repo "${GH_REPO:-}" \
      --arg default_branch "${DEFAULT_BRANCH:-main}" \
      --arg config "$cfg" \
      "{label:\$label,pane:\$pane,workdir:\$workdir,project:\$project,repo:\$repo,default_branch:\$default_branch,config:\$config}"
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

source_branch=$(git -C "$source_workdir" branch --show-current 2>/dev/null || true)
source_head=$(git -C "$source_workdir" rev-parse --short HEAD 2>/dev/null || true)
dirty_count=$(git -C "$source_workdir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
source_pr=""
source_pr_state=""
if [[ -n "$source_repo" && -n "$source_branch" ]] && command -v gh >/dev/null 2>&1; then
  pr_json=$(GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" gh pr list \
    --repo "$source_repo" \
    --state open \
    --head "$source_branch" \
    --json number,mergeStateStatus \
    --limit 1 2>/dev/null || printf '[]')
  source_pr=$(printf '%s' "$pr_json" | jq -r '.[0].number // ""')
  source_pr_state=$(printf '%s' "$pr_json" | jq -r '.[0].mergeStateStatus // ""')
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

target_branch=$(git -C "$target_workdir" branch --show-current 2>/dev/null || true)
target_head=$(git -C "$target_workdir" rev-parse --short HEAD 2>/dev/null || true)
target_dirty_count=$(git -C "$target_workdir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
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

tmux has-session -t "$brief_session" 2>/dev/null || {
  echo "tmux session not found: $brief_session" >&2
  exit 8
}

if [[ "$MODE" == "hard" ]]; then
  # shellcheck disable=SC1090
  source "$TARGET_CFG"
  source "$TK/lib/tmux_helpers.sh"
  source "$TK/lib/worktree_helpers.sh"
  launch_cmd=$(agent_launch_command "$target_pane")
  tmux respawn-pane -k -t "$target_pane" -c "$target_workdir" "$launch_cmd"
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
  tmux send-keys -t "$brief_pane" "$brief"
  sleep 0.3
  tmux send-keys -t "$brief_pane" Enter
fi

printf 'switched mode=%s pane=%s source=%s target=%s workdir=%s state=%s\n' \
  "$MODE" "$source_pane" "$SOURCE_PROJECT" "$TARGET_PROJECT" "$target_workdir" "$safe_state"
