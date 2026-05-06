#!/usr/bin/env bash
# scripts/portfolio_poc.sh - reproducible local/fleet POC runner for portfolio features.
#
# Usage:
#   portfolio_poc.sh <portfolio-config> [--phase local|fleet|all] [--output-dir DIR]
#                    [--apply-safe] [--yolo-priority]
#                    [--switch source:agent:target[:target-agent]]
#
# Defaults are read-only. --apply-safe only enables deterministic remediation
# already guarded by portfolio_session_start.sh: missing clone creation and
# clean default-branch fast-forward.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/portfolio_config.sh"

PORTFOLIO_ARG=${1:?usage: portfolio_poc.sh <portfolio-config> [--phase local|fleet|all]}
shift

PHASE="local"
OUTPUT_DIR=""
APPLY_SAFE=0
SWITCH_SPEC=""
PRIORITY_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --phase)
      PHASE=${2:?missing value for --phase}
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR=${2:?missing value for --output-dir}
      shift 2
      ;;
    --apply-safe)
      APPLY_SAFE=1
      shift
      ;;
    --yolo-priority)
      PORTFOLIO_YOLO_PRIORITY=1
      PRIORITY_ARGS=(--yolo-priority)
      shift
      ;;
    --switch)
      SWITCH_SPEC=${2:?missing value for --switch}
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

case "$PHASE" in
  local|fleet|all) ;;
  *)
    echo "unknown phase: $PHASE" >&2
    exit 2
    ;;
esac

load_portfolio_config "$PORTFOLIO_ARG"
portfolio_require_priorities || exit 14
priority_mode=$(portfolio_priority_mode)

run_id="$(date -u +'%Y%m%dT%H%M%SZ')-${PHASE}-$$"
if [ -z "$OUTPUT_DIR" ]; then
  OUTPUT_DIR="$(portfolio_state_dir)/poc/${run_id}"
fi
mkdir -p "$OUTPUT_DIR"

steps_file="$OUTPUT_DIR/steps.jsonl"
: > "$steps_file"

quote_cmd() {
  local arg
  for arg in "$@"; do
    printf '%q ' "$arg"
  done | sed 's/[[:space:]]$//'
}

sanitize_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

run_step() {
  local name=${1:?usage: run_step <name> <cmd...>}
  shift
  local safe_name stdout_file stderr_file started_at ended_at status cmd_text allowed accepted=0

  safe_name=$(sanitize_name "$name")
  stdout_file="$OUTPUT_DIR/${safe_name}.out"
  stderr_file="$OUTPUT_DIR/${safe_name}.err"
  started_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  cmd_text=$(quote_cmd "$@")
  allowed=",${ORDO_POC_ACCEPT_STATUS:-0},"

  set +e
  "$@" > "$stdout_file" 2> "$stderr_file"
  status=$?
  set -e

  ended_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  if [[ "$allowed" == *",$status,"* ]]; then
    accepted=1
  fi
  jq -nc \
    --arg name "$name" \
    --arg command "$cmd_text" \
    --arg started_at "$started_at" \
    --arg ended_at "$ended_at" \
    --arg stdout "$stdout_file" \
    --arg stderr "$stderr_file" \
    --argjson status "$status" \
    --argjson accepted "$accepted" \
    '{
      name:$name,
      command:$command,
      status:$status,
      accepted:$accepted,
      started_at:$started_at,
      ended_at:$ended_at,
      stdout:$stdout,
      stderr:$stderr
    }' >> "$steps_file"
}

run_step_allow() {
  local accepted_statuses=${1:?usage: run_step_allow <statuses> <name> <cmd...>}
  shift
  ORDO_POC_ACCEPT_STATUS="$accepted_statuses" run_step "$@"
}

write_file() {
  local path=${1:?usage: write_file <path> <content>}
  local content=${2:-}
  printf '%s\n' "$content" > "$path"
}

