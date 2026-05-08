#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

write_json() {
  local name=${1:?usage: write_json <name> <json>}
  local json=${2:?usage: write_json <name> <json>}
  local path="$TEST_TMP/$name.json"
  printf '%s\n' "$json" > "$path"
  printf '%s\n' "$path"
}

host_report() {
  jq -nc '{
    schema_version:"ordo.host_assessment.v1",
    requested_fleet:{agents:2},
    capacity:{estimated_agents:3},
    capabilities:{
      terminal_adapter:{
        required:false
      }
    },
    environment_recommendation:{
      suitability:"suitable",
      decision:"keep_current_machine",
      bottlenecks:[]
    }
  }'
}

repository_report() {
  jq -nc '{
    status:"ready",
    repository:"sensitive-repository",
    active_identity:"sensitive-identity",
    capabilities:{
      repository_access:{ready:true},
      push_permission:{ready:true},
      ci_status_visibility:{ready:true}
    },
    identity_bindings:[
      {agent:"sensitive-agent-one",identity:"sensitive-identity-one",status:"bound"},
      {agent:"sensitive-agent-two",identity:"sensitive-identity-two",status:"bound"}
    ],
    blockers:[]
  }'
}

bootstrap_report() {
  jq -nc --arg workdir "$TEST_TMP/sensitive-workdir" '{
    status:"ready",
    mode:"apply",
    repository_case:"existing",
    repository:"sensitive-repository",
    workdir:$workdir,
    default_branch:"main",
    safe_to_apply:true,
    blockers:[],
    readiness:{status:"ready"},
    baseline_config:"PROJECT=sensitive-repository\n"
  }'
}

scaffold_report() {
  jq -nc --arg target "$TEST_TMP/sensitive-project" '{
    status:"ready",
    mode:"apply",
    product_intent:"sensitive product intent",
    selected_archetype:"service",
    target_dir:$target,
    repository_contract:{
      mode:"existing",
      readiness_report:"sensitive-readiness-report",
      readiness_status:"ready"
    },
    decisions_required:["Confirm interface contract."],
    blockers:[],
    apply_blockers:[],
    written_files:["README.md"]
  }'
}

fleet_report() {
  jq -nc '{
    schema_version:"ordo.fleet_sizing.v1",
    recommendation:{
      decision:"provision",
      recommended_agents:2,
      role_mix:[
        {role:"implementation",count:1},
        {role:"review",count:1}
      ],
      blockers:[],
      warnings:[],
      resize:{direction:"new",required:false},
      rerun:{recommended:false,reasons:[]}
    },
    provisioning:{
      schema_version:"ordo.provisioning.input.v1",
      requested_agent_count:2,
      role_mix:[
        {role:"implementation",count:1},
        {role:"review",count:1}
      ],
      identity_binding_required:true,
      candidate_identity_bindings:[
        {agent:"sensitive-agent-one",identity:"sensitive-identity-one",status:"bound"},
        {agent:"sensitive-agent-two",identity:"sensitive-identity-two",status:"bound"}
      ],
      required_capabilities:{
        execution_cli:["agent_execution"],
        terminal_adapter_required:false
      }
    }
  }'
}

assert_redacted() {
  local label=${1:?usage: assert_redacted <label> <content>}
  local content=${2:?usage: assert_redacted <label> <content>}
  local forbidden
  for forbidden in \
    "$TEST_TMP" \
    "sensitive-repository" \
    "sensitive-identity" \
    "sensitive-agent" \
    "sensitive product intent" \
    "sensitive-workdir" \
    "sensitive-project"; do
    if grep -Fq "$forbidden" <<< "$content"; then
      fail "$label should redact runtime-sensitive content: found $forbidden"
    fi
  done
}

host_file=$(write_json host "$(host_report)")
repository_file=$(write_json repository "$(repository_report)")
bootstrap_file=$(write_json bootstrap "$(bootstrap_report)")
scaffold_file=$(write_json scaffold "$(scaffold_report)")
fleet_file=$(write_json fleet "$(fleet_report)")

provisioning_json=$(
  bash "$ROOT/scripts/fleet_provisioning.sh" \
    --fleet-sizing "$fleet_file" \
    --repository-bootstrap "$bootstrap_file" \
    --workdir-template "$TEST_TMP/provisioned/%s" \
    --profile-output "$TEST_TMP/provisioned/generated-profile.sh" \
    --state-output "$TEST_TMP/provisioned/generated-state.json" \
    --json
)
provisioning_file=$(write_json provisioning "$provisioning_json")

onboarding_profile="$TEST_TMP/persist/onboarding-profile.json"
onboarding_state="$TEST_TMP/persist/onboarding-state.json"
guided_json=$(
  bash "$ROOT/scripts/guided_onboarding.sh" \
    --repo-mode existing \
    --host-report "$host_file" \
    --repository-report "$repository_file" \
    --bootstrap-report "$bootstrap_file" \
    --scaffold-report "$scaffold_file" \
    --fleet-sizing "$fleet_file" \
    --provisioning-report "$provisioning_file" \
    --profile-output "$onboarding_profile" \
    --state-output "$onboarding_state" \
    --write-profile \
    --write-state \
    --apply \
    --json
)
jq -e '.status == "applied"' <<< "$guided_json" >/dev/null \
  || fail "guided onboarding fixture should persist profile and state: $guided_json"

verification_report="$TEST_TMP/verification/report.json"
reconfiguration_output="$TEST_TMP/verification/reconfiguration.json"

plan_json=$(
  bash "$ROOT/scripts/onboarding_verification.sh" \
    --profile "$onboarding_profile" \
    --state "$onboarding_state" \
    --provisioning-input "$provisioning_file" \
    --report-output "$verification_report" \
    --reconfiguration-output "$reconfiguration_output" \
    --json
)

