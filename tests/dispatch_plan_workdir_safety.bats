#!/usr/bin/env bats
# tests/dispatch_plan_workdir_safety.bats — coverage for ORDO #454.
#
# Cluster cause: `agent_pool_status.sh examples/rbok.config.sh --tsv`
# reports `dirty,dirty_after_pr` for several fleet slots while
# `dispatch_plan.sh --ready-only` still emits P0/P1 ready candidates.
# The supervisor was expected to join those two signals manually before
# dispatch, which is a fail-open posture for multi-agent waves.
#
# This file exercises the three surfaces that close the gap:
#
#   1. The pure capacity-class classifier helpers in
#      `lib/dispatch_capacity.sh` (`dispatch_capacity_class_dispatchable`,
#      `dispatch_capacity_blocked_reason`,
#      `dispatch_capacity_remediation_for_class`). These are the
#      vocabulary every downstream surface shares so the "dirty workdir
#      is not dispatchable" rule is encoded once.
#
#   2. The sibling preflight in `lib/dispatch_workdir_preflight.sh`
#      (`dispatch_workdir_safety_preflight`), which refuses (or warns,
#      or skips) BEFORE the brief is pasted into a dirty pane.
#
#   3. The `dirty_after_pr` remediation hint — the most common cause in
#      the source ticket — flows through both helpers.

load './helpers.bash'

setup() {
  setup_orch_test

  toolkit_file lib/dispatch_capacity.sh >/dev/null
  toolkit_file lib/dispatch_workdir_preflight.sh >/dev/null
  toolkit_file lib/audit_log.sh >/dev/null
  toolkit_file lib/log_bounds.sh >/dev/null
  toolkit_file lib/config_check.sh >/dev/null

  # shellcheck disable=SC1090,SC1091
  source "$SANITIZED_TK/lib/audit_log.sh"
  # shellcheck disable=SC1090,SC1091
  source "$SANITIZED_TK/lib/dispatch_capacity.sh"
  # shellcheck disable=SC1090,SC1091
  source "$SANITIZED_TK/lib/dispatch_workdir_preflight.sh"

  WORK_BASE="$BATS_TEST_TMPDIR/clones"
  mkdir -p "$WORK_BASE/clean" "$WORK_BASE/dirty"

  # A clean repo: `git status --porcelain` is empty so the preflight
  # treats it as dispatchable.
  git -C "$WORK_BASE/clean" init -q
  git -C "$WORK_BASE/clean" -c user.name=ci -c user.email=ci@example.com \
    commit --allow-empty -q -m "seed"

  # A dirty repo: an untracked file makes `status --porcelain` non-empty,
  # which mirrors the live `RBOK-codex` / `RBOK-copilot` slots in the
  # source ticket.
  git -C "$WORK_BASE/dirty" init -q
  git -C "$WORK_BASE/dirty" -c user.name=ci -c user.email=ci@example.com \
    commit --allow-empty -q -m "seed"
  : > "$WORK_BASE/dirty/STRAY-ARTIFACT"

  # Reset both guards to their script-level defaults so prior tests do
  # not leak `off`/`warn` overrides across files in the same bats run.
  unset ORCH_DISPATCH_WORKDIR_SAFETY_GUARD
}

assert_safety() {
  # assert_safety <expected-status> <args...>
  local expected=$1
  shift
  local rc=0
  local stderr_file
  stderr_file="$BATS_TEST_TMPDIR/safety.stderr.$$"
  : > "$stderr_file"
  dispatch_workdir_safety_preflight "$@" 2>"$stderr_file" || rc=$?
  SAFETY_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
  [ "$rc" -eq "$expected" ] || {
    printf 'expected status=%s got=%s args=%s stderr=%s\n' \
      "$expected" "$rc" "$*" "$SAFETY_STDERR" >&2
    return 1
  }
}

# ----- pure classifier vocabulary ---------------------------------------

