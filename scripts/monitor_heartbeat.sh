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
#   restart_attempted      — the loop is stopped while work remains and the
#                            audited orch-loop watchdog was invoked.
#   restart_blocked        — the loop is stopped while work remains but the
#                            audited restart path refused or failed.
#   noop                   — nothing to do (no state change, or no queue
#                            pressure).
#
# Data sources (all overridable via env so tests stay offline):
#   ORCH_MONITOR_HEARTBEAT_IN_FLIGHT          — explicit in-flight count
#   ORCH_MONITOR_HEARTBEAT_IN_FLIGHT_CLEAN    — explicit clean count
#   ORCH_MONITOR_HEARTBEAT_IN_FLIGHT_STALE    — explicit stale count
#   ORCH_MONITOR_HEARTBEAT_QUEUED             — explicit queued count
#   ORCH_MONITOR_HEARTBEAT_DISPATCH_REQUIRED  — explicit dispatch-required bit
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
# shellcheck disable=SC1091
source "$TK/lib/dry_run.sh"
# shellcheck source=../lib/config_resolver.sh
# shellcheck disable=SC1091
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
# shellcheck disable=SC1091
source "$TK/lib/audit_log.sh"
# Forge access goes through the provider adapter (#816): no direct gh call.
# shellcheck source=../lib/ordo_provider_adapter.sh
source "$TK/lib/ordo_provider_adapter.sh"
# shellcheck source=../lib/monitor_heartbeat.sh
# shellcheck disable=SC1091
source "$TK/lib/monitor_heartbeat.sh"
# shellcheck source=../lib/runtime_freshness.sh
# shellcheck disable=SC1091
source "$TK/lib/runtime_freshness.sh"

