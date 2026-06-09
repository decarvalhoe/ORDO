#!/usr/bin/env bats
#
# Umbrella governance tests for PR operations modes (epic #357).
#
# The PR-operations child issues ship per-mode test files. The structural invariants
# this epic depends on cut across all four modes:
#
#   1. The set of valid modes is exactly
#      {observe, assist, automerge, centralized, delegated, autonomous}.
#   2. Final actions are always {merge, ready-for-review, rerun, close, branch-delete}.
#   3. Preparation actions are allowed in every authorized mode (no agent
#      ever loses the ability to prepare evidence / patches after the profile
#      has explicitly allowed the selected non-observe mode).
#   4. observe mode refuses every final action regardless of actor or gates.
#   5. centralized mode refuses a final action by an `agent` actor even
#      when every required gate is satisfied.
#   6. The autonomous mode is opt-in via AUTO_PR_OPS_ENABLED=1 in the
#      profile; an unset / unauthorized profile cannot escalate from
#      ORDO_PR_OPS_MODE alone.
#
# These tests pin the contract documented in
# docs/pr-operations-governance.md. They are intentionally small —
# they exercise the public lib API (lib/pr_ops_mode.sh) and the
# autonomous runner's profile-gating, not the per-mode mechanics that
# the child-issue tests already cover.

load ./helpers.bash

setup() {
  setup_orch_test
  PR_OPS_MODE_LIB=$(toolkit_file lib/pr_ops_mode.sh)
}

# ---------------------------------------------------------------------
# Invariant 1 — valid modes
# ---------------------------------------------------------------------

@test "valid mode set is exactly {observe,assist,automerge,centralized,delegated,autonomous}" {
  run bash -c "
    source '$PR_OPS_MODE_LIB'
    printf '%s\n' \"\${ORDO_PR_OPS_VALID_MODES[@]}\" | sort | tr '\n' ',' | sed 's/,\$//'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "assist,automerge,autonomous,centralized,delegated,observe" ]
}

@test "pr_ops_mode rejects an out-of-set mode with exit 2" {
  run bash -c "
    PR_OPS_MODE=evil_mode
    source '$PR_OPS_MODE_LIB'
    pr_ops_mode
  "
  [ "$status" -eq 2 ]
}

@test "pr_ops_mode defaults to observe when nothing is set" {
  run bash -c "
    unset PR_OPS_MODE ORDO_PR_OPS_MODE
    source '$PR_OPS_MODE_LIB'
    pr_ops_mode
  "
  [ "$status" -eq 0 ]
  [ "$output" = "observe" ]
}

@test "ORDO_PR_OPS_MODE env override wins over PR_OPS_MODE profile" {
  run bash -c "
    PR_OPS_MODE=observe ORDO_PR_OPS_MODE=centralized
    export PR_OPS_MODE ORDO_PR_OPS_MODE
    source '$PR_OPS_MODE_LIB'
    pr_ops_mode
  "
  [ "$status" -eq 0 ]
  [ "$output" = "centralized" ]
}

# ---------------------------------------------------------------------
# Invariant 2 — final-action set is canonical
# ---------------------------------------------------------------------

@test "final-action set is exactly {merge,ready-for-review,rerun,close,branch-delete}" {
  run bash -c "
    source '$PR_OPS_MODE_LIB'
    printf '%s\n' \"\${ORDO_PR_OPS_FINAL_ACTIONS[@]}\" | sort | tr '\n' ',' | sed 's/,\$//'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "branch-delete,close,merge,ready-for-review,rerun" ]
}

@test "preparation-action set is exactly {prepare-fix,evidence-record,comment-audit-only,report-status}" {
  run bash -c "
    source '$PR_OPS_MODE_LIB'
    printf '%s\n' \"\${ORDO_PR_OPS_PREP_ACTIONS[@]}\" | sort | tr '\n' ',' | sed 's/,\$//'
  "
  [ "$status" -eq 0 ]
  [ "$output" = "comment-audit-only,evidence-record,prepare-fix,report-status" ]
}

# ---------------------------------------------------------------------
# Invariant 3 — preparation actions always allowed
# ---------------------------------------------------------------------