@test "AC#454-1 dispatch_capacity_class_dispatchable only accepts 'available'" {
  # Only 'available' is a green light. Every blocked class — including
  # 'dispatched' and 'local_work' — must come back as non-dispatchable
  # so the planner cannot double-book an agent that is already carrying
  # work in flight.
  run dispatch_capacity_class_dispatchable available
  [ "$status" -eq 0 ]

  for class in dirty_clone dispatched local_work reserved switch_required \
    pane_not_ready clone_missing supervisor_mirror identity_mismatch unknown; do
    run dispatch_capacity_class_dispatchable "$class"
    [ "$status" -ne 0 ]
  done
}

@test "AC#454-2 dispatch_capacity_blocked_reason promotes dirty_after_pr over dirty_clone" {
  # The source ticket calls out `dirty_after_pr` as the cluster cause —
  # the agent merged a PR but the workdir still carries stray artifacts.
  # The blocked_reason MUST surface the sub-state when the signals CSV
  # carries it so downstream tooling can branch on it.
  run dispatch_capacity_blocked_reason dirty_clone "dirty,dirty_after_pr"
  [ "$status" -eq 0 ]
  [ "$output" = "dirty_after_pr" ]

  # Without the dirty_after_pr signal the reason falls back to the
  # generic dirty_clone token.
  run dispatch_capacity_blocked_reason dirty_clone ""
  [ "$status" -eq 0 ]
  [ "$output" = "dirty_clone" ]

  # 'available' is intentionally empty so callers can treat empty output
  # as a "no blocker" sentinel.
  run dispatch_capacity_blocked_reason available ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "AC#454-3 dispatch_capacity_remediation_for_class points dirty_after_pr at post_merge_cleanup" {
  # The remediation MUST mention post_merge_cleanup.sh for the
  # dirty_after_pr cluster cause; otherwise an operator reading only
  # the ready queue would default to `git stash`, which buries the
  # leftover artifacts instead of removing them.
  run dispatch_capacity_remediation_for_class dirty_clone "dirty,dirty_after_pr"
  [ "$status" -eq 0 ]
  [[ "$output" == *"post_merge_cleanup.sh"* ]]

  # Plain dirty_clone (no PR signal) gets the stash/commit hint.
  run dispatch_capacity_remediation_for_class dirty_clone ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"stash"* || "$output" == *"commit"* ]]

  # 'available' emits nothing so callers can treat empty as
  # "no remediation needed".
  run dispatch_capacity_remediation_for_class available ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ----- dispatch_workdir_safety_preflight -------------------------------

@test "AC#454-4 enforce mode refuses dispatch into a dirty workdir" {
  ORCH_DISPATCH_WORKDIR_SAFETY_GUARD=enforce

  assert_safety 5 agent-codex 454 "$WORK_BASE/dirty"

  [ "${DISPATCH_WORKDIR_SAFETY_RESULT}" = "dirty_clone" ]
  [ "${DISPATCH_WORKDIR_SAFETY_GUARD_MODE}" = "enforce" ]
  [ "${DISPATCH_WORKDIR_SAFETY_DIRTY_COUNT}" -ge 1 ]
  [[ "${SAFETY_STDERR}" == *"dispatch refused"* ]]
  [[ "${SAFETY_STDERR}" == *"agent-codex"* ]]
  [[ "${SAFETY_STDERR}" == *"remediation:"* ]]

  log="$ORCH_LOG_DIR/$PROJECT.log"
  [ -s "$log" ]
  grep -q 'DISPATCH REFUSED reason=workdir_dirty_clone agent=agent-codex' "$log"
}

@test "AC#454-5 enforce mode surfaces dirty_after_pr remediation when signals carry it" {
  # The caller (dispatch_ticket / dispatch_plan) already has the
  # agent_pool_status.sh signal list. When `dirty_after_pr` is present
  # the preflight MUST forward the post_merge_cleanup hint instead of
  # the generic stash/commit one.
  ORCH_DISPATCH_WORKDIR_SAFETY_GUARD=enforce

  assert_safety 5 agent-copilot 454 "$WORK_BASE/dirty" "dirty,dirty_after_pr"

  [ "${DISPATCH_WORKDIR_SAFETY_RESULT}" = "dirty_after_pr" ]
  [[ "${DISPATCH_WORKDIR_SAFETY_REMEDIATION}" == *"post_merge_cleanup.sh"* ]]
  [[ "${SAFETY_STDERR}" == *"dirty_after_pr"* ]]
  [[ "${SAFETY_STDERR}" == *"post_merge_cleanup.sh"* ]]

  log="$ORCH_LOG_DIR/$PROJECT.log"
  grep -q 'DISPATCH REFUSED reason=workdir_dirty_after_pr agent=agent-copilot' "$log"
}

