#!/usr/bin/env bash
# scripts/fleet_provisioning.sh - generate and optionally apply ORDO fleet profile.
#
# Usage:
#   fleet_provisioning.sh --fleet-sizing FILE --repository-bootstrap FILE
#     [--workdir-template TEMPLATE] [--terminal-target-template TEMPLATE]
#     [--profile-output FILE] [--state-output FILE]
#     [--create-workdirs] [--write-profile] [--write-state]
#     [--terminal-apply --terminal-adapter CMD] [--overwrite]
#     [--apply|--dry-run] [--json|--text]

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=../lib/dry_run.sh
source "$TK/lib/dry_run.sh"
# shellcheck source=../lib/fleet_provisioning.sh
source "$TK/lib/fleet_provisioning.sh"

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
}

FLEET_SIZING_FILE=""
REPOSITORY_BOOTSTRAP_FILE=""
WORKDIR_TEMPLATE="${ORDO_PROVISION_WORKDIR_TEMPLATE:-}"
TERMINAL_TARGET_TEMPLATE="${ORDO_PROVISION_TERMINAL_TARGET_TEMPLATE:-}"
PROFILE_OUTPUT="${ORDO_PROVISION_PROFILE_OUTPUT:-}"
STATE_OUTPUT="${ORDO_PROVISION_STATE_OUTPUT:-}"
TERMINAL_ADAPTER="${ORDO_PROVISION_TERMINAL_ADAPTER:-}"
FORMAT="json"
APPLY=0
CREATE_WORKDIRS=0
WRITE_PROFILE=0
WRITE_STATE=0
TERMINAL_APPLY=0
OVERWRITE=0
DRY_ARGS=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --fleet-sizing)
      FLEET_SIZING_FILE=${2:?missing value for --fleet-sizing}
      shift
      ;;
    --fleet-sizing=*) FLEET_SIZING_FILE=${1#--fleet-sizing=} ;;
    --repository-bootstrap|--bootstrap-report)
      REPOSITORY_BOOTSTRAP_FILE=${2:?missing value for --repository-bootstrap}
      shift
      ;;
    --repository-bootstrap=*|--bootstrap-report=*) REPOSITORY_BOOTSTRAP_FILE=${1#*=} ;;
    --workdir-template)
      WORKDIR_TEMPLATE=${2:?missing value for --workdir-template}
      shift
      ;;
    --workdir-template=*) WORKDIR_TEMPLATE=${1#--workdir-template=} ;;
    --terminal-target-template)
      TERMINAL_TARGET_TEMPLATE=${2:?missing value for --terminal-target-template}
      shift
      ;;
    --terminal-target-template=*) TERMINAL_TARGET_TEMPLATE=${1#--terminal-target-template=} ;;
    --profile-output)
      PROFILE_OUTPUT=${2:?missing value for --profile-output}
      shift
      ;;
    --profile-output=*) PROFILE_OUTPUT=${1#--profile-output=} ;;
    --state-output)
      STATE_OUTPUT=${2:?missing value for --state-output}
      shift
      ;;
    --state-output=*) STATE_OUTPUT=${1#--state-output=} ;;
    --terminal-adapter)
      TERMINAL_ADAPTER=${2:?missing value for --terminal-adapter}
      shift
      ;;
    --terminal-adapter=*) TERMINAL_ADAPTER=${1#--terminal-adapter=} ;;
    --create-workdirs) CREATE_WORKDIRS=1 ;;
    --write-profile) WRITE_PROFILE=1 ;;
    --write-state) WRITE_STATE=1 ;;
    --terminal-apply) TERMINAL_APPLY=1 ;;
    --overwrite) OVERWRITE=1 ;;
    --apply) APPLY=1 ;;
    --dry-run)
      DRY_ARGS+=("--dry-run")
      ;;
    --json) FORMAT="json" ;;
    --text) FORMAT="text" ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'fleet_provisioning: unknown arg: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

dry_run_parse_args "${DRY_ARGS[@]}"

mode="plan"
if [[ "$APPLY" -eq 1 ]]; then
  if dry_run_enabled; then
    mode="dry-run"
  else
    mode="apply"
  fi
fi

actions_file=$(mktemp)
applied_file=$(mktemp)
blockers_file=$(mktemp)
warnings_file=$(mktemp)
# shellcheck disable=SC2317 # invoked by EXIT trap.
cleanup() {
  rm -f "$actions_file" "$applied_file" "$blockers_file" "$warnings_file"
}
trap cleanup EXIT

