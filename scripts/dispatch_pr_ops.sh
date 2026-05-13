#!/usr/bin/env bash
# scripts/dispatch_pr_ops.sh - delegated PR operations dispatch (#359, epic #357).
#
# Universal — no agent-CLI assumptions, no project-name hardcoding. Reads
# JSON shapes already emitted by `scripts/pr_block_signals.sh` (or accepts a
# pre-computed file via --pr-signals-file) and `scripts/agent_pool_status.sh`
# (--agent-pool-file), classifies each open blocked PR into one of three
# task kinds (`fix_ci`, `resolve_conflict`, `mark_ready_candidate`),
# allocates one PR per available agent (no duplicates, no hotspot conflict),
# and renders dispatch markdown files via `lib/pr_ops_tasks.sh` and the
# `templates/pr_op_*.md.tpl` library.
#
# Default behaviour is "dry-run" (write rendered prompts under a temp dir,
# print a JSON or TSV summary, never call dispatch_ticket). The orchestrator
# can opt in to actual dispatch with `--apply` once the rendered prompts
# have been reviewed; that path is centralized through dispatch_ticket and
# inherits its own external-pr-mutation gate (#268) and dispatch-matrix
# gate (#253).
#
# Usage:
#   dispatch_pr_ops.sh <project_short|config_path>
#       [--mode observe|centralized|delegated|autonomous]
#       [--pr-signals-file <path>] [--agent-pool-file <path>]
#       [--output-dir <path>]
#       [--tsv|--json]
#       [--wave <id>]
#       [--dry-run|--apply]
#
# Mode default: `observe` (no tasks emitted, only the classification table).
# The autonomous mode is reserved for a future ticket — refused here.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/config_resolver.sh"
source "$TK/lib/process_safety.sh"
source "$TK/lib/pr_ops_tasks.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: dispatch_pr_ops.sh <project> [--mode <mode>] [--pr-signals-file <path>] [--agent-pool-file <path>] [--output-dir <path>] [--tsv|--json] [--wave <id>] [--dry-run|--apply]}
shift
MODE="observe"
PR_SIGNALS_FILE=""
AGENT_POOL_FILE=""
OUTPUT_DIR=""
FORMAT="tsv"
WAVE_ID="ad-hoc"
APPLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) MODE=${2:?missing value for --mode}; shift ;;
    --pr-signals-file) PR_SIGNALS_FILE=${2:?missing value for --pr-signals-file}; shift ;;
    --agent-pool-file) AGENT_POOL_FILE=${2:?missing value for --agent-pool-file}; shift ;;
    --output-dir) OUTPUT_DIR=${2:?missing value for --output-dir}; shift ;;
    --tsv) FORMAT="tsv" ;;
    --json) FORMAT="json" ;;
    --wave) WAVE_ID=${2:?missing value for --wave}; shift ;;
    --apply) APPLY=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$MODE" in
  observe|centralized|delegated) ;;
  autonomous)
    echo "dispatch_pr_ops: mode=autonomous is reserved for a future iteration; refused" >&2
    exit "${ORCH_PR_OPS_REFUSED_EXIT_CODE:-80}" ;;
  *)
    echo "dispatch_pr_ops: unknown mode=$MODE" >&2
    exit 2 ;;
esac

load_project_config "$CFG_ARG"
source "$TK/lib/audit_log.sh"

# PR-ops policy gate: non-`observe` modes require the project profile to
# explicitly opt in via `PR_OPS_MODE_ALLOWED` (a comma list). Missing or
# empty means the project has not authorized delegated PR ops; the gate
# refuses with `missing-policy` per the issue's negative test.
PR_OPS_MODE_ALLOWED=${PR_OPS_MODE_ALLOWED:-}
case "$MODE" in
  observe) ;;
  *)
    if [ -z "$PR_OPS_MODE_ALLOWED" ]; then
      audit "PR_OPS REFUSED reason=missing-policy mode=$MODE project=$PROJECT"
      printf 'dispatch_pr_ops: project %s has no PR_OPS_MODE_ALLOWED in its profile; mode=%s refused\n' \
        "$PROJECT" "$MODE" >&2
      exit "${ORCH_PR_OPS_REFUSED_EXIT_CODE:-80}"
    fi
    case ",$PR_OPS_MODE_ALLOWED," in
      *,$MODE,*) ;;
      *)
        audit "PR_OPS REFUSED reason=mode-not-authorized mode=$MODE allowed=$PR_OPS_MODE_ALLOWED project=$PROJECT"
        printf 'dispatch_pr_ops: project %s does not authorize mode=%s (PR_OPS_MODE_ALLOWED=%s)\n' \
          "$PROJECT" "$MODE" "$PR_OPS_MODE_ALLOWED" >&2
        exit "${ORCH_PR_OPS_REFUSED_EXIT_CODE:-80}" ;;
    esac ;;
