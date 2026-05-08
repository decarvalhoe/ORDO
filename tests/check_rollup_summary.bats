#!/usr/bin/env bats
# tests/check_rollup_summary.bats — multi-check rollup evaluation (#346).
#
# Regression coverage for the Wave-9 portfolio summary bug: a PR with
# `lint=SUCCESS, test (3.11)=CANCELLED, test (3.12)=FAILURE` was reported
# as `ci=SUCCESS, merge=UNSTABLE` because a naive summary picked
# `statusCheckRollup[0].conclusion`. The new
# `lib/check_rollup_summary.sh::ordo_check_rollup_summary` helper is the
# project-agnostic source of truth: any failed or cancelled entry STOPS
# the aggregate from being reported as success.
#
# Fixtures cover:
#   - the exact issue #346 fixture (lint ok + 3.11 cancelled + 3.12 failure);
#   - all-success rollup;
#   - pending-only rollup;
#   - empty rollup;
#   - cancelled-only rollup;
#   - state-driven entries (no conclusion field, only state);
#   - case-insensitive normalization;
#   - failed/cancelled name surfacing.

load './helpers.bash'

setup() {
  setup_orch_test
  # shellcheck disable=SC1090
  source "$TK/lib/check_rollup_summary.sh"
}

@test "issue #346 fixture: lint=success + test(3.11)=cancelled + test(3.12)=failure -> failed_or_cancelled" {
  rollup='[{"name":"lint","status":"COMPLETED","conclusion":"SUCCESS"},
           {"name":"test (3.11)","status":"COMPLETED","conclusion":"CANCELLED"},
           {"name":"test (3.12)","status":"COMPLETED","conclusion":"FAILURE"}]'
  result=$(ordo_check_rollup_summary "$rollup")

  aggregate=$(printf '%s' "$result" | jq -r '.aggregate')
  total=$(printf '%s' "$result" | jq -r '.total')
  failed_names=$(printf '%s' "$result" | jq -r '.failed[].name' | sort)
  cancelled_names=$(printf '%s' "$result" | jq -r '.cancelled[].name')
  passed_names=$(printf '%s' "$result" | jq -r '.passed[].name')

  [ "$aggregate" = "failed_or_cancelled" ]
  [ "$total" = "3" ]
  [ "$failed_names" = "test (3.12)" ]
  [ "$cancelled_names" = "test (3.11)" ]
  [ "$passed_names" = "lint" ]
}

@test "all-success rollup -> success" {
  rollup='[{"name":"lint","conclusion":"SUCCESS"},{"name":"test","conclusion":"SUCCESS"}]'
  [ "$(ordo_check_rollup_aggregate "$rollup")" = "success" ]
}

@test "pending-only rollup -> pending" {
  rollup='[{"name":"lint","status":"IN_PROGRESS"},{"name":"test","status":"QUEUED"}]'
  [ "$(ordo_check_rollup_aggregate "$rollup")" = "pending" ]
}

@test "empty rollup -> no_checks" {
  [ "$(ordo_check_rollup_aggregate '[]')" = "no_checks" ]
}

@test "cancelled-only rollup -> failed_or_cancelled" {
  rollup='[{"name":"test (3.11)","conclusion":"CANCELLED"}]'
  [ "$(ordo_check_rollup_aggregate "$rollup")" = "failed_or_cancelled" ]
}

@test "state-driven entries (commit status API shape) classify correctly" {
  # Some providers populate `state` instead of `conclusion`. Mix both shapes.
  rollup='[{"context":"ci/lint","state":"SUCCESS"},
           {"context":"ci/security","state":"FAILURE"}]'
  result=$(ordo_check_rollup_summary "$rollup")
  aggregate=$(printf '%s' "$result" | jq -r '.aggregate')
  failed_names=$(printf '%s' "$result" | jq -r '.failed[].name')
  [ "$aggregate" = "failed_or_cancelled" ]
  [ "$failed_names" = "ci/security" ]
}

@test "case-insensitive normalization handles lowercase conclusions" {
  rollup='[{"name":"lint","conclusion":"success"},{"name":"test","conclusion":"failure"}]'
  [ "$(ordo_check_rollup_aggregate "$rollup")" = "failed_or_cancelled" ]
}

@test "ordo_check_rollup_failed_names emits failed and cancelled names" {
  rollup='[{"name":"lint","conclusion":"SUCCESS"},
           {"name":"test (3.11)","conclusion":"CANCELLED"},
           {"name":"test (3.12)","conclusion":"FAILURE"}]'
  names=$(ordo_check_rollup_failed_names "$rollup" | sort | paste -sd, -)
  [ "$names" = "test (3.11),test (3.12)" ]
}

@test "checks without name fall back to context, then to 'unknown'" {
  rollup='[{"context":"deploy/staging","conclusion":"FAILURE"},
           {"conclusion":"FAILURE"}]'
  result=$(ordo_check_rollup_summary "$rollup")
  failed_names=$(printf '%s' "$result" | jq -r '.failed[].name' | sort)
  expected=$(printf 'deploy/staging\nunknown\n' | sort)
  [ "$failed_names" = "$expected" ]
}

@test "TIMED_OUT, ACTION_REQUIRED, STARTUP_FAILURE all classify as failed_or_cancelled" {
  for conclusion in TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE; do
    rollup='[{"name":"lint","conclusion":"SUCCESS"},
             {"name":"matrix","conclusion":"'"$conclusion"'"}]'
    aggregate=$(ordo_check_rollup_aggregate "$rollup")
    [ "$aggregate" = "failed_or_cancelled" ] \
      || { echo "expected failed_or_cancelled for $conclusion, got $aggregate"; return 1; }
  done
}

@test "regression: a single failed entry beats many successful ones (#346)" {
  # Stress the wave-9 bug pattern with many passes and one failure: the
  # naive `statusCheckRollup[0].conclusion` summary would say SUCCESS;
  # the correct aggregate is failed_or_cancelled.
  entries=()
  for i in $(seq 1 20); do
    entries+=("{\"name\":\"pass-${i}\",\"conclusion\":\"SUCCESS\"}")
  done
  entries+=("{\"name\":\"matrix-fail\",\"conclusion\":\"FAILURE\"}")
  rollup="[$(IFS=,; printf '%s' "${entries[*]}")]"

  aggregate=$(ordo_check_rollup_aggregate "$rollup")
  failed=$(ordo_check_rollup_failed_names "$rollup")
  passed_count=$(ordo_check_rollup_summary "$rollup" | jq -r '.passed | length')

  [ "$aggregate" = "failed_or_cancelled" ]
  [ "$failed" = "matrix-fail" ]
  [ "$passed_count" = "20" ]
}

@test "summary is project-agnostic: no project, repo, or vendor name leaks into output" {
  rollup='[{"name":"lint","conclusion":"SUCCESS"}]'
  result=$(ordo_check_rollup_summary "$rollup")
  ! grep -qi 'praxis\|rbok\|ordo\|nomos\|lumen\|github\|claude\|codex' <<< "$result"
}
