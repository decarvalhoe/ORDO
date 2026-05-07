#!/usr/bin/env bash
# scripts/host_load_gate.sh - standalone entry point for the host pressure gate.
#
# Usage:
#   host_load_gate.sh [--context NAME] [--mode off|warn|refuse]
#
# The CLI enables the gate by default so it can be used directly as a preflight.
# Library callers remain opt-in unless ORCH_HOST_LOAD_GATE=1 or a non-off mode
# is configured.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../lib/host_load_gate.sh
source "$TK/lib/host_load_gate.sh"

CONTEXT="host"
MODE="${ORCH_HOST_GATE_MODE:-refuse}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --context)
      CONTEXT=${2:?missing value for --context}
      shift
      ;;
    --context=*) CONTEXT=${1#--context=} ;;
    --mode)
      MODE=${2:?missing value for --mode}
      shift
      ;;
    --mode=*) MODE=${1#--mode=} ;;
    -h|--help)
      sed -n '1,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

ORCH_HOST_LOAD_GATE="${ORCH_HOST_LOAD_GATE:-1}"
orch_host_load_gate "$CONTEXT" "$MODE"
