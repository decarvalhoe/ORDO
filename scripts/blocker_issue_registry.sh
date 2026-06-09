#!/usr/bin/env bash
# scripts/blocker_issue_registry.sh - create, dedupe, and resolve ORDO blocker issues.
#
# Usage:
#   blocker_issue_registry.sh <project> report --blocker-kind <kind> --resource <id> \
#     --profile <profile> --command <cmd> --output-summary <text> \
#     --next-action <text> --owner <owner> --severity <value> [--artifact <ref>] \
#     [--impacted-ref <ref>] [--repo <owner/repo>] [--apply] [--json]
#   blocker_issue_registry.sh <project> resolve --blocker-kind <kind> --resource <id> \
#     --resolution-summary <text> [--resolution-policy comment|label|close] \
#     [--resolved-label <label>] [--repo <owner/repo>] [--apply] [--json]
set -euo pipefail

TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../lib/dry_run.sh disable=SC1091
source "$TK/lib/dry_run.sh"
# shellcheck source=../lib/config_resolver.sh disable=SC1091
source "$TK/lib/config_resolver.sh"
# shellcheck source=../lib/gh_body_helpers.sh disable=SC1091
source "$TK/lib/gh_body_helpers.sh"
# shellcheck source=../lib/blocker_issue_registry.sh disable=SC1091
source "$TK/lib/blocker_issue_registry.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: blocker_issue_registry.sh <project> <report|resolve|key> [args]}
COMMAND=${2:?usage: blocker_issue_registry.sh <project> <report|resolve|key> [args]}
shift 2

load_project_config "$CFG_ARG"
: "${PROJECT:?}"

utc_now() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

emit_or_print_result() {
  local json=${1:?usage: emit_or_print_result <json-flag> <decision-json>}
  local decision_json=${2:?usage: emit_or_print_result <json-flag> <decision-json>}
  if [[ "$json" -eq 1 ]]; then
    printf '%s\n' "$decision_json"
  else
    jq -r '
      [
        "decision=" + .decision,
        "repo=" + .repo,
        "dedupe_key=" + .dedupe_key,
        "issue_number=" + ((.issue_number // "none") | tostring),
        "blocker_issue_url=" + (.blocker_issue_url // "none")
      ] | .[]
    ' <<< "$decision_json"
  fi
}

issue_url_from_create_output() {
  awk '/^https?:\/\// { url=$0 } END { if (url != "") print url }'
}

validate_resolution_policy() {
  local policy=${1:?usage: validate_resolution_policy <policy>}
  case "$policy" in
    comment|label|close) ;;
    *)
      printf 'blocker_issue_registry: --resolution-policy must be one of: comment, label, close\n' >&2
      exit 2
      ;;
  esac
}

cmd_key() {
  local blocker_kind="" resource=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --blocker-kind|--kind) blocker_kind=${2:?missing value for --blocker-kind}; shift 2 ;;
      --resource) resource=${2:?missing value for --resource}; shift 2 ;;
      *)
        printf 'blocker_issue_registry key: unknown arg: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done
  blocker_issue_require_value "--blocker-kind" "$blocker_kind"
  blocker_issue_require_value "--resource" "$resource"
  blocker_issue_key "$PROJECT" "$blocker_kind" "$resource"
}

