#!/usr/bin/env bash
# scripts/check_ci_health.sh — pre-action gate. Refuses to dispatch when
# the default branch is RED.
# Usage: check_ci_health.sh <project_short|config_path> [look=8]
#
# Surviving log signatures:
#   CI HEALTH start project=<id> branch=<branch> look=<N>
#   CI HEALTH FINDING - successful workflow warnings on <branch>:
#     <ts> <name>/<job> [<level>] sha=<sha> run=<run> location=<path:line> message=<message>
#   CI HEALTH PREJOB - failures before job creation on <branch>:
#     <ts> <name> [<conclusion>] sha=<sha> run=<run> workflow=<workflow> event=<event> jobs=0
#   CI HEALTH METADATA_DRIFT - path-like workflow metadata on <branch>:
#     <ts> <name> [<conclusion>] sha=<sha> run=<run> workflow=<workflow> event=<event>
#   CI HEALTH ALERT — failures on <branch>:
#     <ts> <name> [<conclusion>] sha=<sha> run=<run>
# Exit codes:
#   0 — healthy or pending (no latest workflow failure on default branch)
#   2 — alert (≥1 latest workflow failure in lookback window)
#   1 — error (auth, network, invalid config)
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TK/lib/config_resolver.sh"

CFG_ARG=${1:?usage: check_ci_health.sh <project_short|config_path> [look]}
LOOK=${2:-8}
load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${DEFAULT_BRANCH:=main}"
: "${CI_HEALTH_WARNING_SCAN:=1}"
: "${CI_HEALTH_WARNING_SCAN_LIMIT:=4}"
: "${CI_HEALTH_WARNING_LEVELS:=warning}"
: "${CI_HEALTH_WARNING_MESSAGE_MAX:=500}"
: "${CI_HEALTH_WORKFLOW_METADATA_PATH_PATTERN:=^\\.github/workflows/[^[:space:]]+\\.ya?ml$}"
: "${CI_HEALTH_DEPLOY_WORKFLOW_NAME:=Deploy DEV}"
: "${CI_HEALTH_DEPLOY_GATE_WORKFLOW_NAME:=Deploy Health Gate}"

audit "CI HEALTH start project=$PROJECT branch=$DEFAULT_BRANCH look=$LOOK"

ci_health_enabled() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

ci_health_uint_or_default() {
  local value=${1:-} fallback=${2:?}
  case "$value" in
    ''|*[!0-9]*) printf '%s' "$fallback" ;;
    *) printf '%s' "$value" ;;
  esac
}