write_manifest() {
  jq -nc \
    --arg run_id "$run_id" \
    --arg portfolio "$PORTFOLIO_ARG" \
    --arg portfolio_name "${PORTFOLIO_NAME:-}" \
    --arg phase "$PHASE" \
    --arg priority_mode "$priority_mode" \
    --arg output_dir "$OUTPUT_DIR" \
    --argjson apply_safe "$APPLY_SAFE" \
    '{
      run_id:$run_id,
      portfolio:$portfolio,
      portfolio_name:$portfolio_name,
      phase:$phase,
      priority_mode:$priority_mode,
      apply_safe:$apply_safe,
      output_dir:$output_dir
    }' > "$OUTPUT_DIR/manifest.json"
}

run_local_phase() {
  run_step "local_portfolio_status" \
    bash "$TK/scripts/portfolio_status.sh" "$PORTFOLIO_ARG" --json "${PRIORITY_ARGS[@]}"

  run_step "local_session_start_no_fetch" \
    bash "$TK/scripts/portfolio_session_start.sh" "$PORTFOLIO_ARG" --json --no-fetch "${PRIORITY_ARGS[@]}"

  run_step "local_session_start_apply_dry_run" \
    bash "$TK/scripts/portfolio_session_start.sh" "$PORTFOLIO_ARG" --json --apply --dry-run --no-fetch "${PRIORITY_ARGS[@]}"

  if [ "$APPLY_SAFE" -eq 1 ]; then
    run_step "local_session_start_apply_safe" \
      bash "$TK/scripts/portfolio_session_start.sh" "$PORTFOLIO_ARG" --json --apply "${PRIORITY_ARGS[@]}"
  fi

  if [ -n "$SWITCH_SPEC" ]; then
    local -a switch_args=()
    IFS=':' read -r switch_source switch_agent switch_target switch_target_agent extra <<< "$SWITCH_SPEC"
    if [ -n "${extra:-}" ] || [ -z "${switch_source:-}" ] || [ -z "${switch_agent:-}" ] || [ -z "${switch_target:-}" ]; then
      write_file "$OUTPUT_DIR/local_switch.invalid" \
        "Invalid --switch format. Expected source:agent:target[:target-agent]."
      echo "invalid --switch format. Expected source:agent:target[:target-agent]." >&2
      return 2
    else
      switch_args=("$PORTFOLIO_ARG" "$switch_source" "$switch_agent" "$switch_target" --soft --no-brief --dry-run)
      if [ -n "${switch_target_agent:-}" ]; then
        switch_args+=(--target-agent "$switch_target_agent")
      fi
      run_step_allow "0,5,7,9,10" "local_soft_switch_dry_run" \
        bash "$TK/scripts/agent_product_switch.sh" "${switch_args[@]}"
    fi
  fi
}

run_fleet_phase() {
  local alias cfg priority
  run_step "fleet_portfolio_status" \
    bash "$TK/scripts/portfolio_status.sh" "$PORTFOLIO_ARG" --json "${PRIORITY_ARGS[@]}"

  run_step "fleet_session_start_no_fetch" \
    bash "$TK/scripts/portfolio_session_start.sh" "$PORTFOLIO_ARG" --json --no-fetch "${PRIORITY_ARGS[@]}"

  while IFS='|' read -r alias cfg; do
    priority=$(portfolio_project_priority "$alias")
    run_step "fleet_${alias}_agent_pool_status" \
      bash "$TK/scripts/agent_pool_status.sh" "$cfg" --json
    run_step "fleet_${alias}_pr_block_signals" \
      bash "$TK/scripts/pr_block_signals.sh" "$cfg" --json
    run_step "fleet_${alias}_dispatch_plan_ready" \
      bash "$TK/scripts/dispatch_plan.sh" "$cfg" --ready-only --json
    run_step "fleet_${alias}_dispatch_plan_atomize_dry_run" \
      bash "$TK/scripts/dispatch_plan.sh" "$cfg" --atomize --dry-run
    run_step "fleet_${alias}_gha_optimize_audit" \
      bash "$TK/scripts/gh_actions_optimize.sh" "$cfg" --audit
    run_step "fleet_${alias}_sixsigma_dry_run" \
      bash "$TK/scripts/sixsigma_autoupgrade.sh" "$cfg" --dry-run
    jq -nc --arg alias "$alias" --arg cfg "$cfg" --arg priority "$priority" \
      '{alias:$alias,config:$cfg,priority:($priority|tonumber)}' >> "$OUTPUT_DIR/projects.jsonl"
  done < <(portfolio_project_entries)
}