jq -e '
  .schema_version == "ordo.onboarding_verification.v1"
  and .status == "passed"
  and .mode == "plan"
  and .safe_to_apply == true
  and .readiness_summary.result == "ready"
  and .readiness_summary.expected_agent_count == 2
  and (.verification_smokes | all(.status == "pass"))
  and (.verification_smokes | map(select(.id == "agent_count_consistency" and .status == "pass")) | length == 1)
  and (.verification_smokes | map(select(.id == "agent_role_consistency" and .status == "pass")) | length == 1)
  and (.verification_smokes | map(select(.id == "source_report_hash_consistency" and .status == "pass")) | length == 1)
  and (.verification_smokes | map(select(.id == "profile_redaction" and .status == "pass")) | length == 1)
  and (.verification_smokes | map(select(.id == "state_redaction" and .status == "pass")) | length == 1)
  and .reconfiguration_artifact.rerun_policy.preview_first == true
  and .reconfiguration_artifact.rerun_policy.no_agent_start == true
  and .reconfiguration_artifact.rerun_policy.no_workdir_provisioning == true
  and .reconfiguration_artifact.rerun_policy.no_terminal_target_creation == true
  and (.actions | map(select(.name == "start_agents_or_terminal_targets" and .enabled == false)) | length == 1)
' <<< "$plan_json" >/dev/null \
  || fail "verification plan should pass without mutation: $plan_json"
assert_redacted "verification plan" "$plan_json"
[[ ! -e "$verification_report" ]] || fail "plan must not write verification report"
[[ ! -e "$reconfiguration_output" ]] || fail "plan must not write reconfiguration artifact"

dry_json=$(
  bash "$ROOT/scripts/onboarding_verification.sh" \
    --profile "$onboarding_profile" \
    --state "$onboarding_state" \
    --provisioning-input "$provisioning_file" \
    --report-output "$verification_report" \
    --reconfiguration-output "$reconfiguration_output" \
    --write-report \
    --write-reconfiguration \
    --apply \
    --dry-run \
    --json
)
jq -e '.status == "passed" and .mode == "dry-run" and .safe_to_apply == true' \
  <<< "$dry_json" >/dev/null \
  || fail "dry-run should preview verification writes: $dry_json"
[[ ! -e "$verification_report" ]] || fail "dry-run must not write verification report"
[[ ! -e "$reconfiguration_output" ]] || fail "dry-run must not write reconfiguration artifact"

apply_json=$(
  bash "$ROOT/scripts/onboarding_verification.sh" \
    --profile "$onboarding_profile" \
    --state "$onboarding_state" \
    --provisioning-input "$provisioning_file" \
    --report-output "$verification_report" \
    --reconfiguration-output "$reconfiguration_output" \
    --write-report \
    --write-reconfiguration \
    --apply \
    --json
)
jq -e '
  .status == "passed"
  and .mode == "apply"
  and (.applied | map(select(.name == "write_verification_report" and .status == "applied")) | length == 1)
  and (.applied | map(select(.name == "write_reconfiguration_artifact" and .status == "applied")) | length == 1)
' <<< "$apply_json" >/dev/null \
  || fail "apply should persist requested verification artifacts: $apply_json"
[[ -s "$verification_report" ]] || fail "apply should write verification report"
[[ -s "$reconfiguration_output" ]] || fail "apply should write reconfiguration artifact"
jq -e '.schema_version == "ordo.onboarding_verification.v1" and .status == "passed"' \
  "$verification_report" >/dev/null \
  || fail "written verification report should be structured"
jq -e '.schema_version == "ordo.onboarding_reconfiguration.v1" and .status == "ready"' \
  "$reconfiguration_output" >/dev/null \
  || fail "written reconfiguration artifact should be structured"
assert_redacted "written verification report" "$(cat "$verification_report")"
assert_redacted "written reconfiguration artifact" "$(cat "$reconfiguration_output")"

bad_profile="$TEST_TMP/bad-profile.json"
jq '.generated_fleet.agent_count = 3' "$onboarding_profile" > "$bad_profile"
blocked_report="$TEST_TMP/blocked/report.json"
set +e
blocked_json=$(
  bash "$ROOT/scripts/onboarding_verification.sh" \
    --profile "$bad_profile" \
    --state "$onboarding_state" \
    --provisioning-input "$provisioning_file" \
    --report-output "$blocked_report" \
    --write-report \
    --apply \
    --json
)
blocked_status=$?
set -e
[[ "$blocked_status" -eq 78 ]] \
  || fail "apply should refuse inconsistent profile/state, got $blocked_status: $blocked_json"
jq -e '.status == "blocked" and (.blockers | index("agent_count_consistency"))' \
  <<< "$blocked_json" >/dev/null \
  || fail "blocked verification should explain agent count mismatch: $blocked_json"
[[ ! -e "$blocked_report" ]] || fail "blocked verification must not write report"

leaky_state="$TEST_TMP/leaky-state.json"
jq '.rerun.reconfiguration_path[0].action = "/tmp/raw-target"' "$onboarding_state" > "$leaky_state"
leak_json=$(
  bash "$ROOT/scripts/onboarding_verification.sh" \
    --profile "$onboarding_profile" \
    --state "$leaky_state" \
    --provisioning-input "$provisioning_file" \
    --json
)
jq -e '.status == "blocked" and (.blockers | index("state_redaction"))' \
  <<< "$leak_json" >/dev/null \
  || fail "verification should detect redaction leaks: $leak_json"

printf 'ok - onboarding verification checks profile/state, smokes, redaction, and reconfiguration artifacts\n'