add_action() {
  local name=${1:?usage: add_action <name> <mutating> <enabled> <detail>}
  local mutating=${2:?usage: add_action <name> <mutating> <enabled> <detail>}
  local enabled=${3:?usage: add_action <name> <mutating> <enabled> <detail>}
  local detail=${4:-}
  jq -nc \
    --arg name "$name" \
    --argjson mutating "$mutating" \
    --argjson enabled "$enabled" \
    --arg detail "$detail" \
    '{name:$name,mutating:$mutating,enabled:$enabled,detail:$detail}' >> "$actions_file"
}

add_applied() {
  local name=${1:?usage: add_applied <name> <status> <detail>}
  local status=${2:?usage: add_applied <name> <status> <detail>}
  local detail=${3:-}
  jq -nc --arg name "$name" --arg status "$status" --arg detail "$detail" \
    '{name:$name,status:$status,detail:$detail}' >> "$applied_file"
}

add_blocker() {
  local blocker=${1:?usage: add_blocker <blocker>}
  printf '%s\n' "$blocker" >> "$blockers_file"
}

add_warning() {
  local warning=${1:?usage: add_warning <warning>}
  printf '%s\n' "$warning" >> "$warnings_file"
}

read_json_file_or_block() {
  local path=${1:?usage: read_json_file_or_block <path> <blocker>}
  local blocker=${2:?usage: read_json_file_or_block <path> <blocker>}
  if [[ -z "$path" ]]; then
    add_blocker "$blocker"
    printf '{}\n'
    return 0
  fi
  if [[ ! -r "$path" ]]; then
    add_blocker "$blocker"
    printf '{}\n'
    return 0
  fi
  if ! jq -c . "$path"; then
    add_blocker "$blocker"
    printf '{}\n'
  fi
}

fleet_json=$(read_json_file_or_block "$FLEET_SIZING_FILE" "fleet_sizing_report_missing")
bootstrap_json=$(read_json_file_or_block "$REPOSITORY_BOOTSTRAP_FILE" "repository_bootstrap_report_missing")

recommended_agents=$(jq -r '.recommendation.recommended_agents // .provisioning.requested_agent_count // 0' <<< "$fleet_json")
recommended_agents=$(fleet_provision_uint_or_default "$recommended_agents" 0)
fleet_decision=$(jq -r '.recommendation.decision // "blocked"' <<< "$fleet_json")
bootstrap_status=$(jq -r '.status // "blocked"' <<< "$bootstrap_json")
bootstrap_workdir=$(jq -r '.workdir // ""' <<< "$bootstrap_json")
bootstrap_repository=$(jq -r '.repository // ""' <<< "$bootstrap_json")
bootstrap_default_branch=$(jq -r '.default_branch // ""' <<< "$bootstrap_json")
terminal_required=$(jq -r '.provisioning.required_capabilities.terminal_multiplexer_required // .inputs.terminal_multiplexer.required // false' <<< "$fleet_json")

if [[ "$fleet_decision" == "blocked" ]]; then
  add_blocker "fleet_sizing_blocked"
fi
if [[ "$recommended_agents" -le 0 ]]; then
  add_blocker "fleet_sizing_no_agents"
fi
if [[ "$bootstrap_status" == "blocked" ]]; then
  add_blocker "repository_bootstrap_blocked"
fi
if [[ "$mode" == "apply" && "$bootstrap_status" != "ready" ]]; then
  add_blocker "repository_bootstrap_not_ready_for_apply"
fi
if [[ "$recommended_agents" -gt 1 && -z "$WORKDIR_TEMPLATE" ]]; then
  add_blocker "workdir_template_missing_for_multi_agent"
fi
if [[ "$recommended_agents" -eq 1 && -z "$WORKDIR_TEMPLATE" && -z "$bootstrap_workdir" ]]; then
  add_blocker "workdir_source_missing"
fi
if [[ "$WRITE_PROFILE" -eq 1 && -z "$PROFILE_OUTPUT" ]]; then
  add_blocker "profile_output_missing"
fi
if [[ "$WRITE_STATE" -eq 1 && -z "$STATE_OUTPUT" ]]; then
  add_blocker "state_output_missing"
