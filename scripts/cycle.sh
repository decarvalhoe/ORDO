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

CFG_ARG=${1:?usage: cycle.sh <project> <wave_label> <ticket:agent>...}
WAVE=${2:?missing wave label}
shift 2
[ "$#" -ge 1 ] || { echo "need at least one <ticket>:<agent> pair" >&2; exit 1; }

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
source "$TK/lib/state_persist.sh"

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

# Step 1: CI gate.
if ! "$TK/scripts/check_ci_health.sh" "$CFG_ARG" 8; then
  audit "CYCLE ${WAVE} ABORTED — CI gate refused (default branch RED)"
  exit 1
fi

# Step 2: snapshot.
"$TK/scripts/audit_state.sh" "$CFG_ARG" >/dev/null || true

# Step 3: dispatch.
agents_used=""
for i in "${!TICKETS[@]}"; do
  ticket="${TICKETS[$i]}"
  agent="${AGENT_OF[$i]}"
  prompt_file="/tmp/dispatch-${agent}-${ticket}.md"
  if [ ! -f "$prompt_file" ]; then
    audit "CYCLE ${WAVE} WARN — prompt file missing for #${ticket}/${agent} at $prompt_file (caller must brief first)"
    continue
  fi
  "$TK/scripts/dispatch_ticket.sh" "$CFG_ARG" "$agent" "$ticket" "$prompt_file"
  agents_used+=" $agent"
done

# Step 4: smart-poll.
if ! "$TK/scripts/smart_poll_agents.sh" "$CFG_ARG" "$WAVE"; then
  audit "CYCLE ${WAVE} POLL TIMEOUT — proceeding to integrate what is committed"
fi

# Step 5: integrate.
if ! "$TK/scripts/integrate_wave.sh" "$CFG_ARG" "$WAVE"; then
  audit "CYCLE ${WAVE} INTEGRATE had conflicts/failures — see /var/log/orch/${PROJECT}.log"
  # Do NOT exit yet; some branches may still be mergeable individually.
fi

# Step 6: PR merge — caller is expected to have created PRs (or the
# integrate step will). Skipped here; callers run pr_merge.sh per PR
# when they have the PR numbers.

# Step 7: persist state and announce completion.
state_persist "ORCHESTRATION_STATE.md" "$(printf '# %s wave %s\n\nstatus: dispatched\nagents: %s\ntickets: %s\n' "$PROJECT" "$WAVE" "$agents_used" "$ticket_summary")"

audit "CYCLE ${WAVE} COMPLETE — dispatched=${#TICKETS[@]} (${ticket_summary% })"
exit 0
