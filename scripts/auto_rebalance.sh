#!/usr/bin/env bash
# scripts/auto_rebalance.sh - conservative external-wait rebalance pipeline.
#
# Usage:
#   auto_rebalance.sh <portfolio-config> [--apply] [--hard|--soft] [--json|--tsv] [--limit <n>] [--assign] [--dry-run]
#
# Default mode records a suggested AUTO_REBALANCE action only. --apply runs the
# existing switch -> brief -> dispatch path after the same conservative plan is
# selected.
set -euo pipefail

TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/portfolio_config.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

PORTFOLIO_ARG=${1:?usage: auto_rebalance.sh <portfolio-config> [--apply] [--dry-run]}
shift

APPLY=0
FORMAT="tsv"
MODE="hard"
ASSIGN=0
LIMIT=1
PRIORITY_ARGS=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=1
      ;;
    --suggest)
      APPLY=0
      ;;
    --hard)
      MODE="hard"
      ;;
    --soft)
      MODE="soft"
      ;;
    --json)
      FORMAT="json"
      ;;
    --tsv)
      FORMAT="tsv"
      ;;
    --assign)
      ASSIGN=1
      ;;
    --limit)
      LIMIT=${2:?missing value for --limit}
      shift
      ;;
    --limit=*)
      LIMIT=${1#--limit=}
      ;;
    --yolo-priority)
      # shellcheck disable=SC2034  # consumed by portfolio_config.sh helpers
      PORTFOLIO_YOLO_PRIORITY=1
      PRIORITY_ARGS+=(--yolo-priority)
      ;;
    *)
      printf 'auto_rebalance: unknown arg: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [[ "$LIMIT" -le 0 ]]; then
  printf 'auto_rebalance: --limit must be a positive integer\n' >&2
  exit 2
fi

if [[ "$APPLY" -eq 1 ]] && ! dry_run_enabled; then
  case "${AGENT_SWITCH_VERIFY_READY:-1}" in
    1|true|TRUE|yes|YES|on|ON) ;;
    *)
      printf 'auto_rebalance: refusing apply with AGENT_SWITCH_VERIFY_READY disabled\n' >&2
      exit 2
      ;;
  esac
  case "${DISPATCH_VERIFY_READY:-1}" in
    1|true|TRUE|yes|YES|on|ON) ;;
    *)
      printf 'auto_rebalance: refusing apply with DISPATCH_VERIFY_READY disabled\n' >&2
      exit 2
      ;;
  esac
  case "${ORCH_CONTEXT_PROOF:-1}" in
    1|true|TRUE|yes|YES|on|ON) ;;
    *)
      printf 'auto_rebalance: refusing apply with ORCH_CONTEXT_PROOF disabled\n' >&2
      exit 2
      ;;
  esac
  if [[ "$MODE" == "soft" && "${AUTO_REBALANCE_ALLOW_SOFT_APPLY:-0}" != "1" ]]; then
    printf 'auto_rebalance: refusing --apply --soft without AUTO_REBALANCE_ALLOW_SOFT_APPLY=1; hard mode provides the readiness and delivery proof path\n' >&2
    exit 2
  fi
fi

load_portfolio_config "$PORTFOLIO_ARG"
portfolio_require_priorities || exit 14

state_dir=$(portfolio_state_dir)
state_file="$state_dir/auto_rebalance.json"
task_file="$state_dir/ORCH_TASKS.md"

status_json=$(bash "$TK/scripts/portfolio_status.sh" "$ORCH_PORTFOLIO_CONFIG_PATH" --json "${PRIORITY_ARGS[@]}")
if ! jq -e 'type == "array"' <<< "$status_json" >/dev/null 2>&1; then
  printf 'auto_rebalance: portfolio_status did not return a JSON array\n' >&2
  exit 1
fi