fi
if [[ "$mode" == "apply" && "$WRITE_PROFILE" -eq 1 && "$OVERWRITE" -ne 1 && -e "$PROFILE_OUTPUT" ]]; then
  add_blocker "profile_output_exists"
fi
if [[ "$mode" == "apply" && "$WRITE_STATE" -eq 1 && "$OVERWRITE" -ne 1 && -e "$STATE_OUTPUT" ]]; then
  add_blocker "state_output_exists"
fi
if [[ "$TERMINAL_APPLY" -eq 1 && "$mode" != "apply" ]]; then
  add_warning "terminal_apply_requires_apply"
fi
if [[ "$TERMINAL_APPLY" -eq 1 && "$mode" == "apply" ]]; then
  if [[ -z "$TERMINAL_ADAPTER" ]]; then
    add_blocker "terminal_adapter_missing"
  elif ! command -v "$TERMINAL_ADAPTER" >/dev/null 2>&1; then
    add_blocker "terminal_adapter_unavailable"
  fi
fi
if [[ "$terminal_required" == "true" && "$TERMINAL_APPLY" -ne 1 ]]; then
  add_warning "terminal_multiplexer_required_but_not_applied"
fi

role_list=$(fleet_provision_roles_json "$fleet_json")
bindings_json=$(jq -c '.provisioning.candidate_identity_bindings // []' <<< "$fleet_json")
agents_file=$(mktemp)
profile_json_file=$(mktemp)
trap 'rm -f "$actions_file" "$applied_file" "$blockers_file" "$warnings_file" "$agents_file" "$profile_json_file"' EXIT

for ((i = 1; i <= recommended_agents; i++)); do
  idx=$((i - 1))
  binding=$(jq -c --argjson idx "$idx" '.[$idx] // {}' <<< "$bindings_json")
  label=$(jq -r '.agent // ""' <<< "$binding")
  [[ -n "$label" ]] || label=$(fleet_provision_generated_label "$i")
  identity=$(jq -r '.identity // ""' <<< "$binding")
  role=$(jq -r --argjson idx "$idx" '.[$idx] // "generalist"' <<< "$role_list")
  if [[ -n "$WORKDIR_TEMPLATE" ]]; then
    workdir=$(fleet_provision_format_template "$WORKDIR_TEMPLATE" "$label" "$i")
  else
    workdir=$bootstrap_workdir
  fi
  if [[ -n "$TERMINAL_TARGET_TEMPLATE" ]]; then
    terminal_target=$(fleet_provision_format_template "$TERMINAL_TARGET_TEMPLATE" "$label" "$i")
  else
    terminal_target=$label
  fi

  if [[ -z "$workdir" ]]; then
    add_blocker "agent_workdir_missing"
  elif [[ -e "$workdir" && ! -d "$workdir" ]]; then
    add_blocker "agent_workdir_not_directory"
  fi

  jq -nc \
    --arg label "$label" \
    --arg role "$role" \
    --arg workdir "$workdir" \
    --arg terminal_target "$terminal_target" \
    --arg identity "$identity" \
    --argjson index "$i" \
    '{
      index:$index,
      label:$label,
      role:$role,
      workdir:$workdir,
      terminal_target:$terminal_target,
      identity:(if $identity == "" then null else $identity end)
    }' >> "$agents_file"
done

agents_json=$(jq -s '.' "$agents_file")
profile_agents_json=$(jq -c 'map(del(.terminal_target))' <<< "$agents_json")
terminal_targets_json=$(jq -c 'map({label,terminal_target,workdir})' <<< "$agents_json")
profile_json=$(jq -nc \
  --arg repository "$bootstrap_repository" \
  --arg default_branch "$bootstrap_default_branch" \
  --arg bootstrap_workdir "$bootstrap_workdir" \
  --argjson agents "$profile_agents_json" \
  '{
    schema_version:"ordo.generated_fleet_profile.v1",
    repository:(if $repository == "" then null else $repository end),
    default_branch:(if $default_branch == "" then null else $default_branch end),
    bootstrap_workdir:(if $bootstrap_workdir == "" then null else $bootstrap_workdir end),
    agents:$agents
  }')
printf '%s\n' "$profile_json" > "$profile_json_file"
profile_text=$(fleet_provision_profile_text "$profile_json")

