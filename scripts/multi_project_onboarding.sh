#!/usr/bin/env bash
# scripts/multi_project_onboarding.sh — drive scripts/guided_onboarding.sh
# once per project under a portfolio manifest (#252).
#
# Why a wrapper rather than a second onboarding system?
#   - Per issue #252, the existing single-project guided_onboarding profile
#     and state remain the canonical onboarding entry point. This wrapper
#     extends the surface for multi-project portfolios without duplicating
#     the profile schema or building a parallel state store.
#   - Each project entry in the manifest results in exactly one canonical
#     `ordo.guided_onboarding_profile.v1` written by guided_onboarding.sh.
#     The portfolio profile this script emits is purely an aggregate
#     index over those per-project profiles.
#
# Manifest schema (input):
#   {
#     "schema_version": "ordo.multi_project_onboarding.manifest.v1",
#     "portfolio_alias": "<string>",
#     "projects": [
#       {
#         "alias":           "<string>",
#         "default_branch":  "<string>",
#         "validation_mode": "gxp" | "dev",
#         "operator_class":  "internal" | "external",
#         "runtime_root":    "<absolute path>",
#         "agent_labels":    ["<string>", ...],
#         "repo_mode":       "existing" | "greenfield",
#         "host_report":           "<path>",
#         "repository_report":     "<path>",
#         "bootstrap_report":      "<path>",
#         "scaffold_report":       "<path>",
#         "fleet_sizing":          "<path>",
#         "provisioning_report":   "<path>"
#       }, ...
#     ]
#   }
#
# Output: aggregated portfolio profile of shape
#   {
#     "schema_version": "ordo.multi_project_onboarding.portfolio.v1",
#     "portfolio_alias": "<string>",
#     "status": "plan" | "applied" | "blocked",
#     "safe_to_apply": true|false,
#     "projects": [
#       {
#         "alias": "<string>",
#         "validation_mode": "<gxp|dev>",
#         "operator_class": "<internal|external>",
#         "status": "<per-project status>",
#         "blockers": [...],
#         "profile_path": "<path-or-null>",
#         "state_path":   "<path-or-null>",
#         "onboarding_profile": { ... canonical guided_onboarding profile ... }
#       }, ...
#     ],
#     "blockers": [<aggregated, deduplicated>]
#   }
#
# Refusal exit code is the same 78 the single-project flow uses, so wave
# orchestration treats blocked portfolio onboarding identically.
set -euo pipefail
TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

: "${ORDO_GUIDED_ONBOARDING_REFUSAL_EXIT_CODE:=78}"

usage() {
  cat <<'EOF' >&2
usage:
  multi_project_onboarding.sh --manifest FILE
    [--profile-dir DIR]       per-project profiles + portfolio profile
    [--state-dir DIR]         per-project states
    [--apply] [--dry-run] [--overwrite]
    [--json|--text]

Reads a JSON manifest enumerating projects and invokes guided_onboarding.sh
once per project. The single-project profile schema remains canonical;
this script aggregates the resulting profiles into a portfolio index.
EOF
}

MANIFEST=""
PROFILE_DIR=""
STATE_DIR=""
APPLY=0
DRY_RUN=0
OVERWRITE=0
FORMAT="json"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST=${2:?missing value for --manifest}; shift ;;
    --manifest=*) MANIFEST=${1#--manifest=} ;;
    --profile-dir) PROFILE_DIR=${2:?missing value for --profile-dir}; shift ;;
    --profile-dir=*) PROFILE_DIR=${1#--profile-dir=} ;;
    --state-dir) STATE_DIR=${2:?missing value for --state-dir}; shift ;;
    --state-dir=*) STATE_DIR=${1#--state-dir=} ;;
    --apply) APPLY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --overwrite) OVERWRITE=1 ;;
    --json) FORMAT="json" ;;
    --text) FORMAT="text" ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'multi_project_onboarding: unknown arg: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
  shift
done

[[ -n "$MANIFEST" && -r "$MANIFEST" ]] \
  || { printf 'multi_project_onboarding: --manifest FILE is required and must be readable\n' >&2; exit 2; }

manifest_json=$(jq -c . "$MANIFEST" 2>/dev/null) \
  || { printf 'multi_project_onboarding: manifest is not valid JSON: %s\n' "$MANIFEST" >&2; exit 2; }

portfolio_alias=$(jq -r '.portfolio_alias // ""' <<< "$manifest_json")
project_count=$(jq -r '.projects | length' <<< "$manifest_json")
[[ "${project_count:-0}" -gt 0 ]] \
  || { printf 'multi_project_onboarding: manifest has no projects\n' >&2; exit 2; }

declare -a project_records=()
declare -a aggregate_blockers=()
overall_safe=true