: "${ORCH_MONITOR_HEARTBEAT_GH_TIMEOUT_SEC:=10}"
: "${ORCH_MONITOR_HEARTBEAT_OPEN_PR_LIMIT:=200}"
: "${ORCH_MONITOR_HEARTBEAT_OPEN_ISSUE_LIMIT:=200}"
: "${ORCH_MONITOR_HEARTBEAT_SUPERVISE_LOOP:=1}"

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
  if out=$(ORDO_PROVIDER_TIMEOUT_SEC="$ORCH_MONITOR_HEARTBEAT_GH_TIMEOUT_SEC" \
      ordo_provider pr_list --repo "$GH_REPO" \
        --state open \
        --limit "$ORCH_MONITOR_HEARTBEAT_OPEN_PR_LIMIT" 2>/dev/null \
      | jq '.items | length' 2>/dev/null); then
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
  # ordo_provider (#816): the list carries `mergeable`; the rollup of each
  # mergeable PR comes from checks_get (one bounded call per PR), with the
  # same conclusion filter as before.
  local prs pr checks count=0 rc=0
  prs=$(ORDO_PROVIDER_TIMEOUT_SEC="$ORCH_MONITOR_HEARTBEAT_GH_TIMEOUT_SEC" \
      ordo_provider pr_list --repo "$GH_REPO" \
        --state open \
        --limit "$ORCH_MONITOR_HEARTBEAT_OPEN_PR_LIMIT" 2>/dev/null \
      | jq -r '.items[]? | select(.mergeable == "mergeable") | .number' 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' 0
    return 0
  fi
  for pr in $prs; do
    checks=$(ORDO_PROVIDER_TIMEOUT_SEC="$ORCH_MONITOR_HEARTBEAT_GH_TIMEOUT_SEC" \
      ordo_provider checks_get "$pr" --repo "$GH_REPO" 2>/dev/null || printf '{}')
    if printf '%s' "$checks" | jq -e '
          [ .checks[]? | (.conclusion // "") ]
          | map(ascii_upcase)
          | all(. == "SUCCESS" or . == "SKIPPED" or . == "NEUTRAL" or . == "")' >/dev/null 2>&1; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

count_queued() {
  if [ -n "${ORCH_MONITOR_HEARTBEAT_QUEUED:-}" ]; then
    printf '%s\n' "$ORCH_MONITOR_HEARTBEAT_QUEUED"
    return 0
  fi
  local out
  if out=$(ORDO_PROVIDER_TIMEOUT_SEC="$ORCH_MONITOR_HEARTBEAT_GH_TIMEOUT_SEC" \
      ordo_provider issue_list --repo "$GH_REPO" \
        --state open \
        --limit "$ORCH_MONITOR_HEARTBEAT_OPEN_ISSUE_LIMIT" \
        --search 'no:assignee' 2>/dev/null \
      | jq '.items | length' 2>/dev/null); then
    printf '%s\n' "${out:-0}"
  else
    printf '%s\n' 0
  fi
}

monitor_watchdog_now_epoch() {
  if [[ -n "${ORCH_NOW_OVERRIDE:-}" ]]; then
    printf '%s\n' "$ORCH_NOW_OVERRIDE"
  else
    date -u +%s
  fi
}

monitor_watchdog_now_iso() {
  if [[ -n "${ORCH_NOW_OVERRIDE:-}" ]]; then
    date -u -d "@$ORCH_NOW_OVERRIDE" +%FT%TZ
  else
    date -u +%FT%TZ
  fi
}

monitor_loop_pids() {
  local proc_dir=${ORCH_PROC_DIR:-/proc}
  local self=$$
  local pid_dir pid arg base i
  local -a argv
  for pid_dir in "$proc_dir"/[0-9]*; do
    [[ -e "$pid_dir" ]] || continue
    pid=${pid_dir##*/}
    [[ "$pid" == "$self" ]] && continue
    [[ -r "$pid_dir/cmdline" ]] || continue
    if ! mapfile -d '' -t argv < "$pid_dir/cmdline" 2>/dev/null; then
      continue
    fi
    [[ ${#argv[@]} -ge 2 ]] || continue
    for ((i = 0; i < ${#argv[@]} - 1; i++)); do
      arg=${argv[i]}
      base=${arg##*/}
      if [[ "$base" == "orch_loop.sh" && "${argv[i+1]}" == "$PROJECT" ]]; then
        printf '%s\n' "$pid"
        break
      fi
    done
  done
}

monitor_assignment_count() {
  if [[ -n "${ORCH_MONITOR_HEARTBEAT_ASSIGNMENTS:-}" ]]; then
    printf '%s\n' "$ORCH_MONITOR_HEARTBEAT_ASSIGNMENTS"
    return 0
  fi
  jq 'to_entries | length' "$(state_dir)/assignments.json" 2>/dev/null || printf '0\n'
}

monitor_dispatch_required() {
  case "${ORCH_MONITOR_HEARTBEAT_DISPATCH_REQUIRED:-}" in
    1|true|TRUE|yes|YES)
      return 0
      ;;
  esac

  local state
  state=$(state_dir)
  [[ -f "$state/orch.dispatch_required" ]] && return 0
  if [[ -s "$state/orch.continuation_decision" ]] \
      && grep -Fx 'dispatch_required' "$state/orch.continuation_decision" >/dev/null; then
    return 0
  fi
  if [[ -s "$state/continuation_guard.json" ]]; then
    if command -v jq >/dev/null 2>&1; then
      jq -e '.decision == "dispatch_required"' "$state/continuation_guard.json" >/dev/null 2>&1 \
        && return 0
    elif grep -Eq '"decision"[[:space:]]*:[[:space:]]*"dispatch_required"' "$state/continuation_guard.json"; then
      return 0
    fi
  fi
  return 1
}

monitor_watchdog_set_status() {
  local key=${1:?usage: monitor_watchdog_set_status <key> <value>}
  local value=${2:-}
  local state
  state=$(state_dir)
  printf '%s\n' "$value" > "$state/orch.watchdog_$key"
}

monitor_watchdog_increment_attempts() {
  local state attempts
  state=$(state_dir)
  attempts=$(cat "$state/orch.watchdog_restart_attempts" 2>/dev/null || printf '0')
  [[ "$attempts" =~ ^[0-9]+$ ]] || attempts=0
  attempts=$((attempts + 1))
  monitor_watchdog_set_status restart_attempts "$attempts"
  printf '%s\n' "$attempts"
}

monitor_watchdog_append_intervention() {
  local queue_path=${1:?usage: monitor_watchdog_append_intervention <queue> <attempts> <rc> <reason>}
  local attempts=${2:-unknown}
  local rc=${3:-unknown}
  local reason=${4:-restart-failed}
  local ts clean_reason
  ts=$(monitor_watchdog_now_iso)
  mkdir -p "$(dirname "$queue_path")" 2>/dev/null || true
  if [[ ! -s "$queue_path" ]]; then
    {
      printf '# ORDO intervention queue\n\n'
      printf '| timestamp | agent | ticket | blocker_excerpt | recommended_action |\n'
      printf '| --- | --- | --- | --- | --- |\n'
    } > "$queue_path"
  fi
  clean_reason=$(printf '%s' "$reason" | tr '\n' ' ' | tr '|' '/' | awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }')
  [[ -n "$clean_reason" ]] || clean_reason="restart-failed"
  printf '| %s | monitor_heartbeat | %s | loop NOT RUNNING; restart_attempts=%s rc=%s reason=%s | inspect audit log, fix the restart refusal, then run ensure_alive.sh orch-loop %s --once from an operator-approved shell |\n' \
    "$ts" "$PROJECT" "$attempts" "$rc" "$clean_reason" "$CFG_ARG" >> "$queue_path"
}

monitor_supervise_stopped_loop() {
  local queued=${1:?usage: monitor_supervise_stopped_loop <queued>}
  local loop_pids assignments dispatch_required=false paused=false
  local work_remaining=false attempts restart_out rc queue_path

  if [[ "${ORCH_MONITOR_HEARTBEAT_SUPERVISE_LOOP:-1}" == "0" ]]; then
    monitor_watchdog_set_status supervised false
    return 0
  fi
  monitor_watchdog_set_status supervised true

  loop_pids=$(monitor_loop_pids | tr '\n' ' ' | sed 's/[[:space:]]$//')
  [[ -n "$loop_pids" ]] && return 0

  if [[ -f "$(state_dir)/orch.paused" ]]; then
    paused=true
  fi

  assignments=$(monitor_assignment_count)
  [[ "$assignments" =~ ^[0-9]+$ ]] || assignments=0
  if monitor_dispatch_required; then
    dispatch_required=true
  fi

  if [[ "$queued" =~ ^[0-9]+$ ]] && (( queued > 0 )); then
    work_remaining=true
  fi
  if (( assignments > 0 )) || [[ "$dispatch_required" == "true" ]]; then
    work_remaining=true
  fi

  if [[ "$paused" == "true" ]]; then
    audit "ORCH_LOOP_WATCHDOG_SUPERVISION supervised=true action=noop reason=paused loop=NOT_RUNNING queued=$queued assignments=$assignments dispatch_required=$dispatch_required"
    return 0
  fi

  if [[ "$work_remaining" != "true" ]]; then
    audit "ORCH_LOOP_WATCHDOG_SUPERVISION supervised=true action=noop reason=no-work loop=NOT_RUNNING queued=$queued assignments=$assignments dispatch_required=$dispatch_required"
    return 0
  fi

  attempts=$(monitor_watchdog_increment_attempts)
  monitor_watchdog_set_status last_restart "$(monitor_watchdog_now_iso)"
  monitor_watchdog_set_status last_restart_epoch "$(monitor_watchdog_now_epoch)"
  monitor_watchdog_set_status last_stop_reason "loop-not-running work-remaining"

  if restart_out=$(bash "$TK/scripts/ensure_alive.sh" orch-loop "$CFG_ARG" --once 2>&1); then
    audit "ORCH_LOOP_WATCHDOG_SUPERVISION supervised=true action=restart_attempted reason=work-remaining loop=NOT_RUNNING queued=$queued assignments=$assignments dispatch_required=$dispatch_required restart_attempts=$attempts"
    printf 'restart_attempted\n'
    return 0
  else
    rc=$?
  fi
  audit "ORCH_LOOP_WATCHDOG_SUPERVISION supervised=true action=blocker-required reason=restart-failed rc=$rc loop=NOT_RUNNING queued=$queued assignments=$assignments dispatch_required=$dispatch_required restart_attempts=$attempts"
  if [[ -n "$restart_out" ]]; then
    audit "ORCH_LOOP_WATCHDOG_SUPERVISION_DETAIL rc=$rc output=${restart_out//$'\n'/;}"
  fi
  queue_path=${ORCH_MONITOR_HEARTBEAT_QUEUE:-$(state_dir)/intervention_queue.md}
  monitor_watchdog_append_intervention "$queue_path" "$attempts" "$rc" "$restart_out"
  audit "ORCH_LOOP OPERATOR_AUTHORIZATION_REQUIRED project=$PROJECT reason=loop-watchdog-restart-failed queue_path=$queue_path"
  printf 'restart_blocked\n'
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
monitor_supervise_stopped_loop "$queued"