source_candidates_json=$(jq -c '
  def disqualifying_signal:
    . as $signal
    | [
        "draft",
        "changes-requested",
        "review-required",
        "ci-failed",
        "needs-rebase",
        "merge-conflict",
        "pr-behind",
        "mergeable-unknown",
        "merge-state-unknown",
        "merge-state-unstable",
        "checks-missing"
      ]
    | index($signal) != null;

  def external_gate_pr:
    ((.deploy_gate_pending // 0) > 0)
    and ((.ci_fail // 0) == 0)
    and ((.ci_pending // 0) == (.deploy_gate_pending // 0))
    and ((.base_current // "1") != "0")
    and ([.signals[]? | select(disqualifying_signal)] | length == 0);

  [
    .[] as $project
    | ($project.agents.parkable // []) as $parkable_agents
    | select(($project.gate_state // "") == "external_wait")
    | select(($parkable_agents | length) > 0)
    | select((($project.counts.open_prs // 0) > 0)
        and (($project.counts.deploy_gate_wait // 0) > 0)
        and (($project.counts.ci_failed // 0) == 0)
        and (($project.counts.needs_rebase // 0) == 0)
        and (($project.counts.conflicts // 0) == 0)
        and (($project.counts.review_required // 0) == 0)
        and (($project.counts.merge_ready // 0) == 0))
    | select(([$project.prs[]? | select((external_gate_pr | not))] | length) == 0)
    | $parkable_agents[] as $agent
    | (($project.prs // []) | map(select((.agent // "") == $agent)) | .[0] // (($project.prs // [])[0] // {})) as $pr
    | select(($pr.pr // "") != "")
    | {
        source_project: $project.alias,
        source_agent: $agent,
        source_pr: ($pr.pr | tostring),
        source_branch: ($pr.branch // ""),
        source_gate_state: ($project.gate_state // ""),
        source_pr_signals: ($pr.signals // []),
        source_ci_pending: ($pr.ci_pending // 0),
        source_deploy_gate_pending: ($pr.deploy_gate_pending // 0)
      }
  ]
' <<< "$status_json")

ready_plan_for_config() {
  local cfg=${1:?usage: ready_plan_for_config <config>}
  local plan
  plan=$(bash "$TK/scripts/dispatch_plan.sh" "$cfg" --ready-only --json 2>/dev/null || printf '[]')
  if jq -e 'type == "array"' <<< "$plan" >/dev/null 2>&1; then
    printf '%s\n' "$plan"
  else
    printf '[]\n'
  fi
}

target_for_source() {
  local source_project=${1:?usage: target_for_source <source-project>}
  local project_b64 project_json alias cfg gate ready_plan ready_item

  while IFS= read -r project_b64; do
    project_json=$(printf '%s' "$project_b64" | base64 -d)
    alias=$(jq -r '.alias' <<< "$project_json")
    [[ "$alias" != "$source_project" ]] || continue
    gate=$(jq -r '.gate_state // ""' <<< "$project_json")
    case "$gate" in
      action_required|merge_ready)
        continue
        ;;
    esac
    cfg=$(jq -r '.config' <<< "$project_json")
    ready_plan=$(ready_plan_for_config "$cfg")
    ready_item=$(jq -c '[.[]? | select((.issue // "") != "")] | .[0] // empty' <<< "$ready_plan")
    [[ -n "$ready_item" ]] || continue
    jq -nc \
      --arg target_project "$alias" \
      --arg target_config "$cfg" \
      --argjson ready "$ready_item" \
      '{
        target_project: $target_project,
        target_config: $target_config,
        target_issue: ($ready.issue | tostring),
        target_title: ($ready.title // ""),
        target_status: ($ready.status // "ready")
      }'
    return 0
  done < <(jq -r '.[] | @base64' <<< "$status_json")

  return 1
}

rollback_release_action() {
  local source_project=${1:?usage: rollback_release_action <source-project> <source-agent> <source-pr>}
  local source_agent=${2:?usage: rollback_release_action <source-project> <source-agent> <source-pr>}
  local source_pr=${3:?usage: rollback_release_action <source-project> <source-agent> <source-pr>}
  printf 'after PR #%s merges or closes, release %s/%s by fetching the default branch, returning the parked worktree to the default branch, and clearing the active switch record' \
    "$source_pr" "$source_project" "$source_agent"
}

plan_record() {
  local source_json=${1:?usage: plan_record <source-json> <target-json>}
  local target_json=${2:?usage: plan_record <source-json> <target-json>}
  local source_project source_agent source_pr rollback

  source_project=$(jq -r '.source_project' <<< "$source_json")
  source_agent=$(jq -r '.source_agent' <<< "$source_json")
  source_pr=$(jq -r '.source_pr' <<< "$source_json")
  rollback=$(rollback_release_action "$source_project" "$source_agent" "$source_pr")

  jq -nc \
    --arg mode "$MODE" \
    --arg target_agent "$source_agent" \
    --arg rollback_release_action "$rollback" \
    --argjson source "$source_json" \
    --argjson target "$target_json" \
    '$source + $target + {
      mode: $mode,
      target_agent: $target_agent,
      rollback_release_action: $rollback_release_action
    }'
}

plans=()
while IFS= read -r source_b64; do
  source_json=$(printf '%s' "$source_b64" | base64 -d)
  source_project=$(jq -r '.source_project' <<< "$source_json")
  if target_json=$(target_for_source "$source_project"); then
    plans+=("$(plan_record "$source_json" "$target_json")")
    if [[ "${#plans[@]}" -ge "$LIMIT" ]]; then
      break
    fi
  fi
done < <(jq -r '.[] | @base64' <<< "$source_candidates_json")

plans_json=$(printf '%s\n' "${plans[@]:-}" | jq -s '.')

record_auto_rebalance() {
  local status=${1:?usage: record_auto_rebalance <status> <plan-json> [detail]}
  local plan_json=${2:?usage: record_auto_rebalance <status> <plan-json> [detail]}
  local detail=${3:-}
  local id created_at record tmp

  id=$(jq -r '[.source_project,.source_agent,.source_pr,.target_project,.target_issue,.mode] | join("|")' \
    <<< "$plan_json" | sha256sum | awk '{print substr($1,1,16)}')
  created_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  record=$(jq -nc \
    --arg id "$id" \
    --arg created_at "$created_at" \
    --arg status "$status" \
    --arg detail "$detail" \
    --argjson plan "$plan_json" \
    '$plan + {id:$id, created_at:$created_at, status:$status, detail:$detail}')

  if dry_run_enabled; then
    dry_run_note "record AUTO_REBALANCE $status id=$id"
    return 0
  fi

  mkdir -p "$state_dir"
  tmp="${state_file}.tmp.$$"
  if [[ -s "$state_file" ]]; then
    jq --arg id "$id" --argjson record "$record" \
      '.active[$id] = $record | .history = ((.history // []) + [$record])' \
      "$state_file" > "$tmp"
  else
    jq -nc --arg id "$id" --argjson record "$record" \
      '{active:{($id):$record},history:[$record]}' > "$tmp"
  fi
  mv "$tmp" "$state_file"

  if [[ ! -f "$task_file" ]]; then
    printf '# ORDO Portfolio Tasks\n\n' > "$task_file"
  fi
  printf -- '- [ ] %s AUTO_REBALANCE %s id=%s source=%s/%s source_pr=#%s target=%s/%s target_issue=#%s rollback_release_action=%s\n' \
    "$created_at" \
    "$status" \
    "$id" \
    "$(jq -r '.source_project' <<< "$plan_json")" \
    "$(jq -r '.source_agent' <<< "$plan_json")" \
    "$(jq -r '.source_pr' <<< "$plan_json")" \
    "$(jq -r '.target_project' <<< "$plan_json")" \
    "$(jq -r '.target_agent' <<< "$plan_json")" \
    "$(jq -r '.target_issue' <<< "$plan_json")" \
    "$(jq -r '.rollback_release_action' <<< "$plan_json")" >> "$task_file"
}

emit_signal() {
  local status=${1:?usage: emit_signal <status> <plan-json>}
  local plan_json=${2:?usage: emit_signal <status> <plan-json>}
  printf 'AUTO_REBALANCE %s source_project=%s source_agent=%s source_pr=#%s target_project=%s target_agent=%s target_issue=#%s rollback_release_action="%s"\n' \
    "$status" \
    "$(jq -r '.source_project' <<< "$plan_json")" \
    "$(jq -r '.source_agent' <<< "$plan_json")" \
    "$(jq -r '.source_pr' <<< "$plan_json")" \
    "$(jq -r '.target_project' <<< "$plan_json")" \
    "$(jq -r '.target_agent' <<< "$plan_json")" \
    "$(jq -r '.target_issue' <<< "$plan_json")" \
    "$(jq -r '.rollback_release_action' <<< "$plan_json")"
}

dry_run_apply_plan() {
  local plan_json=${1:?usage: dry_run_apply_plan <plan-json>}
  dry_run_note "bash scripts/agent_product_switch.sh <portfolio> $(jq -r '.source_project' <<< "$plan_json") $(jq -r '.source_agent' <<< "$plan_json") $(jq -r '.target_project' <<< "$plan_json") --$(jq -r '.mode' <<< "$plan_json")"
  dry_run_note "bash scripts/brief_agents.sh <target-config> $(jq -r '.target_agent' <<< "$plan_json") $(jq -r '.target_issue' <<< "$plan_json")"
  dry_run_note "bash scripts/dispatch_ticket.sh <target-config> $(jq -r '.target_agent' <<< "$plan_json") $(jq -r '.target_issue' <<< "$plan_json") <prompt> --portfolio <portfolio> --portfolio-project $(jq -r '.target_project' <<< "$plan_json")"
}

apply_plan() {
  local plan_json=${1:?usage: apply_plan <plan-json>}
  local source_project source_agent target_project target_agent target_config target_issue target_title prompt_file
  local -a switch_args dispatch_args

  source_project=$(jq -r '.source_project' <<< "$plan_json")
  source_agent=$(jq -r '.source_agent' <<< "$plan_json")
  target_project=$(jq -r '.target_project' <<< "$plan_json")
  target_agent=$(jq -r '.target_agent' <<< "$plan_json")
  target_config=$(jq -r '.target_config' <<< "$plan_json")
  target_issue=$(jq -r '.target_issue' <<< "$plan_json")
  target_title=$(jq -r '.target_title' <<< "$plan_json")

  if dry_run_enabled; then
    emit_signal "suggested" "$plan_json"
    dry_run_apply_plan "$plan_json"
    return 0
  fi

  record_auto_rebalance "suggested" "$plan_json"
  emit_signal "suggested" "$plan_json"

  switch_args=(
    bash "$TK/scripts/agent_product_switch.sh"
    "$ORCH_PORTFOLIO_CONFIG_PATH"
    "$source_project"
    "$source_agent"
    "$target_project"
    --target-agent "$target_agent"
    --reason "auto-rebalance source_pr=#$(jq -r '.source_pr' <<< "$plan_json") target_issue=#${target_issue}"
    "--$MODE"
  )
  "${switch_args[@]}"

  prompt_file=$(mktemp "${TMPDIR:-/tmp}/auto-rebalance-${target_agent}-${target_issue}.XXXXXX.md")
  bash "$TK/scripts/brief_agents.sh" "$target_config" "$target_agent" "$target_issue" \
    "summary=${target_title}" > "$prompt_file"

  dispatch_args=(
    bash "$TK/scripts/dispatch_ticket.sh"
    "$target_config"
    "$target_agent"
    "$target_issue"
    "$prompt_file"
    --portfolio "$ORCH_PORTFOLIO_CONFIG_PATH"
    --portfolio-project "$target_project"
  )
  if [[ "$ASSIGN" -eq 1 ]]; then
    dispatch_args+=(--assign)
  fi
  "${dispatch_args[@]}"

  record_auto_rebalance "applied" "$plan_json"
  emit_signal "applied" "$plan_json"
}

if [[ "$(jq -r 'length' <<< "$plans_json")" -eq 0 ]]; then
  if [[ "$FORMAT" == "json" ]]; then
    printf '[]\n'
  else
    printf 'AUTO_REBALANCE none reason=no-conservative-external-wait-candidate\n'
  fi
  exit 0
fi

if [[ "$FORMAT" == "json" && "$APPLY" -eq 0 ]]; then
  printf '%s\n' "$plans_json"
  if ! dry_run_enabled; then
    while IFS= read -r plan_b64; do
      plan_json=$(printf '%s' "$plan_b64" | base64 -d)
      record_auto_rebalance "suggested" "$plan_json"
    done < <(jq -r '.[] | @base64' <<< "$plans_json")
  fi
  exit 0
fi

while IFS= read -r plan_b64; do
  plan_json=$(printf '%s' "$plan_b64" | base64 -d)
  if [[ "$APPLY" -eq 1 ]]; then
    apply_plan "$plan_json"
  else
    record_auto_rebalance "suggested" "$plan_json"
    emit_signal "suggested" "$plan_json"
  fi
done < <(jq -r '.[] | @base64' <<< "$plans_json")