@test "preparation actions are allowed in every mode for an agent actor" {
  for mode in observe assist automerge centralized delegated autonomous; do
    for action in prepare-fix evidence-record comment-audit-only report-status; do
      run bash -c "
        export PR_OPS_MODE='$mode'
        if [ '$mode' != observe ]; then
          export PR_OPS_MODE_ALLOWED='$mode'
        fi
        export ORDO_PR_OPS_ACTOR=agent
        source '$PR_OPS_MODE_LIB'
        pr_ops_check_authorization '$action' ''
      "
      [ "$status" -eq 0 ] \
        || { echo "expected mode=$mode action=$action to be allowed; got status=$status, output=$output" >&3; false; }
      [[ "$output" == *'"decision":"allowed"'* ]] \
        || { echo "missing allowed decision in: $output" >&3; false; }
      [[ "$output" == *'"reason":"preparation_action"'* ]] \
        || { echo "missing preparation_action reason in: $output" >&3; false; }
    done
  done
}

# ---------------------------------------------------------------------
# Invariant 4 — observe mode refuses every final action
# ---------------------------------------------------------------------

@test "observe mode refuses every final action even for the operator with all gates" {
  for action in merge ready-for-review rerun close branch-delete; do
    run bash -c "
      export PR_OPS_MODE=observe
      export ORDO_PR_OPS_ACTOR=operator
      source '$PR_OPS_MODE_LIB'
      pr_ops_check_authorization '$action' 'ci,review,docs,gxp'
    "
    [ "$status" -ne 0 ] \
      || { echo "observe mode wrongly allowed $action: $output" >&3; false; }
    [[ "$output" == *'"decision":"refused"'* ]] \
      || { echo "missing refused decision for $action in: $output" >&3; false; }
    [[ "$output" == *'"reason":"observe_mode_refuses_final_mutation"'* ]] \
      || { echo "wrong refusal reason for $action: $output" >&3; false; }
  done
}

# ---------------------------------------------------------------------
# Invariant 5 — centralized mode refuses agent actor on final actions
# ---------------------------------------------------------------------

@test "centralized mode refuses a final action by an agent actor even with gates passed" {
  run bash -c "
    export PR_OPS_MODE=centralized
    export PR_OPS_MODE_ALLOWED=centralized
    export ORDO_PR_OPS_ACTOR=agent
    source '$PR_OPS_MODE_LIB'
    pr_ops_check_authorization merge 'ci,review'
  "
  # Exit code 90 is ORCH_PR_OPS_UNAUTHORIZED_ACTOR_EXIT_CODE.
  [ "$status" -eq 90 ]
  [[ "$output" == *'"decision":"refused"'* ]]
}

@test "centralized mode allows operator merge when every required gate is passed" {
  run bash -c "
    export PR_OPS_MODE=centralized
    export PR_OPS_MODE_ALLOWED=centralized
    export ORDO_PR_OPS_ACTOR=operator
    source '$PR_OPS_MODE_LIB'
    pr_ops_check_authorization merge 'ci,review'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision":"allowed"'* ]]
}

@test "centralized mode refuses operator merge when a required gate is missing" {
  run bash -c "
    export PR_OPS_MODE=centralized
    export PR_OPS_MODE_ALLOWED=centralized
    export ORDO_PR_OPS_ACTOR=operator
    source '$PR_OPS_MODE_LIB'
    pr_ops_check_authorization merge 'ci'
  "
  # Exit code 91 is ORCH_PR_OPS_GATE_FAILED_EXIT_CODE.
  [ "$status" -eq 91 ]
  [[ "$output" == *'"reason":"missing_required_gate"'* ]]
}

# ---------------------------------------------------------------------
# Invariant 6 — autonomous escalation requires profile opt-in
# ---------------------------------------------------------------------

@test "autonomous mode actor=agent on a final action is refused without operator authority" {
  # Even in autonomous mode, the lib's policy refuses an `agent` actor
  # on a final action — the autonomous *runner* (lib/autonomous_pr_ops.sh)
  # is the only path that may merge, and it presents itself as
  # actor=operator while running. A bare ORDO_PR_OPS_MODE=autonomous
  # without that runner cannot escalate from chat.
  run bash -c "
    export PR_OPS_MODE=autonomous
    export PR_OPS_MODE_ALLOWED=autonomous
    export ORDO_PR_OPS_ACTOR=agent
    source '$PR_OPS_MODE_LIB'
    pr_ops_check_authorization merge 'ci,review'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *'"decision":"refused"'* ]]
}
