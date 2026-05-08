#!/usr/bin/env bash
# tests/test_multi_project_onboarding.sh — multi-project portfolio
# onboarding extension (#252). Drives scripts/multi_project_onboarding.sh
# against a 2-project manifest and verifies:
#
#   1. Each project's per-run profile carries project_metadata
#      (alias / default_branch / validation_mode / operator_class /
#      agent_labels) and runtime_root with the 8 required subdirs.
#   2. Aggregate portfolio profile lists both projects, retains each
#      per-project blockers under the project_<alias>::<blocker>
#      namespace, and refuses with exit 78 when at least one project's
#      gate fails.
#   3. The single-project canonical schema
#      `ordo.guided_onboarding_profile.v1` is preserved (each per-project
#      onboarding_profile in the portfolio still uses that schema_version).
#   4. Existing onboarding verification tests still pass — covered by
#      tests/test_guided_onboarding.sh + tests/test_onboarding_verification.sh
#      as part of the regular runner.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT
fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

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
    requested_fleet:{agents:2}, capacity:{estimated_agents:3},
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
      {agent:"sensitive-agent-one",identity:"sensitive-identity-one",status:"bound"},
      {agent:"sensitive-agent-two",identity:"sensitive-identity-two",status:"bound"}
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
    recommendation:{decision:"provision", recommended_agents:2,
      role_mix:[{role:"implementation",count:1},{role:"review",count:1}],
      blockers:[], warnings:[],
      resize:{direction:"new",required:false},
      rerun:{recommended:false,reasons:[]}},
    provisioning:{schema_version:"ordo.provisioning.input.v1",
      requested_agent_count:2,
      role_mix:[{role:"implementation",count:1},{role:"review",count:1}],
      identity_binding_required:true,
      candidate_identity_bindings:[
        {agent:"sensitive-agent-one",identity:"sensitive-identity-one",status:"bound"},
        {agent:"sensitive-agent-two",identity:"sensitive-identity-two",status:"bound"}
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
    --workdir-template "$TEST_TMP/provisioned/%s" \
    --profile-output "$TEST_TMP/provisioned/profile.sh" \
    --state-output "$TEST_TMP/provisioned/state.json" \
    --json
)
provisioning_file=$(write_json provisioning "$provisioning_json")

# Project alpha: GxP, internal — should pass the gate.
# Project beta:  dev, external — should also pass the gate (same upstream evidence).
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
  --arg runtime_beta  "$TEST_TMP/runtime/beta"  \
  '{
    schema_version:"ordo.multi_project_onboarding.manifest.v1",
    portfolio_alias:$portfolio_alias,
    projects:[
      {
        alias:"alpha", default_branch:"main",
        validation_mode:"gxp", operator_class:"internal",
        runtime_root:$runtime_alpha,
        agent_labels:["primary","review"],
        repo_mode:"existing",
        host_report:$host, repository_report:$repository,
        bootstrap_report:$bootstrap, scaffold_report:$scaffold,
        fleet_sizing:$fleet, provisioning_report:$provisioning
      },
      {
        alias:"beta", default_branch:"trunk",
        validation_mode:"dev", operator_class:"external",
        runtime_root:$runtime_beta,
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

apply_json=$(
  bash "$ROOT/scripts/multi_project_onboarding.sh" \
    --manifest "$manifest_path" \
    --profile-dir "$profile_dir" \
    --state-dir "$state_dir" \
    --apply --json
)

jq -e '
  .schema_version == "ordo.multi_project_onboarding.portfolio.v1"
  and .portfolio_alias == "generic-portfolio"
  and .status == "applied"
  and .safe_to_apply == true
  and (.projects | length == 2)
  and (.projects[0].alias == "alpha")
  and (.projects[0].validation_mode == "gxp")
  and (.projects[0].operator_class == "internal")
  and (.projects[0].onboarding_profile.schema_version == "ordo.guided_onboarding_profile.v1")
  and (.projects[0].onboarding_profile.project_metadata.agent_labels | sort) == ["primary","review"]
  and (.projects[0].onboarding_profile.runtime_root.subdirs | keys | sort) == ["audit","cache","launch","logs","orchestrator","profiles","repos","state"]
  and (.projects[1].alias == "beta")
  and (.projects[1].validation_mode == "dev")
  and (.projects[1].operator_class == "external")
  and (.projects[1].onboarding_profile.project_metadata.default_branch == "trunk")
' <<< "$apply_json" >/dev/null \
  || fail "portfolio apply must surface per-project metadata + canonical onboarding_profile schema: $apply_json"

# Per-project canonical profiles must have been written under profile_dir.
[[ -s "$profile_dir/onboarding-profile-alpha.json" ]] \
  || fail "missing per-project onboarding profile for alpha"
[[ -s "$profile_dir/onboarding-profile-beta.json" ]] \
  || fail "missing per-project onboarding profile for beta"
jq -e '.schema_version == "ordo.guided_onboarding_profile.v1"' \
  "$profile_dir/onboarding-profile-alpha.json" >/dev/null \
  || fail "alpha profile must use canonical schema_version"
jq -e '.schema_version == "ordo.guided_onboarding_profile.v1"' \
  "$profile_dir/onboarding-profile-beta.json"  >/dev/null \
  || fail "beta profile must use canonical schema_version"
[[ -s "$profile_dir/portfolio-onboarding-profile.json" ]] \
  || fail "portfolio aggregate profile must be written under --profile-dir"

# Per-project state files must have been written under state_dir.
[[ -s "$state_dir/onboarding-state-alpha.json" ]] \
  || fail "missing per-project onboarding state for alpha"
[[ -s "$state_dir/onboarding-state-beta.json" ]] \
  || fail "missing per-project onboarding state for beta"

# Refusal case: if any project has an invalid validation_mode, the whole
# portfolio refuses with exit 78 and surfaces a namespaced blocker.
manifest_bad="$TEST_TMP/manifest_bad.json"
jq '.projects[1].validation_mode = "unsupported"' \
  "$manifest_path" > "$manifest_bad"

set +e
bad_output=$(
  bash "$ROOT/scripts/multi_project_onboarding.sh" \
    --manifest "$manifest_bad" \
    --profile-dir "$TEST_TMP/bad-profiles" \
    --state-dir "$TEST_TMP/bad-states" \
    --apply --json
)
bad_status=$?
set -e
[[ "$bad_status" -eq 78 ]] \
  || fail "invalid validation_mode in any project must refuse with exit 78, got $bad_status: $bad_output"
jq -e '.status == "blocked" and (.blockers | map(test("project_beta::validation_mode_invalid")) | any)' \
  <<< "$bad_output" >/dev/null \
  || fail "portfolio blockers must namespace per-project blockers as project_<alias>::<blocker>: $bad_output"

# Empty-projects manifest is rejected pre-flight (exit 2, not 78).
empty_manifest="$TEST_TMP/empty.json"
jq -nc '{schema_version:"ordo.multi_project_onboarding.manifest.v1", portfolio_alias:"x", projects:[]}' \
  > "$empty_manifest"
set +e
bash "$ROOT/scripts/multi_project_onboarding.sh" \
  --manifest "$empty_manifest" --json >/dev/null 2>&1
empty_status=$?
set -e
[[ "$empty_status" -eq 2 ]] \
  || fail "empty projects array must be rejected with exit 2, got $empty_status"

printf 'ok - multi_project_onboarding wraps guided_onboarding per-project, surfaces project_metadata + runtime_root, and refuses portfolios with any blocked project (#252)\n'
