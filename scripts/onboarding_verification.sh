#!/usr/bin/env bash
# scripts/onboarding_verification.sh - verify guided ORDO onboarding profile/state.
set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=../lib/dry_run.sh
source "$TK/lib/dry_run.sh"

usage() {
  cat <<'EOF' >&2
usage:
  onboarding_verification.sh --profile FILE --state FILE --provisioning-input FILE
    [--report-output FILE --write-report]
    [--reconfiguration-output FILE --write-reconfiguration]
    [--apply] [--dry-run] [--overwrite] [--json|--text]

Verifies the redaction-safe guided onboarding profile/state against generated
fleet provisioning verification input. By default this runs non-mutating
checks only. Persistent verification reports and reconfiguration artifacts
require --apply plus explicit write flags.
EOF
}

: "${ORDO_ONBOARDING_VERIFICATION_REFUSAL_EXIT_CODE:=78}"

PROFILE_FILE="${ORDO_VERIFY_ONBOARDING_PROFILE:-}"
STATE_FILE="${ORDO_VERIFY_ONBOARDING_STATE:-}"
PROVISIONING_INPUT_FILE="${ORDO_VERIFY_PROVISIONING_INPUT:-}"
REPORT_OUTPUT="${ORDO_VERIFY_REPORT_OUTPUT:-}"
RECONFIGURATION_OUTPUT="${ORDO_VERIFY_RECONFIGURATION_OUTPUT:-}"
FORMAT="json"
APPLY=0
WRITE_REPORT=0
WRITE_RECONFIGURATION=0
OVERWRITE=0
DRY_ARGS=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --profile|--onboarding-profile)
      PROFILE_FILE=${2:?missing value for --profile}
      shift
      ;;
    --profile=*|--onboarding-profile=*) PROFILE_FILE=${1#*=} ;;
    --state|--onboarding-state)
      STATE_FILE=${2:?missing value for --state}
      shift
      ;;
    --state=*|--onboarding-state=*) STATE_FILE=${1#*=} ;;
    --provisioning-input|--provisioning-report)
      PROVISIONING_INPUT_FILE=${2:?missing value for --provisioning-input}
      shift
      ;;
    --provisioning-input=*|--provisioning-report=*) PROVISIONING_INPUT_FILE=${1#*=} ;;
    --report-output)
      REPORT_OUTPUT=${2:?missing value for --report-output}
      shift
      ;;
    --report-output=*) REPORT_OUTPUT=${1#--report-output=} ;;
    --reconfiguration-output)
      RECONFIGURATION_OUTPUT=${2:?missing value for --reconfiguration-output}
      shift
      ;;
    --reconfiguration-output=*) RECONFIGURATION_OUTPUT=${1#--reconfiguration-output=} ;;
    --write-report) WRITE_REPORT=1 ;;
    --write-reconfiguration) WRITE_RECONFIGURATION=1 ;;
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
      printf 'onboarding_verification: unknown arg: %s\n' "$1" >&2
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

checks_file=$(mktemp)
blockers_file=$(mktemp)
warnings_file=$(mktemp)
actions_file=$(mktemp)
applied_file=$(mktemp)
# shellcheck disable=SC2317 # invoked by EXIT trap.
cleanup() {
  rm -f "$checks_file" "$blockers_file" "$warnings_file" "$actions_file" "$applied_file"
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

add_check() {
  local id=${1:?usage: add_check <id> <status> <severity> <detail>}
  local status=${2:?usage: add_check <id> <status> <severity> <detail>}
  local severity=${3:?usage: add_check <id> <status> <severity> <detail>}
  local detail=${4:-}
  jq -nc \
    --arg id "$id" \
    --arg status "$status" \
    --arg severity "$severity" \
    --arg detail "$detail" \
    '{id:$id,status:$status,severity:$severity,detail:$detail}' >> "$checks_file"
  case "$status:$severity" in
    fail:required) add_blocker "$id" ;;
    warn:*) add_warning "$id" ;;
  esac
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

