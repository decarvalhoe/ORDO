#!/usr/bin/env bash
# scripts/cycle.sh — full orchestrator cycle wrapper.
#
# Usage: cycle.sh <project_short|config_path> <wave_label> <ticket1>:<agent1> [<ticket2>:<agent2> ...]
#
# Pipeline (mirrors the surviving rbok.log CYCLE 1/2/3 patterns):
#   1. CI HEALTH gate (refuse if default branch is RED).
#   2. AUDIT START / state snapshot.
#   3. For each <ticket>:<agent> pair:
#        - Brief from template (stub — caller is expected to provide a fully
#          rendered prompt under /tmp/dispatch-<agent>-<ticket>.md beforehand,
#          OR pass a kvargs file via $CYCLE_BRIEF_KVS_<agent>_<ticket>).
#        - dispatch_ticket.sh
#   4. SMART POLL until trigger or timeout.
#   5. INTEGRATE wave.
#   6. For each open PR opened during the wave: pr_merge.sh.
#   7. AUDIT END / persist ORCHESTRATION_STATE.md.
#
# Surviving log signatures:
#   CYCLE <N> START — dispatch <X> issues (#... ...)
#   CYCLE <N> COMPLETE — <X>/<Y> PRs merged (#... ...)
#
# Exit codes:
#   0 — full cycle succeeded
#   1 — CI gate refused (default branch RED)
#   2 — smart-poll timed out
#   3 — integrate had conflicts
#   4 — at least one PR failed to merge
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/config_resolver.sh"
source "$TK/lib/process_safety.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: cycle.sh <project> <wave_label> <ticket:agent>... [--dry-run]}
WAVE=${2:?missing wave label}
shift 2
[ "$#" -ge 1 ] || { echo "need at least one <ticket>:<agent> pair" >&2; exit 1; }

load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"
source "$TK/lib/state_persist.sh"
source "$TK/lib/host_load_gate.sh"

merge_drain_detail() {
  tr '\n\r\t' '   ' | tr -s ' ' | cut -c1-300
}

