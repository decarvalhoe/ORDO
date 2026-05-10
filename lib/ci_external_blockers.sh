#!/usr/bin/env bash
# Helpers for CI failures that are external to the worktree, such as
# GitHub Actions billing/spending-limit job-start failures.

: "${CI_EXTERNAL_BLOCKER_ANNOTATION_PATTERN:=job (was )?not started|recent account payments (have )?failed|spending limit (needs to be increased|has been reached|exceeded)|billing}"
: "${CI_EXTERNAL_BLOCKER_MESSAGE_MAX:=500}"

ci_external_blocker_uint_or_default() {
  local value=${1:-} fallback=${2:?}
  case "$value" in
    ''|*[!0-9]*) printf '%s' "$fallback" ;;
    *) printf '%s' "$value" ;;
  esac
}

ci_external_blocker_annotation_rows() {
  local repo=${1:?usage: ci_external_blocker_annotation_rows <repo> <check-run-id>}
  local check_run_id=${2:?usage: ci_external_blocker_annotation_rows <repo> <check-run-id>}
  local message_max

  message_max=$(ci_external_blocker_uint_or_default "$CI_EXTERNAL_BLOCKER_MESSAGE_MAX" 500)

  GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" gh api "repos/${repo}/check-runs/${check_run_id}/annotations" --paginate --slurp 2>/dev/null \
    | jq -r --arg pattern "$CI_EXTERNAL_BLOCKER_ANNOTATION_PATTERN" --argjson message_max "$message_max" '
        def annotation_items:
          if type == "array" and ((.[0]? | type) == "array") then .[]?[]? else .[]? end;
        def clean:
          tostring
          | gsub("[\r\n\t]+"; " ")
          | gsub("  +"; " ")
          | .[0:$message_max];
        def nonempty:
          if length > 0 then . else "-" end;

        annotation_items
        | ((.title // "") + " " + (.message // "")) as $text
        | select($text | test($pattern; "i"))
        | [
            ((.annotation_level // "failure") | clean | nonempty),
            "github_actions_billing_job_start",
            ((.title // "") | clean | nonempty),
            ((.message // "") | clean | nonempty)
          ]
        | @tsv
      ' 2>/dev/null || true
}

ci_external_blocker_run_rows() {
  local repo=${1:?usage: ci_external_blocker_run_rows <repo> <run-id>}
  local run_id=${2:?usage: ci_external_blocker_run_rows <repo> <run-id>}
  local jobs job_id job_name annotations level reason title message rows=""

  jobs=$(GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" gh run view "$run_id" --repo "$repo" --json jobs 2>/dev/null \
    | jq -r '
        .jobs[]?
        | select((.conclusion // "") as $c | ["failure","timed_out","cancelled","startup_failure","action_required"] | index($c))
        | [
            (.databaseId | tostring),
            (.name // "")
          ]
        | @tsv
      ' 2>/dev/null || true)
  [ -n "$jobs" ] || return 0

  while IFS=$'\t' read -r job_id job_name; do
    [ -n "$job_id" ] || continue
    annotations=$(ci_external_blocker_annotation_rows "$repo" "$job_id")
    [ -n "$annotations" ] || continue
    while IFS=$'\t' read -r level reason title message; do
      [ -n "$reason" ] || continue
      rows+="$job_id"$'\t'"$job_name"$'\t'"$level"$'\t'"$reason"$'\t'"$title"$'\t'"$message"$'\n'
    done <<< "$annotations"
  done <<< "$jobs"

  printf '%s' "$rows"
}
