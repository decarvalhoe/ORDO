#!/usr/bin/env bash
# orch_loop.sh — the main orchestrator loop.
#
# A long-running bash supervisor that calls a Codex/Claude CLI with the orch
# system prompt + a context-aware per-cycle task prompt. Sleeps adaptively between
# cycles based on detected activity.
#
# Inspired by:
#   - 42T pattern (claude -p in a while loop)
#   - NOMOS active_loop (state persistence + smart polling)
#   - Anthropic Agent Teams (lead + workers, with hooks for governance gates)
#   - Overstory (recovery on stuck agents)
#
# Usage:
#   bash orch_loop.sh <project> [--daemon-confirm <operator-name>]
# Examples:
#   ORCH_DAEMON_CONFIRM="$USER" bash orch_loop.sh rbok
#   bash orch_loop.sh rbok --daemon-confirm "Jane Operator"
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

usage() {
  cat <<EOF >&2
usage: orch_loop.sh <project> [--daemon-confirm <operator-name>]

orch_loop.sh is a long-running daemon. It is blocked by default so manual
in-session orchestration stays inside the active operator shell.

Manual in-session path:
  bash $TK/scripts/orch_manual_session.sh <project>

Intentional daemon start:
  ORCH_DAEMON_CONFIRM=<operator-name> bash orch_loop.sh <project>
  bash orch_loop.sh <project> --daemon-confirm <operator-name>
EOF
}

PROJECT_ARG=""
DAEMON_CONFIRM_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --daemon-confirm)
      DAEMON_CONFIRM_ARG=${2:?missing value for --daemon-confirm}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "unknown arg: $1" >&2
      usage
      exit 2
      ;;
    *)
      if [[ -n "$PROJECT_ARG" ]]; then
        echo "unexpected extra arg: $1" >&2
        usage
        exit 2
      fi
      PROJECT_ARG=$1
      shift
      ;;
  esac
done
PROJECT_ARG=${PROJECT_ARG:?usage: orch_loop.sh <project> [--daemon-confirm <operator-name>]}

source "$TK/lib/config_resolver.sh"
source "$TK/lib/agent_inventory.sh"
load_project_config "$PROJECT_ARG"

# shellcheck disable=SC1091
source "$TK/lib/audit_log.sh"

require_daemon_confirmation() {
  local confirm_name=${DAEMON_CONFIRM_ARG:-${ORCH_DAEMON_CONFIRM:-}}
  if [[ -z "${confirm_name//[[:space:]]/}" ]]; then
    cat <<EOF >&2
orch_loop.sh refused to start without an explicit daemon confirmation.

Use the manual in-session path instead:
  bash $TK/scripts/orch_manual_session.sh $PROJECT_ARG

If you intentionally want the detached daemon, rerun with a named operator
confirmation:
  ORCH_DAEMON_CONFIRM=<operator-name> bash orch_loop.sh $PROJECT_ARG
  bash orch_loop.sh $PROJECT_ARG --daemon-confirm <operator-name>
EOF
    audit "ORCH_LOOP refused daemon start project=$PROJECT operator_confirmation=missing"
    exit 14
  fi
  audit "ORCH_LOOP daemon confirmed project=$PROJECT operator=$confirm_name"
}

require_daemon_confirmation

# shellcheck disable=SC1091
source "$TK/lib/state_persist.sh"
# shellcheck disable=SC1091
source "$TK/lib/preflight.sh"
# shellcheck disable=SC1091
source "$TK/lib/worktree_helpers.sh"

fleet_count() {
  local count
  count=$(agent_inventory_entries | wc -l | tr -d ' ')
  printf '%s\n' "${count:-0}"
}

# --- Tunables (override via env) ---
: "${ORCH_CADENCE_BURST:=30}"
: "${ORCH_CADENCE_NORMAL:=120}"
: "${ORCH_CADENCE_IDLE:=600}"
: "${ORCH_CADENCE_BACKOFF:=1800}"
: "${ORCH_MAX_CYCLES:=0}"          # 0 = infinite
: "${ORCH_CLI_BIN:=${SUPERVISOR_CLI_BIN:-}}" # supervisor LLM CLI binary; project/operator must choose
: "${ORCH_CODEX_MODEL:=gpt-5.5}"   # used only when ORCH_CLI_BIN=codex
: "${ORCH_CODEX_SANDBOX:=danger-full-access}"
: "${ORCH_CODEX_APPROVAL:=never}"
: "${ORCH_CLAUDE_MODEL:=}"         # only used when ORCH_CLI_BIN=claude
: "${ORCH_DRY_RUN:=false}"

if [[ -z "$ORCH_CLI_BIN" ]]; then
  audit "ORCH_LOOP refused start project=$PROJECT reason=missing-supervisor-cli"
  echo "ORCH_CLI_BIN required: set it in the project config or environment" >&2
  exit 14
fi
preflight_or_die "ORCH_LOOP" "$ORCH_CLI_BIN" gh jq tmux

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

