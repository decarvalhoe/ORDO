#!/usr/bin/env bash
# tests/test_multi_project_onboarding_idempotency.sh — hermetic guard:
# multi_project_onboarding --apply reruns are byte-identical and do not
# churn ORCH_STATE_BASE/ORCH_LOG_DIR (#447, building on #547).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

# Scope ORCH_STATE_BASE / ORCH_LOG_DIR inside TEST_TMP so the rerun guard
# can observe any state/log churn shared libraries might introduce in
# future revisions of the script (#447).
export ORCH_STATE_BASE="$TEST_TMP/orch-state"
export ORCH_LOG_DIR="$TEST_TMP/orch-logs"
mkdir -p "$ORCH_STATE_BASE" "$ORCH_LOG_DIR"

snapshot_tree() {
  local dir=${1:?usage: snapshot_tree <dir>}
  if [[ -d "$dir" ]]; then
    find "$dir" -type f -printf '%P\n' 2>/dev/null | LC_ALL=C sort
  fi
}

write_json() {
  local name=${1:?usage: write_json <name> <json>}
  local json=${2:?usage: write_json <name> <json>}
  local path="$TEST_TMP/$name.json"
  printf '%s\n' "$json" > "$path"
  printf '%s\n' "$path"
}

file_hash() {
  local path=${1:?usage: file_hash <path>}
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

host_report() {
  jq -nc '{
    schema_version:"ordo.host_assessment.v1",
    requested_fleet:{agents:1}, capacity:{estimated_agents:2},
    capabilities:{terminal_multiplexer:{required:false,topology_required:false}},
    environment_recommendation:{suitability:"suitable",
      decision:"keep_current_machine", bottlenecks:[]}
  }'
}

repository_report() {
  jq -nc '{
    status:"ready", repository:"sensitive-repository",
    active_identity:"sensitive-identity",
    capabilities:{repository_access:{ready:true},push_permission:{ready:true},
      ci_status_visibility:{ready:true}},
    identity_bindings:[
      {agent:"sensitive-agent-one",identity:"sensitive-identity-one",status:"bound"}
    ],
    blockers:[]
  }'
}

bootstrap_report() {
  jq -nc --arg workdir "$TEST_TMP/sensitive-workdir" '{
    status:"ready", mode:"apply", repository_case:"existing",
    repository:"sensitive-repository", workdir:$workdir,
    default_branch:"main", safe_to_apply:true,
    blockers:[], readiness:{status:"ready"},
    baseline_config:"PROJECT=sensitive-repository\n"
  }'
}

scaffold_report() {
  jq -nc --arg target "$TEST_TMP/sensitive-project" '{
    status:"ready", mode:"apply",
    product_intent:"sensitive product intent",
    selected_archetype:"service", target_dir:$target,
    repository_contract:{mode:"existing", readiness_report:"sensitive-readiness-report",
      readiness_status:"ready"},
    decisions_required:["Confirm interface contract."],
    blockers:[], apply_blockers:[], written_files:["README.md"]
  }'
}

fleet_report() {
  jq -nc '{
    schema_version:"ordo.fleet_sizing.v1",
    recommendation:{decision:"provision", recommended_agents:1,
      role_mix:[{role:"implementation",count:1}],
      blockers:[], warnings:[],
      resize:{direction:"new",required:false},
      rerun:{recommended:false,reasons:[]}},
    provisioning:{schema_version:"ordo.provisioning.input.v1",
      requested_agent_count:1,
      role_mix:[{role:"implementation",count:1}],
      identity_binding_required:true,
      candidate_identity_bindings:[
        {agent:"sensitive-agent-one",identity:"sensitive-identity-one",status:"bound"}
      ],
      required_capabilities:{repository_platform:["identity_binding"],
        provider_cli:["agent_execution"], terminal_multiplexer_required:false}}
  }'
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
    --profile-output "$TEST_TMP/provisioned/profile.sh" \
    --state-output "$TEST_TMP/provisioned/state.json" \
    --json
)
provisioning_file=$(write_json provisioning "$provisioning_json")