cmd_report() {
  blocker_issue_require_jq
  local repo=${BLOCKER_ISSUE_REPO:-${GH_REPO:-}} blocker_kind="" resource=""
  local profile="" command_text="" output_summary="" next_action="" owner=""
  local severity="" title="" apply=0 json=0 created_at
  local -a artifacts=() impacted_refs=()

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --repo) repo=${2:?missing value for --repo}; shift 2 ;;
      --blocker-kind|--kind) blocker_kind=${2:?missing value for --blocker-kind}; shift 2 ;;
      --resource) resource=${2:?missing value for --resource}; shift 2 ;;
      --profile) profile=${2:?missing value for --profile}; shift 2 ;;
      --command) command_text=${2:?missing value for --command}; shift 2 ;;
      --output-summary|--summary) output_summary=${2:?missing value for --output-summary}; shift 2 ;;
      --artifact) artifacts+=("$2"); shift 2 ;;
      --impacted-ref) impacted_refs+=("$2"); shift 2 ;;
      --next-action) next_action=${2:?missing value for --next-action}; shift 2 ;;
      --owner|--suggested-owner) owner=${2:?missing value for --owner}; shift 2 ;;
      --severity) severity=${2:?missing value for --severity}; shift 2 ;;
      --title) title=${2:?missing value for --title}; shift 2 ;;
      --apply) apply=1; shift ;;
      --json) json=1; shift ;;
      *)
        printf 'blocker_issue_registry report: unknown arg: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done

  blocker_issue_require_value "GH_REPO, BLOCKER_ISSUE_REPO, or --repo" "$repo"
  blocker_issue_require_value "--blocker-kind" "$blocker_kind"
  blocker_issue_require_value "--resource" "$resource"
  blocker_issue_require_value "--profile" "$profile"
  blocker_issue_require_value "--command" "$command_text"
  blocker_issue_require_value "--output-summary" "$output_summary"
  blocker_issue_require_value "--next-action" "$next_action"
  blocker_issue_require_value "--owner" "$owner"
  blocker_issue_require_value "--severity" "$severity"

  local dedupe_key artifact_json impacted_json issue_json issue_number issue_url
  local decision_json body create_output update_comment state
  dedupe_key=$(blocker_issue_key "$PROJECT" "$blocker_kind" "$resource")
  artifact_json=$(blocker_issue_json_array "${artifacts[@]}")
  impacted_json=$(blocker_issue_json_array "${impacted_refs[@]}")
  title=${title:-"[blocker][$blocker_kind] $resource"}
  created_at=$(utc_now)
  body=$(blocker_issue_report_body "$dedupe_key" "$PROJECT" "$blocker_kind" "$resource" \
    "$profile" "$command_text" "$output_summary" "$next_action" "$owner" "$severity" \
    "$artifact_json" "$impacted_json" "$created_at")

  if [[ "$apply" -ne 1 || "${ORCH_DRY_RUN:-0}" == "1" ]]; then
    decision_json=$(blocker_issue_json_result "dry-run" "$repo" "$dedupe_key")
    if [[ "$json" -eq 1 ]]; then
      emit_or_print_result "$json" "$decision_json"
    else
      dry_run_note "report blocker $dedupe_key to $repo"
      printf '%s\n' "$body"
    fi
    return 0
  fi

  issue_json=$(blocker_issue_pick_match "$(blocker_issue_search_json "$repo" "$dedupe_key")" "$dedupe_key" || true)
  if [[ -n "$issue_json" ]]; then
    issue_number=$(jq -r '.number' <<< "$issue_json")
    state=$(jq -r '.state // ""' <<< "$issue_json")
    issue_url=$(jq -r '.url // ""' <<< "$issue_json")
    if [[ "$state" == "CLOSED" ]]; then
      blocker_issue_gh issue reopen "$issue_number" --repo "$repo" >/dev/null
    fi
    update_comment=$(blocker_issue_update_comment "$dedupe_key" "$profile" "$command_text" \
      "$output_summary" "$next_action" "$owner" "$severity" "$artifact_json" "$impacted_json" "$created_at")
    printf '%s' "$update_comment" | gh_issue_comment_body_file "$issue_number" --repo "$repo" >/dev/null
    decision_json=$(blocker_issue_json_result "updated" "$repo" "$dedupe_key" "$issue_number" "$issue_url")
    emit_or_print_result "$json" "$decision_json"
    return 0
  fi

  create_output=$(
    printf '%s' "$body" | gh_issue_create_body_file \
      --repo "$repo" \
      --title "$title"
  )
  issue_url=$(printf '%s\n' "$create_output" | issue_url_from_create_output)
  decision_json=$(blocker_issue_json_result "created" "$repo" "$dedupe_key" "" "$issue_url")
  emit_or_print_result "$json" "$decision_json"
}

