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
      terminal_multiplexer:{
        required:false,
        topology_required:false
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
        repository_platform:["identity_binding"],
        provider_cli:["agent_execution"],
        terminal_multiplexer_required:false
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
    --profile-output "$TEST_TMP/provisioned/profile.sh" \
    --state-output "$TEST_TMP/provisioned/state.json" \
    --json
)
provisioning_file=$(write_json provisioning "$provisioning_json")

profile_output="$TEST_TMP/persist/onboarding-profile.json"
state_output="$TEST_TMP/persist/onboarding-state.json"

plan_json=$(
  bash "$ROOT/scripts/guided_onboarding.sh" \
    --repo-mode existing \
    --host-report "$host_file" \
    --repository-report "$repository_file" \
    --bootstrap-report "$bootstrap_file" \
    --scaffold-report "$scaffold_file" \
    --fleet-sizing "$fleet_file" \
    --provisioning-report "$provisioning_file" \
    --profile-output "$profile_output" \
    --state-output "$state_output" \
    --json
)

jq -e '
  .schema_version == "ordo.guided_onboarding.v1"
  and .status == "plan"
  and .mode == "plan"
  and .safe_to_apply == true
  and .flow.next_step == "persist_onboarding_profile_state"
  and (.flow.steps | map(select(.id == "generate_fleet_profile" and .status == "ready")) | length == 1)
  and .onboarding_profile.schema_version == "ordo.guided_onboarding_profile.v1"
  and .onboarding_profile.generated_fleet.agent_count == 2
  and (.onboarding_profile.generated_fleet.agents | all((has("label") | not) and (has("workdir") | not)))
  and .onboarding_profile.verification_input.schema_version == "ordo.onboarding_verification.input.v1"
  and .onboarding_profile.verification_input.expected_agent_count == 2
  and .inputs.summaries.repository_readiness.identity_bindings.bound == 2
  and .inputs.summaries.fleet_provisioning.terminal_adapter.requested == false
  and (.actions | map(select(.name == "invoke_terminal_adapter" and .enabled == false)) | length == 1)
' <<< "$plan_json" >/dev/null \
  || fail "plan should assemble guided onboarding without mutation: $plan_json"
assert_redacted "plan report" "$plan_json"
[[ ! -e "$profile_output" ]] || fail "plan must not write onboarding profile"
[[ ! -e "$state_output" ]] || fail "plan must not write onboarding state"

dry_json=$(
  bash "$ROOT/scripts/guided_onboarding.sh" \
    --repo-mode existing \
    --host-report "$host_file" \
    --repository-report "$repository_file" \
    --bootstrap-report "$bootstrap_file" \
    --scaffold-report "$scaffold_file" \
    --fleet-sizing "$fleet_file" \
    --provisioning-report "$provisioning_file" \
    --profile-output "$profile_output" \
    --state-output "$state_output" \
    --write-profile \
    --write-state \
    --apply \
    --dry-run \
    --json
)
jq -e '.status == "dry-run" and .mode == "dry-run" and .safe_to_apply == true' \
  <<< "$dry_json" >/dev/null \
  || fail "dry-run apply should preview persistent writes: $dry_json"
[[ ! -e "$profile_output" ]] || fail "dry-run must not write onboarding profile"
[[ ! -e "$state_output" ]] || fail "dry-run must not write onboarding state"

apply_json=$(
  bash "$ROOT/scripts/guided_onboarding.sh" \
    --repo-mode existing \
    --host-report "$host_file" \
    --repository-report "$repository_file" \
    --bootstrap-report "$bootstrap_file" \
    --scaffold-report "$scaffold_file" \
    --fleet-sizing "$fleet_file" \
    --provisioning-report "$provisioning_file" \
    --profile-output "$profile_output" \
    --state-output "$state_output" \
    --write-profile \
    --write-state \
    --apply \
    --json
)

jq -e '
  .status == "applied"
  and .mode == "apply"
  and .flow.next_step == null
  and (.applied | map(select(.name == "write_onboarding_profile" and .status == "applied")) | length == 1)
  and (.applied | map(select(.name == "write_onboarding_state" and .status == "applied")) | length == 1)
' <<< "$apply_json" >/dev/null \
  || fail "apply should write requested onboarding profile and state: $apply_json"
[[ -s "$profile_output" ]] || fail "apply should write onboarding profile"
[[ -s "$state_output" ]] || fail "apply should write onboarding state"
jq -e '.schema_version == "ordo.guided_onboarding_profile.v1" and .generated_fleet.agent_count == 2' \
  "$profile_output" >/dev/null \
  || fail "written onboarding profile should be structured"
jq -e '.schema_version == "ordo.guided_onboarding_state.v1" and .status == "applied"' \
  "$state_output" >/dev/null \
  || fail "written onboarding state should be structured"
assert_redacted "written profile" "$(cat "$profile_output")"
assert_redacted "written state" "$(cat "$state_output")"

blocked_state="$TEST_TMP/blocked/state.json"
set +e
blocked_json=$(
  bash "$ROOT/scripts/guided_onboarding.sh" \
    --repo-mode greenfield \
    --host-report "$host_file" \
    --repository-report "$repository_file" \
    --profile-output "$TEST_TMP/blocked/profile.json" \
    --state-output "$blocked_state" \
    --write-profile \
    --write-state \
    --apply \
    --json
)
blocked_status=$?
set -e
[[ "$blocked_status" -eq 78 ]] \
  || fail "apply must refuse missing upstream evidence, got $blocked_status: $blocked_json"
