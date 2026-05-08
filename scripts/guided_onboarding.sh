#!/usr/bin/env bash
# scripts/guided_onboarding.sh - assemble guided ORDO onboarding profile/state.
set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=../lib/dry_run.sh
source "$TK/lib/dry_run.sh"

usage() {
  cat <<'EOF' >&2
usage:
  guided_onboarding.sh --repo-mode <existing|greenfield>
    --host-report FILE --repository-report FILE --bootstrap-report FILE
    --scaffold-report FILE --fleet-sizing FILE --provisioning-report FILE
    [--profile-output FILE --write-profile]
    [--state-output FILE --write-state]
    [--apply] [--dry-run] [--overwrite] [--json|--text]

Builds a guided onboarding preview by default. Persistent profile/state writes
require --apply and explicit write flags. This command consumes upstream ORDO
reports; it does not create repositories, project files, workdirs, or terminal
adapter targets.
EOF
}

: "${ORDO_GUIDED_ONBOARDING_REFUSAL_EXIT_CODE:=78}"

REPO_MODE="${ORDO_ONBOARDING_REPO_MODE:-}"
HOST_REPORT_FILE="${ORDO_ONBOARDING_HOST_REPORT:-}"
REPOSITORY_REPORT_FILE="${ORDO_ONBOARDING_REPOSITORY_REPORT:-}"
BOOTSTRAP_REPORT_FILE="${ORDO_ONBOARDING_BOOTSTRAP_REPORT:-}"
SCAFFOLD_REPORT_FILE="${ORDO_ONBOARDING_SCAFFOLD_REPORT:-}"
FLEET_SIZING_FILE="${ORDO_ONBOARDING_FLEET_SIZING:-}"
PROVISIONING_REPORT_FILE="${ORDO_ONBOARDING_PROVISIONING_REPORT:-}"
PROFILE_OUTPUT="${ORDO_ONBOARDING_PROFILE_OUTPUT:-}"
STATE_OUTPUT="${ORDO_ONBOARDING_STATE_OUTPUT:-}"
FORMAT="json"
APPLY=0
WRITE_PROFILE=0
WRITE_STATE=0
OVERWRITE=0
DRY_ARGS=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --repo-mode)
      REPO_MODE=${2:?missing value for --repo-mode}
      shift
      ;;
    --repo-mode=*) REPO_MODE=${1#--repo-mode=} ;;
    --host-report)
      HOST_REPORT_FILE=${2:?missing value for --host-report}
      shift
      ;;
    --host-report=*) HOST_REPORT_FILE=${1#--host-report=} ;;
    --repository-report|--repository-readiness)
      REPOSITORY_REPORT_FILE=${2:?missing value for --repository-report}
      shift
      ;;
    --repository-report=*|--repository-readiness=*) REPOSITORY_REPORT_FILE=${1#*=} ;;
    --bootstrap-report|--repository-bootstrap)
      BOOTSTRAP_REPORT_FILE=${2:?missing value for --bootstrap-report}
      shift
      ;;
    --bootstrap-report=*|--repository-bootstrap=*) BOOTSTRAP_REPORT_FILE=${1#*=} ;;
    --scaffold-report|--project-scaffold)
      SCAFFOLD_REPORT_FILE=${2:?missing value for --scaffold-report}
      shift
      ;;
    --scaffold-report=*|--project-scaffold=*) SCAFFOLD_REPORT_FILE=${1#*=} ;;
    --fleet-sizing)
      FLEET_SIZING_FILE=${2:?missing value for --fleet-sizing}
      shift
      ;;
    --fleet-sizing=*) FLEET_SIZING_FILE=${1#--fleet-sizing=} ;;
    --provisioning-report|--fleet-provisioning)
      PROVISIONING_REPORT_FILE=${2:?missing value for --provisioning-report}
      shift
      ;;
    --provisioning-report=*|--fleet-provisioning=*) PROVISIONING_REPORT_FILE=${1#*=} ;;
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
    --write-profile) WRITE_PROFILE=1 ;;
    --write-state) WRITE_STATE=1 ;;
    --overwrite) OVERWRITE=1 ;;
    --apply) APPLY=1 ;;
    --dry-run) DRY_ARGS+=("--dry-run") ;;
    --json) FORMAT="json" ;;
    --text) FORMAT="text" ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'guided_onboarding: unknown arg: %s\n' "$1" >&2
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