read_json_input() {
  local path=${1-}
  local missing_blocker=${2:?usage: read_json_input <path> <missing-blocker> <invalid-blocker>}
  local invalid_blocker=${3:?usage: read_json_input <path> <missing-blocker> <invalid-blocker>}
  local output

  if [[ -z "$path" ]]; then
    add_check "$missing_blocker" "fail" "required" "input path not supplied"
    printf '{}\n'
    return 0
  fi
  if [[ ! -r "$path" ]]; then
    add_check "$missing_blocker" "fail" "required" "input file is not readable"
    printf '{}\n'
    return 0
  fi
  if output=$(jq -c . "$path" 2>/dev/null); then
    printf '%s\n' "$output"
  else
    add_check "$invalid_blocker" "fail" "required" "input file is not valid JSON"
    printf '{}\n'
  fi
}

normalize_profile() {
  jq -c '
    if .schema_version == "ordo.guided_onboarding_profile.v1" then .
    elif .onboarding_profile.schema_version == "ordo.guided_onboarding_profile.v1" then .onboarding_profile
    else .
    end
  ' <<< "$1"
}

normalize_state() {
  jq -c '
    if .schema_version == "ordo.guided_onboarding_state.v1" then .
    elif .onboarding_state.schema_version == "ordo.guided_onboarding_state.v1" then .onboarding_state
    else .
    end
  ' <<< "$1"
}

normalize_provisioning_input() {
  jq -c '
    if .schema_version == "ordo.provisioning_verification.input.v1" then .
    elif .verification_input.schema_version == "ordo.provisioning_verification.input.v1" then .verification_input
    else .
    end
  ' <<< "$1"
}

json_redaction_leaks() {
  jq -c '
    def path_string($p): $p | map(tostring) | join(".");
    def sensitive_key:
      . as $key
      | [
          "repository",
          "active_identity",
          "expected_identity",
          "identity",
          "workdir",
          "target_dir",
          "product_intent",
          "remote_url",
          "profile_output",
          "state_output"
        ] | index($key);
    [
      paths(scalars) as $p
      | {path:path_string($p), key:($p[-1] | tostring), value:getpath($p)}
      | select(
          (.key | sensitive_key)
          or (
            (.value | type) == "string"
            and (
              (.value | test("/(root|home|Users|tmp|var|mnt|Volumes|private)/"))
              or (.value | test("https?://"))
              or (.value | test("([0-9]{1,3}\\.){3}[0-9]{1,3}"))
              or (.value | test("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"))
            )
          )
        )
      | {path:.path}
    ]
  ' <<< "$1"
}

sorted_json() {
  jq -S -c . <<< "$1"
}

