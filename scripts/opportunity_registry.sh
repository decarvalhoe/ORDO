#!/usr/bin/env bash
# scripts/opportunity_registry.sh - durable ORDO improvement opportunity registry.
#
# Usage:
#   opportunity_registry.sh <project> path [--registry <path>]
#   opportunity_registry.sh <project> schema
#   opportunity_registry.sh <project> add --code <id> --finding <text> --impact <text> \
#     --detection-signal <text> --remediation <text> --validation-plan <text> \
#     --priority <value> --evidence <ref> [--apply] [--json]
#   opportunity_registry.sh <project> list [--registry <path>] [--json]
#
# Safe default: add is non-mutating unless --apply is present. --dry-run or
# ORCH_DRY_RUN=1 always keeps add non-mutating even when --apply is supplied.
set -euo pipefail

TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/config_resolver.sh"
source "$TK/lib/dry_run.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: opportunity_registry.sh <project> <path|schema|add|list> [args]}
COMMAND=${2:?usage: opportunity_registry.sh <project> <path|schema|add|list> [args]}
shift 2

load_project_config "$CFG_ARG"
: "${PROJECT:?}"

utc_now() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

safe_name() {
  local raw=${1:?usage: safe_name <value>}
  printf '%s\n' "${raw//[^A-Za-z0-9_.-]/_}"
}

registry_root() {
  local project_safe
  project_safe=$(safe_name "$PROJECT")
  if [[ -n "${ORCH_OPPORTUNITY_REGISTRY_DIR:-}" ]]; then
    printf '%s/%s\n' "$ORCH_OPPORTUNITY_REGISTRY_DIR" "$project_safe"
  elif [[ -n "${ORCH_STATE_BASE:-}" ]]; then
    printf '%s/%s\n' "$ORCH_STATE_BASE" "$project_safe"
  elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s/ordo/opportunity-registry/%s\n' "$XDG_STATE_HOME" "$project_safe"
  elif [[ -n "${HOME:-}" ]]; then
    printf '%s/.local/state/ordo/opportunity-registry/%s\n' "$HOME" "$project_safe"
  else
    printf '%s/%s\n' "/tmp/ordo-opportunity-registry" "$project_safe"
  fi
}

default_registry_path() {
  printf '%s/opportunities.jsonl\n' "$(registry_root)"
}

require_value() {
  local name=${1:?usage: require_value <name> <value>}
  local value=${2:-}
  [[ -n "$value" ]] || {
    printf 'opportunity_registry: missing %s\n' "$name" >&2
    exit 2
  }
}

require_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf 'opportunity_registry: jq is required\n' >&2
    exit 2
  }
}

json_string_array() {
  if [[ "$#" -eq 0 ]]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\0' "$@" | jq -Rs 'split("\u0000")[:-1]'
}

schema_json() {
  jq -nc '{
    schema: "ordo.opportunity_registry.schema.v1",
    record_schema: "ordo.opportunity.v1",
    required_fields: [
      "id",
      "created_at",
      "project",
      "status",
      "priority",
      "severity",
      "finding",
      "impact",
      "detection_signal",
      "remediation_candidate",
      "validation_plan",
      "linked_evidence"
    ],
    safe_default: "add previews unless --apply is supplied",
    record_format: "jsonl"
  }'
}

validate_record_json() {
  local record=${1:?usage: validate_record_json <json>}
  jq -e '
    .schema == "ordo.opportunity.v1" and
    (.id | type == "string" and length > 0) and
    (.created_at | type == "string" and length > 0) and
    (.project | type == "string" and length > 0) and
    (.status | type == "string" and length > 0) and
    (.priority | type == "string" and length > 0) and
    (.severity | type == "string" and length > 0) and
    (.finding | type == "string" and length > 0) and
    (.impact | type == "string" and length > 0) and
    (.detection_signal | type == "string" and length > 0) and
    (.remediation_candidate | type == "string" and length > 0) and
    (.validation_plan | type == "string" and length > 0) and
    (.linked_evidence | type == "array" and length > 0)
  ' <<< "$record" >/dev/null
}

registry_has_id() {
  local registry=${1:?usage: registry_has_id <registry> <id>}
  local id=${2:?usage: registry_has_id <registry> <id>}
  [[ -f "$registry" ]] || return 1
  jq -e --arg id "$id" 'select(.id == $id)' "$registry" >/dev/null
}

build_record_json() {
  local code=${1:?} created_at=${2:?} status=${3:?} priority=${4:?}
  local severity=${5:?} finding=${6:?} impact=${7:?} detection_signal=${8:?}
  local remediation=${9:?} validation_plan=${10:?} source=${11:-}
  local evidence_json=${12:?} related_json=${13:?}

  jq -nc \
    --arg id "$code" \
    --arg created_at "$created_at" \
    --arg project "$PROJECT" \
    --arg status "$status" \
    --arg priority "$priority" \
    --arg severity "$severity" \
    --arg finding "$finding" \
    --arg impact "$impact" \
    --arg detection_signal "$detection_signal" \
    --arg remediation "$remediation" \
    --arg validation_plan "$validation_plan" \
    --arg source "$source" \
    --argjson linked_evidence "$evidence_json" \
    --argjson related_refs "$related_json" \
    '{
      schema: "ordo.opportunity.v1",
      id: $id,
      created_at: $created_at,
      project: $project,
      status: $status,
      priority: $priority,
      severity: $severity,
      finding: $finding,
      impact: $impact,
      detection_signal: $detection_signal,
      remediation_candidate: $remediation,
      validation_plan: $validation_plan,
      linked_evidence: $linked_evidence,
      source: $source,
      related_refs: $related_refs
    }'
}

