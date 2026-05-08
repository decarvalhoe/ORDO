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

host_report() {
  local capacity=${1:?usage: host_report <capacity> <terminal-required> <terminal-status> <suitability>}
  local terminal_required=${2:?usage: host_report <capacity> <terminal-required> <terminal-status> <suitability>}
  local terminal_status=${3:?usage: host_report <capacity> <terminal-required> <terminal-status> <suitability>}
  local suitability=${4:?usage: host_report <capacity> <terminal-required> <terminal-status> <suitability>}

  jq -nc \
    --argjson capacity "$capacity" \
    --argjson terminal_required "$terminal_required" \
    --arg terminal_status "$terminal_status" \
    --arg suitability "$suitability" \
    '{
      schema_version:"ordo.host_assessment.v1",
      capacity:{
        estimated_agents:$capacity,
        dimensions:{
          cpu:$capacity,
          memory:$capacity,
          disk:$capacity,
          process_limits:$capacity
        }
      },
      capabilities:{
        terminal_multiplexer:{
          required:$terminal_required,
          configured:($terminal_status != "not_configured"),
          available:($terminal_status == "available"),
          status:$terminal_status,
          topology_required:$terminal_required
        }
      },
      environment_recommendation:{
        decision:"keep_current_machine",
        suitability:$suitability,
        bottlenecks:(if $capacity < 5 then ["host_capacity"] else [] end)
      }
    }'
}

repository_report() {
  local count=${1:?usage: repository_report <bound-count>}
  jq -nc --argjson count "$count" '
    {
      status:"ready",
      capabilities:{
        identity_binding:{ready:true,detail:"ready"},
        repository_access:{ready:true,detail:"ready"},
        push_permission:{ready:true,detail:"ready"},
        pr_review_capability:{ready:true,detail:"ready"},
        issue_assignment_capability:{ready:true,detail:"ready"},
        ci_status_visibility:{ready:true,detail:"ready"}
      },
      identity_bindings:[range(0; $count) | {agent:("agent-" + tostring),identity:("identity-" + tostring),status:"bound"}],
      blockers:[]
    }'
}

provider_report() {
  local capacity=${1:?usage: provider_report <capacity>}
  jq -nc --argjson capacity "$capacity" '
    {
      status:"ready",
      capacity:{available_agents:$capacity},
      capabilities:{
        agent_execution:{ready:true,capacity:$capacity},
        workspace_access:{ready:true},
        evidence_capture:{ready:true}
      },
      role_capabilities:{},
      blockers:[]
    }'
}

write_fixture() {
  local name=${1:?usage: write_fixture <name> <json>}
  local json=${2:?usage: write_fixture <name> <json>}
  local path="$TEST_TMP/$name.json"
  printf '%s\n' "$json" > "$path"
  printf '%s\n' "$path"
}

undersized_host_file=$(write_fixture host-undersized "$(host_report 2 false available undersized)")
ready_repo_file=$(write_fixture repo-ready "$(repository_report 5)")
provider_five_file=$(write_fixture provider-five "$(provider_report 5)")

undersized_json=$(
  bash "$ROOT/scripts/fleet_sizing.sh" \
    --requested-agents 5 \
    --host-report "$undersized_host_file" \
    --repository-report "$ready_repo_file" \
    --provider-report "$provider_five_file" \
    --json
)

jq -e '
  .schema_version == "ordo.fleet_sizing.v1"
  and .recommendation.decision == "provision_limited_fleet"
  and .recommendation.recommended_agents == 2
  and (.recommendation.bottlenecks | index("host_capacity"))
  and .provisioning.requested_agent_count == 2
  and (.provisioning.role_mix | map(.count) | add) == 2
  and .onboarding_state.fleet_sizing.recommended_agents == 2
' <<< "$undersized_json" >/dev/null \
  || fail "undersized host should limit fleet size: $undersized_json"

missing_repo_file="$TEST_TMP/repo-missing.json"
cat > "$missing_repo_file" <<'JSON'
{
  "status": "blocked",
  "capabilities": {
    "identity_binding": {"ready": false, "detail": "identity_unavailable"},
    "repository_access": {"ready": true, "detail": "ready"},
    "push_permission": {"ready": true, "detail": "ready"},
    "pr_review_capability": {"ready": true, "detail": "ready"},
    "issue_assignment_capability": {"ready": true, "detail": "ready"},
    "ci_status_visibility": {"ready": true, "detail": "ready"}
  },
  "identity_bindings": [],
  "blockers": ["identity_binding"]
}
JSON
missing_provider_file="$TEST_TMP/provider-missing.json"
cat > "$missing_provider_file" <<'JSON'
{
  "status": "blocked",
  "capacity": {"available_agents": 4},
  "capabilities": {
    "agent_execution": {"ready": false},
    "workspace_access": {"ready": true},
    "evidence_capture": {"ready": true}
  },
  "blockers": ["agent_execution"]
}
JSON
host_ready_file=$(write_fixture host-ready "$(host_report 4 false available suitable)")

missing_json=$(
  bash "$ROOT/scripts/fleet_sizing.sh" \
    --requested-agents 4 \
    --host-report "$host_ready_file" \
    --repository-report "$missing_repo_file" \
    --provider-report "$missing_provider_file" \
    --json
)

jq -e '
  .recommendation.decision == "blocked"
  and .recommendation.recommended_agents == 0
  and (.recommendation.blockers | index("repository_capability:identity_binding"))
  and (.recommendation.blockers | index("provider_capability:agent_execution"))
  and .recommendation.rerun.recommended == true
  and (.recommendation.rerun.reasons | index("after_blocker_remediation"))
' <<< "$missing_json" >/dev/null \
  || fail "missing identity and provider capability should block sizing: $missing_json"

optional_terminal_file=$(write_fixture host-optional-terminal "$(host_report 4 false unavailable_optional suitable)")
provider_four_file=$(write_fixture provider-four "$(provider_report 4)")
repo_four_file=$(write_fixture repo-four "$(repository_report 4)")

optional_terminal_json=$(
  bash "$ROOT/scripts/fleet_sizing.sh" \
    --requested-agents 3 \
    --host-report "$optional_terminal_file" \
    --repository-report "$repo_four_file" \
    --provider-report "$provider_four_file" \
    --json
)

jq -e '
  .recommendation.decision == "provision"
  and .recommendation.recommended_agents == 3
  and (.recommendation.blockers | index("terminal_multiplexer_required_unavailable") | not)
  and (.recommendation.warnings | index("terminal_multiplexer_optional_unavailable"))
  and .inputs.terminal_multiplexer.optional == true
' <<< "$optional_terminal_json" >/dev/null \
  || fail "optional terminal multiplexer should warn but not block: $optional_terminal_json"

resize_json=$(
  bash "$ROOT/scripts/fleet_sizing.sh" \
    --requested-agents 4 \
    --current-agents 1 \
    --host-report "$host_ready_file" \
    --repository-report "$repo_four_file" \
    --provider-report "$provider_four_file" \
    --json
)

jq -e '
  .recommendation.decision == "resize_up"
  and .recommendation.resize.current_agents == 1
  and .recommendation.resize.target_agents == 4
  and .recommendation.resize.direction == "up"
  and .recommendation.resize.required == true
  and .recommendation.rerun.recommended == true
  and (.recommendation.rerun.reasons | index("after_resize_decision"))
  and .onboarding_state.fleet_sizing.rerun_recommended == true
' <<< "$resize_json" >/dev/null \
  || fail "rerun with changed constraints should recommend resize: $resize_json"

printf 'ok - fleet sizing combines host, repository, provider, terminal, and rerun constraints\n'