for ((i=0; i<project_count; i++)); do
  project=$(jq -c --argjson i "$i" '.projects[$i]' <<< "$manifest_json")
  alias=$(jq -r '.alias // ""' <<< "$project")
  if [[ -z "$alias" ]]; then
    aggregate_blockers+=("project_alias_missing_at_index_$i")
    overall_safe=false
    project_records+=("$(jq -nc \
      --arg index "$i" \
      '{index: ($index | tonumber), alias: null, status: "blocked",
        blockers:["project_alias_missing"]}')")
    continue
  fi

  args=(
    --repo-mode "$(jq -r '.repo_mode // "existing"' <<< "$project")"
    --project-alias "$alias"
  )
  for k in default_branch validation_mode operator_class runtime_root; do
    v=$(jq -r --arg k "$k" '.[$k] // ""' <<< "$project")
    if [[ -n "$v" ]]; then
      args+=("--${k//_/-}" "$v")
    fi
  done
  while IFS= read -r label; do
    [[ -n "$label" ]] || continue
    args+=(--agent-label "$label")
  done < <(jq -r '.agent_labels // [] | .[]' <<< "$project")
  for report_key in host_report repository_report bootstrap_report scaffold_report fleet_sizing provisioning_report; do
    v=$(jq -r --arg k "$report_key" '.[$k] // ""' <<< "$project")
    if [[ -n "$v" ]]; then
      args+=("--${report_key//_/-}" "$v")
    fi
  done

  per_profile=""
  per_state=""
  if [[ -n "$PROFILE_DIR" ]]; then
    per_profile="$PROFILE_DIR/onboarding-profile-${alias}.json"
    args+=(--profile-output "$per_profile" --write-profile)
  fi
  if [[ -n "$STATE_DIR" ]]; then
    per_state="$STATE_DIR/onboarding-state-${alias}.json"
    args+=(--state-output "$per_state" --write-state)
  fi
  [[ "$APPLY" -eq 1 ]] && args+=(--apply)
  [[ "$DRY_RUN" -eq 1 ]] && args+=(--dry-run)
  [[ "$OVERWRITE" -eq 1 ]] && args+=(--overwrite)
  args+=(--json)

  set +e
  per_project_output=$(bash "$TK/scripts/guided_onboarding.sh" "${args[@]}" 2>&1)
  per_project_status=$?
  set -e

  if ! per_project_json=$(jq -c . <<< "$per_project_output" 2>/dev/null); then
    aggregate_blockers+=("project_${alias}_invalid_output")
    overall_safe=false
    project_records+=("$(jq -nc --arg alias "$alias" --arg index "$i" \
      --arg raw "$per_project_output" --arg rc "$per_project_status" \
      '{index:($index|tonumber), alias:$alias, status:"blocked",
        exit_code:($rc|tonumber), blockers:["invalid_output"], raw:$raw}')")
    continue
  fi

  per_project_blockers=$(jq -c '.blockers // []' <<< "$per_project_json")
  per_project_safe=$(jq -r '.safe_to_apply // false' <<< "$per_project_json")
  if [[ "$per_project_safe" != "true" ]]; then
    overall_safe=false
  fi
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    aggregate_blockers+=("project_${alias}::${b}")
  done < <(jq -r '.[]' <<< "$per_project_blockers")

  project_records+=("$(jq -nc \
    --arg index "$i" \
    --arg alias "$alias" \
    --arg validation_mode "$(jq -r '.onboarding_profile.project_metadata.validation_mode // ""' <<< "$per_project_json")" \
    --arg operator_class "$(jq -r '.onboarding_profile.project_metadata.operator_class // ""' <<< "$per_project_json")" \
    --arg status "$(jq -r '.status // ""' <<< "$per_project_json")" \
    --arg exit_code "$per_project_status" \
    --arg profile_path "$per_profile" \
    --arg state_path "$per_state" \
    --argjson safe "$per_project_safe" \
    --argjson blockers "$per_project_blockers" \
    --argjson onboarding_profile "$(jq '.onboarding_profile // null' <<< "$per_project_json")" \
    '{
      index:($index|tonumber), alias:$alias,
      validation_mode:(if $validation_mode == "" then null else $validation_mode end),
      operator_class:(if $operator_class == "" then null else $operator_class end),
      status:$status, safe_to_apply:$safe,
      exit_code:($exit_code|tonumber),
      blockers:$blockers,
      profile_path:(if $profile_path == "" then null else $profile_path end),
      state_path:(if $state_path == "" then null else $state_path end),
      onboarding_profile:$onboarding_profile
    }')")
done

projects_json='[]'
if [[ "${#project_records[@]}" -gt 0 ]]; then
  projects_json=$(printf '%s\n' "${project_records[@]}" | jq -s '.')
fi
blockers_json='[]'
if [[ "${#aggregate_blockers[@]}" -gt 0 ]]; then
  blockers_json=$(printf '%s\n' "${aggregate_blockers[@]}" | jq -R -s 'split("\n") | map(select(length > 0)) | unique')
fi

overall_status="plan"
if [[ "$overall_safe" != "true" ]]; then
  overall_status="blocked"
elif [[ "$APPLY" -eq 1 && "$DRY_RUN" -ne 1 ]]; then
  overall_status="applied"
elif [[ "$DRY_RUN" -eq 1 ]]; then
  overall_status="dry-run"
fi

portfolio=$(jq -nc \
  --arg portfolio_alias "$portfolio_alias" \
  --arg status "$overall_status" \
  --argjson safe_to_apply "$overall_safe" \
  --argjson projects "$projects_json" \
  --argjson blockers "$blockers_json" \
  '{
    schema_version:"ordo.multi_project_onboarding.portfolio.v1",
    portfolio_alias:(if $portfolio_alias == "" then null else $portfolio_alias end),
    status:$status,
    safe_to_apply:$safe_to_apply,
    projects:$projects,
    blockers:$blockers
  }')

if [[ -n "$PROFILE_DIR" && "$APPLY" -eq 1 && "$DRY_RUN" -ne 1 ]]; then
  mkdir -p "$PROFILE_DIR"
  printf '%s\n' "$portfolio" | jq . > "$PROFILE_DIR/portfolio-onboarding-profile.json"
fi

if [[ "$FORMAT" == "json" ]]; then
  jq . <<< "$portfolio"
else
  jq -r '
    "Multi-project onboarding: " + .status,
    "Projects: " + ([.projects[].alias] | join(",")),
    "Blockers: " + (if (.blockers | length) == 0 then "none" else (.blockers | join(",")) end)
  ' <<< "$portfolio"
fi

if [[ "$overall_safe" != "true" ]]; then
  exit "$ORDO_GUIDED_ONBOARDING_REFUSAL_EXIT_CODE"
fi
exit 0