esac

# Collect PR signals JSON. Either passed in or computed via pr_block_signals.
load_pr_signals() {
  if [ -n "$PR_SIGNALS_FILE" ]; then
    [ -f "$PR_SIGNALS_FILE" ] || { echo "pr-signals file not found: $PR_SIGNALS_FILE" >&2; exit 2; }
    cat "$PR_SIGNALS_FILE"
    return 0
  fi
  bash "$TK/scripts/pr_block_signals.sh" "$CFG_ARG" --json
}

# Collect agent pool JSON. Either passed in or computed via agent_pool_status.
load_agent_pool() {
  if [ -n "$AGENT_POOL_FILE" ]; then
    [ -f "$AGENT_POOL_FILE" ] || { echo "agent-pool file not found: $AGENT_POOL_FILE" >&2; exit 2; }
    cat "$AGENT_POOL_FILE"
    return 0
  fi
  bash "$TK/scripts/agent_pool_status.sh" "$CFG_ARG" --json
}

PR_SIGNALS_JSON=$(load_pr_signals)
AGENT_POOL_JSON=$(load_agent_pool)

# Output directory for rendered prompts. Defaults to a per-wave temp.
if [ -z "$OUTPUT_DIR" ]; then
  OUTPUT_DIR=$(mktemp -d -t "ordo-pr-ops.XXXXXX")
fi
mkdir -p "$OUTPUT_DIR"

# Track which agents have already been assigned a PR-op task this wave so
# the "one PR per agent" invariant is enforced regardless of input order.
declare -A AGENT_ASSIGNED=()

# Track which paths are already claimed by another PR-op task this wave so
# hotspot conflicts surface as a blocker instead of double-assignment.
declare -A PATH_CLAIMED_BY=()

pr_ops_log_commands_from_urls() {
  local urls_json=${1:-[]}
  local pr_number=${2:-}
  local repo=${3:-}
  local run_ids run_id emitted=0

  run_ids=$(printf '%s' "$urls_json" \
    | jq -r '.[]? | (capture("actions/runs/(?<run>[0-9]+)") | .run)? // empty' 2>/dev/null \
    | sort -u)

  while IFS= read -r run_id; do
    [ -n "$run_id" ] || continue
    printf -- '- gh run view %s --log --repo %s\n' "$run_id" "$repo"
    emitted=1
  done <<< "$run_ids"

  if [ "$emitted" -eq 0 ]; then
    printf -- '- gh pr checks %s --repo %s\n' "$pr_number" "$repo"
  fi
}

results_file=$(mktemp)
json_file=$(mktemp)
trap 'rm -f "$results_file" "$json_file"' EXIT

