#!/usr/bin/env bash
# check_rollup_summary.sh — project-agnostic multi-check rollup evaluator (#346).
#
# A GitHub-style PR statusCheckRollup is an array of check entries, each with
# `conclusion`, `status`, `state`, and a name (`name` or `context`). Naive
# summaries that pick `[0]` or call any-success on the array under-report
# multi-check matrices: a PR with `lint=SUCCESS, test(3.11)=CANCELLED,
# test(3.12)=FAILURE` looked like `ci=SUCCESS` to the orchestrator wave-9
# summary, masking failed CI as merge-ready.
#
# This helper is the single source of truth for evaluating any rollup-shaped
# response. It is intentionally GitHub-style (it understands the standard
# `conclusion` / `status` / `state` vocabulary) but never references a
# specific repo, project, or check name. Other providers can call the same
# helper if their adapter normalizes responses to the same field names.
#
# Public API:
#
#   ordo_check_rollup_summary <rollup-json-array>
#     Echoes a JSON object on stdout with:
#       aggregate    : "no_checks" | "pending" | "failed_or_cancelled"
#                    | "success"   | "unknown"
#       total        : number of entries in the rollup
#       failed       : [{name, conclusion}, ...]
#       cancelled    : [{name}, ...]
#       pending      : [{name}, ...]
#       passed       : [{name}, ...]
#
# Aggregate semantics — failed_or_cancelled wins over pending wins over
# success, so any failed/cancelled entry STOPS the rollup from being
# reported as success even when other entries passed. Project-specific
# flaky/main-CI caveats applied elsewhere MUST NOT override this PR-level
# state — see docs/orchestrator-injected-rules.md.

ordo_check_rollup_summary() {
  local rollup=${1:?usage: ordo_check_rollup_summary <rollup-json-array>}
  printf '%s' "$rollup" | jq -c '
    def name_of: (.name // .context // "unknown");
    # Capture the upper-cased fields up front so the array-membership tests
    # below operate on plain strings — see issue #346 reproduction. jq
    # evaluates function arguments against the current input, so a naive
    # `["FAILURE",...] | index(upper(.conclusion))` re-evaluates `.conclusion`
    # against the array literal rather than the rollup entry.
    def normalized: . as $entry | {
      name:       name_of,
      conclusion: (($entry.conclusion // "") | ascii_upcase),
      status:     (($entry.status // "")     | ascii_upcase),
      state:      (($entry.state // "")      | ascii_upcase),
      raw_conclusion: ($entry.conclusion // ""),
      raw_state:      ($entry.state // "")
    };
    def is_failed:
      .conclusion as $c | .state as $s
      | ((["FAILURE","TIMED_OUT","ACTION_REQUIRED","STARTUP_FAILURE"] | index($c)) != null)
        or ((["FAILURE","ERROR"] | index($s)) != null);
    def is_cancelled: (.conclusion == "CANCELLED");
    def is_pending:
      .status as $s1 | .state as $s2
      | ((["QUEUED","IN_PROGRESS","REQUESTED","WAITING","PENDING"] | index($s1)) != null)
        or ((["PENDING","EXPECTED"] | index($s2)) != null);
    def is_passed:
      (.conclusion == "SUCCESS") or (.state == "SUCCESS");
    (. // []) as $raw
    | ([$raw[]? | normalized])                                          as $rollup
    | ([$rollup[] | select(is_failed)
        | {name, conclusion: (.raw_conclusion // .raw_state // "")}])   as $failed
    | ([$rollup[] | select(is_cancelled and (is_failed | not))
        | {name}])                                                      as $cancelled
    | ([$rollup[] | select(is_pending and (is_failed | not) and (is_cancelled | not))
        | {name}])                                                      as $pending
    | ([$rollup[] | select(is_passed and (is_failed | not) and (is_cancelled | not) and (is_pending | not))
        | {name}])                                                      as $passed
    | {
        aggregate: (
          if   ($rollup | length) == 0       then "no_checks"
          elif ($failed | length) > 0
            or ($cancelled | length) > 0     then "failed_or_cancelled"
          elif ($pending | length) > 0       then "pending"
          elif ($passed | length) > 0        then "success"
          else "unknown"
          end
        ),
        total:     ($rollup    | length),
        failed:    $failed,
        cancelled: $cancelled,
        pending:   $pending,
        passed:    $passed
      }
  '
}

ordo_check_rollup_failed_names() {
  # Convenience: print just the failed check names, one per line.
  # Useful for portfolio-level aggregation that wants a flat samples list.
  local rollup=${1:?usage: ordo_check_rollup_failed_names <rollup-json-array>}
  ordo_check_rollup_summary "$rollup" \
    | jq -r '(.failed[]?.name), (.cancelled[]?.name)'
}

ordo_check_rollup_aggregate() {
  # Convenience: print just the aggregate token (no JSON wrapping).
  local rollup=${1:?usage: ordo_check_rollup_aggregate <rollup-json-array>}
  ordo_check_rollup_summary "$rollup" | jq -r '.aggregate'
}
