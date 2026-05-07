#!/usr/bin/env bash
# scripts/check_ci_health.sh — pre-action gate. Refuses to dispatch when
# the default branch is RED.
# Usage: check_ci_health.sh <project_short|config_path> [look=8]
#
# Surviving log signatures:
#   CI HEALTH start project=<id> branch=<branch> look=<N>
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

audit "CI HEALTH start project=$PROJECT branch=$DEFAULT_BRANCH look=$LOOK"

runs=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh run list \
  --repo "$GH_REPO" \
  --branch "$DEFAULT_BRANCH" \
  --limit "$LOOK" \
  --json databaseId,name,conclusion,status,headSha,createdAt 2>/dev/null || echo "[]")

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
          (.databaseId | tostring)
        ]
      | @tsv
    )' 2>/dev/null || true)

warnings=
pending=
failures=

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
        failures+="$col1"$'\t'"$col2"$'\t'"$col3"$'\t'"$col4"$'\t'"$col5"$'\n'
        ;;
    esac
  done <<<"$signals"
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

if [ -z "$failures" ]; then
  audit "CI HEALTH OK project=$PROJECT branch=$DEFAULT_BRANCH (no latest workflow failures in last $LOOK runs)"
  exit 0
fi

audit "CI HEALTH ALERT — failures on $DEFAULT_BRANCH:"
while IFS=$'\t' read -r ts name conclusion sha run; do
  audit "  $ts $name [$conclusion] sha=$sha run=$run"
done <<<"$failures"
exit 2
