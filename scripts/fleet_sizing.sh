#!/usr/bin/env bash
# scripts/fleet_sizing.sh - recommend ORDO fleet size from readiness reports.
#
# Usage:
#   fleet_sizing.sh [project|config] [--requested-agents N] [--current-agents N]
#     [--host-report FILE] [--repository-report FILE] [--provider-report FILE]
#     [--repo-root PATH] [--json|--text]

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=../lib/host_assessment.sh
source "$TK/lib/host_assessment.sh"
# shellcheck source=../lib/fleet_sizing.sh
source "$TK/lib/fleet_sizing.sh"

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
}

CFG_ARG=""
if [[ "$#" -gt 0 && "${1:-}" != --* ]]; then
  CFG_ARG=$1
  shift
fi

REQUESTED_AGENTS="${ORDO_FLEET_REQUESTED_AGENTS:-1}"
CURRENT_AGENTS="${ORDO_FLEET_CURRENT_AGENTS:-}"
REPO_ROOT="${ORDO_FLEET_REPO_ROOT:-$PWD}"
HOST_REPORT_FILE=""
REPOSITORY_REPORT_FILE=""
PROVIDER_REPORT_FILE=""
FORMAT="json"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --requested-agents)
      REQUESTED_AGENTS=${2:?missing value for --requested-agents}
      shift
      ;;
    --requested-agents=*) REQUESTED_AGENTS=${1#--requested-agents=} ;;
    --current-agents)
      CURRENT_AGENTS=${2:?missing value for --current-agents}
      shift
      ;;
    --current-agents=*) CURRENT_AGENTS=${1#--current-agents=} ;;
    --repo-root)
      REPO_ROOT=${2:?missing value for --repo-root}
      shift
      ;;
    --repo-root=*) REPO_ROOT=${1#--repo-root=} ;;
    --host-report)
      HOST_REPORT_FILE=${2:?missing value for --host-report}
      shift
      ;;
    --host-report=*) HOST_REPORT_FILE=${1#--host-report=} ;;
    --repository-report)
      REPOSITORY_REPORT_FILE=${2:?missing value for --repository-report}
      shift
      ;;
    --repository-report=*) REPOSITORY_REPORT_FILE=${1#--repository-report=} ;;
    --provider-report)
      PROVIDER_REPORT_FILE=${2:?missing value for --provider-report}
      shift
      ;;
    --provider-report=*) PROVIDER_REPORT_FILE=${1#--provider-report=} ;;
    --json) FORMAT="json" ;;
    --text) FORMAT="text" ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown arg: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

read_json_file() {
  local path=${1:?usage: read_json_file <path>}
  jq -c . "$path"
}

host_report_json() {
  if [[ -n "$HOST_REPORT_FILE" ]]; then
    read_json_file "$HOST_REPORT_FILE"
  elif [[ -n "${ORDO_FLEET_HOST_REPORT_JSON:-}" ]]; then
    jq -c . <<< "$ORDO_FLEET_HOST_REPORT_JSON"
  else
    host_assessment_report_json "$REQUESTED_AGENTS" "$REPO_ROOT"
  fi
}

repository_report_json() {
  if [[ -n "$REPOSITORY_REPORT_FILE" ]]; then
    read_json_file "$REPOSITORY_REPORT_FILE"
  elif [[ -n "${ORDO_FLEET_REPOSITORY_REPORT_JSON:-}" ]]; then
    jq -c . <<< "$ORDO_FLEET_REPOSITORY_REPORT_JSON"
  elif [[ -n "$CFG_ARG" ]]; then
    local output status
    set +e
    output=$(bash "$TK/scripts/repository_platform_readiness.sh" "$CFG_ARG" --json 2>/dev/null)
    status=$?
    set -e
    if jq -e . >/dev/null 2>&1 <<< "$output"; then
      jq -c . <<< "$output"
    else
      jq -nc --arg status "$status" '{
        status:"blocked",
        capabilities:{},
        identity_bindings:[],
        blockers:["repository_platform_report_unusable"],
        detail:{exit_status:($status | tonumber? // null)}
      }'
    fi
  else
    fleet_sizing_missing_repository_report_json
  fi
}

provider_report_json() {
  if [[ -n "$PROVIDER_REPORT_FILE" ]]; then
    read_json_file "$PROVIDER_REPORT_FILE"
  elif [[ -n "${ORDO_FLEET_PROVIDER_REPORT_JSON:-}" ]]; then
    jq -c . <<< "$ORDO_FLEET_PROVIDER_REPORT_JSON"
  else
    fleet_sizing_missing_provider_report_json
  fi
}

host_report=$(host_report_json)
repository_report=$(repository_report_json)
provider_report=$(provider_report_json)
report=$(fleet_sizing_report_json \
  "$REQUESTED_AGENTS" \
  "$CURRENT_AGENTS" \
  "$host_report" \
  "$repository_report" \
  "$provider_report")

case "$FORMAT" in
  json)
    jq . <<< "$report"
    ;;
  text)
    jq -r '
      "Fleet sizing: " + .recommendation.decision,
      "Requested agents: " + (.requested_fleet.agents | tostring),
      "Recommended agents: " + (.recommendation.recommended_agents | tostring),
      "Resize: " + .recommendation.resize.direction,
      "Blockers: " + (if (.recommendation.blockers | length) == 0 then "none" else (.recommendation.blockers | join(",")) end),
      "Bottlenecks: " + (if (.recommendation.bottlenecks | length) == 0 then "none" else (.recommendation.bottlenecks | join(",")) end),
      .recommendation.explanation
    ' <<< "$report"
    ;;
  *)
    printf 'unknown format: %s\n' "$FORMAT" >&2
    exit 2
    ;;
esac
