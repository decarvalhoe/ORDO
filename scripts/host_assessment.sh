#!/usr/bin/env bash
# scripts/host_assessment.sh - emit structured host capability recommendations.
#
# Usage:
#   host_assessment.sh [--requested-agents N] [--repo-root PATH] [--json|--text]
#   host_assessment.sh --require-terminal-multiplexer [--multiplexer-cmd CMD]

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=../lib/host_assessment.sh
source "$TK/lib/host_assessment.sh"

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
}

REQUESTED_AGENTS="${ORDO_HOST_ASSESSMENT_REQUESTED_AGENTS:-1}"
REPO_ROOT="${ORDO_HOST_ASSESSMENT_REPO_ROOT:-$PWD}"
FORMAT="json"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --requested-agents)
      REQUESTED_AGENTS=${2:?missing value for --requested-agents}
      shift
      ;;
    --requested-agents=*) REQUESTED_AGENTS=${1#--requested-agents=} ;;
    --repo-root)
      REPO_ROOT=${2:?missing value for --repo-root}
      shift
      ;;
    --repo-root=*) REPO_ROOT=${1#--repo-root=} ;;
    --json) FORMAT="json" ;;
    --text) FORMAT="text" ;;
    --require-terminal-multiplexer)
      ORDO_HOST_ASSESSMENT_MULTIPLEXER_REQUIRED=1
      export ORDO_HOST_ASSESSMENT_MULTIPLEXER_REQUIRED
      ;;
    --multiplexer-cmd)
      ORDO_HOST_ASSESSMENT_MULTIPLEXER_CMD=${2:?missing value for --multiplexer-cmd}
      export ORDO_HOST_ASSESSMENT_MULTIPLEXER_CMD
      shift
      ;;
    --multiplexer-cmd=*)
      ORDO_HOST_ASSESSMENT_MULTIPLEXER_CMD=${1#--multiplexer-cmd=}
      export ORDO_HOST_ASSESSMENT_MULTIPLEXER_CMD
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

report=$(host_assessment_report_json "$REQUESTED_AGENTS" "$REPO_ROOT")

case "$FORMAT" in
  json)
    jq . <<< "$report"
    ;;
  text)
    jq -r '
      "Host assessment: " + .environment_recommendation.suitability,
      "Recommendation: " + .environment_recommendation.decision,
      "Requested agents: " + (.requested_fleet.agents | tostring),
      "Estimated agents: " + (.capacity.estimated_agents // "unknown" | tostring),
      "Bottlenecks: " + (if (.environment_recommendation.bottlenecks | length) == 0 then "none" else (.environment_recommendation.bottlenecks | join(",")) end),
      .environment_recommendation.explanation
    ' <<< "$report"
    ;;
  *)
    echo "unknown format: $FORMAT" >&2
    exit 2
    ;;
esac
