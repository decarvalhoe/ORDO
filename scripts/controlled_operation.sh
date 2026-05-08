#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/dry_run.sh
source "$ROOT/lib/dry_run.sh"
# shellcheck source=../lib/config_resolver.sh
source "$ROOT/lib/config_resolver.sh"

usage() {
  cat <<'EOF' >&2
usage:
  controlled_operation.sh <project|config> plan --type <emergency-admin|provider-workflow> --id <id> --reason <text> [--json]
  controlled_operation.sh <project|config> verify --evidence-file <file> [--json]
  controlled_operation.sh <project|config> record --evidence-file <file> [--dry-run] [--json]

Models exceptional operator workflows as controlled operations. The script does
not perform the operation; it verifies and records evidence for the temporary
branch, workflow, secrets, run, cache, and cleanup steps.
EOF
}

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'controlled_operation: jq is required\n' >&2
    exit 2
  fi
}

require_value() {
  local name=${1:?usage: require_value <name> <value>}
  local value=${2:-}
  if [[ -z "${value//[[:space:]]/}" ]]; then
    printf 'controlled_operation: missing %s\n' "$name" >&2
    usage
    exit 2
  fi
}

valid_operation_type() {
  case "${1:-}" in
    emergency-admin|provider-workflow)
      return 0
      ;;
  esac
  return 1
}

load_state_helpers() {
  # shellcheck source=../lib/audit_log.sh
  source "$ROOT/lib/audit_log.sh"
  # shellcheck source=../lib/state_persist.sh
  source "$ROOT/lib/state_persist.sh"
}

parse_common_options() {
  OPERATION_TYPE=""
  OPERATION_ID=""
  OPERATION_REASON=""
  EVIDENCE_FILE=""
  OUTPUT_JSON=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --type)
        OPERATION_TYPE=${2:-}
        shift 2
        ;;
      --id)
        OPERATION_ID=${2:-}
        shift 2
        ;;
      --reason)
        OPERATION_REASON=${2:-}
        shift 2
        ;;
      --evidence-file)
        EVIDENCE_FILE=${2:-}
        shift 2
        ;;
      --json)
        OUTPUT_JSON=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'controlled_operation: unknown arg: %s\n' "$1" >&2
        usage
        exit 2
        ;;
    esac
  done
}

required_evidence_json() {
  jq -cn '[
    "operation.id",
    "operation.type",
    "operation.reason",
    "approval.approved_by",
    "temporary_branch.name",
    "temporary_branch.base",
    "temporary_branch.created",
    "temporary_branch.removed",
    "workflow.path",
    "workflow.created",
    "workflow.removed",
    "secrets.names",
    "secrets.created",
    "secrets.removed",
    "run.id",
    "run.url",
    "run.conclusion",
    "cache.key",
    "cache.purged",
    "cleanup.completed",
    "cleanup.branch_deleted",
    "cleanup.workflow_removed",
    "cleanup.secrets_removed",
    "cleanup.cache_purged"
  ]'
}

plan_json() {
  local required
  required=$(required_evidence_json)
  jq -n \
    --arg id "$OPERATION_ID" \
    --arg type "$OPERATION_TYPE" \
    --arg reason "$OPERATION_REASON" \
    --argjson required "$required" \
    '{
      operation: {
        id: $id,
        type: $type,
        reason: $reason
      },
      mode: "controlled-operation",
      required_evidence: $required,
      evidence_sections: [
        "approval",
        "temporary_branch",
        "workflow",
        "secrets",
        "run",
        "cache",
        "cleanup"
      ],
      note: "Record references and outcomes only; do not store secret material."
    }'
}