blockers_file=$(mktemp)
warnings_file=$(mktemp)
actions_file=$(mktemp)
applied_file=$(mktemp)
# shellcheck disable=SC2317 # invoked by EXIT trap.
cleanup() {
  rm -f "$blockers_file" "$warnings_file" "$actions_file" "$applied_file"
}
trap cleanup EXIT

add_line() {
  local file=${1:?usage: add_line <file> <value>}
  local value=${2:?usage: add_line <file> <value>}
  printf '%s\n' "$value" >> "$file"
}

add_blocker() {
  add_line "$blockers_file" "$1"
}

add_warning() {
  add_line "$warnings_file" "$1"
}

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
  local applied_status=${2:?usage: add_applied <name> <status> <detail>}
  local detail=${3:-}
  jq -nc --arg name "$name" --arg status "$applied_status" --arg detail "$detail" \
    '{name:$name,status:$status,detail:$detail}' >> "$applied_file"
}

valid_repo_mode() {
  case "${1:-}" in
    existing|greenfield) return 0 ;;
  esac
  return 1
}

read_report() {
  local path=${1-}
  local missing_blocker=${2:?usage: read_report <path> <missing-blocker> <invalid-blocker>}
  local invalid_blocker=${3:?usage: read_report <path> <missing-blocker> <invalid-blocker>}
  local output

  if [[ -z "$path" ]]; then
    add_blocker "$missing_blocker"
    printf '{}\n'
    return 0
  fi
  if [[ ! -r "$path" ]]; then
    add_blocker "$missing_blocker"
    printf '{}\n'
    return 0
  fi
  if output=$(jq -c . "$path" 2>/dev/null); then
    printf '%s\n' "$output"
  else
    add_blocker "$invalid_blocker"
    printf '{}\n'
  fi
}

source_sha256() {
  local path=${1:-}
  [[ -n "$path" && -r "$path" ]] || {
    printf '\n'
    return 0
  }
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
  else
    printf '\n'
  fi
}

json_present() {
  jq -e 'length > 0' >/dev/null 2>&1 <<< "$1"
}

if [[ -z "$REPO_MODE" ]]; then
  add_blocker "repository_mode_missing"
elif ! valid_repo_mode "$REPO_MODE"; then
  add_blocker "repository_mode_invalid"
fi

host_json=$(read_report "$HOST_REPORT_FILE" "host_assessment_report_missing" "host_assessment_report_invalid")
repository_json=$(read_report "$REPOSITORY_REPORT_FILE" "repository_readiness_report_missing" "repository_readiness_report_invalid")
bootstrap_json=$(read_report "$BOOTSTRAP_REPORT_FILE" "repository_bootstrap_report_missing" "repository_bootstrap_report_invalid")
scaffold_json=$(read_report "$SCAFFOLD_REPORT_FILE" "project_scaffold_report_missing" "project_scaffold_report_invalid")
fleet_json=$(read_report "$FLEET_SIZING_FILE" "fleet_sizing_report_missing" "fleet_sizing_report_invalid")
provisioning_json=$(read_report "$PROVISIONING_REPORT_FILE" "fleet_provisioning_report_missing" "fleet_provisioning_report_invalid")

host_step="missing"
repository_step="missing"
bootstrap_step="missing"
scaffold_step="missing"
fleet_step="missing"
provisioning_step="missing"

if json_present "$host_json"; then
  host_suitability=$(jq -r '.environment_recommendation.suitability // ""' <<< "$host_json")
  if [[ "$host_suitability" == "suitable" ]]; then
    host_step="ready"
  else
    host_step="blocked"
    add_blocker "host_assessment_not_suitable"
  fi