if [[ "$CREATE_WORKDIRS" -eq 1 ]]; then
  add_action "create_workdirs" "true" "$([[ "$mode" == "apply" ]] && printf true || printf false)" "create missing agent workdirs from generated profile"
else
  add_action "create_workdirs" "true" "false" "disabled unless --create-workdirs and --apply are both set"
fi
if [[ "$WRITE_PROFILE" -eq 1 ]]; then
  add_action "write_profile" "true" "$([[ "$mode" == "apply" ]] && printf true || printf false)" "write generated shell profile"
else
  add_action "write_profile" "true" "false" "profile text is reported but not written by default"
fi
if [[ "$WRITE_STATE" -eq 1 ]]; then
  add_action "write_onboarding_state" "true" "$([[ "$mode" == "apply" ]] && printf true || printf false)" "write onboarding state patch for persistent profile/state"
else
  add_action "write_onboarding_state" "true" "false" "state patch is reported but not written by default"
fi
if [[ "$TERMINAL_APPLY" -eq 1 ]]; then
  add_action "terminal_adapter_apply" "true" "$([[ "$mode" == "apply" ]] && printf true || printf false)" "call configured terminal adapter for generated terminal targets"
else
  add_action "terminal_adapter_apply" "true" "false" "terminal target creation is disabled by default"
fi
add_action "generate_profile" "false" "true" "generate universal ORDO fleet profile and verification inputs"

