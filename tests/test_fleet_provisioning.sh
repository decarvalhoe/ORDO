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

fleet_report() {
  local count=${1:?usage: fleet_report <count> <terminal-required>}
  local terminal_required=${2:?usage: fleet_report <count> <terminal-required>}
  jq -nc --argjson count "$count" --argjson terminal_required "$terminal_required" '
    {
      schema_version:"ordo.fleet_sizing.v1",
      recommendation:{
        decision:"provision",
        recommended_agents:$count,
        role_mix:[
          {role:"implementation",count:(if $count > 1 then ($count - 1) else $count end)},
          {role:"review",count:(if $count > 1 then 1 else 0 end)}
        ],
        blockers:[],
        warnings:[],
        resize:{direction:"new",required:false},
        rerun:{recommended:false,reasons:[]}
      },
      provisioning:{
        schema_version:"ordo.provisioning.input.v1",
        requested_agent_count:$count,
        role_mix:[
          {role:"implementation",count:(if $count > 1 then ($count - 1) else $count end)},
          {role:"review",count:(if $count > 1 then 1 else 0 end)}
        ],
        identity_binding_required:true,
        candidate_identity_bindings:[
          range(1; $count + 1)
          | {agent:("agent-" + tostring),identity:("identity-" + tostring),status:"bound"}
        ],
        required_capabilities:{
          repository_platform:["identity_binding"],
          provider_cli:["agent_execution"],
          terminal_multiplexer_required:$terminal_required
        }
      },
      onboarding_state:{
        schema_version:"ordo.onboarding_state_patch.v1",
        fleet_sizing:{recommended_agents:$count,decision:"provision"}
      }
    }'
}

bootstrap_report() {
  local status=${1:?usage: bootstrap_report <status> <workdir>}
  local workdir=${2:?usage: bootstrap_report <status> <workdir>}
  jq -nc --arg status "$status" --arg workdir "$workdir" '{
    status:$status,
    mode:$status,
    repository:"repository-fixture",
    workdir:$workdir,
    default_branch:"main",
    safe_to_apply:($status != "blocked"),
    blockers:[],
    baseline_config:"PROJECT=repository-fixture\n"
  }'
}

write_json() {
  local name=${1:?usage: write_json <name> <json>}
  local json=${2:?usage: write_json <name> <json>}
  local path="$TEST_TMP/$name.json"
  printf '%s\n' "$json" > "$path"
  printf '%s\n' "$path"
}

ready_bootstrap_file=$(write_json bootstrap-ready "$(bootstrap_report ready "$TEST_TMP/bootstrap-workdir")")
fleet_two_required_file=$(write_json fleet-two-required "$(fleet_report 2 true)")
workdir_template="$TEST_TMP/workdirs/%s"
terminal_template="terminal-%s"
profile_output="$TEST_TMP/generated/profile.config.sh"
state_output="$TEST_TMP/generated/onboarding-state.json"

plan_json=$(
  bash "$ROOT/scripts/fleet_provisioning.sh" \
    --fleet-sizing "$fleet_two_required_file" \
    --repository-bootstrap "$ready_bootstrap_file" \
    --workdir-template "$workdir_template" \
    --terminal-target-template "$terminal_template" \
    --profile-output "$profile_output" \
    --state-output "$state_output" \
    --json
)

jq -e '
  .schema_version == "ordo.fleet_provisioning.v1"
  and .status == "plan"
  and .mode == "plan"
  and .safe_to_apply == true
  and (.generated_profile.agents | length) == 2
  and (.generated_profile.agents | all(has("terminal_target") | not))
  and (.generated_profile.profile_text | contains("ORDO_GENERATED_AGENT_TARGETS=("))
  and (.generated_profile.profile_text | contains("AGENT_PANES") | not)
  and (.generated_profile.profile_text | contains("terminal-agent-1") | not)
  and (.warnings | index("terminal_multiplexer_required_but_not_applied"))
  and (.actions | map(select(.name == "terminal_adapter_apply" and .enabled == false)) | length == 1)
  and .verification_input.schema_version == "ordo.provisioning_verification.input.v1"
  and (.verification_input.agent_targets | length) == 2
  and .verification_input.terminal_adapter.requested == false
  and (.verification_input.terminal_adapter.targets | length) == 0
  and .onboarding_state.schema_version == "ordo.onboarding_state_patch.v1"
' <<< "$plan_json" >/dev/null \
  || fail "plan should generate profile without mutation: $plan_json"
[[ ! -e "$TEST_TMP/workdirs/agent-1" ]] || fail "plan must not create agent workdirs"
[[ ! -e "$profile_output" ]] || fail "plan must not write profile"
[[ ! -e "$state_output" ]] || fail "plan must not write state"