manifest_path="$TEST_TMP/manifest.json"
jq -nc \
  --arg portfolio_alias generic-portfolio \
  --arg host "$host_file" \
  --arg repository "$repository_file" \
  --arg bootstrap "$bootstrap_file" \
  --arg scaffold "$scaffold_file" \
  --arg fleet "$fleet_file" \
  --arg provisioning "$provisioning_file" \
  --arg runtime_alpha "$TEST_TMP/runtime/alpha" \
  '{
    schema_version:"ordo.multi_project_onboarding.manifest.v1",
    portfolio_alias:$portfolio_alias,
    projects:[
      {
        alias:"alpha", default_branch:"main",
        validation_mode:"gxp", operator_class:"internal",
        runtime_root:$runtime_alpha,
        agent_labels:["primary"],
        repo_mode:"existing",
        host_report:$host, repository_report:$repository,
        bootstrap_report:$bootstrap, scaffold_report:$scaffold,
        fleet_sizing:$fleet, provisioning_report:$provisioning
      }
    ]
  }' > "$manifest_path"

profile_dir="$TEST_TMP/profiles"
state_dir="$TEST_TMP/states"
profile_output="$profile_dir/onboarding-profile-alpha.json"
state_output="$state_dir/onboarding-state-alpha.json"
portfolio_output="$profile_dir/portfolio-onboarding-profile.json"

first_output=$(
  bash "$ROOT/scripts/multi_project_onboarding.sh" \
    --manifest "$manifest_path" \
    --profile-dir "$profile_dir" \
    --state-dir "$state_dir" \
    --apply --json
)
jq -e '.status == "applied" and .safe_to_apply == true and .blockers == []' \
  <<< "$first_output" >/dev/null \
  || fail "first apply should persist onboarding artifacts: $first_output"

profile_hash_before=$(file_hash "$profile_output")
state_hash_before=$(file_hash "$state_output")
portfolio_hash_before=$(file_hash "$portfolio_output")
state_base_before=$(snapshot_tree "$ORCH_STATE_BASE")
log_dir_before=$(snapshot_tree "$ORCH_LOG_DIR")

set +e
second_output=$(
  bash "$ROOT/scripts/multi_project_onboarding.sh" \
    --manifest "$manifest_path" \
    --profile-dir "$profile_dir" \
    --state-dir "$state_dir" \
    --apply --json
)
second_status=$?
set -e
[[ "$second_status" -eq 0 ]] \
  || fail "unchanged second apply should be idempotent, got $second_status: $second_output"
jq -e '.status == "applied" and .safe_to_apply == true and .blockers == []' \
  <<< "$second_output" >/dev/null \
  || fail "unchanged second apply should report applied/no blockers: $second_output"
[[ "$(file_hash "$profile_output")" == "$profile_hash_before" ]] \
  || fail "unchanged second apply must not change the per-project profile"
[[ "$(file_hash "$state_output")" == "$state_hash_before" ]] \
  || fail "unchanged second apply must not change the per-project state"
[[ "$(file_hash "$portfolio_output")" == "$portfolio_hash_before" ]] \
  || fail "unchanged second apply must not change the portfolio profile"
[[ "$(snapshot_tree "$ORCH_STATE_BASE")" == "$state_base_before" ]] \
  || fail "unchanged second apply must not add files under ORCH_STATE_BASE"
[[ "$(snapshot_tree "$ORCH_LOG_DIR")" == "$log_dir_before" ]] \
  || fail "unchanged second apply must not add log files under ORCH_LOG_DIR"

jq '.project_metadata.default_branch = "drifted"' \
  "$profile_output" > "$TEST_TMP/drifted-profile.json"
mv "$TEST_TMP/drifted-profile.json" "$profile_output"

set +e
drift_output=$(
  bash "$ROOT/scripts/multi_project_onboarding.sh" \
    --manifest "$manifest_path" \
    --profile-dir "$profile_dir" \
    --state-dir "$state_dir" \
    --apply --json
)
drift_status=$?
set -e
[[ "$drift_status" -eq 78 ]] \
  || fail "divergent existing profile should still refuse, got $drift_status: $drift_output"
jq -e '.status == "blocked" and (.blockers | index("project_alpha::profile_output_exists"))' \
  <<< "$drift_output" >/dev/null \
  || fail "divergent existing profile should preserve the namespaced blocker: $drift_output"

printf 'ok - unchanged multi_project_onboarding --apply reruns are idempotent (no state/log churn) and divergent outputs still block (#447, #547)\n'
