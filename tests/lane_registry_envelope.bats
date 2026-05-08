#!/usr/bin/env bats

# Coverage for #312: lib/lane_registry.sh registers capability lanes and emits
# a canonical evidence envelope (schema_version "ordo.lane.v1") so dispatchers
# and consumers can stop reading lane internals directly.

load './helpers.bash'

setup() {
  setup_orch_test
  LANE_LIB=$(toolkit_file lib/lane_registry.sh)
  export LANE_LIB
}

# Source the registry in a fresh shell. set +e after sourcing so non-zero
# returns from registry helpers do not abort the bats run before we read $?.
run_in_registry() {
  local script=$1
  bash -lc "$(orch_env_exports)
    source '$LANE_LIB'
    set +e
    $script
  "
}

@test "default registry preregisters known lanes" {
  run run_in_registry 'lane_registry_lanes'
  [ "$status" -eq 0 ]
  [[ "$output" == *"auth"* ]]
  [[ "$output" == *"host_assessment"* ]]
  [[ "$output" == *"host_health"* ]]
  [[ "$output" == *"network"* ]]
  [[ "$output" == *"visual"* ]]
}

@test "lane_registry_known returns 0 for registered, 1 for unknown" {
  run run_in_registry '
    lane_registry_known visual && echo visual-known || echo visual-unknown
    lane_registry_known not_a_real_lane && echo bogus-known || echo bogus-unknown
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"visual-known"* ]]
  [[ "$output" == *"bogus-unknown"* ]]
}

@test "lane_registry_register is idempotent and refreshes description" {
  run run_in_registry '
    lane_registry_register myprobe "first description" "ORCH_MY_" "mycli"
    meta_first=$(lane_registry_meta myprobe)
    lane_registry_register myprobe "second description" "ORCH_MY_" "mycli"
    meta_second=$(lane_registry_meta myprobe)
    echo first=$meta_first
    echo second=$meta_second
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"first=myprobe|first description|ORCH_MY_|mycli"* ]]
  [[ "$output" == *"second=myprobe|second description|ORCH_MY_|mycli"* ]]
}

@test "lane_registry_register refuses ids containing pipe" {
  run run_in_registry '
    lane_registry_register "a|b" "bad id" "" ""
    rc=$?
    echo rc=$rc
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=2"* ]]
}

@test "envelope contains every required key with the canonical schema_version" {
  run run_in_registry '
    env=$(lane_registry_evidence_envelope visual ok "{\"display\":\":20\"}" true true)
    echo "$env" | jq -e "
      .schema_version == \"ordo.lane.v1\"
      and .lane == \"visual\"
      and (.lane_description | length > 0)
      and (.captured_at | test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$\"))
      and (.host | length > 0)
      and .status == \"ok\"
      and .configured == true
      and .available == true
      and .details.display == \":20\"
    "
    rc=$?
    echo rc=$rc
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
}

@test "envelope rejects unknown lane id with rc=2" {
  run run_in_registry '
    lane_registry_evidence_envelope nonexistent_lane unknown "{}" false false
    rc=$?
    echo rc=$rc
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=2"* ]]
  [[ "$output" == *"unknown lane"* ]]
}

@test "envelope rejects unknown status with rc=3" {
  run run_in_registry '
    lane_registry_evidence_envelope visual not_a_status "{}" false false
    rc=$?
    echo rc=$rc
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=3"* ]]
  [[ "$output" == *"unknown status"* ]]
}

@test "envelope defaults: status=unknown, details={}, configured/available=false" {
  run run_in_registry '
    lane_registry_evidence_envelope host_health
  '
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .schema_version == "ordo.lane.v1"
    and .lane == "host_health"
    and .status == "unknown"
    and .configured == false
    and .available == false
    and (.details | type == "object")
    and (.details | length == 0)
  ' >/dev/null
}

@test "lane_registry_envelope_validate accepts a fresh envelope and rejects a malformed one" {
  run run_in_registry '
    good=$(lane_registry_evidence_envelope host_assessment warning "{\"k\":1}" true true)
    bad=$(printf "%s" "$good" | jq "del(.host)")
    if lane_registry_envelope_validate "$good"; then echo good=ok; else echo good=fail; fi
    if lane_registry_envelope_validate "$bad"; then echo bad=ok; else echo bad=fail; fi
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"good=ok"* ]]
  [[ "$output" == *"bad=fail"* ]]
}

@test "lane_registry_envelope_validate rejects wrong schema_version" {
  run run_in_registry '
    good=$(lane_registry_evidence_envelope host_assessment ok "{}" true true)
    wrong=$(printf "%s" "$good" | jq ".schema_version = \"ordo.lane.v999\"")
    if lane_registry_envelope_validate "$wrong"; then echo wrong=ok; else echo wrong=fail; fi
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrong=fail"* ]]
}

@test "envelope passes through booleans expressed as 1/yes/on" {
  run run_in_registry '
    env=$(lane_registry_evidence_envelope visual ok "{}" 1 yes)
    echo "$env" | jq -e ".configured == true and .available == true" >/dev/null
    echo rc=$?
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"rc=0"* ]]
}