build_supervisor_args() {
  local task=${1:?usage: build_supervisor_args <task>}
  SUPERVISOR_ARGS=()
  case "$ORCH_CLI_BIN" in
    codex|*/codex)
      SUPERVISOR_ARGS=(
        -m "$ORCH_CODEX_MODEL"
        -s "$ORCH_CODEX_SANDBOX"
        -a "$ORCH_CODEX_APPROVAL"
        "$(printf '%s\n\n%s\n' "$SYSTEM_PROMPT" "$task")"
      )
      ;;
    claude|*/claude)
      SUPERVISOR_ARGS=(--append-system-prompt "$SYSTEM_PROMPT" -p "$task")
      [[ -n "$ORCH_CLAUDE_MODEL" ]] && SUPERVISOR_ARGS=(--model "$ORCH_CLAUDE_MODEL" "${SUPERVISOR_ARGS[@]}")
      ;;
    *)
      SUPERVISOR_ARGS=("$(printf '%s\n\n%s\n' "$SYSTEM_PROMPT" "$task")")
      ;;
  esac
}

# Build the per-cycle task prompt.
build_task_prompt() {
  local cycle=$1
  local n_agents
  n_agents=$(fleet_count)
  local n_assigned
  n_assigned=$(state_get assignments | jq 'to_entries | length' 2>/dev/null || echo 0)
  local backlog_count
  backlog_count=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh issue list \
    --repo "$GH_REPO" --state open --search 'no:assignee' --json number --jq 'length' 2>/dev/null || echo "?")

  if [[ "$cycle" -eq 1 ]]; then
    cat <<EOF
ORCH CYCLE 1 (cold start) for project=$PROJECT.

Your toolkit is at \$TK=$TK. Source the config first:
  source ${ORCH_CONFIG_PATH:-\$TK/examples/$PROJECT.config.sh}

Required first actions:
1. bash \$TK/scripts/audit_state.sh   (snapshot what's running)
2. bash \$TK/scripts/project_meta_context.sh $PROJECT
3. bash \$TK/scripts/dispatch_plan.sh $PROJECT --ready-only
4. Review the snapshot — are there agents stuck (idle but with WIP)?
5. If safe: bash \$TK/scripts/cycle.sh   (one full cycle)

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
2. bash \$TK/scripts/project_meta_context.sh $PROJECT
3. bash \$TK/scripts/dispatch_plan.sh $PROJECT --ready-only
4. For each assigned agent, check if they committed since dispatch
   (compare agent_head vs assignments[agent].head_at_dispatch).
5. If committed AND PR exists AND CI green: approve_and_merge.
6. If agent idle with no assignment AND backlog > 0: dispatch next ready ticket.
7. If issue status is atomize: run dispatch_plan --atomize --dry-run first.
8. If agent stuck (no commit in 30+ min, pane shows error): bash \$TK/scripts/recover.sh <agent>.

Concise report (<300 chars): what merged, what dispatched, what's blocked.
EOF
  fi
}

# Capture the system prompt template
SYSTEM_PROMPT_FILE="$TK/templates/orch_briefing.md"
if [[ -f "$SYSTEM_PROMPT_FILE" ]]; then
  n_agents=$(fleet_count)
  SYSTEM_PROMPT=$(sed \
    -e "s|{{PROJECT}}|$PROJECT|g" \
    -e "s|{{GH_REPO}}|$GH_REPO|g" \
    -e "s|{{DEFAULT_BRANCH}}|$DEFAULT_BRANCH|g" \
    -e "s|{{N_AGENTS}}|$n_agents|g" \
    -e "s|{{TK}}|$TK|g" \
    "$SYSTEM_PROMPT_FILE")
else
  n_agents=$(fleet_count)
  SYSTEM_PROMPT="You are the orchestrator for $PROJECT ($GH_REPO). Toolkit at $TK. Coordinate $n_agents agents. PR target=$DEFAULT_BRANCH. Never push direct. Mandatory ORDO operating rules: run readiness preflight before dispatch or after remediation; surface silent blockers as explicit unblock actions; verify after every apply/clone/switch/autofix; run continuation_guard before any final/stop and continue when it says continue_required, dispatch_required, or rebalance_required; capacity with ready work requires dispatch, higher-priority merge/unblock, blocker marking, or explicit remediation before stopping; keep multi-product context isolated to the confirmed target workdir; prefer metadata before pane capture; every operational finding must become a durable improvement opportunity with finding, impact, detection signal, safe remediation candidate, validation/POC plan, and priority."
fi

# Boot
mkdir -p "$(dirname "$LOOP_LOG")"
audit "ORCH_LOOP boot project=$PROJECT cli=$ORCH_CLI_BIN codex_model=$ORCH_CODEX_MODEL claude_model=${ORCH_CLAUDE_MODEL:-default} dry=$ORCH_DRY_RUN"
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
    audit "ORCH_LOOP DRY_RUN, would call $ORCH_CLI_BIN with task: $(head -c 200 <<< "$task")"
    rc=0
  else
    build_supervisor_args "$task"
    orch_log_rotate_if_needed "$LOOP_LOG"
    if "$ORCH_CLI_BIN" "${SUPERVISOR_ARGS[@]}" 2>&1 | tee -a "$LOOP_LOG"; then
      rc=0
    else
      rc=${PIPESTATUS[0]}
    fi
    orch_log_rotate_if_needed "$LOOP_LOG"
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