fi

if json_present "$repository_json"; then
  repository_status=$(jq -r '.status // ""' <<< "$repository_json")
  if [[ "$repository_status" == "ready" ]]; then
    repository_step="ready"
  else
    repository_step="blocked"
    add_blocker "repository_platform_not_ready"
  fi
fi

if json_present "$bootstrap_json"; then
  bootstrap_status=$(jq -r '.status // ""' <<< "$bootstrap_json")
  if [[ "$bootstrap_status" == "ready" ]]; then
    bootstrap_step="ready"
  else
    bootstrap_step="blocked"
    add_blocker "repository_bootstrap_not_ready"
  fi
fi

if json_present "$scaffold_json"; then
  scaffold_status=$(jq -r '.status // ""' <<< "$scaffold_json")
  if [[ "$scaffold_status" == "ready" ]]; then
    scaffold_step="ready"
  else
    scaffold_step="blocked"
    add_blocker "project_scaffold_not_ready"
  fi
fi

if json_present "$fleet_json"; then
  fleet_decision=$(jq -r '.recommendation.decision // "blocked"' <<< "$fleet_json")
  fleet_agents=$(jq -r '.recommendation.recommended_agents // .provisioning.requested_agent_count // 0' <<< "$fleet_json")
  if [[ "$fleet_decision" != "blocked" && "$fleet_agents" =~ ^[0-9]+$ && "$fleet_agents" -gt 0 ]]; then
    fleet_step="ready"
  else
    fleet_step="blocked"
    add_blocker "fleet_sizing_not_ready"
  fi
fi

if json_present "$provisioning_json"; then
  provisioning_status=$(jq -r '.status // "blocked"' <<< "$provisioning_json")
  provisioning_safe=$(jq -r '.safe_to_apply // false' <<< "$provisioning_json")
  provisioning_agents=$(jq -r '.generated_profile.agents | length' <<< "$provisioning_json" 2>/dev/null || printf '0\n')
  if [[ "$provisioning_status" != "blocked" && "$provisioning_safe" == "true" && "$provisioning_agents" -gt 0 ]]; then
    provisioning_step="ready"
  else
    provisioning_step="blocked"
    add_blocker "fleet_provisioning_not_ready"
  fi
  if ! jq -e '.generated_profile.schema_version == "ordo.generated_fleet_profile.v1"' \
    >/dev/null 2>&1 <<< "$provisioning_json"; then
    add_blocker "fleet_provisioning_profile_missing"
    provisioning_step="blocked"
  fi
fi

if [[ "$fleet_step" == "ready" && "$provisioning_step" == "ready" ]]; then
  expected_agents=$(jq -r '.recommendation.recommended_agents // .provisioning.requested_agent_count // 0' <<< "$fleet_json")
  provisioned_agents=$(jq -r '.generated_profile.agents | length' <<< "$provisioning_json")
  if [[ "$expected_agents" =~ ^[0-9]+$ && "$provisioned_agents" =~ ^[0-9]+$ \
    && "$expected_agents" -ne "$provisioned_agents" ]]; then
    add_blocker "fleet_provisioning_agent_count_mismatch"
    provisioning_step="blocked"
  fi
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
if [[ "$mode" == "apply" && "$WRITE_PROFILE" -eq 0 && "$WRITE_STATE" -eq 0 ]]; then
  add_warning "apply_requested_without_persistent_writes"
fi

add_action "review_guided_flow" "false" "true" "assemble operator prompts, readiness state, and rerun guidance"
add_action "write_onboarding_profile" "true" \
  "$([[ "$mode" == "apply" && "$WRITE_PROFILE" -eq 1 ]] && printf true || printf false)" \
  "write redaction-safe onboarding profile only when explicitly requested"
add_action "write_onboarding_state" "true" \
  "$([[ "$mode" == "apply" && "$WRITE_STATE" -eq 1 ]] && printf true || printf false)" \
  "write resumable onboarding state only when explicitly requested"
add_action "invoke_terminal_adapter" "true" "false" "terminal adapter actions stay outside guided onboarding"