make_report() {
  local status=${1:?usage: make_report <status>}
  local blockers_json warnings_json actions_json applied_json safe_to_apply apply_requested dry_run_json terminal_apply_requested
  blockers_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$blockers_file")
  warnings_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$warnings_file")
  actions_json=$(jq -s '.' "$actions_file")
  applied_json=$(jq -s '.' "$applied_file")
  if [[ "$(jq -r 'length' <<< "$blockers_json")" -eq 0 ]]; then
    safe_to_apply=true
  else
    safe_to_apply=false
  fi
  [[ "$APPLY" -eq 1 ]] && apply_requested=true || apply_requested=false
  [[ "$TERMINAL_APPLY" -eq 1 ]] && terminal_apply_requested=true || terminal_apply_requested=false
  if dry_run_enabled; then dry_run_json=true; else dry_run_json=false; fi

  jq -n \
    --arg status "$status" \
    --arg mode "$mode" \
    --arg profile_output "$PROFILE_OUTPUT" \
    --arg state_output "$STATE_OUTPUT" \
    --arg profile_text "$profile_text" \
    --argjson apply_requested "$apply_requested" \
    --argjson dry_run "$dry_run_json" \
    --argjson safe_to_apply "$safe_to_apply" \
    --argjson fleet_sizing "$fleet_json" \
    --argjson repository_bootstrap "$bootstrap_json" \
    --argjson profile "$profile_json" \
    --argjson terminal_targets "$terminal_targets_json" \
    --argjson actions "$actions_json" \
    --argjson applied "$applied_json" \
    --argjson blockers "$blockers_json" \
    --argjson warnings "$warnings_json" \
    --argjson terminal_apply_requested "$terminal_apply_requested" \
    '{
      schema_version:"ordo.fleet_provisioning.v1",
      status:$status,
      mode:$mode,
      apply_requested:$apply_requested,
      dry_run:$dry_run,
      safe_to_apply:$safe_to_apply,
      inputs:{
        fleet_sizing:{
          schema_version:($fleet_sizing.schema_version // null),
          decision:($fleet_sizing.recommendation.decision // null),
          recommended_agents:($fleet_sizing.recommendation.recommended_agents // null),
          provisioning:($fleet_sizing.provisioning // {})
        },
        repository_bootstrap:{
          status:($repository_bootstrap.status // null),
          safe_to_apply:($repository_bootstrap.safe_to_apply // null),
          repository:($repository_bootstrap.repository // null),
          workdir:($repository_bootstrap.workdir // null),
          default_branch:($repository_bootstrap.default_branch // null)
        }
      },
      generated_profile:($profile + {
        profile_text:$profile_text,
        profile_output:(if $profile_output == "" then null else $profile_output end)
      }),
      actions:$actions,
      applied:$applied,
      blockers:$blockers,
      warnings:$warnings,
      verification_input:{
        schema_version:"ordo.provisioning_verification.input.v1",
        expected_agent_count:($profile.agents | length),
        profile_output:(if $profile_output == "" then null else $profile_output end),
        state_output:(if $state_output == "" then null else $state_output end),
        expected_workdirs:($profile.agents | map({label,workdir})),
        agent_targets:($profile.agents | map({label,role,workdir})),
        terminal_adapter:{
          requested:$terminal_apply_requested,
          targets:(if $terminal_apply_requested then ($terminal_targets | map({label,target:.terminal_target,workdir})) else [] end),
          actions_applied:(any($applied[]?; .name == "terminal_adapter_apply" and .status == "applied"))
        }
      },
      onboarding_state:{
        schema_version:"ordo.onboarding_state_patch.v1",
        generated_profile:{
          schema_version:$profile.schema_version,
          agent_count:($profile.agents | length),
          profile_output:(if $profile_output == "" then null else $profile_output end),
          state_output:(if $state_output == "" then null else $state_output end),
          agents:$profile.agents,
          source_decision:($fleet_sizing.recommendation.decision // null)
        }
      }
    }'
}

blocker_count=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique | length' "$blockers_file")
if [[ "$mode" != "apply" ]]; then
  if [[ "$blocker_count" -eq 0 ]]; then
    report=$(make_report "$mode")
  else
    report=$(make_report "blocked")
  fi
  if [[ "$FORMAT" == "json" ]]; then
    jq . <<< "$report"
  else
    jq -r '"Fleet provisioning: " + .status, "Mode: " + .mode, "Agents: " + (.generated_profile.agents | length | tostring), "Blockers: " + (if (.blockers | length) == 0 then "none" else (.blockers | join(",")) end)' <<< "$report"
  fi
  exit 0
fi

if [[ "$blocker_count" -gt 0 ]]; then
  report=$(make_report "blocked")
  if [[ "$FORMAT" == "json" ]]; then
    jq . <<< "$report"
  else
    jq -r '"Fleet provisioning: blocked", "Blockers: " + (.blockers | join(","))' <<< "$report"
  fi
  exit "$ORDO_PROVISION_REFUSAL_EXIT_CODE"
fi

if [[ "$CREATE_WORKDIRS" -eq 1 ]]; then
  while IFS=$'\t' read -r label workdir; do
    [[ -n "$label" && -n "$workdir" ]] || continue
    if [[ -d "$workdir" ]]; then
      add_applied "create_workdirs" "already_ready" "$label"
    else
      mkdir -p "$workdir"
      add_applied "create_workdirs" "applied" "$label"
    fi
  done < <(jq -r '.agents[] | [.label,.workdir] | @tsv' "$profile_json_file")
fi

if [[ "$WRITE_PROFILE" -eq 1 ]]; then
  mkdir -p "$(dirname "$PROFILE_OUTPUT")"
  printf '%s\n' "$profile_text" > "$PROFILE_OUTPUT"
  add_applied "write_profile" "applied" "profile_output"
fi

if [[ "$TERMINAL_APPLY" -eq 1 ]]; then
  while IFS=$'\t' read -r label terminal_target workdir; do
    [[ -n "$label" ]] || continue
    if "$TERMINAL_ADAPTER" provision-target --label "$label" --target "$terminal_target" --workdir "$workdir"; then
      add_applied "terminal_adapter_apply" "applied" "$label"
    else
      add_applied "terminal_adapter_apply" "failed" "$label"
      add_blocker "terminal_adapter_apply_failed"
      report=$(make_report "blocked")
      jq . <<< "$report"
      exit "$ORDO_PROVISION_REFUSAL_EXIT_CODE"
    fi
  done < <(jq -r '.[] | [.label,.terminal_target,.workdir] | @tsv' <<< "$terminal_targets_json")
fi

if [[ "$WRITE_STATE" -eq 1 ]]; then
  mkdir -p "$(dirname "$STATE_OUTPUT")"
  state_report=$(make_report "applied")
  jq '.onboarding_state' <<< "$state_report" > "$STATE_OUTPUT"
  add_applied "write_onboarding_state" "applied" "state_output"
fi

report=$(make_report "applied")
if [[ "$FORMAT" == "json" ]]; then
  jq . <<< "$report"
else
  jq -r '"Fleet provisioning: " + .status, "Mode: " + .mode, "Agents: " + (.generated_profile.agents | length | tostring), "Blockers: " + (if (.blockers | length) == 0 then "none" else (.blockers | join(",")) end)' <<< "$report"
fi