@test "AC#454-6 warn mode emits stderr signal but lets dispatch proceed" {
  # The default rollout mode is `warn` so a fleet that still has dirty
  # slots from before this guard existed does not refuse the wave.
  ORCH_DISPATCH_WORKDIR_SAFETY_GUARD=warn

  assert_safety 0 agent-claude 454 "$WORK_BASE/dirty"

  [ "${DISPATCH_WORKDIR_SAFETY_RESULT}" = "dirty_clone" ]
  [ "${DISPATCH_WORKDIR_SAFETY_GUARD_MODE}" = "warn" ]
  [[ "${SAFETY_STDERR}" == *"DISPATCH_WORKDIR_SAFETY_GUARD warn"* ]]

  log="$ORCH_LOG_DIR/$PROJECT.log"
  grep -q 'DISPATCH WORKDIR_SAFETY_GUARD warn agent=agent-claude' "$log"
}

@test "AC#454-7 off mode skips refusal and records an audit line" {
  # `audit()` mirrors every record to stderr by design (so dashboards
  # tailing the log pick it up), so we assert on the audit line itself,
  # not on stderr emptiness — that is true of every audit-emitting
  # helper in this repo.
  ORCH_DISPATCH_WORKDIR_SAFETY_GUARD=off

  assert_safety 0 agent-codex 454 "$WORK_BASE/dirty"

  [ "${DISPATCH_WORKDIR_SAFETY_RESULT}" = "skipped" ]
  [[ "${SAFETY_STDERR}" != *"dispatch refused"* ]]
  [[ "${SAFETY_STDERR}" != *"DISPATCH_WORKDIR_SAFETY_GUARD warn"* ]]

  log="$ORCH_LOG_DIR/$PROJECT.log"
  grep -q 'DISPATCH WORKDIR_SAFETY_GUARD skipped agent=agent-codex' "$log"
}

@test "AC#454-8 clean workdir is accepted in enforce mode" {
  # Healthy path: a clean clone is a green light. The guard records a
  # positive `ok` audit line so dashboards can prove the surface was
  # checked, not skipped. (stderr carries the audit mirror but no
  # refusal/warn token — those are the operator-facing signals.)
  ORCH_DISPATCH_WORKDIR_SAFETY_GUARD=enforce

  assert_safety 0 agent-codex 454 "$WORK_BASE/clean"

  [ "${DISPATCH_WORKDIR_SAFETY_RESULT}" = "clean" ]
  [ "${DISPATCH_WORKDIR_SAFETY_DIRTY_COUNT}" -eq 0 ]
  [[ "${SAFETY_STDERR}" != *"dispatch refused"* ]]
  [[ "${SAFETY_STDERR}" != *"DISPATCH_WORKDIR_SAFETY_GUARD warn"* ]]

  log="$ORCH_LOG_DIR/$PROJECT.log"
  grep -q 'DISPATCH WORKDIR_SAFETY_GUARD ok agent=agent-codex' "$log"
}

@test "AC#454-9 missing workdir defers to downstream provisioning guards" {
  # A pre-clone slot (no .git yet) must not be classified as dirty —
  # the worktree_create or operator provisioning step is what populates
  # the clone, and forcing this guard to fail there would block fresh
  # fleets from booting.
  ORCH_DISPATCH_WORKDIR_SAFETY_GUARD=enforce

  assert_safety 0 agent-fresh 454 "$BATS_TEST_TMPDIR/never-cloned"

  [ "${DISPATCH_WORKDIR_SAFETY_RESULT}" = "workdir_missing" ]
}