host_sha=$(source_sha256 "$HOST_REPORT_FILE")
repository_sha=$(source_sha256 "$REPOSITORY_REPORT_FILE")
bootstrap_sha=$(source_sha256 "$BOOTSTRAP_REPORT_FILE")
scaffold_sha=$(source_sha256 "$SCAFFOLD_REPORT_FILE")
fleet_sha=$(source_sha256 "$FLEET_SIZING_FILE")
provisioning_sha=$(source_sha256 "$PROVISIONING_REPORT_FILE")

make_report() {
  local status=${1:?usage: make_report <status>}
  local blockers_json warnings_json actions_json applied_json safe_to_apply
  local apply_requested_json dry_run_json write_profile_json write_state_json
  blockers_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$blockers_file")
  warnings_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$warnings_file")
  actions_json=$(jq -s '.' "$actions_file")
  applied_json=$(jq -s '.' "$applied_file")
  if [[ "$(jq -r 'length' <<< "$blockers_json")" -eq 0 ]]; then
    safe_to_apply=true
  else
    safe_to_apply=false
  fi
  [[ "$APPLY" -eq 1 ]] && apply_requested_json=true || apply_requested_json=false
  if dry_run_enabled; then dry_run_json=true; else dry_run_json=false; fi
  [[ "$WRITE_PROFILE" -eq 1 ]] && write_profile_json=true || write_profile_json=false
  [[ "$WRITE_STATE" -eq 1 ]] && write_state_json=true || write_state_json=false

  jq -n \
    --arg status "$status" \
    --arg mode "$mode" \
    --arg repo_mode "$REPO_MODE" \
    --arg host_step "$host_step" \
    --arg repository_step "$repository_step" \
    --arg bootstrap_step "$bootstrap_step" \
    --arg scaffold_step "$scaffold_step" \
    --arg fleet_step "$fleet_step" \
    --arg provisioning_step "$provisioning_step" \
    --arg host_sha "$host_sha" \
    --arg repository_sha "$repository_sha" \
    --arg bootstrap_sha "$bootstrap_sha" \
    --arg scaffold_sha "$scaffold_sha" \
    --arg fleet_sha "$fleet_sha" \
    --arg provisioning_sha "$provisioning_sha" \
    --argjson host "$host_json" \
    --argjson repository "$repository_json" \
    --argjson bootstrap "$bootstrap_json" \
    --argjson scaffold "$scaffold_json" \
    --argjson fleet "$fleet_json" \
    --argjson provisioning "$provisioning_json" \
    --argjson apply_requested "$apply_requested_json" \
    --argjson dry_run "$dry_run_json" \
    --argjson write_profile "$write_profile_json" \
    --argjson write_state "$write_state_json" \
    --argjson safe_to_apply "$safe_to_apply" \
    --argjson blockers "$blockers_json" \
    --argjson warnings "$warnings_json" \
    --argjson actions "$actions_json" \
    --argjson applied "$applied_json" \
    '
      def source_report($report; $sha; $summary):
        {
          provided:($sha != ""),
          sha256:(if $sha == "" then null else $sha end),
          schema_version:($report.schema_version // null),
          status:($summary.status // null),
          blockers:($summary.blockers // []),
          warnings:($summary.warnings // [])
        };
      def count_status($rows; $status):
        ($rows // []) | map(select(.status == $status)) | length;
      def source_reports:
        {
          host_assessment:source_report($host; $host_sha; {
            status:($host.environment_recommendation.suitability // null),
            blockers:($host.environment_recommendation.bottlenecks // []),
            warnings:[]
          }),
          repository_readiness:source_report($repository; $repository_sha; {
            status:($repository.status // null),
            blockers:($repository.blockers // []),
            warnings:[]
          }),
          repository_bootstrap:source_report($bootstrap; $bootstrap_sha; {
            status:($bootstrap.status // null),
            blockers:($bootstrap.blockers // []),
            warnings:[]
          }),
          project_scaffold:source_report($scaffold; $scaffold_sha; {
            status:($scaffold.status // null),
            blockers:(($scaffold.blockers // []) + ($scaffold.apply_blockers // [])),
            warnings:[]
          }),
          fleet_sizing:source_report($fleet; $fleet_sha; {
            status:($fleet.recommendation.decision // null),
            blockers:($fleet.recommendation.blockers // []),
            warnings:($fleet.recommendation.warnings // [])
          }),
          fleet_provisioning:source_report($provisioning; $provisioning_sha; {
            status:($provisioning.status // null),
            blockers:($provisioning.blockers // []),
            warnings:($provisioning.warnings // [])
          })
        };
      def neutral_agents:
        ($provisioning.generated_profile.agents // [])
        | to_entries
        | map({
            index:(.value.index // (.key + 1)),
            role:(.value.role // "unspecified")
          });
      def flow_steps:
        [
          {
            id:"choose_repository_mode",
            contract:"operator_choice",
            status:(if ($repo_mode == "existing" or $repo_mode == "greenfield") then "ready" else "missing" end),
            prompt:"Select whether onboarding starts from an existing repository or a greenfield repository.",
            reconfigure:"rerun with --repo-mode existing or --repo-mode greenfield"
          },
          {
            id:"assess_host",
            contract:"ordo.host_assessment.v1",
            status:$host_step,
            prompt:"Review host capacity and environment recommendation before sizing the fleet.",
            reconfigure:"regenerate with scripts/host_assessment.sh --requested-agents <count> --json"
          },
          {
            id:"verify_repository_platform",
            contract:"repository_platform_readiness",
            status:$repository_step,
            prompt:"Confirm repository access, identity binding, issue workflow, and CI visibility.",
            reconfigure:"regenerate with scripts/repository_platform_readiness.sh <project-config> --json"
          },
          {
            id:"bootstrap_repository",
            contract:"repository_bootstrap",
            status:$bootstrap_step,
            prompt:"Plan or apply repository bootstrap evidence before provisioning agents.",
            reconfigure:"regenerate with scripts/repository_bootstrap.sh <project-config> --json"
          },
          {
            id:"scaffold_project",
            contract:"project_scaffold",
            status:$scaffold_step,
            prompt:"Confirm the neutral project scaffold report and remaining engineering decisions.",
            reconfigure:"regenerate with scripts/project_scaffold.sh <project-config> --json"
          },
          {
            id:"size_fleet",
            contract:"ordo.fleet_sizing.v1",
            status:$fleet_step,
            prompt:"Review the fleet size, resize guidance, identity requirements, and rerun recommendation.",
            reconfigure:"regenerate with scripts/fleet_sizing.sh <project-config> --host-report <host-report> --repository-report <repository-report> --provider-report <capability-report> --json"
          },
          {
            id:"generate_fleet_profile",
            contract:"ordo.fleet_provisioning.v1",
            status:$provisioning_step,
            prompt:"Review generated fleet profile, workdir expectations, and verification input.",
            reconfigure:"regenerate with scripts/fleet_provisioning.sh --fleet-sizing <fleet-sizing-report> --repository-bootstrap <bootstrap-report> --json"
          },
          {
            id:"persist_onboarding_profile_state",
            contract:"ordo.guided_onboarding_profile.v1",
            status:(if $status == "applied" then "ready" elif $safe_to_apply then "pending_apply" else "blocked" end),
            prompt:"Persist the redaction-safe onboarding profile and state after reviewing the preview.",
            reconfigure:"rerun guided_onboarding.sh with --apply plus explicit write flags"
          },
          {
            id:"verify_or_rerun",
            contract:"ordo.onboarding_verification.input.v1",
            status:(if $safe_to_apply then "ready_for_verification" else "blocked" end),
            prompt:"Use the verification input to run downstream onboarding verification or rerun after reconfiguration.",
            reconfigure:"rerun upstream reports, then rerun guided_onboarding.sh"
          }
        ];
      source_reports as $sources
      | flow_steps as $steps
      | {
          schema_version:"ordo.guided_onboarding.v1",
          status:$status,
          mode:$mode,
          apply_requested:$apply_requested,
          dry_run:$dry_run,
          safe_to_apply:$safe_to_apply,
          write_requests:{
            profile:$write_profile,
            state:$write_state
          },
          repository_mode:(if $repo_mode == "" then null else $repo_mode end),
          flow:{
            description:"guided_onboarding_preview_then_explicit_persist",
            steps:$steps,
            next_step:(($steps | map(select(.status != "ready" and .status != "ready_for_verification")) | .[0].id) // null)
          },
          inputs:{
            source_reports:$sources,
            summaries:{
              host:{
                suitability:($host.environment_recommendation.suitability // null),
                decision:($host.environment_recommendation.decision // null),
                estimated_agents:($host.capacity.estimated_agents // null)
              },
              repository_readiness:{
                status:($repository.status // null),
                capability_keys:(($repository.capabilities // {}) | keys),
                identity_bindings:{
                  bound:count_status($repository.identity_bindings; "bound"),
                  unresolved:count_status($repository.identity_bindings; "unresolved")
                }
              },
              repository_bootstrap:{
                status:($bootstrap.status // null),
                mode:($bootstrap.mode // null),
                repository_case:($bootstrap.repository_case // null),
                safe_to_apply:($bootstrap.safe_to_apply // null)
              },
              project_scaffold:{
                status:($scaffold.status // null),
                mode:($scaffold.mode // null),
                selected_archetype:($scaffold.selected_archetype // null),
                repository_contract_mode:($scaffold.repository_contract.mode // null),
                decisions_required_count:(($scaffold.decisions_required // []) | length)
              },
              fleet_sizing:{
                decision:($fleet.recommendation.decision // null),
                recommended_agents:($fleet.recommendation.recommended_agents // null),
                role_mix:($fleet.recommendation.role_mix // []),
                resize:($fleet.recommendation.resize // null),
                rerun:($fleet.recommendation.rerun // null)
              },
              fleet_provisioning:{
                status:($provisioning.status // null),
                mode:($provisioning.mode // null),
                safe_to_apply:($provisioning.safe_to_apply // null),
                generated_agent_count:(($provisioning.generated_profile.agents // []) | length),
                terminal_adapter:{
                  requested:($provisioning.verification_input.terminal_adapter.requested // false),
                  actions_applied:($provisioning.verification_input.terminal_adapter.actions_applied // false)
                }
              }
            }
          },
          onboarding_profile:{
            schema_version:"ordo.guided_onboarding_profile.v1",
            repository_mode:(if $repo_mode == "" then null else $repo_mode end),
            source_reports:$sources,
            operator_choices:{
              selected_archetype:($scaffold.selected_archetype // null),
              repository_contract_mode:($scaffold.repository_contract.mode // null),
              requested_agent_count:($fleet.provisioning.requested_agent_count // $fleet.recommendation.recommended_agents // null),
              recommended_agent_count:($fleet.recommendation.recommended_agents // null),
              role_mix:($fleet.recommendation.role_mix // [])
            },
            generated_fleet:{
              schema_version:($provisioning.generated_profile.schema_version // null),
              agent_count:(($provisioning.generated_profile.agents // []) | length),
              agents:neutral_agents,
              source_decision:($fleet.recommendation.decision // null)
            },
            verification_input:{
              schema_version:"ordo.onboarding_verification.input.v1",
              expected_agent_count:(($provisioning.generated_profile.agents // []) | length),
              agent_roles:neutral_agents,
              source_report_sha256:{
                host_assessment:(if $host_sha == "" then null else $host_sha end),
                repository_readiness:(if $repository_sha == "" then null else $repository_sha end),
                repository_bootstrap:(if $bootstrap_sha == "" then null else $bootstrap_sha end),
                project_scaffold:(if $scaffold_sha == "" then null else $scaffold_sha end),
                fleet_sizing:(if $fleet_sha == "" then null else $fleet_sha end),
                fleet_provisioning:(if $provisioning_sha == "" then null else $provisioning_sha end)
              },
              terminal_adapter:{
                requested:($provisioning.verification_input.terminal_adapter.requested // false),
                actions_applied:($provisioning.verification_input.terminal_adapter.actions_applied // false)
              }
            }
          },
          onboarding_state:{
            schema_version:"ordo.guided_onboarding_state.v1",
            status:$status,
            mode:$mode,
            safe_to_apply:$safe_to_apply,
            blockers:$blockers,
            warnings:$warnings,
            steps:$steps,
            last_profile:{
              schema_version:"ordo.guided_onboarding_profile.v1",
              agent_count:(($provisioning.generated_profile.agents // []) | length),
              repository_mode:(if $repo_mode == "" then null else $repo_mode end),
              source_report_sha256:{
                host_assessment:(if $host_sha == "" then null else $host_sha end),
                repository_readiness:(if $repository_sha == "" then null else $repository_sha end),
                repository_bootstrap:(if $bootstrap_sha == "" then null else $bootstrap_sha end),
                project_scaffold:(if $scaffold_sha == "" then null else $scaffold_sha end),
                fleet_sizing:(if $fleet_sha == "" then null else $fleet_sha end),
                fleet_provisioning:(if $provisioning_sha == "" then null else $provisioning_sha end)
              }
            },
            rerun:{
              required_inputs:[
                "repo-mode",
                "host-report",
                "repository-report",
                "bootstrap-report",
                "scaffold-report",
                "fleet-sizing",
                "provisioning-report"
              ],
              blocked_reasons:$blockers,
              reconfiguration_path:($steps | map({step:.id, status:.status, action:.reconfigure}))
            }
          },
          actions:$actions,
          applied:$applied,
          blockers:$blockers,
          warnings:$warnings
        }'
}

blocker_count=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique | length' "$blockers_file")
if [[ "$mode" != "apply" ]]; then
  if [[ "$blocker_count" -gt 0 ]]; then
    report=$(make_report "blocked")
  else
    report=$(make_report "$mode")
  fi
  if [[ "$FORMAT" == "json" ]]; then
    jq . <<< "$report"
  else
    jq -r '
      "Guided onboarding: " + .status,
      "Mode: " + .mode,
      "Next step: " + (.flow.next_step // "verification"),
      "Blockers: " + (if (.blockers | length) == 0 then "none" else (.blockers | join(",")) end),
      (.flow.steps[] | "- " + .id + ": " + .status + " - " + .prompt)
    ' <<< "$report"
  fi
  exit 0
fi

if [[ "$blocker_count" -gt 0 ]]; then
  report=$(make_report "blocked")
  if [[ "$FORMAT" == "json" ]]; then
    jq . <<< "$report"
  else
    jq -r '"Guided onboarding: blocked", "Blockers: " + (.blockers | join(","))' <<< "$report"
  fi
  exit "$ORDO_GUIDED_ONBOARDING_REFUSAL_EXIT_CODE"
fi

if [[ "$WRITE_PROFILE" -eq 1 ]]; then
  mkdir -p "$(dirname "$PROFILE_OUTPUT")"
  make_report "applied" | jq '.onboarding_profile' > "$PROFILE_OUTPUT"
  add_applied "write_onboarding_profile" "applied" "profile_output"
fi

if [[ "$WRITE_STATE" -eq 1 ]]; then
  mkdir -p "$(dirname "$STATE_OUTPUT")"
  make_report "applied" | jq '.onboarding_state' > "$STATE_OUTPUT"
  add_applied "write_onboarding_state" "applied" "state_output"
fi

report=$(make_report "applied")
if [[ "$FORMAT" == "json" ]]; then
  jq . <<< "$report"
else
  jq -r '
    "Guided onboarding: " + .status,
    "Mode: " + .mode,
    "Next step: " + (.flow.next_step // "verification"),
    "Blockers: " + (if (.blockers | length) == 0 then "none" else (.blockers | join(",")) end)
  ' <<< "$report"
fi
