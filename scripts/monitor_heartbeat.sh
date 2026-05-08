#!/usr/bin/env bash
# scripts/monitor_heartbeat.sh — orchestrator monitor-loop heartbeat (#339).
#
# Usage:
#   monitor_heartbeat.sh <project_short|config_path> [--dry-run]
#
# Take a snapshot of the orchestrator's "what's in flight vs what's
# queued" state, classify it against the previous snapshot, decide an
# action, and emit a structured audit line. The decision keyword is
# echoed on stdout so callers (the orch loop, an operator script, a
# CI smoke job) can branch on it without parsing audit logs.
#
# Decision keywords:
#   advance_queue          — the run-now flag should be set so the loop
#                            advances queued work on the next cycle.
#   block_stale_at_prompt  — the loop has been parked at the prompt with
#                            all in-flight PRs clean and queued work
#                            still untouched; surface a structured blocker.
#   noop                   — nothing to do (no state change, or no queue
#                            pressure).
#
# Data sources (all overridable via env so tests stay offline):
#   ORCH_MONITOR_HEARTBEAT_IN_FLIGHT          — explicit in-flight count
#   ORCH_MONITOR_HEARTBEAT_IN_FLIGHT_CLEAN    — explicit clean count
#   ORCH_MONITOR_HEARTBEAT_IN_FLIGHT_STALE    — explicit stale count
#   ORCH_MONITOR_HEARTBEAT_QUEUED             — explicit queued count
#
# When the explicit env values are not set, the script consults `gh` for
# the configured repo. The two queries are bounded by
# `ORCH_MONITOR_HEARTBEAT_GH_TIMEOUT_SEC` (default 10s) so the heartbeat
# can never hang the orch loop. Failure of any query is downgraded to a
# zero count plus a `degraded=<reason>` audit field — the heartbeat
# always returns a decision rather than aborting the loop.

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=../lib/dry_run.sh
source "$TK/lib/dry_run.sh"
# shellcheck source=../lib/config_resolver.sh
source "$TK/lib/config_resolver.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: monitor_heartbeat.sh <project> [--dry-run]}
shift || true
if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help)
      sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) printf 'monitor_heartbeat: unknown arg %s\n' "$1" >&2; exit 2 ;;
  esac
fi

load_project_config "$CFG_ARG"

# shellcheck source=../lib/audit_log.sh
source "$TK/lib/audit_log.sh"
# shellcheck source=../lib/monitor_heartbeat.sh
source "$TK/lib/monitor_heartbeat.sh"
# shellcheck source=../lib/runtime_freshness.sh
source "$TK/lib/runtime_freshness.sh"

: "${ORCH_MONITOR_HEARTBEAT_GH_TIMEOUT_SEC:=10}"
: "${ORCH_MONITOR_HEARTBEAT_OPEN_PR_LIMIT:=200}"
: "${ORCH_MONITOR_HEARTBEAT_OPEN_ISSUE_LIMIT:=200}"

# #377 — runtime freshness preflight. Before reading any GitHub state,
# verify the orchestrator runtime ($TK) is a fresh sibling of
# `origin/<default>`. When it is `clean-behind`, fast-forward it; when it
# is `dirty-tracked`, `ahead-only`, or `diverged`, refuse and emit a
# structured RUNTIME_FRESHNESS audit line with old/new SHA. The heartbeat
# then continues to a decision regardless — the freshness verdict is
# durable evidence in the audit log, not a hard abort, so the monitor
# loop never silently parks because of a transient runtime state issue.
# Operators who want to disable the preflight (e.g., on the agent
# workspace where the runtime is intentionally pinned) set
# ORCH_RUNTIME_FRESHNESS_DISABLED=1.
if [[ "${ORCH_RUNTIME_FRESHNESS_DISABLED:-0}" != "1" ]]; then
  runtime_freshness_assert "$TK" "monitor_heartbeat" || true
fi

count_open_prs_total() {
  if [ -n "${ORCH_MONITOR_HEARTBEAT_IN_FLIGHT:-}" ]; then
    printf '%s\n' "$ORCH_MONITOR_HEARTBEAT_IN_FLIGHT"
    return 0
  fi
  local out
  if out=$(timeout "$ORCH_MONITOR_HEARTBEAT_GH_TIMEOUT_SEC" \
      gh pr list --repo "$GH_REPO" \
        --state open \
        --limit "$ORCH_MONITOR_HEARTBEAT_OPEN_PR_LIMIT" \
        --json number 2>/dev/null \
      | jq 'length' 2>/dev/null); then
    printf '%s\n' "${out:-0}"
  else
    printf '%s\n' 0
  fi
}

count_open_prs_clean() {
  if [ -n "${ORCH_MONITOR_HEARTBEAT_IN_FLIGHT_CLEAN:-}" ]; then
    printf '%s\n' "$ORCH_MONITOR_HEARTBEAT_IN_FLIGHT_CLEAN"
    return 0
  fi
  # "Clean" = mergeable AND every status check rolled up to SUCCESS / SKIPPED /
  # NEUTRAL. We count the strict positive case so a transient `null` from a
  # check still in flight does not get classified as ready.
  local out
  if out=$(timeout "$ORCH_MONITOR_HEARTBEAT_GH_TIMEOUT_SEC" \
      gh pr list --repo "$GH_REPO" \
        --state open \
        --limit "$ORCH_MONITOR_HEARTBEAT_OPEN_PR_LIMIT" \
        --json mergeable,statusCheckRollup 2>/dev/null \
      | jq '[ .[] | select(.mergeable == "MERGEABLE")
                  | select( ([ .statusCheckRollup[]?
                                | (.conclusion // .state // "")
                              ]
                            | map(ascii_upcase)
                            | all(. == "SUCCESS" or . == "SKIPPED" or . == "NEUTRAL" or . == "")) )
            ] | length' 2>/dev/null); then
    printf '%s\n' "${out:-0}"
  else
    printf '%s\n' 0
  fi
}

count_queued() {
  if [ -n "${ORCH_MONITOR_HEARTBEAT_QUEUED:-}" ]; then
    printf '%s\n' "$ORCH_MONITOR_HEARTBEAT_QUEUED"
    return 0
  fi
  local out
  if out=$(timeout "$ORCH_MONITOR_HEARTBEAT_GH_TIMEOUT_SEC" \
      gh issue list --repo "$GH_REPO" \
        --state open \
        --limit "$ORCH_MONITOR_HEARTBEAT_OPEN_ISSUE_LIMIT" \
        --search 'no:assignee' \
        --json number 2>/dev/null \
      | jq 'length' 2>/dev/null); then
    printf '%s\n' "${out:-0}"
  else
    printf '%s\n' 0
  fi
}

if dry_run_enabled; then
  audit "ORCH_MONITOR_HEARTBEAT dry_run=1 project=$PROJECT"
  printf 'noop\n'
  exit 0
fi

in_flight=$(count_open_prs_total)
in_flight_clean=$(count_open_prs_clean)
if [ -n "${ORCH_MONITOR_HEARTBEAT_IN_FLIGHT_STALE:-}" ]; then
  in_flight_stale=$ORCH_MONITOR_HEARTBEAT_IN_FLIGHT_STALE
else
  in_flight_stale=$((in_flight - in_flight_clean))
  [ "$in_flight_stale" -lt 0 ] && in_flight_stale=0
fi
queued=$(count_queued)

cur=$(monitor_heartbeat_compose "$in_flight" "$in_flight_clean" "$in_flight_stale" "$queued")
monitor_heartbeat_step "$cur"