write_report() {
  local report="$OUTPUT_DIR/report.md"
  local session_summary status_summary failures

  session_summary="[]"
  if [ -s "$OUTPUT_DIR/local_session_start_no_fetch.out" ] || [ -s "$OUTPUT_DIR/fleet_session_start_no_fetch.out" ]; then
    local session_file
    session_file="$OUTPUT_DIR/local_session_start_no_fetch.out"
    [ -s "$session_file" ] || session_file="$OUTPUT_DIR/fleet_session_start_no_fetch.out"
    session_summary=$(jq '
      sort_by(.alias)
      | group_by(.alias)
      | map({
          alias: .[0].alias,
          priority: .[0].priority,
          total: length,
          ready: (map(select(.ready == 1)) | length),
          statuses: (group_by(.status) | map({status: .[0].status, count: length}))
        })
    ' "$session_file" 2>/dev/null || printf '[]')
  fi

  status_summary="[]"
  if [ -s "$OUTPUT_DIR/local_portfolio_status.out" ]; then
    status_summary=$(jq '[.[] | {alias, priority, gate_state, rebalance_signal, free: .counts.free, dirty: .counts.dirty, local_work: .counts.local_work, open_prs: .counts.open_prs}]' \
      "$OUTPUT_DIR/local_portfolio_status.out" 2>/dev/null || printf '[]')
  elif [ -s "$OUTPUT_DIR/fleet_portfolio_status.out" ]; then
    status_summary=$(jq '[.[] | {alias, priority, gate_state, rebalance_signal, free: .counts.free, dirty: .counts.dirty, local_work: .counts.local_work, open_prs: .counts.open_prs}]' \
      "$OUTPUT_DIR/fleet_portfolio_status.out" 2>/dev/null || printf '[]')
  fi

  failures=$(jq -s '[.[] | select(.accepted != 1) | {name,status,stderr}]' "$steps_file")

  {
    printf '# ORDO Portfolio POC Report\n\n'
    printf -- "- run_id: \`%s\`\n" "$run_id"
    printf -- "- phase: \`%s\`\n" "$PHASE"
    printf -- "- portfolio: \`%s\`\n" "$PORTFOLIO_ARG"
    printf -- "- priority_mode: \`%s\`\n" "$priority_mode"
    printf -- "- apply_safe: \`%s\`\n" "$APPLY_SAFE"
    printf -- "- output_dir: \`%s\`\n\n" "$OUTPUT_DIR"

    printf '## Portfolio Status\n\n'
    printf "\`\`\`json\n%s\n\`\`\`\n\n" "$status_summary"

    printf '## Session Start Summary\n\n'
    printf "\`\`\`json\n%s\n\`\`\`\n\n" "$session_summary"

    printf '## Step Results\n\n'
    jq -r '. | "- `\(.name)`: status=\(.status) accepted=\(.accepted)"' "$steps_file"
    printf '\n## Failures\n\n'
    printf "\`\`\`json\n%s\n\`\`\`\n" "$failures"
  } > "$report"
}

write_manifest
case "$PHASE" in
  local)
    run_local_phase
    ;;
  fleet)
    run_fleet_phase
    ;;
  all)
    run_local_phase
    run_fleet_phase
    ;;
esac
write_report

printf 'portfolio POC report: %s\n' "$OUTPUT_DIR/report.md"