cmd_resolve() {
  blocker_issue_require_jq
  local repo=${BLOCKER_ISSUE_REPO:-${GH_REPO:-}} blocker_kind="" resource=""
  local resolution_summary="" policy=${BLOCKER_ISSUE_RESOLUTION_POLICY:-comment}
  local resolved_label=${BLOCKER_ISSUE_RESOLVED_LABEL:-ordo:blocker-resolved}
  local apply=0 json=0 resolved_at

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --repo) repo=${2:?missing value for --repo}; shift 2 ;;
      --blocker-kind|--kind) blocker_kind=${2:?missing value for --blocker-kind}; shift 2 ;;
      --resource) resource=${2:?missing value for --resource}; shift 2 ;;
      --resolution-summary|--summary) resolution_summary=${2:?missing value for --resolution-summary}; shift 2 ;;
      --resolution-policy) policy=${2:?missing value for --resolution-policy}; shift 2 ;;
      --resolved-label) resolved_label=${2:?missing value for --resolved-label}; shift 2 ;;
      --apply) apply=1; shift ;;
      --json) json=1; shift ;;
      *)
        printf 'blocker_issue_registry resolve: unknown arg: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done

  blocker_issue_require_value "GH_REPO, BLOCKER_ISSUE_REPO, or --repo" "$repo"
  blocker_issue_require_value "--blocker-kind" "$blocker_kind"
  blocker_issue_require_value "--resource" "$resource"
  blocker_issue_require_value "--resolution-summary" "$resolution_summary"
  validate_resolution_policy "$policy"

  local dedupe_key issue_json issue_number issue_url comment_body decision_json
  dedupe_key=$(blocker_issue_key "$PROJECT" "$blocker_kind" "$resource")
  resolved_at=$(utc_now)

  if [[ "$apply" -ne 1 || "${ORCH_DRY_RUN:-0}" == "1" ]]; then
    decision_json=$(blocker_issue_json_result "dry-run" "$repo" "$dedupe_key" "" "" "$policy")
    if [[ "$json" -eq 1 ]]; then
      emit_or_print_result "$json" "$decision_json"
    else
      dry_run_note "resolve blocker $dedupe_key in $repo with policy $policy"
    fi
    return 0
  fi

  issue_json=$(blocker_issue_pick_match "$(blocker_issue_search_json "$repo" "$dedupe_key")" "$dedupe_key" || true)
  if [[ -z "$issue_json" ]]; then
    decision_json=$(blocker_issue_json_result "no-match" "$repo" "$dedupe_key" "" "" "$policy")
    emit_or_print_result "$json" "$decision_json"
    return 0
  fi

  issue_number=$(jq -r '.number' <<< "$issue_json")
  issue_url=$(jq -r '.url // ""' <<< "$issue_json")
  comment_body=$(blocker_issue_resolution_comment "$dedupe_key" "$resolution_summary" "$policy" "$resolved_at")

  case "$policy" in
    comment)
      printf '%s' "$comment_body" | gh_issue_comment_body_file "$issue_number" --repo "$repo" >/dev/null
      ;;
    label)
      blocker_issue_gh issue edit "$issue_number" --repo "$repo" --add-label "$resolved_label" >/dev/null
      printf '%s' "$comment_body" | gh_issue_comment_body_file "$issue_number" --repo "$repo" >/dev/null
      ;;
    close)
      printf '%s' "$comment_body" | gh_issue_comment_body_file "$issue_number" --repo "$repo" >/dev/null
      blocker_issue_gh issue close "$issue_number" --repo "$repo" --reason completed >/dev/null
      ;;
  esac

  decision_json=$(blocker_issue_json_result "resolved" "$repo" "$dedupe_key" "$issue_number" "$issue_url" "$policy")
  emit_or_print_result "$json" "$decision_json"
}

case "$COMMAND" in
  key) cmd_key "$@" ;;
  report) cmd_report "$@" ;;
  resolve) cmd_resolve "$@" ;;
  *)
    printf 'blocker_issue_registry: unknown command: %s\n' "$COMMAND" >&2
    exit 2
    ;;
esac
