#!/usr/bin/env bash
# scripts/repository_platform_readiness.sh - provider-neutral repository readiness report.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/config_resolver.sh"
source "$TK/lib/agent_inventory.sh"
source "$TK/lib/process_safety.sh"
source "$TK/lib/repository_platform.sh"

CFG_ARG=${1:?usage: repository_platform_readiness.sh <project|config> [--json|--tsv]}
FORMAT="json"
shift || true
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --json) FORMAT="json" ;;
    --tsv) FORMAT="tsv" ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

load_project_config "$CFG_ARG"

: "${REPOSITORY_PLATFORM_READINESS_REFUSAL_EXIT_CODE:=78}"

repo=$(repository_platform_repo_identifier)
expected_identity=$(repository_platform_expected_identity)
active_identity=""
permission=""
repo_metadata=""
status="ready"

capabilities_file=$(mktemp)
bindings_file=$(mktemp)
blockers_file=$(mktemp)
capabilities_json_file=$(mktemp)
blockers_json_file=$(mktemp)
# shellcheck disable=SC2317 # invoked by EXIT trap.
cleanup() {
  rm -f "$capabilities_file" "$bindings_file" "$blockers_file" \
    "$capabilities_json_file" "$blockers_json_file"
}
trap cleanup EXIT

add_blocker() {
  local blocker=${1:?usage: add_blocker <blocker>}
  printf '%s\n' "$blocker" >> "$blockers_file"
}

add_capability() {
  local name=${1:?usage: add_capability <name> <true|false> <detail>}
  local ready=${2:?usage: add_capability <name> <true|false> <detail>}
  local detail=${3:-}
  jq -nc --arg name "$name" --argjson ready "$ready" --arg detail "$detail" \
    '{name:$name,ready:$ready,detail:$detail}' >> "$capabilities_file"
  if [[ "$ready" != "true" ]]; then
    add_blocker "$name"
  fi
}

add_identity_binding() {
  local agent=${1:?usage: add_identity_binding <agent> <identity> <status>}
  local identity=${2:-}
  local binding_status=${3:-unresolved}
  jq -nc --arg agent "$agent" --arg identity "$identity" --arg status "$binding_status" \
    '{agent:$agent,identity:(if $identity == "" then null else $identity end),status:$status}' \
    >> "$bindings_file"
}

adapter_detail() {
  local cli_bin
  if cli_bin=$(repository_platform_cli_bin 2>/dev/null); then
    printf 'adapter_cli=%s' "$(basename "$cli_bin")"
  else
    printf 'adapter_cli=missing'
  fi
}

active_error=""
if active_identity=$(repository_platform_active_identity 2>&1); then
  active_identity=$(printf '%s\n' "$active_identity" | sed -n '1p')
  if [[ -n "$active_identity" ]]; then
    add_capability "identity_binding" "true" "active_identity_detected"
  else
    add_capability "identity_binding" "false" "active_identity_empty"
    add_blocker "repository_platform_auth_unusable"
  fi
else
  active_error=$active_identity
  active_identity=""
  add_capability "identity_binding" "false" "active_identity_unusable: $(printf '%s' "$active_error" | tr '\n' ' ' | cut -c1-160)"
  add_blocker "repository_platform_auth_unusable"
fi

if [[ -n "$expected_identity" && -n "$active_identity" && "$active_identity" != "$expected_identity" ]]; then
  add_blocker "identity_binding"
  jq -nc --arg name "identity_binding" --arg detail "expected_identity_mismatch" \
    '{name:$name,ready:false,detail:$detail}' >> "$capabilities_file"
fi

if [[ -z "$repo" ]]; then
  add_capability "repository_access" "false" "repository_binding_missing"
else
  repo_error=""
  if repo_metadata=$(repository_platform_repo_metadata "$repo" 2>&1); then
    add_capability "repository_access" "true" "$(adapter_detail)"
    permission=$(printf '%s' "$repo_metadata" | jq -r '.permission // ""' 2>/dev/null || true)
  else
    repo_error=$repo_metadata
    add_capability "repository_access" "false" "repository_metadata_unusable: $(printf '%s' "$repo_error" | tr '\n' ' ' | cut -c1-160)"
  fi
fi

if [[ -n "$permission" ]] && repository_platform_permission_allows_write "$permission"; then
  add_capability "push_permission" "true" "permission=$permission"
else
  add_capability "push_permission" "false" "permission=${permission:-unknown}"
fi

if [[ -n "$repo" && -n "$active_identity" ]] \
  && repository_platform_pr_review_capable "$repo" "$active_identity" 2>/dev/null; then
  add_capability "pr_review_capability" "true" "active_identity_can_review"
else
  add_capability "pr_review_capability" "false" "permission=${permission:-unknown}"
fi

if [[ -n "$repo" && -n "$active_identity" ]] \
  && repository_platform_issue_assignment_capable "$repo" "$active_identity" 2>/dev/null; then
  add_capability "issue_assignment_capability" "true" "active_identity_assignable"
else
  add_capability "issue_assignment_capability" "false" "active_identity_not_assignable"
fi

if [[ -n "$repo" ]] && repository_platform_ci_status_visible "$repo" 2>/dev/null; then
  add_capability "ci_status_visibility" "true" "ci_status_visible"
else
  add_capability "ci_status_visibility" "false" "ci_status_unavailable"
fi

if agent_inventory_entries >/dev/null 2>&1; then
  while IFS='|' read -r label _pane _workdir; do
    [[ -n "$label" ]] || continue
    identity=$(resolve_agent_repository_platform_identity "$label" || true)
    if [[ -n "$identity" ]]; then
      add_identity_binding "$label" "$identity" "bound"
    else
      add_identity_binding "$label" "" "unresolved"
      add_blocker "identity_binding"
    fi
  done < <(agent_inventory_entries)
fi

jq -s 'map({key:.name,value:{ready:.ready,detail:.detail}}) | from_entries' \
  "$capabilities_file" > "$capabilities_json_file"
jq -R -s 'split("\n") | map(select(length > 0)) | unique' \
  "$blockers_file" > "$blockers_json_file"

if [[ "$(jq -r 'length' "$blockers_json_file")" -gt 0 ]]; then
  status="blocked"
fi

if [[ "$FORMAT" == "json" ]]; then
  jq -n \
    --arg status "$status" \
    --arg repository "$repo" \
    --arg active_identity "$active_identity" \
    --arg expected_identity "$expected_identity" \
    --slurpfile capabilities "$capabilities_json_file" \
    --slurpfile identity_bindings "$bindings_file" \
    --slurpfile blockers "$blockers_json_file" \
    '{
      status:$status,
      repository:(if $repository == "" then null else $repository end),
      active_identity:(if $active_identity == "" then null else $active_identity end),
      expected_identity:(if $expected_identity == "" then null else $expected_identity end),
      capabilities:$capabilities[0],
      identity_bindings:$identity_bindings,
      blockers:$blockers[0]
    }'
else
  printf 'status\t%s\n' "$status"
  printf 'repository\t%s\n' "${repo:-missing}"
  printf 'active_identity\t%s\n' "${active_identity:-missing}"
  jq -r '. as $cap | keys[] as $k | "capability\t\($k)\t\($cap[$k].ready)\t\($cap[$k].detail)"' \
    "$capabilities_json_file"
  jq -r '.[] | "blocker\t" + .' "$blockers_json_file"
fi

if [[ "$status" == "ready" ]]; then
  exit 0
fi
exit "$REPOSITORY_PLATFORM_READINESS_REFUSAL_EXIT_CODE"