drain_merge_ready_pr_queue() {
  local cfg_arg=${1:?usage: drain_merge_ready_pr_queue <config> <wave>}
  local wave=${2:?usage: drain_merge_ready_pr_queue <config> <wave>}
  local scan_timeout=${ORCH_PR_MERGE_DRAIN_SCAN_TIMEOUT_SEC:-30}
  local merge_timeout=${ORCH_PR_MERGE_DRAIN_MERGE_TIMEOUT_SEC:-300}
  local signals_json scan_rc detail entry pr branch merge_rc
  local failed=0
  local -a ready_prs merge_args

  if signals_json=$(orch_run_timeout "$scan_timeout" \
      bash "$TK/scripts/pr_block_signals.sh" "$cfg_arg" --json 2>&1); then
    :
  else
    scan_rc=$?
    detail=$(printf '%s' "$signals_json" | merge_drain_detail)
    audit "CYCLE ${wave} PR_MERGE_DRAIN reason=signal-scan-failed rc=${scan_rc} detail=${detail}"
    return 4
  fi

  if ! printf '%s' "$signals_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    detail=$(printf '%s' "$signals_json" | merge_drain_detail)
    audit "CYCLE ${wave} PR_MERGE_DRAIN reason=invalid-signal-json detail=${detail}"
    return 4
  fi

  mapfile -t ready_prs < <(printf '%s' "$signals_json" | jq -r '
    .[]?
    | select((.signals // []) | index("merge-ready"))
    | [.pr, (.branch // "")] | @tsv
  ')

  if [ "${#ready_prs[@]}" -eq 0 ]; then
    audit "CYCLE ${wave} PR_MERGE_DRAIN reason=no-merge-candidates count=0"
    return 0
  fi

  audit "CYCLE ${wave} PR_MERGE_DRAIN reason=merge-ready-candidates count=${#ready_prs[@]}"

  for entry in "${ready_prs[@]}"; do
    IFS=$'\t' read -r pr branch <<< "$entry"
    if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
      audit "CYCLE ${wave} PR_MERGE_DRAIN reason=invalid-pr-number pr=${pr:-missing} branch=${branch}"
      failed=1
      continue
    fi

    merge_args=("$cfg_arg" "$pr")
    if dry_run_enabled; then
      merge_args+=(--dry-run)
    fi

    if orch_run_timeout "$merge_timeout" bash "$TK/lib/pr_merge.sh" "${merge_args[@]}"; then
      audit "CYCLE ${wave} PR_MERGE_DRAIN pr=#${pr} branch=${branch} reason=merge-attempt-complete"
    else
      merge_rc=$?
      audit "CYCLE ${wave} PR_MERGE_DRAIN pr=#${pr} branch=${branch} reason=merge-refused-or-failed rc=${merge_rc}"
      failed=1
    fi
  done

  [ "$failed" -eq 0 ] || return 4
  return 0
}

# Parse pairs.
declare -a TICKETS AGENT_OF
ticket_summary=""
for pair in "$@"; do
  [[ "$pair" == *:* ]] || { echo "bad pair (need ticket:agent): $pair" >&2; exit 1; }
  TICKETS+=("${pair%%:*}")
  AGENT_OF+=("${pair##*:}")
  ticket_summary+="#${pair%%:*} "
done

audit "CYCLE ${WAVE} START — dispatch ${#TICKETS[@]} issues (${ticket_summary% })"

orch_host_load_gate \
  "dispatch_wave:${PROJECT}:${WAVE}" \
  "${ORCH_HOST_GATE_DISPATCH_MODE:-${ORCH_HOST_GATE_MODE:-off}}"

# Step 1: CI gate.
if ! "$TK/scripts/check_ci_health.sh" "$CFG_ARG" 8; then
  audit "CYCLE ${WAVE} ABORTED — CI gate refused (default branch RED)"
  exit 1
fi

# Step 1b (#245): Six Sigma auto-upgrade is now standard cycle behavior.
# Runs after the default-branch CI gate so the autofix dispatcher sees a
# stable base, before the wave's own dispatches take over the agent pool.
# The script's contract is observe-and-dispatch (it never merges and
# never bypasses CI), so failure here MUST warn + audit but never abort
# the cycle — the load-bearing step is the wave dispatch below. Operators
# who want to opt out (e.g. on a constrained host) set
# ORCH_SIXSIGMA_DISABLED=1.
if [[ "${ORCH_SIXSIGMA_DISABLED:-0}" != "1" ]]; then
  sixsigma_args=("$CFG_ARG")
  if dry_run_enabled; then
    sixsigma_args+=(--dry-run)
  fi
  if "$TK/scripts/sixsigma_autoupgrade.sh" "${sixsigma_args[@]}"; then
    audit "CYCLE ${WAVE} SIXSIGMA OK project=$PROJECT"
  else
    audit "CYCLE ${WAVE} SIXSIGMA WARN — sixsigma_autoupgrade.sh exited non-zero project=$PROJECT (cycle continues)"
  fi
fi

# Step 2: snapshot.
"$TK/scripts/audit_state.sh" "$CFG_ARG" >/dev/null || true

# Step 3: dispatch.
agents_used=""
dispatch_extra_args=()
if dry_run_enabled; then
  dispatch_extra_args+=(--dry-run)
fi
for i in "${!TICKETS[@]}"; do
  ticket="${TICKETS[$i]}"
  agent="${AGENT_OF[$i]}"
  prompt_file="/tmp/dispatch-${agent}-${ticket}.md"
  if [ ! -f "$prompt_file" ]; then
    audit "CYCLE ${WAVE} WARN — prompt file missing for #${ticket}/${agent} at $prompt_file (caller must brief first)"
    continue
  fi
  "$TK/scripts/dispatch_ticket.sh" "$CFG_ARG" "$agent" "$ticket" "$prompt_file" "${dispatch_extra_args[@]}"
  agents_used+=" $agent"
done

# Step 4: smart-poll.
if dry_run_enabled; then
  dry_run_note "$TK/scripts/smart_poll_agents.sh $CFG_ARG $WAVE"
else
  if ! "$TK/scripts/smart_poll_agents.sh" "$CFG_ARG" "$WAVE"; then
    audit "CYCLE ${WAVE} POLL TIMEOUT — proceeding to integrate what is committed"
  fi
fi

# Step 5: integrate.
integrate_extra_args=()
if dry_run_enabled; then
  integrate_extra_args+=(--dry-run)
fi
if ! "$TK/scripts/integrate_wave.sh" "$CFG_ARG" "$WAVE" "${integrate_extra_args[@]}"; then
  audit "CYCLE ${WAVE} INTEGRATE had conflicts/failures — see /var/log/orch/${PROJECT}.log"
  # Do NOT exit yet; some branches may still be mergeable individually.
fi

# Step 6 (#475, related #463): drain merge-ready PRs after blockers clear.
# pr_merge.sh owns the policy gate and emits the concrete no-merge reason
# when review, branch protection, draft state, CI, or permissions block a PR.
merge_drain_rc=0
drain_merge_ready_pr_queue "$CFG_ARG" "$WAVE" || merge_drain_rc=$?

# Step 7: persist state and announce completion.
if dry_run_enabled; then
  dry_run_note "state_persist ORCHESTRATION_STATE.md"
else
  state_persist "ORCHESTRATION_STATE.md" "$(printf '# %s wave %s\n\nstatus: dispatched\nagents: %s\ntickets: %s\n' "$PROJECT" "$WAVE" "$agents_used" "$ticket_summary")"
fi

audit "CYCLE ${WAVE} COMPLETE — dispatched=${#TICKETS[@]} (${ticket_summary% })"
if [ "$merge_drain_rc" -ne 0 ]; then
  exit 4
fi
exit 0
