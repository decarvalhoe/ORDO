#!/usr/bin/env bash
# orch_loop.sh — the main orchestrator loop.
#
# A long-running bash supervisor that calls `claude -p` with the orch system
# prompt + a context-aware per-cycle task prompt. Sleeps adaptively between
# cycles based on detected activity.
#
# Inspired by:
#   - 42T pattern (claude -p in a while loop)
#   - NOMOS active_loop (state persistence + smart polling)
#   - Anthropic Agent Teams (lead + workers, with hooks for governance gates)
#   - Overstory (recovery on stuck agents)
#
# Usage:
#   bash orch_loop.sh <project>
# Example:
#   bash orch_loop.sh rbok    # source examples/rbok.config.sh implicitly
#
# Signals:
#   SIGTERM   — clean shutdown after current cycle
#   SIGUSR1   — pause (skip cycles until SIGUSR2)
#   SIGUSR2   — resume / run a cycle NOW
#
# Adaptive cadence:
#   - Burst mode (PRs being merged actively):  30s between cycles
#   - Normal:                                  120s
#   - Idle (no agent active):                  600s
#   - Backoff (gh rate limit hit):             1800s

set -euo pipefail

TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_ARG=${1:?usage: orch_loop.sh <project>}

# Source project config
CFG="$TK/examples/$PROJECT_ARG.config.sh"
[[ -f "$CFG" ]] || { echo "config not found: $CFG" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CFG"

# shellcheck disable=SC1091
source "$TK/lib/audit_log.sh"
# shellcheck disable=SC1091
source "$TK/lib/state_persist.sh"
# shellcheck disable=SC1091
source "$TK/lib/preflight.sh"
# shellcheck disable=SC1091
source "$TK/lib/worktree_helpers.sh"

preflight_or_die "ORCH_LOOP" claude gh jq tmux

# --- Tunables (override via env) ---
: "${ORCH_CADENCE_BURST:=30}"
: "${ORCH_CADENCE_NORMAL:=120}"
: "${ORCH_CADENCE_IDLE:=600}"
: "${ORCH_CADENCE_BACKOFF:=1800}"
: "${ORCH_MAX_CYCLES:=0}"          # 0 = infinite
: "${ORCH_CLAUDE_MODEL:=}"         # default model from claude config; set to override
: "${ORCH_DRY_RUN:=false}"

LOOP_LOG="$ORCH_LOG_DIR/$PROJECT-orch-loop.log"
PAUSE_FLAG="$(state_dir)/orch.paused"
RUN_NOW_FLAG="$(state_dir)/orch.run_now"
CYCLE_COUNT_FILE="$(state_dir)/orch.cycle_count"
LAST_ACTIVITY_FILE="$(state_dir)/orch.last_activity"

# --- Signal handlers ---
SHUTDOWN=false
trap 'SHUTDOWN=true; audit "ORCH_LOOP SIGTERM received, will stop after current cycle"' TERM INT
trap 'touch "$PAUSE_FLAG"; audit "ORCH_LOOP paused (SIGUSR1)"' USR1
trap 'rm -f "$PAUSE_FLAG"; touch "$RUN_NOW_FLAG"; audit "ORCH_LOOP resumed (SIGUSR2)"' USR2

# --- Helpers ---

# Detect cadence based on recent state.
detect_cadence() {
  # Burst: a PR was merged or dispatched in the last 5 min
  local last; last=$(cat "$LAST_ACTIVITY_FILE" 2>/dev/null || echo 0)
  local now; now=$(date +%s)
  if (( now - last < 300 )); then
    echo "$ORCH_CADENCE_BURST"; return
  fi
  # Idle: zero open assignments
  local n_assigned
  n_assigned=$(state_get assignments | jq 'to_entries | length' 2>/dev/null || echo 0)
  if [[ "$n_assigned" -eq 0 ]]; then
    echo "$ORCH_CADENCE_IDLE"; return
  fi
  echo "$ORCH_CADENCE_NORMAL"
}

# Detect rate-limit + backoff
hit_rate_limit() {
  local last_fail; last_fail=$(grep -c 'rate limit' "$LOOP_LOG" 2>/dev/null | tail -3 | grep -c .)
  [[ "$last_fail" -gt 1 ]]
}

# Build the per-cycle task prompt.
build_task_prompt() {
  local cycle=$1
  local n_agents=${#AGENTS[@]}
  local n_assigned
  n_assigned=$(state_get assignments | jq 'to_entries | length' 2>/dev/null || echo 0)
  local backlog_count
  backlog_count=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh issue list \
    --repo "$GH_REPO" --state open --search 'no:assignee' --json number --jq 'length' 2>/dev/null || echo "?")

  if [[ "$cycle" -eq 1 ]]; then
    cat <<EOF
ORCH CYCLE 1 (cold start) for project=$PROJECT.

Your toolkit is at \$TK=$TK. Source the config first:
  source \$TK/examples/$PROJECT.config.sh

Required first actions:
1. bash \$TK/scripts/audit_state.sh   (snapshot what's running)
2. Review the snapshot — are there agents stuck (idle but with WIP)?
3. If safe: bash \$TK/scripts/cycle.sh   (one full cycle)

Constraints:
- One issue per agent maximum.
- PR target = $DEFAULT_BRANCH only, never main.
- Use pr_can_merge() before any merge attempt.
- Never push to a protected branch directly.

Report back: what you did, what's blocked, what you'll do next cycle.
EOF
  else
    cat <<EOF
ORCH CYCLE $cycle for project=$PROJECT.

State:
- Agents: $n_agents total, $n_assigned currently assigned
- Backlog (unassigned open issues): $backlog_count

Standard cycle actions:
1. bash \$TK/scripts/audit_state.sh
2. For each assigned agent, check if they committed since dispatch
   (compare agent_head vs assignments[agent].head_at_dispatch).
3. If committed AND PR exists AND CI green: approve_and_merge.
4. If agent idle with no assignment AND backlog > 0: dispatch next ticket.
5. If agent stuck (no commit in 30+ min, pane shows error): bash \$TK/scripts/recover.sh <agent>.

Concise report (<300 chars): what merged, what dispatched, what's blocked.
EOF
  fi
}

# Capture the system prompt template
SYSTEM_PROMPT_FILE="$TK/templates/orch_briefing.md"
if [[ -f "$SYSTEM_PROMPT_FILE" ]]; then
  SYSTEM_PROMPT=$(sed \
    -e "s|{{PROJECT}}|$PROJECT|g" \
    -e "s|{{GH_REPO}}|$GH_REPO|g" \
    -e "s|{{DEFAULT_BRANCH}}|$DEFAULT_BRANCH|g" \
    -e "s|{{N_AGENTS}}|${#AGENTS[@]}|g" \
    -e "s|{{TK}}|$TK|g" \
    "$SYSTEM_PROMPT_FILE")
else
  SYSTEM_PROMPT="You are the orchestrator for $PROJECT ($GH_REPO). Toolkit at $TK. Coordinate ${#AGENTS[@]} agents. PR target=$DEFAULT_BRANCH. Never push direct."
fi

# Boot
mkdir -p "$(dirname "$LOOP_LOG")"
audit "ORCH_LOOP boot project=$PROJECT model=${ORCH_CLAUDE_MODEL:-default} dry=$ORCH_DRY_RUN"
if worktree_enabled; then
  worktree_cleanup_stale || audit "WORKTREE CLEANUP WARN project=$PROJECT"
fi
echo 0 > "$CYCLE_COUNT_FILE"

# --- Main loop ---
while true; do
  if [[ "$SHUTDOWN" == "true" ]]; then
    audit "ORCH_LOOP shutdown clean"
    exit 0
  fi

  # Pause check
  if [[ -f "$PAUSE_FLAG" ]]; then
    audit "ORCH_LOOP paused, sleeping 30s waiting for SIGUSR2"
    sleep 30
    continue
  fi

  cycle=$(($(cat "$CYCLE_COUNT_FILE") + 1))
  echo "$cycle" > "$CYCLE_COUNT_FILE"
  cycle_start=$(date +%s)

  audit "ORCH_LOOP === cycle $cycle start ==="
  task=$(build_task_prompt "$cycle")

  if [[ "$ORCH_DRY_RUN" == "true" ]]; then
    audit "ORCH_LOOP DRY_RUN, would call claude with task: $(head -c 200 <<< "$task")"
    rc=0
  else
    # Build claude args
    claude_args=(--append-system-prompt "$SYSTEM_PROMPT" -p "$task")
    [[ -n "$ORCH_CLAUDE_MODEL" ]] && claude_args=(--model "$ORCH_CLAUDE_MODEL" "${claude_args[@]}")
    if claude "${claude_args[@]}" 2>&1 | tee -a "$LOOP_LOG"; then
      rc=0
    else
      rc=${PIPESTATUS[0]}
    fi
  fi

  cycle_end=$(date +%s)
  cycle_duration=$((cycle_end - cycle_start))
  audit "ORCH_LOOP cycle $cycle ended rc=$rc duration=${cycle_duration}s"

  # Update activity timestamp if cycle did something
  if grep -qE 'DISPATCH|merged|RECOVER' <<< "$(tail -200 "$ORCH_LOG_DIR/$PROJECT.log" 2>/dev/null)"; then
    date +%s > "$LAST_ACTIVITY_FILE"
  fi

  # Stop if max cycles reached
  if [[ "$ORCH_MAX_CYCLES" -gt 0 && "$cycle" -ge "$ORCH_MAX_CYCLES" ]]; then
    audit "ORCH_LOOP reached ORCH_MAX_CYCLES=$ORCH_MAX_CYCLES, exiting"
    exit 0
  fi

  # Run-now flag bypasses sleep
  if [[ -f "$RUN_NOW_FLAG" ]]; then
    rm -f "$RUN_NOW_FLAG"
    audit "ORCH_LOOP run-now flag set, skipping sleep"
    continue
  fi

  # Adaptive sleep
  if hit_rate_limit; then
    sleep_for=$ORCH_CADENCE_BACKOFF
    audit "ORCH_LOOP rate-limit detected, backoff ${sleep_for}s"
  elif [[ "$rc" -ne 0 ]]; then
    sleep_for=30
    audit "ORCH_LOOP claude exited non-zero, retry in 30s"
  else
    cadence_label=''
    sleep_for=$(detect_cadence)
    if [[ "$sleep_for" -le 60 ]]; then
      cadence_label=burst
    elif [[ "$sleep_for" -le 300 ]]; then
      cadence_label=normal
    else
      cadence_label=idle
    fi
    audit "ORCH_LOOP next cycle in ${sleep_for}s (cadence=${cadence_label})"
  fi
  sleep "$sleep_for"
done