ci_health_successful_run_warning_rows() {
  local runs_json=${1:-}
  local scan_limit message_max success_runs rows="" jobs annotations
  scan_limit=$(ci_health_uint_or_default "$CI_HEALTH_WARNING_SCAN_LIMIT" 4)
  message_max=$(ci_health_uint_or_default "$CI_HEALTH_WARNING_MESSAGE_MAX" 500)

  [ "$scan_limit" -gt 0 ] || return 0

  success_runs=$(printf '%s' "$runs_json" | jq -r --argjson limit "$scan_limit" '
    def short_sha:
      (.headSha // "")[0:7];

    sort_by(.name, .createdAt, .databaseId)
    | group_by(.name)
    | map(last)
    | map(select(.status == "completed" and .conclusion == "success"))
    | sort_by(.createdAt, .databaseId)
    | reverse
    | .[:$limit]
    | .[]
    | [
        (.databaseId | tostring),
        .createdAt,
        .name,
        short_sha
      ]
    | @tsv
  ' 2>/dev/null || true)

  [ -n "$success_runs" ] || return 0

  while IFS=$'\t' read -r run_id run_ts run_name run_sha; do
    [ -n "$run_id" ] || continue
    jobs=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh run view "$run_id" --repo "$GH_REPO" --json jobs 2>/dev/null \
      | jq -r '
          .jobs[]?
          | select((.status // "") == "completed")
          | [
              (.databaseId | tostring),
              (.name // "")
            ]
          | @tsv
        ' 2>/dev/null || true)
    [ -n "$jobs" ] || continue

    while IFS=$'\t' read -r job_id job_name; do
      [ -n "$job_id" ] || continue
      annotations=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh api "repos/${GH_REPO}/check-runs/${job_id}/annotations" --paginate --slurp 2>/dev/null \
        | jq -r --arg levels "$CI_HEALTH_WARNING_LEVELS" --argjson message_max "$message_max" '
            def annotation_items:
              if type == "array" and ((.[0]? | type) == "array") then .[]?[]? else .[]? end;
            def wanted_level:
              ($levels | split(",") | map(gsub("^ +| +$"; "") | ascii_downcase)) as $wanted
              | ((.annotation_level // "") | ascii_downcase) as $level
              | ($wanted | index($level));
            def clean:
              tostring
              | gsub("[\r\n\t]+"; " ")
              | gsub("  +"; " ")
              | .[0:$message_max];
            def nonempty:
              if length > 0 then . else "-" end;

            annotation_items
            | select(wanted_level)
            | [
                ((.annotation_level // "warning") | clean | nonempty),
                ((.path // "") | clean | nonempty),
                ((.start_line // .end_line // "") | tostring | nonempty),
                ((.title // "") | clean | nonempty),
                ((.message // "") | clean | nonempty)
              ]
            | @tsv
          ' 2>/dev/null || true)
      [ -n "$annotations" ] || continue

      while IFS=$'\t' read -r level path line title message; do
        [ -n "$level$message$title$path" ] || continue
        rows+="$run_ts"$'\t'"$run_name"$'\t'"$run_sha"$'\t'"$run_id"$'\t'"$job_name"$'\t'"$level"$'\t'"$path"$'\t'"$line"$'\t'"$title"$'\t'"$message"$'\n'
      done <<<"$annotations"
    done <<<"$jobs"
  done <<<"$success_runs"

  printf '%s' "$rows"
}

ci_health_run_job_count() {
  local run_id=${1:?usage: ci_health_run_job_count <run-id>}
  local run_json

  if ! run_json=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh run view "$run_id" --repo "$GH_REPO" --json jobs 2>/dev/null); then
    printf 'unknown'
    return 0
  fi

  printf '%s' "$run_json" | jq -r '[.jobs[]?] | length' 2>/dev/null || printf 'unknown'
}

ci_health_sha_matches() {
  local left=${1,,} right=${2,,}

  [ -n "$left" ] && [ -n "$right" ] || return 1
  case "$left" in
    "$right"*) return 0 ;;
  esac
  case "$right" in
    "$left"*) return 0 ;;
  esac
  return 1
}

ci_health_deploy_gate_payload_context() {
  local run_id=${1:?usage: ci_health_deploy_gate_payload_context <run-id>}
  local logs line scan sha="" deploy_run=""

  logs=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh run view "$run_id" --repo "$GH_REPO" --log 2>/dev/null || true)
  [ -n "$logs" ] || return 0

  while IFS= read -r line; do
    scan=" ${line,,} "
    case "$scan" in
      *"deploy gate"*) ;;
      *) continue ;;
    esac

    if [[ -z "$sha" && $scan =~ (payload[-_[:space:]]*sha|deploy[-_[:space:]]*sha|head[-_[:space:]]*sha|sha)[=:[:space:]]+([0-9a-f]{7,40}) ]]; then
      sha=${BASH_REMATCH[2]}
    fi
    if [[ -z "$deploy_run" && $scan =~ (payload[-_[:space:]]*run|deploy[-_[:space:]]*run|run[-_[:space:]]*id|run)[=:[:space:]]+([0-9]+) ]]; then
      deploy_run=${BASH_REMATCH[2]}
    fi
    if [[ -z "$sha" && $scan =~ [^0-9a-f]([0-9a-f]{7,40})[^0-9a-f] ]]; then
      sha=${BASH_REMATCH[1]}
    fi
  done <<<"$logs"

  [ -n "$sha" ] || return 0
  printf '%s\t%s\n' "$sha" "$deploy_run"
}

ci_health_latest_deploy_signal() {
  printf '%s' "$runs" | jq -r --arg workflow_name "$CI_HEALTH_DEPLOY_WORKFLOW_NAME" '
    map(select((.name // "") == $workflow_name or (.workflowName // "") == $workflow_name))
    | sort_by(.createdAt, .databaseId)
    | last // empty
    | select(. != null)
    | [
        (.createdAt // ""),
        (.status // ""),
        (.conclusion // "-"),
        (.headSha // ""),
        (.databaseId | tostring),
        (.url // "-")
      ]
    | @tsv
  ' 2>/dev/null || true
}

ci_health_stale_deploy_gate_warning() {
  local ts=${1:-} name=${2:-} conclusion=${3:-} sha=${4:-} run=${5:-}
  local workflow=${6:-} event=${7:-} url=${8:-}
  local payload latest payload_sha payload_run latest_ts latest_status latest_conclusion latest_sha latest_run latest_url relation

  [ "$event" = "workflow_run" ] || return 0
  [ "$name" = "$CI_HEALTH_DEPLOY_GATE_WORKFLOW_NAME" ] || [ "$workflow" = "$CI_HEALTH_DEPLOY_GATE_WORKFLOW_NAME" ] || return 0
  [ -n "$run" ] || return 0

  payload=$(ci_health_deploy_gate_payload_context "$run")
  [ -n "$payload" ] || return 0
  IFS=$'\t' read -r payload_sha payload_run <<<"$payload"
  [ -n "$payload_sha" ] || return 0

  latest=$(ci_health_latest_deploy_signal)
  [ -n "$latest" ] || return 0
  IFS=$'\t' read -r latest_ts latest_status latest_conclusion latest_sha latest_run latest_url <<<"$latest"
  [ -n "$latest_sha" ] || return 0

  ci_health_sha_matches "$payload_sha" "$latest_sha" && return 0

  case "$latest_status:$latest_conclusion" in
    completed:success) relation="stale-payload-superseded" ;;
    completed:*) return 0 ;;
    *) relation="stale-payload-superseded-by-pending" ;;
  esac

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$name" "$conclusion" "${payload_sha:0:7}" "$run" "$relation" \
    "$latest_ts" "$latest_status" "${latest_conclusion:-"-"}" "${latest_sha:0:7}" "$latest_run"
}

runs=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh run list \
  --repo "$GH_REPO" \
  --branch "$DEFAULT_BRANCH" \
  --limit "$LOOK" \
  --json databaseId,name,workflowName,workflowDatabaseId,conclusion,status,headSha,createdAt,event,url 2>/dev/null || echo "[]")

# Evaluate only the newest run per workflow name. Historical failures or
# cancellations that have a newer signal are downgraded to warnings so the
# gate reflects the latest branch state instead of stale noise.
signals=$(printf '%s' "$runs" | jq -r '
  def ignored_conclusion:
    . as $conclusion
    | ["success", "skipped", "neutral", "cancelled"]
    | index($conclusion);
  def is_failure:
    .status == "completed"
    and .conclusion != null
    and (.conclusion | ignored_conclusion | not);
  def short_sha:
    (.headSha // "")[0:7];

  sort_by(.name, .createdAt, .databaseId)
  | group_by(.name)
  | map({latest: (last), history: .[0:-1]})
  | .[] as $group
  | (
      $group.history[]?
      | select((is_failure or .conclusion == "cancelled") and ($group.latest | is_failure | not))
      | [
          "WARN",
          .createdAt,
          .name,
          (.conclusion // "-"),
          short_sha,
          (.databaseId | tostring),
          (
            if $group.latest.status != "completed" then "superseded-by-pending"
            elif $group.latest.conclusion == "success" then "healed"
            else "superseded"
            end
          ),
          $group.latest.createdAt,
          $group.latest.status,
          ($group.latest.conclusion // "-"),
          (($group.latest.headSha // "")[0:7]),
          ($group.latest.databaseId | tostring)
        ]
      | @tsv
    ),
    (
      $group.latest
      | select(.status != "completed")
      | [
          "PENDING",
          .createdAt,
          .name,
          .status,
          short_sha,
          (.databaseId | tostring)
        ]
      | @tsv
    ),
    (
      $group.latest
      | select(is_failure)
      | [
          "FAIL",
          .createdAt,
          .name,
          .conclusion,
          short_sha,
          (.databaseId | tostring),
          (.workflowName // .name // "-"),
          (.event // "-"),
          (.url // "-")
        ]
      | @tsv
    )' 2>/dev/null || true)

warnings=
pending=
failures=
normal_failures=
prejob_failures=
metadata_drifts=
green_warnings=
green_warning_count=0
prejob_failure_count=0
metadata_drift_count=0

if [ -n "$signals" ]; then
  while IFS=$'\t' read -r kind col1 col2 col3 col4 col5 col6 col7 col8 col9 col10 col11; do
    case "$kind" in
      WARN)
        warnings+="$col1"$'\t'"$col2"$'\t'"$col3"$'\t'"$col4"$'\t'"$col5"$'\t'"$col6"$'\t'"$col7"$'\t'"$col8"$'\t'"$col9"$'\t'"$col10"$'\t'"$col11"$'\n'
        ;;
      PENDING)
        pending+="$col1"$'\t'"$col2"$'\t'"$col3"$'\t'"$col4"$'\t'"$col5"$'\n'
        ;;
      FAIL)
        stale_payload_warning=$(ci_health_stale_deploy_gate_warning "$col1" "$col2" "$col3" "$col4" "$col5" "$col6" "$col7" "$col8")
        if [ -n "$stale_payload_warning" ]; then
          warnings+="$stale_payload_warning"$'\n'
        else
          failures+="$col1"$'\t'"$col2"$'\t'"$col3"$'\t'"$col4"$'\t'"$col5"$'\t'"$col6"$'\t'"$col7"$'\t'"$col8"$'\n'
        fi
        ;;
    esac
  done <<<"$signals"
fi

if [ -n "$failures" ]; then
  while IFS=$'\t' read -r ts name conclusion sha run workflow event url; do
    [ -n "$run" ] || continue
    job_count=$(ci_health_run_job_count "$run")
    if [ "$job_count" = "0" ]; then
      prejob_failures+="$ts"$'\t'"$name"$'\t'"$conclusion"$'\t'"$sha"$'\t'"$run"$'\t'"$workflow"$'\t'"$event"$'\t'"$url"$'\n'
      prejob_failure_count=$((prejob_failure_count + 1))
      if printf '%s\n%s\n' "$workflow" "$name" | grep -Eq "$CI_HEALTH_WORKFLOW_METADATA_PATH_PATTERN"; then
        metadata_drifts+="$ts"$'\t'"$name"$'\t'"$conclusion"$'\t'"$sha"$'\t'"$run"$'\t'"$workflow"$'\t'"$event"$'\t'"$url"$'\n'
        metadata_drift_count=$((metadata_drift_count + 1))
      fi
    else
      normal_failures+="$ts"$'\t'"$name"$'\t'"$conclusion"$'\t'"$sha"$'\t'"$run"$'\t'"$workflow"$'\t'"$event"$'\t'"$url"$'\n'
    fi
  done <<<"$failures"
fi

if ci_health_enabled "$CI_HEALTH_WARNING_SCAN"; then
  green_warnings=$(ci_health_successful_run_warning_rows "$runs")
fi

if [ -n "$warnings" ]; then
  audit "CI HEALTH WARN — superseded historical signals on $DEFAULT_BRANCH:"
  while IFS=$'\t' read -r ts name conclusion sha run relation latest_ts latest_status latest_conclusion latest_sha latest_run; do
    audit "  $ts $name [$conclusion] sha=$sha run=$run relation=$relation latest=$latest_ts [$latest_status/$latest_conclusion] sha=$latest_sha run=$latest_run"
  done <<<"$warnings"
fi

if [ -n "$pending" ]; then
  audit "CI HEALTH PENDING — latest workflow signals still running on $DEFAULT_BRANCH:"
  while IFS=$'\t' read -r ts name status sha run; do
    audit "  $ts $name [$status] sha=$sha run=$run"
  done <<<"$pending"
fi

if [ -n "$green_warnings" ]; then
  audit "CI HEALTH FINDING - successful workflow warnings on $DEFAULT_BRANCH:"
  while IFS=$'\t' read -r ts name sha run job level path line title message; do
    location=${path:-unknown}
    [ "$location" = "-" ] && location="unknown"
    if [ -n "$line" ] && [ "$line" != "-" ]; then
      location="${location}:${line}"
    fi
    detail=$message
    if [ -n "$title" ] && [ "$title" != "-" ]; then
      detail="${title} - ${detail}"
    fi
    green_warning_count=$((green_warning_count + 1))
    audit "  $ts $name/$job [$level] sha=$sha run=$run location=$location message=$detail"
  done <<<"$green_warnings"
fi

if [ -n "$prejob_failures" ]; then
  audit "CI HEALTH PREJOB - failures before job creation on $DEFAULT_BRANCH:"
  while IFS=$'\t' read -r ts name conclusion sha run workflow event url; do
    audit "  $ts $name [$conclusion] sha=$sha run=$run workflow=$workflow event=$event jobs=0 url=$url"
  done <<<"$prejob_failures"
fi

if [ -n "$metadata_drifts" ]; then
  audit "CI HEALTH METADATA_DRIFT - path-like workflow metadata on $DEFAULT_BRANCH:"
  while IFS=$'\t' read -r ts name conclusion sha run workflow event url; do
    audit "  $ts $name [$conclusion] sha=$sha run=$run workflow=$workflow event=$event url=$url"
  done <<<"$metadata_drifts"
fi

if [ -z "$normal_failures$prejob_failures" ]; then
  audit "CI HEALTH OK project=$PROJECT branch=$DEFAULT_BRANCH (no latest workflow failures in last $LOOK runs; successful_run_warnings=$green_warning_count prejob_failures=0 metadata_drifts=0)"
  exit 0
fi

if [ -n "$normal_failures" ]; then
  audit "CI HEALTH ALERT — failures on $DEFAULT_BRANCH:"
  while IFS=$'\t' read -r ts name conclusion sha run workflow event url; do
    audit "  $ts $name [$conclusion] sha=$sha run=$run workflow=$workflow event=$event url=$url"
  done <<<"$normal_failures"
fi

audit "CI HEALTH SUMMARY project=$PROJECT branch=$DEFAULT_BRANCH status=alert normal_failures=$(printf '%s' "$normal_failures" | grep -c . || true) prejob_failures=$prejob_failure_count metadata_drifts=$metadata_drift_count successful_run_warnings=$green_warning_count"
exit 2