role_rows_from_profile_agents() {
  jq -S -c '
    (.generated_fleet.agents // [])
    | map({index:(.index // 0), role:(.role // "unspecified")})
  ' <<< "$1"
}

role_rows_from_profile_verification() {
  jq -S -c '
    (.verification_input.agent_roles // [])
    | map({index:(.index // 0), role:(.role // "unspecified")})
  ' <<< "$1"
}

role_rows_from_provisioning() {
  jq -S -c '
    (.agent_targets // [])
    | to_entries
    | map({index:(.value.index // (.key + 1)), role:(.value.role // "unspecified")})
  ' <<< "$1"
}

PROFILE_RAW=$(read_json_input "$PROFILE_FILE" "profile_missing" "profile_invalid")
STATE_RAW=$(read_json_input "$STATE_FILE" "state_missing" "state_invalid")
PROVISIONING_RAW=$(read_json_input "$PROVISIONING_INPUT_FILE" "provisioning_input_missing" "provisioning_input_invalid")

PROFILE_JSON=$(normalize_profile "$PROFILE_RAW")
STATE_JSON=$(normalize_state "$STATE_RAW")
PROVISIONING_JSON=$(normalize_provisioning_input "$PROVISIONING_RAW")

if jq -e '.schema_version == "ordo.guided_onboarding_profile.v1"' >/dev/null 2>&1 <<< "$PROFILE_JSON"; then
  add_check "profile_schema" "pass" "required" "guided onboarding profile schema recognized"
else
  add_check "profile_schema" "fail" "required" "expected ordo.guided_onboarding_profile.v1"
fi

if jq -e '.schema_version == "ordo.guided_onboarding_state.v1"' >/dev/null 2>&1 <<< "$STATE_JSON"; then
  add_check "state_schema" "pass" "required" "guided onboarding state schema recognized"
else
  add_check "state_schema" "fail" "required" "expected ordo.guided_onboarding_state.v1"
fi

if jq -e '.schema_version == "ordo.provisioning_verification.input.v1"' \
  >/dev/null 2>&1 <<< "$PROVISIONING_JSON"; then
  add_check "provisioning_input_schema" "pass" "required" "generated provisioning verification schema recognized"
else
  add_check "provisioning_input_schema" "fail" "required" "expected ordo.provisioning_verification.input.v1"
fi

state_profile_schema=$(jq -r '.last_profile.schema_version // ""' <<< "$STATE_JSON")
profile_repo_mode=$(jq -r '.repository_mode // ""' <<< "$PROFILE_JSON")
state_repo_mode=$(jq -r '.last_profile.repository_mode // ""' <<< "$STATE_JSON")
if [[ "$state_profile_schema" == "ordo.guided_onboarding_profile.v1" && "$profile_repo_mode" == "$state_repo_mode" ]]; then
  add_check "profile_state_identity" "pass" "required" "state references the same profile schema and repository mode"
else
  add_check "profile_state_identity" "fail" "required" "profile/state repository mode or schema mismatch"
fi

profile_count=$(jq -r '.generated_fleet.agent_count // empty' <<< "$PROFILE_JSON")
profile_agent_len=$(jq -r '(.generated_fleet.agents // []) | length' <<< "$PROFILE_JSON")
profile_expected=$(jq -r '.verification_input.expected_agent_count // empty' <<< "$PROFILE_JSON")
state_agent_count=$(jq -r '.last_profile.agent_count // empty' <<< "$STATE_JSON")
provisioning_expected=$(jq -r '.expected_agent_count // empty' <<< "$PROVISIONING_JSON")
provisioning_workdirs=$(jq -r '(.expected_workdirs // []) | length' <<< "$PROVISIONING_JSON")

if [[ "$profile_count" =~ ^[0-9]+$ \
  && "$profile_expected" =~ ^[0-9]+$ \
  && "$state_agent_count" =~ ^[0-9]+$ \
  && "$provisioning_expected" =~ ^[0-9]+$ \
  && "$profile_count" -eq "$profile_agent_len" \
  && "$profile_count" -eq "$profile_expected" \
  && "$profile_count" -eq "$state_agent_count" \
  && "$profile_count" -eq "$provisioning_expected" ]]; then
  add_check "agent_count_consistency" "pass" "required" "agent counts match profile, state, and provisioning input"
else
  add_check "agent_count_consistency" "fail" "required" "agent counts differ across profile, state, or provisioning input"
fi

if [[ "$provisioning_workdirs" =~ ^[0-9]+$ && "$profile_count" =~ ^[0-9]+$ \
  && "$provisioning_workdirs" -eq "$profile_count" ]]; then
  add_check "provisioning_target_count" "pass" "required" "provisioning target inventory count matches generated fleet"
else
  add_check "provisioning_target_count" "fail" "required" "provisioning target inventory count mismatch"
fi

profile_roles=$(role_rows_from_profile_agents "$PROFILE_JSON")
profile_verification_roles=$(role_rows_from_profile_verification "$PROFILE_JSON")
provisioning_roles=$(role_rows_from_provisioning "$PROVISIONING_JSON")
if [[ "$(sorted_json "$profile_roles")" == "$(sorted_json "$profile_verification_roles")" \
  && "$(sorted_json "$profile_roles")" == "$(sorted_json "$provisioning_roles")" ]]; then
  add_check "agent_role_consistency" "pass" "required" "agent roles match profile verification and provisioning input"
else
  add_check "agent_role_consistency" "fail" "required" "agent roles differ across profile or provisioning input"
fi

profile_agent_shape=$(jq -e '
  (.generated_fleet.agents // [])
  | all((keys_unsorted | sort) == ["index","role"])
' >/dev/null 2>&1 <<< "$PROFILE_JSON"; printf '%s' "$?")
if [[ "$profile_agent_shape" == "0" ]]; then
  add_check "profile_agent_inventory_redacted" "pass" "required" "profile agent inventory contains only neutral index and role"
else
  add_check "profile_agent_inventory_redacted" "fail" "required" "profile agent inventory exposes non-neutral target fields"
fi

profile_hashes=$(jq -S -c '.verification_input.source_report_sha256 // {}' <<< "$PROFILE_JSON")
state_hashes=$(jq -S -c '.last_profile.source_report_sha256 // {}' <<< "$STATE_JSON")
if [[ "$profile_hashes" == "$state_hashes" ]] && jq -e '
  . as $hashes
  | [
      "host_assessment",
      "repository_readiness",
      "repository_bootstrap",
      "project_scaffold",
      "fleet_sizing",
      "fleet_provisioning"
    ] as $required
  | all($required[]; ($hashes[.] | type == "string") and ($hashes[.] | test("^[A-Fa-f0-9]{64}$")))
' >/dev/null 2>&1 <<< "$profile_hashes"; then
  add_check "source_report_hash_consistency" "pass" "required" "profile and state source report hashes match"
else
  add_check "source_report_hash_consistency" "fail" "required" "profile/state source report hashes are missing or inconsistent"
fi

profile_leaks=$(json_redaction_leaks "$PROFILE_JSON")
state_leaks=$(json_redaction_leaks "$STATE_JSON")
if [[ "$(jq -r 'length' <<< "$profile_leaks")" -eq 0 ]]; then
  add_check "profile_redaction" "pass" "required" "profile contains no raw target, identity, URL, IP, email, or absolute-path values"
else
  add_check "profile_redaction" "fail" "required" "profile contains redaction leaks at $(jq -r 'map(.path) | join(",")' <<< "$profile_leaks")"
fi
if [[ "$(jq -r 'length' <<< "$state_leaks")" -eq 0 ]]; then
  add_check "state_redaction" "pass" "required" "state contains no raw target, identity, URL, IP, email, or absolute-path values"
else
  add_check "state_redaction" "fail" "required" "state contains redaction leaks at $(jq -r 'map(.path) | join(",")' <<< "$state_leaks")"
fi

if jq -e '
  (.rerun.required_inputs // []) as $inputs
  | ["repo-mode","host-report","repository-report","bootstrap-report","scaffold-report","fleet-sizing","provisioning-report"] as $required
  | all($required[]; $inputs | index(.))
' >/dev/null 2>&1 <<< "$STATE_JSON"; then
  add_check "rerun_inputs_complete" "pass" "required" "state includes all rerun inputs required for reconfiguration"
else
  add_check "rerun_inputs_complete" "fail" "required" "state rerun inputs are incomplete"
fi

if jq -e '
  (.rerun.reconfiguration_path // []) as $path
  | ($path | length) > 0
  and all($path[]; ((.step // "") | length) > 0 and ((.action // "") | length) > 0)
' >/dev/null 2>&1 <<< "$STATE_JSON"; then
  add_check "reconfiguration_guidance_actionable" "pass" "required" "state includes actionable reconfiguration guidance"
else
  add_check "reconfiguration_guidance_actionable" "fail" "required" "state reconfiguration guidance is missing or not actionable"
fi

if jq -e '
  (.terminal_adapter.actions_applied // false) == false
' >/dev/null 2>&1 <<< "$PROVISIONING_JSON"; then
  add_check "terminal_adapter_not_started_by_verification" "pass" "required" "verification consumes terminal adapter status without starting anything"
else
  add_check "terminal_adapter_not_started_by_verification" "warn" "advisory" "terminal adapter actions were already marked applied in provisioning evidence"
fi

if [[ "$WRITE_REPORT" -eq 1 && -z "$REPORT_OUTPUT" ]]; then
  add_check "report_output_missing" "fail" "required" "--write-report requires --report-output"
fi
if [[ "$WRITE_RECONFIGURATION" -eq 1 && -z "$RECONFIGURATION_OUTPUT" ]]; then
  add_check "reconfiguration_output_missing" "fail" "required" "--write-reconfiguration requires --reconfiguration-output"
fi
if [[ "$mode" == "apply" && "$WRITE_REPORT" -eq 1 && "$OVERWRITE" -ne 1 && -e "$REPORT_OUTPUT" ]]; then
  add_check "report_output_exists" "fail" "required" "report output already exists"
fi
if [[ "$mode" == "apply" && "$WRITE_RECONFIGURATION" -eq 1 && "$OVERWRITE" -ne 1 && -e "$RECONFIGURATION_OUTPUT" ]]; then
  add_check "reconfiguration_output_exists" "fail" "required" "reconfiguration output already exists"
fi
if [[ "$mode" == "apply" && "$WRITE_REPORT" -eq 0 && "$WRITE_RECONFIGURATION" -eq 0 ]]; then
  add_warning "apply_requested_without_persistent_outputs"
fi

add_action "run_verification_smokes" "false" "true" "validate profile, state, provisioning input, hashes, roles, redaction, and rerun guidance"
add_action "write_verification_report" "true" \
  "$([[ "$mode" == "apply" && "$WRITE_REPORT" -eq 1 ]] && printf true || printf false)" \
  "persist verification report only when explicitly requested"
add_action "write_reconfiguration_artifact" "true" \
  "$([[ "$mode" == "apply" && "$WRITE_RECONFIGURATION" -eq 1 ]] && printf true || printf false)" \
  "persist reconfiguration/rerun artifact only when explicitly requested"
add_action "start_agents_or_terminal_targets" "true" "false" "verification never starts agents or terminal targets"
add_action "provision_workdirs" "true" "false" "verification never provisions workdirs"

make_report() {
  local status=${1:?usage: make_report <status>}
  local blockers_json warnings_json checks_json actions_json applied_json safe_to_apply
  local apply_requested_json dry_run_json write_report_json write_reconfiguration_json
  blockers_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$blockers_file")
  warnings_json=$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$warnings_file")
  checks_json=$(jq -s '.' "$checks_file")
  actions_json=$(jq -s '.' "$actions_file")
  applied_json=$(jq -s '.' "$applied_file")
  if [[ "$(jq -r 'length' <<< "$blockers_json")" -eq 0 ]]; then
    safe_to_apply=true
  else
    safe_to_apply=false
  fi
  [[ "$APPLY" -eq 1 ]] && apply_requested_json=true || apply_requested_json=false
  if dry_run_enabled; then dry_run_json=true; else dry_run_json=false; fi
  [[ "$WRITE_REPORT" -eq 1 ]] && write_report_json=true || write_report_json=false
  [[ "$WRITE_RECONFIGURATION" -eq 1 ]] && write_reconfiguration_json=true || write_reconfiguration_json=false

  jq -n \
    --arg status "$status" \
    --arg mode "$mode" \
    --argjson profile "$PROFILE_JSON" \
    --argjson state "$STATE_JSON" \
    --argjson provisioning "$PROVISIONING_JSON" \
    --argjson checks "$checks_json" \
    --argjson blockers "$blockers_json" \
    --argjson warnings "$warnings_json" \
    --argjson actions "$actions_json" \
    --argjson applied "$applied_json" \
    --argjson safe_to_apply "$safe_to_apply" \
    --argjson apply_requested "$apply_requested_json" \
    --argjson dry_run "$dry_run_json" \
    --argjson write_report "$write_report_json" \
    --argjson write_reconfiguration "$write_reconfiguration_json" \
    '{
      schema_version:"ordo.onboarding_verification.v1",
      status:$status,
      mode:$mode,
      apply_requested:$apply_requested,
      dry_run:$dry_run,
      safe_to_apply:$safe_to_apply,
      write_requests:{
        report:$write_report,
        reconfiguration:$write_reconfiguration
      },
      readiness_summary:{
        result:(if ($blockers | length) == 0 then "ready" else "blocked" end),
        expected_agent_count:($profile.verification_input.expected_agent_count // null),
        generated_agent_count:($profile.generated_fleet.agent_count // null),
        provisioning_expected_agent_count:($provisioning.expected_agent_count // null),
        roles:($profile.generated_fleet.agents // []),
        source_report_hash_count:(($profile.verification_input.source_report_sha256 // {}) | to_entries | map(select(.value != null)) | length),
        rerun_input_count:(($state.rerun.required_inputs // []) | length),
        reconfiguration_step_count:(($state.rerun.reconfiguration_path // []) | length),
        terminal_adapter:{
          requested:($profile.verification_input.terminal_adapter.requested // $provisioning.terminal_adapter.requested // false),
          actions_applied:($profile.verification_input.terminal_adapter.actions_applied // $provisioning.terminal_adapter.actions_applied // false)
        }
      },
      verification_smokes:$checks,
      reconfiguration_artifact:{
        schema_version:"ordo.onboarding_reconfiguration.v1",
        status:(if ($blockers | length) == 0 then "ready" else "blocked" end),
        required_inputs:($state.rerun.required_inputs // []),
        blocked_reasons:$blockers,
        source_report_sha256:($profile.verification_input.source_report_sha256 // {}),
        current_fleet:{
          agent_count:($profile.generated_fleet.agent_count // null),
          agents:($profile.generated_fleet.agents // [])
        },
        reconfiguration_path:($state.rerun.reconfiguration_path // []),
        rerun_policy:{
          preview_first:true,
          persistent_outputs_require_apply:true,
          no_agent_start:true,
          no_workdir_provisioning:true,
          no_terminal_target_creation:true
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
    report=$(make_report "passed")
  fi
  if [[ "$FORMAT" == "json" ]]; then
    jq . <<< "$report"
  else
    jq -r '
      "Onboarding verification: " + .status,
      "Mode: " + .mode,
      "Agents: " + (.readiness_summary.expected_agent_count // 0 | tostring),
      "Blockers: " + (if (.blockers | length) == 0 then "none" else (.blockers | join(",")) end),
      (.verification_smokes[] | "- " + .id + ": " + .status)
    ' <<< "$report"
  fi
  exit 0
fi

if [[ "$blocker_count" -gt 0 ]]; then
  report=$(make_report "blocked")
  if [[ "$FORMAT" == "json" ]]; then
    jq . <<< "$report"
  else
    jq -r '"Onboarding verification: blocked", "Blockers: " + (.blockers | join(","))' <<< "$report"
  fi
  exit "$ORDO_ONBOARDING_VERIFICATION_REFUSAL_EXIT_CODE"
fi

if [[ "$WRITE_REPORT" -eq 1 ]]; then
  mkdir -p "$(dirname "$REPORT_OUTPUT")"
  make_report "passed" > "$REPORT_OUTPUT"
  add_applied "write_verification_report" "applied" "report_output"
fi

if [[ "$WRITE_RECONFIGURATION" -eq 1 ]]; then
  mkdir -p "$(dirname "$RECONFIGURATION_OUTPUT")"
  make_report "passed" | jq '.reconfiguration_artifact' > "$RECONFIGURATION_OUTPUT"
  add_applied "write_reconfiguration_artifact" "applied" "reconfiguration_output"
fi

report=$(make_report "passed")
if [[ "$FORMAT" == "json" ]]; then
  jq . <<< "$report"
else
  jq -r '
    "Onboarding verification: " + .status,
    "Mode: " + .mode,
    "Agents: " + (.readiness_summary.expected_agent_count // 0 | tostring),
    "Blockers: " + (if (.blockers | length) == 0 then "none" else (.blockers | join(",")) end)
  ' <<< "$report"
fi
