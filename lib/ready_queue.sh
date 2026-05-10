#!/usr/bin/env bash
# ready_queue.sh - shared dispatch_plan --ready-only queue helpers.

ordo_ready_queue_toolkit_root() {
  if [[ -n "${TK:-}" ]]; then
    printf '%s\n' "$TK"
    return 0
  fi
  (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
}

ordo_ready_queue_json() {
  local cfg=${1:?usage: ordo_ready_queue_json <project-config>}
  local timeout=${ORDO_READY_QUEUE_TIMEOUT_SEC:-30}
  local toolkit_root
  toolkit_root=$(ordo_ready_queue_toolkit_root)

  if declare -F orch_run_timeout >/dev/null 2>&1 && [[ "$timeout" =~ ^[0-9]+$ ]] && [[ "$timeout" -gt 0 ]]; then
    orch_run_timeout "$timeout" bash "$toolkit_root/scripts/dispatch_plan.sh" "$cfg" --ready-only --json
  else
    bash "$toolkit_root/scripts/dispatch_plan.sh" "$cfg" --ready-only --json
  fi
}

ordo_ready_queue_count() {
  local cfg=${1:?usage: ordo_ready_queue_count <project-config>}
  local plan_json
  plan_json=$(ordo_ready_queue_json "$cfg") || return $?

  printf '%s' "$plan_json" | python3 -c '
import json
import sys

try:
    payload = json.loads(sys.stdin.read() or "[]")
except json.JSONDecodeError:
    sys.exit(1)

if not isinstance(payload, list):
    sys.exit(1)

print(len(payload))
'
}