cmd_path() {
  local registry=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --registry) registry=${2:?missing value for --registry}; shift 2 ;;
      *)
        printf 'opportunity_registry path: unknown arg: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done
  printf '%s\n' "${registry:-$(default_registry_path)}"
}

cmd_schema() {
  [[ "$#" -eq 0 ]] || {
    printf 'opportunity_registry schema: unknown arg: %s\n' "$1" >&2
    exit 2
  }
  require_jq
  schema_json
}

cmd_add() {
  require_jq
  local registry="" code="" finding="" impact="" detection_signal=""
  local remediation="" validation_plan="" priority="" severity="medium"
  local status="proposed" source="" created_at="" apply=0 json=0
  local -a linked_evidence=() related_refs=()

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --registry) registry=${2:?missing value for --registry}; shift 2 ;;
      --code) code=${2:?missing value for --code}; shift 2 ;;
      --finding) finding=${2:?missing value for --finding}; shift 2 ;;
      --impact) impact=${2:?missing value for --impact}; shift 2 ;;
      --detection-signal) detection_signal=${2:?missing value for --detection-signal}; shift 2 ;;
      --remediation) remediation=${2:?missing value for --remediation}; shift 2 ;;
      --validation-plan) validation_plan=${2:?missing value for --validation-plan}; shift 2 ;;
      --priority) priority=${2:?missing value for --priority}; shift 2 ;;
      --severity) severity=${2:?missing value for --severity}; shift 2 ;;
      --status) status=${2:?missing value for --status}; shift 2 ;;
      --source) source=${2:?missing value for --source}; shift 2 ;;
      --evidence) linked_evidence+=("$2"); shift 2 ;;
      --related) related_refs+=("$2"); shift 2 ;;
      --created-at) created_at=${2:?missing value for --created-at}; shift 2 ;;
      --apply) apply=1; shift ;;
      --json) json=1; shift ;;
      *)
        printf 'opportunity_registry add: unknown arg: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done

  require_value "--code" "$code"
  require_value "--finding" "$finding"
  require_value "--impact" "$impact"
  require_value "--detection-signal" "$detection_signal"
  require_value "--remediation" "$remediation"
  require_value "--validation-plan" "$validation_plan"
  require_value "--priority" "$priority"
  [[ "${#linked_evidence[@]}" -gt 0 ]] || {
    printf 'opportunity_registry: missing --evidence\n' >&2
    exit 2
  }

  registry=${registry:-$(default_registry_path)}
  created_at=${created_at:-$(utc_now)}
  local evidence_json related_json record
  evidence_json=$(json_string_array "${linked_evidence[@]}")
  related_json=$(json_string_array "${related_refs[@]}")
  record=$(
    build_record_json "$code" "$created_at" "$status" "$priority" "$severity" \
      "$finding" "$impact" "$detection_signal" "$remediation" \
      "$validation_plan" "$source" "$evidence_json" "$related_json"
  )
  validate_record_json "$record" || {
    printf 'opportunity_registry: invalid opportunity record\n' >&2
    exit 2
  }

  if [[ "$apply" -ne 1 || "${ORCH_DRY_RUN:-0}" == "1" ]]; then
    if [[ "$json" -eq 1 ]]; then
      jq -nc --arg decision "dry-run" --arg registry "$registry" \
        --argjson record "$record" \
        '{decision: $decision, registry: $registry, record: $record}'
    else
      dry_run_note "append opportunity $code to $registry"
      printf '%s\n' "$record"
    fi
    return 0
  fi

  if registry_has_id "$registry" "$code"; then
    printf 'opportunity_registry: duplicate opportunity id: %s\n' "$code" >&2
    exit 3
  fi

  mkdir -p "$(dirname "$registry")"
  printf '%s\n' "$record" >> "$registry"
  if [[ "$json" -eq 1 ]]; then
    jq -nc --arg decision "recorded" --arg registry "$registry" \
      --argjson record "$record" \
      '{decision: $decision, registry: $registry, record: $record}'
  else
    printf 'recorded %s %s\n' "$code" "$registry"
  fi
}

cmd_list() {
  require_jq
  local registry="" json=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --registry) registry=${2:?missing value for --registry}; shift 2 ;;
      --json) json=1; shift ;;
      *)
        printf 'opportunity_registry list: unknown arg: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done
  registry=${registry:-$(default_registry_path)}
  if [[ ! -s "$registry" ]]; then
    if [[ "$json" -eq 1 ]]; then
      printf '[]\n'
    fi
    return 0
  fi
  if [[ "$json" -eq 1 ]]; then
    jq -s '.' "$registry"
  else
    jq -r '[.id, .priority, .severity, .status, .finding] | @tsv' "$registry"
  fi
}

case "$COMMAND" in
  path) cmd_path "$@" ;;
  schema) cmd_schema "$@" ;;
  add) cmd_add "$@" ;;
  list) cmd_list "$@" ;;
  *)
    printf 'opportunity_registry: unknown command: %s\n' "$COMMAND" >&2
    exit 2
    ;;
esac
