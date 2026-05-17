#!/usr/bin/env bats
# tests/dispatch_proof_prompt_visible_with_activity.bats — ORDO #652 regression.
#
# Issue: PROMPT_EXECUTION_PROOF_FAILED reason=submission-still-visible was
# raised even when the dispatched pane was demonstrably working — the
# submitted prompt was still scrollback-visible at the top of the capture
# window WHILE the agent had already begun a tool call (e.g. `Reading ...`,
# `bash`, `git ...`) on a line below it. The early bail at "submission
# visible" never reached the active-pattern check.
#
# Fix shape: when the submitted prompt is visible AND the capture also
# contains an active-pattern line that is NOT a substring of the submitted
# text (i.e. genuine new activity, not a repaint of the prompt itself),
# treat the dispatch as consumed and emit
# `proof_signal=prompt-visible-with-activity-below`.
#
# Guard rails preserved (must keep failing closed):
# - prompt visible + only generic "esc to interrupt" footer below → still
#   submission-still-visible (covers existing #569/#638 fixtures 8008/8012).
# - prompt visible + nothing else → still submission-still-visible.
# - empty capture → still no-positive-execution-proof.

load './helpers.bash'

setup() {
  setup_orch_test
  unset ORCH_DISPATCH_VISIBLE_TEXT_PREFIX_CHARS
  unset ORCH_DISPATCH_VISIBLE_TEXT_MIN_CHARS
  unset ORCH_DISPATCH_VISIBLE_TEXT_FRAGMENT_CHARS
  unset ORCH_DISPATCH_VISIBLE_TEXT_FRAGMENT_STRIDE
  unset ORCH_DISPATCH_IDLE_PROMPT_PATTERN
  unset ORCH_DISPATCH_ACTIVE_PATTERN
  unset ORCH_DISPATCH_CONSUME_CAPTURE_LINES
  # shellcheck disable=SC1090
  source "$TK/lib/tmux_helpers.sh"
  # Shadow the just-sourced capture_pane with a fixture-driven mock so the
  # bats run is hermetic — no real tmux is involved. CAPTURE_FIXTURE is set
  # by each test body and is the only input the mock honors.
  capture_pane() {
    printf '%s' "${CAPTURE_FIXTURE:-}"
  }
  export -f capture_pane
}

submitted_prompt() {
  printf '%s' "Read /tmp/dispatch-agent-001-9001.md and execute it end-to-end. Stay strictly in scope. Verify your git identity matches the agent name before commit. Report final status."
}

# `bats run` executes the probe in a subshell, so we serialize the proof
# diagnostics onto stdout — the test then asserts on $output and $status.
probe_consumed() {
  local prompt=$1
  DISPATCH_SUBMIT_LAST_REASON=""
  DISPATCH_SUBMIT_LAST_DETAIL=""
  DISPATCH_SUBMIT_LAST_PROOF=""
  DISPATCH_SUBMIT_LAST_SIGNAL=""
  DISPATCH_SUBMIT_LAST_CAPTURE=""
  if terminal_dispatch_pane_not_consumed "fixture-pane:0.0" "$prompt"; then
    printf 'verdict=not-consumed reason=%s signal=%s\n' \
      "${DISPATCH_SUBMIT_LAST_REASON:-}" "${DISPATCH_SUBMIT_LAST_SIGNAL:-}"
    return 0
  fi
  printf 'verdict=consumed proof=%s signal=%s\n' \
    "${DISPATCH_SUBMIT_LAST_PROOF:-}" "${DISPATCH_SUBMIT_LAST_SIGNAL:-}"
  return 1
}

@test "consumed when prompt is visible AND a tool-call line appears below it (#652)" {
  CAPTURE_FIXTURE=$'> Read /tmp/dispatch-agent-001-9001.md and execute it end-to-end. Stay strictly in scope. Verify your git identity matches the agent name before commit. Report final status.\nReading /tmp/dispatch-agent-001-9001.md\nbash\nesc to interrupt'
  run probe_consumed "$(submitted_prompt)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"verdict=consumed"* ]]
  [[ "$output" == *"proof=prompt-visible-with-activity-below"* ]]
  [[ "$output" == *"signal=prompt-visible-with-activity-below"* ]]
}

@test "still failed when prompt is visible AND only an esc-to-interrupt footer is below it (#652 guard for #569/#638)" {
  CAPTURE_FIXTURE=$'> Read /tmp/dispatch-agent-001-9001.md and execute it end-to-end. Stay strictly in scope. Verify your git identity matches the agent name before commit. Report final status.\nesc to interrupt'
  run probe_consumed "$(submitted_prompt)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verdict=not-consumed"* ]]
  [[ "$output" == *"reason=submission-still-visible"* ]]
  [[ "$output" == *"signal=submission-still-visible"* ]]
}

@test "still failed when prompt is visible alone (no activity, no footer) (#652 guard)" {
  CAPTURE_FIXTURE=$'> Read /tmp/dispatch-agent-001-9001.md and execute it end-to-end. Stay strictly in scope. Verify your git identity matches the agent name before commit. Report final status.'
  run probe_consumed "$(submitted_prompt)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason=submission-still-visible"* ]]
  [[ "$output" == *"signal=submission-still-visible"* ]]
}

@test "consumed when capture shows clean activity and no visible prompt (#652 sanity)" {
  CAPTURE_FIXTURE=$'working on dispatch'
  run probe_consumed "$(submitted_prompt)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"proof=post-submit-action-pattern"* ]]
  [[ "$output" == *"signal=post-submit-action-pattern"* ]]
}

@test "empty capture stays no-positive-execution-proof (#652 sanity)" {
  CAPTURE_FIXTURE=""
  run probe_consumed "$(submitted_prompt)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"reason=no-positive-execution-proof"* ]]
  [[ "$output" == *"signal=no-positive-execution-proof"* ]]
}

@test "prompt-visible-with-activity-below ignores esc-to-interrupt and treats Reading as activity (#652)" {
  # Real-world capture from the issue: Claude printed the prompt, started a
  # tool call, and the footer banner is also present. Activity below must win.
  CAPTURE_FIXTURE=$'> Read /tmp/dispatch-agent-001-9001.md and execute it end-to-end. Stay strictly in scope. Verify your git identity matches the agent name before commit. Report final status.\nReading dispatch brief\nesc to interrupt'
  run probe_consumed "$(submitted_prompt)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"proof=prompt-visible-with-activity-below"* ]]
}
