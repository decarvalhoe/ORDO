#!/usr/bin/env bash
# orch_manual_session.sh — one-shot interactive ORDO checklist.
#
# Usage:
#   bash orch_manual_session.sh <project_short|config_path>
#
# This path is intentionally non-daemonized. It runs the operator-facing
# session-start checks and exits instead of creating a background supervisor.

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CFG_ARG=${1:?usage: orch_manual_session.sh <project_short|config_path>}
shift || true

if [[ $# -gt 0 ]]; then
  echo "unknown arg: $1" >&2
  exit 2
fi

bash "$TK/scripts/audit_state.sh" "$CFG_ARG"
bash "$TK/scripts/project_meta_context.sh" "$CFG_ARG"
bash "$TK/scripts/check_ci_health.sh" "$CFG_ARG"
bash "$TK/scripts/dispatch_plan.sh" "$CFG_ARG" --ready-only
