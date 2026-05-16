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

# Surface ORDO self-checkout state before the dispatch/audit sequence so a
# behind, diverged, or dirty toolkit cannot silently re-issue stale rules.
# The guard is intentional: callers that ship only orch_manual_session.sh
# (e.g. its dedicated test fixture) keep working without dragging in the
# preflight dependency.
if [[ -f "$TK/scripts/orch_self_checkout_preflight.sh" ]]; then
  bash "$TK/scripts/orch_self_checkout_preflight.sh" "$CFG_ARG"
fi

bash "$TK/scripts/audit_state.sh" "$CFG_ARG"
bash "$TK/scripts/project_meta_context.sh" "$CFG_ARG"
bash "$TK/scripts/check_ci_health.sh" "$CFG_ARG"
bash "$TK/scripts/dispatch_plan.sh" "$CFG_ARG" --ready-only