apply_json=$(
  bash "$ROOT/scripts/fleet_provisioning.sh" \
    --fleet-sizing "$fleet_two_required_file" \
    --repository-bootstrap "$ready_bootstrap_file" \
    --workdir-template "$workdir_template" \
    --terminal-target-template "$terminal_template" \
    --profile-output "$profile_output" \
    --state-output "$state_output" \
    --create-workdirs \
    --write-profile \
    --write-state \
    --apply \
    --json
)

jq -e '
  .status == "applied"
  and .mode == "apply"
  and (.applied | map(select(.name == "create_workdirs" and .status == "applied")) | length == 2)
  and (.applied | map(select(.name == "write_profile" and .status == "applied")) | length == 1)
  and (.applied | map(select(.name == "write_onboarding_state" and .status == "applied")) | length == 1)
  and (.applied | map(select(.name == "terminal_adapter_apply")) | length == 0)
' <<< "$apply_json" >/dev/null \
  || fail "apply should create workdirs and write generated files only when requested: $apply_json"
[[ -d "$TEST_TMP/workdirs/agent-1" ]] || fail "apply should create first agent workdir"
[[ -d "$TEST_TMP/workdirs/agent-2" ]] || fail "apply should create second agent workdir"
grep -q 'ORDO_GENERATED_AGENT_TARGETS=' "$profile_output" || fail "profile output should contain fleet inventory"
! grep -q 'AGENT_PANES' "$profile_output" || fail "profile output must not use pane-oriented inventory"
! grep -q 'terminal-agent-1' "$profile_output" || fail "profile output must not encode terminal targets"
jq -e '.generated_profile.agent_count == 2' "$state_output" >/dev/null \
  || fail "state output should contain generated profile patch"

bootstrap_plan_file=$(write_json bootstrap-plan "$(bootstrap_report plan "$TEST_TMP/bootstrap-plan-workdir")")
blocked_profile="$TEST_TMP/generated/blocked-profile.config.sh"
set +e
blocked_json=$(
  bash "$ROOT/scripts/fleet_provisioning.sh" \
    --fleet-sizing "$fleet_two_required_file" \
    --repository-bootstrap "$bootstrap_plan_file" \
    --workdir-template "$TEST_TMP/blocked/%s" \
    --profile-output "$blocked_profile" \
    --write-profile \
    --apply \
    --json
)
blocked_status=$?
set -e
[[ "$blocked_status" -eq 78 ]] \
  || fail "apply must refuse when repository bootstrap is not ready, got $blocked_status: $blocked_json"
jq -e '.status == "blocked" and (.blockers | index("repository_bootstrap_not_ready_for_apply"))' \
  <<< "$blocked_json" >/dev/null \
  || fail "blocked apply should identify bootstrap readiness blocker: $blocked_json"
[[ ! -e "$blocked_profile" ]] || fail "blocked apply must not write profile"

terminal_log="$TEST_TMP/terminal-adapter.log"
terminal_adapter="$TEST_TMP/terminal-adapter"
cat > "$terminal_adapter" <<'ADAPTER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TERMINAL_ADAPTER_LOG"
ADAPTER
chmod +x "$terminal_adapter"

terminal_profile="$TEST_TMP/generated/terminal-profile.config.sh"
terminal_state="$TEST_TMP/generated/terminal-state.json"
terminal_json=$(
  TERMINAL_ADAPTER_LOG="$terminal_log" \
  bash "$ROOT/scripts/fleet_provisioning.sh" \
    --fleet-sizing "$fleet_two_required_file" \
    --repository-bootstrap "$ready_bootstrap_file" \
    --workdir-template "$TEST_TMP/terminal-workdirs/%s" \
    --terminal-target-template "$terminal_template" \
    --profile-output "$terminal_profile" \
    --state-output "$terminal_state" \
    --create-workdirs \
    --write-profile \
    --write-state \
    --terminal-apply \
    --terminal-adapter "$terminal_adapter" \
    --apply \
    --json
)

jq -e '
  .status == "applied"
  and (.applied | map(select(.name == "terminal_adapter_apply" and .status == "applied")) | length == 2)
  and .verification_input.terminal_adapter.requested == true
  and (.verification_input.terminal_adapter.targets | length == 2)
  and .verification_input.terminal_adapter.actions_applied == true
' <<< "$terminal_json" >/dev/null \
  || fail "explicit terminal adapter apply should be recorded: $terminal_json"
grep -q 'provision-target --label agent-1 --target terminal-agent-1' "$terminal_log" \
  || fail "terminal adapter should receive generic provision-target calls"
! grep -q 'terminal-agent-1' "$terminal_profile" \
  || fail "terminal adapter targets must not be written to generated profile"

printf 'ok - fleet provisioning plans, applies generated profiles, refuses unsafe apply, and gates terminal adapters\n'