jq -e '
  .status == "blocked"
  and (.blockers | index("repository_bootstrap_report_missing"))
  and (.blockers | index("project_scaffold_report_missing"))
  and (.blockers | index("fleet_sizing_report_missing"))
  and (.blockers | index("fleet_provisioning_report_missing"))
  and (.onboarding_state.rerun.reconfiguration_path | length > 0)
' <<< "$blocked_json" >/dev/null \
  || fail "blocked apply should report missing evidence and reconfiguration path: $blocked_json"
[[ ! -e "$blocked_state" ]] || fail "blocked apply must not write state"

# #252 — multi-project extension: per-project metadata flags surface in
# onboarding_profile.project_metadata and onboarding_profile.runtime_root,
# without breaking the existing single-project flow.
multi_profile_output="$TEST_TMP/multi/onboarding-profile.json"
multi_state_output="$TEST_TMP/multi/onboarding-state.json"
multi_runtime_root="$TEST_TMP/multi/runtime"

multi_json=$(
  bash "$ROOT/scripts/guided_onboarding.sh" \
    --repo-mode existing \
    --host-report "$host_file" \
    --repository-report "$repository_file" \
    --bootstrap-report "$bootstrap_file" \
    --scaffold-report "$scaffold_file" \
    --fleet-sizing "$fleet_file" \
    --provisioning-report "$provisioning_file" \
    --profile-output "$multi_profile_output" \
    --state-output "$multi_state_output" \
    --project-alias project-alpha \
    --default-branch main \
    --validation-mode gxp \
    --operator-class internal \
    --runtime-root "$multi_runtime_root" \
    --agent-label primary \
    --agent-label secondary \
    --write-profile \
    --write-state \
    --apply \
    --json
)

jq -e '
  .status == "applied"
  and .onboarding_profile.project_metadata.alias == "project-alpha"
  and .onboarding_profile.project_metadata.default_branch == "main"
  and .onboarding_profile.project_metadata.validation_mode == "gxp"
  and .onboarding_profile.project_metadata.operator_class == "internal"
  and (.onboarding_profile.project_metadata.agent_labels | sort) == ["primary","secondary"]
  and .onboarding_profile.runtime_root.base != null
  and (.onboarding_profile.runtime_root.subdirs | keys | sort) == ["audit","cache","launch","logs","orchestrator","profiles","repos","state"]
' <<< "$multi_json" >/dev/null \
  || fail "multi-project flags should surface in onboarding_profile.project_metadata and runtime_root: $multi_json"

[[ -s "$multi_profile_output" ]] || fail "multi-project apply should write onboarding profile"
jq -e '
  .project_metadata.alias == "project-alpha"
  and .project_metadata.validation_mode == "gxp"
  and .project_metadata.operator_class == "internal"
  and .runtime_root.subdirs.audit != null
  and .runtime_root.subdirs.orchestrator != null
' "$multi_profile_output" >/dev/null \
  || fail "written multi-project profile should include project_metadata + runtime_root"

# Validation: invalid validation-mode is refused with refusal exit (78).
set +e
invalid_validation=$(
  bash "$ROOT/scripts/guided_onboarding.sh" \
    --repo-mode existing \
    --host-report "$host_file" \
    --repository-report "$repository_file" \
    --bootstrap-report "$bootstrap_file" \
    --scaffold-report "$scaffold_file" \
    --fleet-sizing "$fleet_file" \
    --provisioning-report "$provisioning_file" \
    --profile-output "$TEST_TMP/invalid/profile.json" \
    --state-output "$TEST_TMP/invalid/state.json" \
    --validation-mode unsupported \
    --write-profile \
    --write-state \
    --apply \
    --json
)
invalid_status=$?
set -e
[[ "$invalid_status" -eq 78 ]] \
  || fail "invalid --validation-mode should refuse (exit 78), got $invalid_status: $invalid_validation"
jq -e '.blockers | index("validation_mode_invalid")' <<< "$invalid_validation" >/dev/null \
  || fail "invalid validation-mode should report validation_mode_invalid blocker: $invalid_validation"

# Validation: invalid operator-class is refused with refusal exit (78).
set +e
invalid_operator=$(
  bash "$ROOT/scripts/guided_onboarding.sh" \
    --repo-mode existing \
    --host-report "$host_file" \
    --repository-report "$repository_file" \
    --bootstrap-report "$bootstrap_file" \
    --scaffold-report "$scaffold_file" \
    --fleet-sizing "$fleet_file" \
    --provisioning-report "$provisioning_file" \
    --profile-output "$TEST_TMP/invalid2/profile.json" \
    --state-output "$TEST_TMP/invalid2/state.json" \
    --operator-class robot \
    --write-profile \
    --write-state \
    --apply \
    --json
)
invalid_operator_status=$?
set -e
[[ "$invalid_operator_status" -eq 78 ]] \
  || fail "invalid --operator-class should refuse (exit 78), got $invalid_operator_status: $invalid_operator"
jq -e '.blockers | index("operator_class_invalid")' <<< "$invalid_operator" >/dev/null \
  || fail "invalid operator-class should report operator_class_invalid blocker: $invalid_operator"

printf 'ok - guided onboarding previews, persists redacted profile/state, refuses unsafe inputs, and accepts multi-project metadata (#252)\n'