# Render one task per actionable PR; emit one row per outcome (assigned or
# blocked). The function is intentionally narrow; full mutation happens
# only when --apply is set, and even then via dispatch_ticket.sh which
# carries its own gates.
process_one_pr() {
  local pr_b64=$1
  local pr_json pr_number pr_url pr_branch pr_base pr_mergeable pr_signals
  local kind candidate_agent_label candidate_workdir candidate_dirty candidate_capacity
  local hotspot_files file_ownership ci_failing ci_pending ci_rollup
  local pr_body_text pr_body_hash linked_issue_context ci_failed_check_names
  local ci_failed_urls ci_pending_urls ci_failed_log_commands ci_pending_log_commands
  local mutation_scope template_path output_file
  local hotspot_conflict=0 already_assigned=0

  pr_json=$(printf '%s' "$pr_b64" | base64 -d)
  pr_json=$(pr_ops_apply_deploy_gate_sha_correlation "$pr_json")
  pr_number=$(printf '%s' "$pr_json" | jq -r '.pr // ""')
  pr_branch=$(printf '%s' "$pr_json" | jq -r '.branch // ""')
  pr_mergeable=$(printf '%s' "$pr_json" | jq -r '.mergeable // "UNKNOWN"')
  pr_signals=$(printf '%s' "$pr_json" | jq -r '(.signals // []) | join(",")')
  pr_url=${PR_URL_TEMPLATE:-https://github.com/${GH_REPO}/pull/${pr_number}}
  pr_base=${DEFAULT_BRANCH:-main}

  # Issue #359 negative path: unknown mergeability or missing branch must
  # surface as a blocker, not as a silent "no-actionable-signal" row. Apply
  # this check BEFORE classification so a PR whose state is too fuzzy to
  # decide on a task kind still appears in the orchestrator's blocker list.
  if [ "$MODE" != "observe" ]; then
    case "$pr_mergeable" in
      UNKNOWN|"")
        audit "PR_OPS REFUSED reason=mergeability-unknown pr=#$pr_number project=$PROJECT"
        printf '%s\t%s\t%s\t%s\tunknown\tblocker:mergeability-unknown\n' \
          "$pr_number" "$pr_branch" "$pr_mergeable" "$pr_signals" >> "$results_file"
        jq -nc \
          --arg pr "$pr_number" --arg branch "$pr_branch" --arg signals "$pr_signals" \
          '{pr:$pr, branch:$branch, signals:($signals | split(",")), kind:"unknown", outcome:"blocker", blocker:"mergeability-unknown"}' \
          >> "$json_file"
        return 0 ;;
    esac
    if [ -z "$pr_branch" ]; then
      audit "PR_OPS REFUSED reason=missing-branch pr=#$pr_number project=$PROJECT"
      printf '%s\t%s\t%s\t%s\tunknown\tblocker:missing-branch\n' \
        "$pr_number" "$pr_branch" "$pr_mergeable" "$pr_signals" >> "$results_file"
      jq -nc \
        --arg pr "$pr_number" --arg branch "" --arg signals "$pr_signals" \
        '{pr:$pr, branch:$branch, signals:($signals | split(",")), kind:"unknown", outcome:"blocker", blocker:"missing-branch"}' \
        >> "$json_file"
      return 0
    fi
  fi

  kind=$(pr_ops_classify_signals "$pr_signals")
  if [ "$kind" = "none" ]; then
    printf '%s\t%s\t%s\t%s\tnone\tno-actionable-signal\n' \
      "$pr_number" "$pr_branch" "$pr_mergeable" "$pr_signals" >> "$results_file"
    jq -nc \
      --arg pr "$pr_number" --arg branch "$pr_branch" --arg signals "$pr_signals" \
      '{pr:$pr, branch:$branch, signals:($signals | split(",")), kind:"none", outcome:"no-actionable-signal"}' \
      >> "$json_file"
    return 0
  fi

  # `observe` mode never assigns; just emit the classification.
  if [ "$MODE" = "observe" ]; then
    printf '%s\t%s\t%s\t%s\t%s\tobserve-only\n' \
      "$pr_number" "$pr_branch" "$pr_mergeable" "$pr_signals" "$kind" >> "$results_file"
    jq -nc \
      --arg pr "$pr_number" --arg branch "$pr_branch" --arg signals "$pr_signals" --arg kind "$kind" \
      '{pr:$pr, branch:$branch, signals:($signals | split(",")), kind:$kind, outcome:"observe-only"}' \
      >> "$json_file"
    return 0
  fi

  # Pick a candidate agent: prefer the PR-owning row only when it is clean
  # dispatch capacity, otherwise fall back to the first clean/switchable
  # fleet slot. This keeps the orchestrator supervising instead of doing
  # long local PR follow-up when a switchable agent exists (#646).
  candidate_agent_label=$(printf '%s' "$AGENT_POOL_JSON" | jq -r --arg pr "$pr_number" '
    map(select(
      ((.pr // "") == $pr)
      and (((.capacity_class // "") == "available") or ((.capacity_class // "") == "switch_required"))
    )) | .[0].label // ""
  ')
  if [ -z "$candidate_agent_label" ]; then
    candidate_agent_label=$(printf '%s' "$AGENT_POOL_JSON" | jq -r '
      map(select(((.capacity_class // "") == "available") or ((.capacity_class // "") == "switch_required"))) | .[0].label // ""
    ')
  fi
  if [ -z "$candidate_agent_label" ]; then
    audit "PR_OPS REFUSED reason=no-clean-or-switchable-agent pr=#$pr_number kind=$kind project=$PROJECT"
    printf '%s\t%s\t%s\t%s\t%s\tblocker:no-clean-or-switchable-agent\n' \
      "$pr_number" "$pr_branch" "$pr_mergeable" "$pr_signals" "$kind" >> "$results_file"
    jq -nc \
      --arg pr "$pr_number" --arg branch "$pr_branch" --arg signals "$pr_signals" --arg kind "$kind" \
      '{pr:$pr, branch:$branch, signals:($signals | split(",")), kind:$kind, outcome:"blocker", blocker:"no-clean-or-switchable-agent"}' \
      >> "$json_file"
    return 0
  fi

  candidate_workdir=$(printf '%s' "$AGENT_POOL_JSON" | jq -r --arg agent_label "$candidate_agent_label" '
    map(select(.label == $agent_label)) | .[0].workdir // ""
  ')
  candidate_dirty=$(printf '%s' "$AGENT_POOL_JSON" | jq -r --arg agent_label "$candidate_agent_label" '
    map(select(.label == $agent_label)) | .[0].dirty // "0"
  ')
  candidate_capacity=$(printf '%s' "$AGENT_POOL_JSON" | jq -r --arg agent_label "$candidate_agent_label" '
    map(select(.label == $agent_label)) | .[0].capacity_class // "unknown"
  ')

  if [ -n "${AGENT_ASSIGNED[$candidate_agent_label]:-}" ]; then
    already_assigned=1
  fi

  # Hot-spot file ownership: pull from the per-PR file list when available
  # (default empty if the upstream signals don't expose files; the gate
  # still works on signals + agent state).
  file_ownership=$(printf '%s' "$pr_json" | jq -r '(.files // []) | join(",")')
  hotspot_files=""
  ci_failing=$(printf '%s' "$pr_json" | jq -r '.ci_fail // 0')
  ci_pending=$(printf '%s' "$pr_json" | jq -r '.ci_pending // 0')
  pr_body_text=$(printf '%s' "$pr_json" | jq -r '.body_text // ""')
  if [ -n "$pr_body_text" ]; then
    pr_body_hash="sha256:$(printf '%s' "$pr_body_text" | sha256sum | awk '{print $1}')"
    linked_issue_context=$(printf '%s\n' "$pr_body_text" \
      | grep -Eio '#[0-9]+' \
      | sort -u \
      | paste -sd, - || true)
    [ -n "$linked_issue_context" ] || linked_issue_context="none-detected"
  else
    pr_body_hash="not-provided-by-upstream-signals"
    linked_issue_context="not-provided-by-upstream-signals"
  fi
  ci_failed_check_names=$(printf '%s' "$pr_json" | jq -r '(.ci_failed_check_names // []) | join(",")')
  [ -n "$ci_failed_check_names" ] || ci_failed_check_names="none"
  ci_failed_urls=$(printf '%s' "$pr_json" | jq -c '.ci_failed_urls // []')
  ci_pending_urls=$(printf '%s' "$pr_json" | jq -c '.ci_pending_urls // []')
  ci_failed_log_commands=$(pr_ops_log_commands_from_urls "$ci_failed_urls" "$pr_number" "$GH_REPO")
  ci_pending_log_commands=$(pr_ops_log_commands_from_urls "$ci_pending_urls" "$pr_number" "$GH_REPO")
  ci_rollup=$(printf '%s' "$pr_json" | jq -r '
    if (.signals // []) | index("ci-pass") then "pass"
    elif (.ci_fail // 0) > 0 then "fail"
    elif (.ci_pending // 0) > 0 then "pending"
    else "unknown" end
  ')

  # Mark every owned file as "claimed by this PR for this wave"; when a
  # later PR's owned file matches a path already claimed by a different PR,
  # surface a hotspot conflict.
  if [ -n "$file_ownership" ]; then
    local IFS_OLD=$IFS
    IFS=',' read -r -a __files <<< "$file_ownership"
    IFS=$IFS_OLD
    for f in "${__files[@]}"; do
      [ -n "$f" ] || continue
      claim=${PATH_CLAIMED_BY[$f]:-}
      if [ -n "$claim" ] && [ "$claim" != "$pr_number" ]; then
        hotspot_conflict=1
        hotspot_files="${hotspot_files:+${hotspot_files},}${f}"
      fi
    done
  fi

  mutation_scope=$(pr_ops_mutation_scope_for "$kind")

  local validate_reason=""
  if ! validate_reason=$(pr_ops_validate_candidate \
    "$kind" "$pr_mergeable" "$candidate_dirty" "$candidate_capacity" "$MODE" \
    "$hotspot_conflict" "$already_assigned" 2>&1); then
    audit "PR_OPS REFUSED reason=$validate_reason pr=#$pr_number kind=$kind agent=$candidate_agent_label project=$PROJECT"
    printf '%s\t%s\t%s\t%s\t%s\tblocker:%s\n' \
      "$pr_number" "$pr_branch" "$pr_mergeable" "$pr_signals" "$kind" "$validate_reason" \
      >> "$results_file"
    jq -nc \
      --arg pr "$pr_number" --arg branch "$pr_branch" --arg signals "$pr_signals" --arg kind "$kind" \
      --arg agent "$candidate_agent_label" --arg agent_capacity "$candidate_capacity" --arg blocker "$validate_reason" \
      '{pr:$pr, branch:$branch, signals:($signals | split(",")), kind:$kind, agent:$agent, agent_capacity:$agent_capacity, outcome:"blocker", blocker:$blocker}' \
      >> "$json_file"
    return 0
  fi

  # Render the dispatch markdown.
  template_path=$(pr_ops_template_path "$kind")
  output_file="$OUTPUT_DIR/dispatch-${candidate_agent_label}-pr${pr_number}.md"
  PR_OPS_TPL_PR_URL="$pr_url" \
  PR_OPS_TPL_PR_NUMBER="$pr_number" \
  PR_OPS_TPL_REPO="$GH_REPO" \
  PR_OPS_TPL_BRANCH="$pr_branch" \
  PR_OPS_TPL_BASE_BRANCH="$pr_base" \
  PR_OPS_TPL_PROJECT="$PROJECT" \
  PR_OPS_TPL_AGENT_LABEL="$candidate_agent_label" \
  PR_OPS_TPL_AGENT_WORKDIR="$candidate_workdir" \
  PR_OPS_TPL_MUTATION_SCOPE="$mutation_scope" \
  PR_OPS_TPL_FILE_OWNERSHIP="${file_ownership:-not-provided-by-upstream-signals}" \
  PR_OPS_TPL_HOTSPOT_FILES="${hotspot_files:-none}" \
  PR_OPS_TPL_CI_FAILING="$ci_failing" \
  PR_OPS_TPL_CI_PENDING="$ci_pending" \
  PR_OPS_TPL_CI_FAILED_CHECK_NAMES="$ci_failed_check_names" \
  PR_OPS_TPL_CI_FAILED_LOG_COMMANDS="$ci_failed_log_commands" \
  PR_OPS_TPL_CI_PENDING_LOG_COMMANDS="$ci_pending_log_commands" \
  PR_OPS_TPL_CI_ROLLUP="$ci_rollup" \
  PR_OPS_TPL_PR_BODY_HASH="$pr_body_hash" \
  PR_OPS_TPL_PR_BODY_REFERENCE="gh pr view $pr_number --repo $GH_REPO --json body" \
  PR_OPS_TPL_LINKED_ISSUE_CONTEXT="$linked_issue_context" \
  PR_OPS_TPL_MERGEABLE="$pr_mergeable" \
  PR_OPS_TPL_CONFLICT_SIGNALS="$pr_signals" \
  PR_OPS_TPL_VERIFICATION_COMMANDS="${PR_OPS_VERIFICATION_COMMANDS:-CI-delegated; see docs/dispatch-planning.md Validation Placement section}" \
  PR_OPS_TPL_MERGE_POLICY="${PR_OPS_MERGE_POLICY:-no-merge-from-this-task}" \
  PR_OPS_TPL_EXPECTED_EVIDENCE="${PR_OPS_EXPECTED_EVIDENCE:-record_local_gate_evidence under state_dir/gate-evidence/}" \
  PR_OPS_TPL_MODE="$MODE" \
  PR_OPS_TPL_WAVE_ID="$WAVE_ID" \
  pr_ops_render_template "$TK/$template_path" > "$output_file"

  AGENT_ASSIGNED[$candidate_agent_label]="$pr_number"
  if [ -n "$file_ownership" ]; then
    local IFS_OLD2=$IFS
    IFS=',' read -r -a __files2 <<< "$file_ownership"
    IFS=$IFS_OLD2
    for f in "${__files2[@]}"; do
      [ -n "$f" ] || continue
      PATH_CLAIMED_BY[$f]="$pr_number"
    done
  fi

  if [ "$APPLY" -eq 1 ]; then
    audit "PR_OPS DISPATCH apply pr=#$pr_number kind=$kind agent=$candidate_agent_label prompt=$output_file mode=$MODE wave=$WAVE_ID"
    bash "$TK/scripts/dispatch_ticket.sh" "$CFG_ARG" "$candidate_agent_label" "$pr_number" "$output_file" \
      --external-pr-mutations "$mutation_scope"
  else
    audit "PR_OPS DISPATCH dry-run pr=#$pr_number kind=$kind agent=$candidate_agent_label prompt=$output_file mode=$MODE wave=$WAVE_ID"
  fi

  printf '%s\t%s\t%s\t%s\t%s\tassigned:%s\t%s\n' \
    "$pr_number" "$pr_branch" "$pr_mergeable" "$pr_signals" "$kind" "$candidate_agent_label" "$output_file" \
    >> "$results_file"
  jq -nc \
    --arg pr "$pr_number" --arg branch "$pr_branch" --arg signals "$pr_signals" --arg kind "$kind" \
    --arg agent "$candidate_agent_label" --arg agent_capacity "$candidate_capacity" --arg prompt "$output_file" --arg scope "$mutation_scope" \
    '{pr:$pr, branch:$branch, signals:($signals | split(",")), kind:$kind, agent:$agent, agent_capacity:$agent_capacity, outcome:"assigned", prompt:$prompt, mutation_scope:$scope}' \
    >> "$json_file"
}

while IFS= read -r pr_b64; do
  [ -n "$pr_b64" ] || continue
  process_one_pr "$pr_b64"
done < <(printf '%s' "$PR_SIGNALS_JSON" | jq -r '.[] | @base64' 2>/dev/null || true)

configured_count=$(jq -s 'length' "$json_file")
dispatched_count=$(jq -s '[.[] | select(.outcome == "assigned")] | length' "$json_file")
refused_count=$(jq -s '[.[] | select(.outcome == "blocker")] | length' "$json_file")
no_action_count=$(jq -s '[.[] | select(.outcome != "assigned" and .outcome != "blocker")] | length' "$json_file")
blocker_reasons=$(jq -rs 'map(select(.outcome == "blocker") | (.blocker // "")) | map(select(length > 0)) | unique | join(",")' "$json_file")
if [ -z "$blocker_reasons" ]; then
  blocker_reasons="none"
fi
no_delegation_reason="none"
if [ "$dispatched_count" = "0" ]; then
  if [ "$refused_count" != "0" ]; then
    no_delegation_reason="$blocker_reasons"
  elif [ "$no_action_count" != "0" ]; then
    no_delegation_reason="no-actionable-signal"
  else
    no_delegation_reason="empty-input"
  fi
fi

if [ "$FORMAT" = "json" ]; then
  jq -s '.' "$json_file"
else
  printf 'pr\tbranch\tmergeable\tsignals\tkind\toutcome\tprompt\n'
  if [ -s "$results_file" ]; then
    cat "$results_file"
  fi
fi

audit "PR_OPS WAVE summary project=$PROJECT mode=$MODE wave=$WAVE_ID configured=$configured_count dispatched=$dispatched_count refused=$refused_count no_action=$no_action_count no_delegation_reason=$no_delegation_reason blockers=$blocker_reasons output_dir=$OUTPUT_DIR apply=$APPLY"