cmd_plan() {
  require_value "--type" "$OPERATION_TYPE"
  require_value "--id" "$OPERATION_ID"
  require_value "--reason" "$OPERATION_REASON"

  if ! valid_operation_type "$OPERATION_TYPE"; then
    printf 'controlled_operation: invalid --type: %s\n' "$OPERATION_TYPE" >&2
    exit 2
  fi

  if [[ "$OUTPUT_JSON" -eq 1 ]]; then
    plan_json
    return 0
  fi

  cat <<EOF
Controlled operation evidence plan

Operation: $OPERATION_ID
Type: $OPERATION_TYPE
Reason: $OPERATION_REASON

Required evidence:
- approval.approved_by
- temporary_branch.name, temporary_branch.base, temporary_branch.created, temporary_branch.removed
- workflow.path, workflow.created, workflow.removed
- secrets.names, secrets.created, secrets.removed
- run.id, run.url, run.conclusion
- cache.key, cache.purged
- cleanup.completed, cleanup.branch_deleted, cleanup.workflow_removed, cleanup.secrets_removed, cleanup.cache_purged

Secret values, tokens, passwords, private keys, and credential material must not
be written to evidence files. Store only names, references, run URLs, and
cleanup outcomes.
EOF
}

assess_evidence() {
  local evidence_file=${1:?usage: assess_evidence <evidence-file>}
  jq -c --arg evidence_file "$evidence_file" '
    def has_text:
      . != null and (. | tostring | length > 0);
    def is_true:
      . == true;
    def nonempty_string_array:
      type == "array" and length > 0 and all(.[]; type == "string" and length > 0);
    def required:
      [
        "operation.id",
        "operation.type",
        "operation.reason",
        "approval.approved_by",
        "temporary_branch.name",
        "temporary_branch.base",
        "temporary_branch.created",
        "temporary_branch.removed",
        "workflow.path",
        "workflow.created",
        "workflow.removed",
        "secrets.names",
        "secrets.created",
        "secrets.removed",
        "run.id",
        "run.url",
        "run.conclusion",
        "cache.key",
        "cache.purged",
        "cleanup.completed",
        "cleanup.branch_deleted",
        "cleanup.workflow_removed",
        "cleanup.secrets_removed",
        "cleanup.cache_purged"
      ];
    def missing_required:
      [
        if (.operation.id | has_text) then empty else "operation.id" end,
        if ((.operation.type == "emergency-admin") or (.operation.type == "provider-workflow")) then empty else "operation.type" end,
        if (.operation.reason | has_text) then empty else "operation.reason" end,
        if ((.approval.approved_by // .operation.approved_by) | has_text) then empty else "approval.approved_by" end,
        if (.temporary_branch.name | has_text) then empty else "temporary_branch.name" end,
        if (.temporary_branch.base | has_text) then empty else "temporary_branch.base" end,
        if (.temporary_branch.created | is_true) then empty else "temporary_branch.created" end,
        if (.temporary_branch.removed | is_true) then empty else "temporary_branch.removed" end,
        if (.workflow.path | has_text) then empty else "workflow.path" end,
        if (.workflow.created | is_true) then empty else "workflow.created" end,
        if (.workflow.removed | is_true) then empty else "workflow.removed" end,
        if (.secrets.names | nonempty_string_array) then empty else "secrets.names" end,
        if (.secrets.created | is_true) then empty else "secrets.created" end,
        if (.secrets.removed | is_true) then empty else "secrets.removed" end,
        if (.run.id | has_text) then empty else "run.id" end,
        if (.run.url | has_text) then empty else "run.url" end,
        if (.run.conclusion | has_text) then empty else "run.conclusion" end,
        if (.cache.key | has_text) then empty else "cache.key" end,
        if (.cache.purged | is_true) then empty else "cache.purged" end,
        if (.cleanup.completed | is_true) then empty else "cleanup.completed" end,
        if (.cleanup.branch_deleted | is_true) then empty else "cleanup.branch_deleted" end,
        if (.cleanup.workflow_removed | is_true) then empty else "cleanup.workflow_removed" end,
        if (.cleanup.secrets_removed | is_true) then empty else "cleanup.secrets_removed" end,
        if (.cleanup.cache_purged | is_true) then empty else "cleanup.cache_purged" end
      ];
    def prohibited_secret_material:
      [
        paths(scalars) as $path
        | select(($path[-1] | tostring | test("^(value|secret_value|password|private_key|token_value|credential)$"; "i")))
        | "prohibited-secret-material:" + ($path | map(tostring) | join("."))
      ];
    (missing_required + prohibited_secret_material) as $missing
    | {
        decision: (if ($missing | length) == 0 then "pass" else "fail" end),
        evidence_file: $evidence_file,
        operation_id: (.operation.id // null),
        operation_type: (.operation.type // null),
        missing: $missing,
        required_evidence: required
      }
  ' "$evidence_file"
}

print_assessment_text() {
  local assessment=${1:?usage: print_assessment_text <assessment-json>}
  local decision evidence_file
  decision=$(jq -r '.decision' <<< "$assessment")
  evidence_file=$(jq -r '.evidence_file' <<< "$assessment")
  printf 'controlled_operation: %s: %s\n' "$decision" "$evidence_file"
  if [[ "$decision" != "pass" ]]; then
    jq -r '.missing[] | "- " + .' <<< "$assessment"
  fi
}

load_assessment_or_exit() {
  local evidence_file=${1:?usage: load_assessment_or_exit <evidence-file>}
  require_value "--evidence-file" "$evidence_file"
  if [[ ! -f "$evidence_file" ]]; then
    printf 'controlled_operation: evidence file not found: %s\n' "$evidence_file" >&2
    exit 2
  fi

  local assessment
  if ! assessment=$(assess_evidence "$evidence_file"); then
    printf 'controlled_operation: invalid evidence JSON: %s\n' "$evidence_file" >&2
    exit 2
  fi
  printf '%s\n' "$assessment"
}

cmd_verify() {
  local assessment decision
  assessment=$(load_assessment_or_exit "$EVIDENCE_FILE")
  decision=$(jq -r '.decision' <<< "$assessment")

  if [[ "$OUTPUT_JSON" -eq 1 ]]; then
    jq . <<< "$assessment"
  else
    print_assessment_text "$assessment"
  fi

  [[ "$decision" == "pass" ]] || exit 10
}

cmd_record() {
  local assessment decision operation_id operation_type recorded_at record state_path
  assessment=$(load_assessment_or_exit "$EVIDENCE_FILE")
  decision=$(jq -r '.decision' <<< "$assessment")

  if [[ "$decision" != "pass" ]]; then
    if [[ "$OUTPUT_JSON" -eq 1 ]]; then
      jq . <<< "$assessment"
    else
      print_assessment_text "$assessment"
    fi
    exit 10
  fi

  operation_id=$(jq -r '.operation_id' <<< "$assessment")
  operation_type=$(jq -r '.operation_type' <<< "$assessment")

  if dry_run_enabled; then
    dry_run_note "would record controlled operation id=$operation_id type=$operation_type" >&2
    if [[ "$OUTPUT_JSON" -eq 1 ]]; then
      jq -n \
        --arg decision "dry-run" \
        --arg operation_id "$operation_id" \
        --arg operation_type "$operation_type" \
        '{decision: $decision, operation_id: $operation_id, operation_type: $operation_type}'
    else
      printf 'controlled_operation: dry-run: %s\n' "$operation_id"
    fi
    return 0
  fi

  load_state_helpers
  recorded_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  record=$(jq -c --arg recorded_at "$recorded_at" '. + {recorded_at: $recorded_at}' "$EVIDENCE_FILE")
  state_append "controlled_operations.jsonl" "$record"
  state_path=$(state_file "controlled_operations.jsonl")
  audit "CONTROLLED_OPERATION recorded id=$operation_id type=$operation_type"

  if [[ "$OUTPUT_JSON" -eq 1 ]]; then
    jq -n \
      --arg decision "recorded" \
      --arg operation_id "$operation_id" \
      --arg operation_type "$operation_type" \
      --arg state_file "$state_path" \
      '{decision: $decision, operation_id: $operation_id, operation_type: $operation_type, state_file: $state_file}'
  else
    printf 'controlled_operation: recorded: %s\n' "$operation_id"
    printf 'state_file: %s\n' "$state_path"
  fi
}

main() {
  require_jq
  if [[ $# -lt 2 ]]; then
    usage
    exit 2
  fi

  local project_arg=$1 command=$2
  shift 2

  load_project_config "$project_arg"

  dry_run_parse_args "$@"
  parse_common_options "${DRY_RUN_ARGS[@]}"

  case "$command" in
    plan)
      cmd_plan
      ;;
    verify)
      cmd_verify
      ;;
    record)
      cmd_record
      ;;
    -h|--help)
      usage
      ;;
    *)
      printf 'controlled_operation: unknown command: %s\n' "$command" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
