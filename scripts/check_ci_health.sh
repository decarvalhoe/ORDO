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
#   0 — healthy (no recent failure on default branch)
#   2 — alert (≥1 failed run in lookback window)
#   1 — error (auth, network, invalid config)
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

CFG_ARG=${1:?usage: check_ci_health.sh <project_short|config_path> [look]}
LOOK=${2:-8}
case "$CFG_ARG" in
  wp|realisons-wp)   CFG="$TK/examples/realisons-wp.config.sh" ;;
  nomos)             CFG="$TK/examples/nomos.config.sh" ;;
  rbok)              CFG="$TK/examples/rbok.config.sh" ;;
  42t|42-training)   CFG="$TK/examples/42t.config.sh" ;;
  *)                 CFG="$CFG_ARG" ;;
esac
[ -f "$CFG" ] || { echo "config not found: $CFG" >&2; exit 1; }
source "$CFG"

source "$TK/lib/audit_log.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${DEFAULT_BRANCH:=main}"

audit "CI HEALTH start project=$PROJECT branch=$DEFAULT_BRANCH look=$LOOK"

runs=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh run list \
  --repo "$GH_REPO" \
  --branch "$DEFAULT_BRANCH" \
  --limit "$LOOK" \
  --json databaseId,name,conclusion,status,headSha,createdAt 2>/dev/null || echo "[]")

# Treat anything that completed with non-success as alert, EXCEPT:
#   - skipped/neutral (intentional no-op)
#   - cancelled (GH Actions concurrency dedup or workflow-cancels-prev-runs;
#     when a newer commit lands while an older run is queued, GH cancels
#     the older one — that's not an actionable failure, just deduplication)
# To still catch user-initiated cancellations during incidents, watch the
# audit log instead: this script is the automated gate.
failures=$(printf '%s' "$runs" | jq -r '.[] | select(.status=="completed" and .conclusion!=null and .conclusion!="success" and .conclusion!="skipped" and .conclusion!="neutral" and .conclusion!="cancelled") | "\(.createdAt)\t\(.name)\t\(.conclusion)\t\(.headSha[0:7])\t\(.databaseId)"' 2>/dev/null || true)

if [ -z "$failures" ]; then
  audit "CI HEALTH OK project=$PROJECT branch=$DEFAULT_BRANCH (no recent failures in last $LOOK runs)"
  exit 0
fi

audit "CI HEALTH ALERT — failures on $DEFAULT_BRANCH:"
while IFS=$'\t' read -r ts name conclusion sha run; do
  audit "  $ts $name [$conclusion] sha=$sha run=$run"
done <<<"$failures"
exit 2
