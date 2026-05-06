#!/usr/bin/env bash
# scripts/agent_product_switch.sh - move a clean/parked agent pane to another product.
#
# Usage:
#   agent_product_switch.sh <portfolio-config> <source-project> <agent> <target-project> [--target-agent <agent>] [--reason <text>] [--no-brief] [--force] [--dry-run]
#
# The source repo must be clean. If it is on a non-default branch, that branch
# must already have an open PR unless --force is provided.
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
    --force)
      FORCE=1
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

inventory_entry_json() {
  local cfg=${1:?usage: inventory_entry_json <config> <selector>}
  local selector=${2:?usage: inventory_entry_json <config> <selector>}
  bash -c '
    set -euo pipefail
    tk=$1
    cfg=$2
    selector=$3
    # shellcheck disable=SC1090
    source "$cfg"
    # shellcheck source=lib/agent_inventory.sh
    source "$tk/lib/agent_inventory.sh"
    entry=$(agent_inventory_find "$selector") || exit 4
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
  ' _ "$TK" "$cfg" "$selector"
}

source_entry=$(inventory_entry_json "$SOURCE_CFG" "$AGENT_SELECTOR") || {
  echo "agent not found in source project: $AGENT_SELECTOR" >&2
  exit 3
}

target_selector=${TARGET_AGENT:-$AGENT_SELECTOR}
target_entry=$(inventory_entry_json "$TARGET_CFG" "$target_selector" 2>/dev/null || true)
if [[ -z "$target_entry" ]]; then
  source_session=$(printf '%s' "$source_entry" | jq -r '.pane | split(":")[0]')
  target_entry=$(inventory_entry_json "$TARGET_CFG" "$source_session" 2>/dev/null || true)
fi
if [[ -z "$target_entry" ]]; then
  echo "agent not found in target project: ${TARGET_AGENT:-$AGENT_SELECTOR}" >&2
  echo "hint: add an AGENT_PANES entry for the same physical pane to the target project config" >&2
  exit 4
fi

source_pane=$(printf '%s' "$source_entry" | jq -r '.pane')
target_pane=$(printf '%s' "$target_entry" | jq -r '.pane')
source_session=${source_pane%%:*}
target_session=${target_pane%%:*}
if [[ "$source_session" != "$target_session" ]]; then
  echo "refusing cross-pane switch: source pane=$source_pane target pane=$target_pane" >&2
  echo "hint: product switching is a physical-pane rebalance; target config must map the same pane" >&2
  exit 5
fi

source_workdir=$(printf '%s' "$source_entry" | jq -r '.workdir')
target_workdir=$(printf '%s' "$target_entry" | jq -r '.workdir')
source_default=$(printf '%s' "$source_entry" | jq -r '.default_branch')
source_repo=$(printf '%s' "$source_entry" | jq -r '.repo')
target_repo=$(printf '%s' "$target_entry" | jq -r '.repo')

[[ -d "$source_workdir/.git" ]] || { echo "source workdir is not a git repo: $source_workdir" >&2; exit 6; }
[[ -d "$target_workdir/.git" ]] || { echo "target workdir is not a git repo: $target_workdir" >&2; exit 6; }

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
  exit 7
fi

switched_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
state_dir=$(portfolio_state_dir)
state_file="$state_dir/switches.json"
switch_record=$(jq -nc \
  --arg pane "$source_pane" \
  --arg source_project "$SOURCE_PROJECT" \
  --arg source_agent "$(printf '%s' "$source_entry" | jq -r '.label')" \
  --arg source_workdir "$source_workdir" \
  --arg source_branch "$source_branch" \
  --arg source_head "$source_head" \
  --arg source_pr "$source_pr" \
  --arg source_pr_state "$source_pr_state" \
  --arg target_project "$TARGET_PROJECT" \
  --arg target_agent "$(printf '%s' "$target_entry" | jq -r '.label')" \
  --arg target_workdir "$target_workdir" \
  --arg target_repo "$target_repo" \
  --arg safe_state "$safe_state" \
  --arg reason "$REASON" \
  --arg switched_at "$switched_at" \
  '{
    pane:$pane,
    source_project:$source_project,
    source_agent:$source_agent,
    source_workdir:$source_workdir,
    source_branch:$source_branch,
    source_head:$source_head,
    source_pr:(if $source_pr == "" then null else ($source_pr | tonumber) end),
    source_pr_state:$source_pr_state,
    target_project:$target_project,
    target_agent:$target_agent,
    target_workdir:$target_workdir,
    target_repo:$target_repo,
    safe_state:$safe_state,
    reason:$reason,
    switched_at:$switched_at
  }')

if dry_run_enabled; then
  printf 'DRY-RUN: switch pane=%s source=%s/%s state=%s target=%s/%s workdir=%s\n' \
    "$source_pane" "$SOURCE_PROJECT" "$source_branch" "$safe_state" "$TARGET_PROJECT" \
    "$(printf '%s' "$target_entry" | jq -r '.label')" "$target_workdir"
  printf 'DRY-RUN: tmux respawn-pane -k -t %s -c %s <detected-agent-cli>\n' "$target_pane" "$target_workdir"
  if [[ "$SEND_BRIEF" -eq 1 ]]; then
    printf 'DRY-RUN: send context brief to %s\n' "$target_pane"
  fi
  printf '%s\n' "$switch_record"
  exit 0
fi

tmux has-session -t "$target_session" 2>/dev/null || {
  echo "tmux session not found: $target_session" >&2
  exit 8
}

# shellcheck disable=SC1090
source "$TARGET_CFG"
source "$TK/lib/tmux_helpers.sh"
source "$TK/lib/worktree_helpers.sh"
launch_cmd=$(agent_launch_command "$target_pane")
tmux respawn-pane -k -t "$target_pane" -c "$target_workdir" "$launch_cmd"

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

if [[ "$SEND_BRIEF" -eq 1 ]]; then
  sleep 2
  brief="You are now on project ${TARGET_PROJECT} (${target_repo}) in ${target_workdir}. Read local project instructions before accepting work. Previous project ${SOURCE_PROJECT} is parked on ${source_branch:-unknown}${source_pr:+ PR #$source_pr}. Report ready status only."
  tmux send-keys -t "$target_pane" "$brief"
  sleep 0.3
  tmux send-keys -t "$target_pane" Enter
fi

printf 'switched pane=%s source=%s target=%s workdir=%s state=%s\n' \
  "$source_pane" "$SOURCE_PROJECT" "$TARGET_PROJECT" "$target_workdir" "$safe_state"
