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
# shellcheck disable=SC1091
if [[ -f "$TK/lib/portfolio_config.sh" ]]; then
  source "$TK/lib/portfolio_config.sh"
fi
load_project_config "$PROJECT_ARG"

# shellcheck disable=SC1091
source "$TK/lib/audit_log.sh"

# --- #669 single-orchestrator enforcement ---------------------------------
# Refuse to start when the current slot is not authorized to run the
# portfolio supervisor, OR when a competing orchestrator-shaped process is
# already running on a disallowed slot. The canonical operator slot is
# fleet-000 on TECHNAI hosts; profiles may override with
# PORTFOLIO_ORCHESTRATOR_SLOT and grant extra operator slots via
# PORTFOLIO_OPERATOR_SLOTS_EXTRA.
orch_loop_self_slot() {
  local override=${ORCH_FLEET_SLOT:-}
  local candidate slot
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  for candidate in \
    "${PWD:-}" \
    "${ORCH_SUPERVISOR_WORKDIR:-}" \
    "${PROJECT_REPO_ROOT:-}" \
    "${SUPERVISOR_REPO:-}" \
    "$TK"; do
    [[ -n "$candidate" ]] || continue
    if slot=$(portfolio_orchestrator_slot_from_path "$candidate" 2>/dev/null); then
      printf '%s\n' "$slot"
      return 0
    fi
  done
  printf 'unknown\n'
  return 1
}

require_single_orchestrator() {
  if ! declare -F portfolio_orchestrator_allowed_slots >/dev/null 2>&1; then
    return 0
  fi
  local self_slot allowed_slots peer_report drift_rc
  if ! self_slot=$(orch_loop_self_slot); then
    self_slot="unknown"
  fi
  allowed_slots=$(portfolio_orchestrator_allowed_slots | paste -sd ',' -)

  if ! portfolio_orchestrator_slot_allowed "$self_slot"; then
    audit "ORCH_LOOP refused start project=$PROJECT reason=disallowed-orchestrator-slot self_slot=$self_slot allowed=${allowed_slots:-unknown}"
    cat <<EOF >&2
orch_loop.sh refused to start: the current slot is not authorized to run
the portfolio supervisor (#669).

  self_slot     = $self_slot
  allowed_slots = ${allowed_slots:-unknown}

Only the canonical operator slot may run the portfolio supervisor. To
grant a second operator slot intentionally, set PORTFOLIO_ORCHESTRATOR_SLOT
or extend PORTFOLIO_OPERATOR_SLOTS_EXTRA in the portfolio profile.
EOF
    exit 14
  fi

  set +e
  peer_report=$(portfolio_orchestrator_drift_report "$PROJECT" "$$" 2>&1)
  drift_rc=$?
  set -e
  if [[ "$drift_rc" -ne 0 ]]; then
    audit "ORCH_LOOP refused start project=$PROJECT reason=competing-orchestrator self_slot=$self_slot allowed=${allowed_slots:-unknown}"
    {
      printf 'orch_loop.sh refused to start: a competing orchestrator-shaped process is already running on a disallowed slot (#669).\n\n'
      printf '%s\n' "$peer_report"
    } >&2
    exit 14
  fi
  audit "ORCH_LOOP single orchestrator ok project=$PROJECT self_slot=$self_slot allowed=${allowed_slots:-unknown}"
}

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
require_single_orchestrator

# shellcheck disable=SC1091
source "$TK/lib/state_persist.sh"
# shellcheck disable=SC1091
source "$TK/lib/preflight.sh"
# shellcheck disable=SC1091
source "$TK/lib/codex_config_preflight.sh"
# shellcheck disable=SC1091
source "$TK/lib/worktree_helpers.sh"
# shellcheck disable=SC1091
source "$TK/lib/process_safety.sh"
# shellcheck disable=SC1091
source "$TK/lib/monitor_heartbeat.sh"
if [[ -f "$TK/lib/mcp_permission_preflight.sh" ]]; then
  # shellcheck disable=SC1091
  source "$TK/lib/mcp_permission_preflight.sh"
fi
if [[ -f "$TK/lib/ready_queue.sh" ]]; then
  # shellcheck disable=SC1091
  source "$TK/lib/ready_queue.sh"
else
  ordo_ready_queue_count() {
    return 1
  }
fi
# Issue #757: soft-block detection + idle-capacity rebalance step. The lib
# is best-effort; when it is missing from a sanitized toolkit copy the
# orchestrator keeps its previous behavior. agent_softblock_run_rebalance_step
# is invoked once per cycle after the supervisor call so the audit row +
# intervention_queue.md entry reflect the freshest pane state.
if [[ -f "$TK/lib/agent_softblock.sh" ]]; then
  # shellcheck disable=SC1091
  source "$TK/lib/agent_softblock.sh"
fi
if ! declare -F agent_softblock_run_rebalance_step >/dev/null 2>&1; then
  agent_softblock_run_rebalance_step() { return 0; }
fi

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
: "${ORCH_CLI_BIN:=${SUPERVISOR_CLI_BIN:-${ORCH_AGENT_CLI:-}}}" # supervisor LLM CLI binary; project/operator must choose
: "${ORCH_CODEX_MODEL:=gpt-5.5}"   # used only when ORCH_CLI_BIN=codex
: "${ORCH_CODEX_SANDBOX:=danger-full-access}"
: "${ORCH_CODEX_APPROVAL:=never}"
: "${ORCH_CODEX_REASONING:=}"      # optional model_reasoning_effort override
: "${ORCH_SUPERVISOR_WORKDIR:=}"
: "${ORCH_SUPERVISOR_CYCLE_TIMEOUT_SEC:=900}"
: "${ORCH_SUPERVISOR_CYCLE_KILL_AFTER_SEC:=5}"
: "${ORCH_CLAUDE_MODEL:=}"         # only used when ORCH_CLI_BIN=claude
: "${ORCH_DRY_RUN:=false}"
: "${ORCH_READY_QUEUE_TIMEOUT_SEC:=30}"
# Issue #770 — queue resolver phase A wire-in. Default mode is `dry-run`
# so the rollout lands safely; an operator must flip to `apply` (or `off`)
# explicitly. Honoured by orch_auto_close_step below.
: "${ORCH_AUTO_CLOSE_MODE:=dry-run}"
: "${ORCH_AUTO_CLOSE_MAX_PER_HOUR:=1}"

if [[ -z "$ORCH_CLI_BIN" ]]; then
  audit "ORCH_LOOP refused start project=$PROJECT reason=missing-supervisor-cli"
  echo "ORCH_CLI_BIN required: set it in the project config or environment" >&2
  exit 14
fi
preflight_or_die "ORCH_LOOP" "$ORCH_CLI_BIN" gh jq tmux timeout

# Validate Codex runtime config before the loop ever spawns the supervisor.
# An invalid `model_reasoning_effort` (e.g. a quoted variant like `'xhigh'`)
# fails Codex at config-load and burns retry cycles in silence; fail fast
# here with a clear diagnostic instead. Issue #667.
case "$ORCH_CLI_BIN" in
  codex|*/codex)
    codex_config_preflight \
      "$ORCH_CODEX_MODEL" \
      "$ORCH_CODEX_REASONING" \
      "$ORCH_CODEX_APPROVAL" \
      "$ORCH_CODEX_SANDBOX"
    ;;
esac

LOOP_LOG="$ORCH_LOG_DIR/$PROJECT-orch-loop.log"
PAUSE_FLAG="$(state_dir)/orch.paused"
RUN_NOW_FLAG="$(state_dir)/orch.run_now"
STOP_BARRIER_FLAG="$(state_dir)/orch.stop_requested"
CYCLE_COUNT_FILE="$(state_dir)/orch.cycle_count"
LAST_ACTIVITY_FILE="$(state_dir)/orch.last_activity"

# --- Signal handlers ---
SHUTDOWN=false
SUPERVISOR_CHILD_PID=
# #653: SIGTERM/SIGINT engages the no-new-dispatch stop barrier. Setting both
# SHUTDOWN and the on-disk flag means subprocesses (sixsigma_autoupgrade,
# monitor_heartbeat, supervisor cycles) can poll for the barrier even when the
# in-memory variable is unreachable, and a follow-up cycle cannot race a stale
# in-memory state by re-reading the flag from disk.
trap 'SHUTDOWN=true; touch "$STOP_BARRIER_FLAG" 2>/dev/null || true; audit "ORCH_LOOP SIGTERM received, stop barrier engaged, will exit at next safe checkpoint"; if [[ -n "$SUPERVISOR_CHILD_PID" ]]; then kill -TERM "$SUPERVISOR_CHILD_PID" 2>/dev/null || true; fi' TERM INT
trap 'touch "$PAUSE_FLAG"; audit "ORCH_LOOP paused (SIGUSR1)"' USR1
trap 'rm -f "$PAUSE_FLAG"; touch "$RUN_NOW_FLAG"; audit "ORCH_LOOP resumed (SIGUSR2)"' USR2

# stop_requested — return 0 (true) when the no-new-dispatch barrier is set,
# either via the in-memory SHUTDOWN flag or the on-disk barrier file.
# Subprocesses can export ORCH_STOP_BARRIER_FLAG and call this helper to
# uniformly honor a fleet clean / stop request.
stop_requested() {
  [[ "$SHUTDOWN" == "true" ]] && return 0
  [[ -f "$STOP_BARRIER_FLAG" ]] && return 0
  return 1
}

# audit_blocked_dispatch — uniform audit event for dispatch suppressed by the
# stop barrier. The checkpoint argument names the gate that fired so an
# operator post-mortem can reconstruct exactly where the loop stopped.
audit_blocked_dispatch() {
  local checkpoint=${1:-unknown}
  local cycle_label=${2:-pre-cycle}
  audit "ORCH_LOOP_BLOCKED_DISPATCH project=$PROJECT cycle=$cycle_label checkpoint=$checkpoint reason=stop_barrier"
}

export ORCH_STOP_BARRIER_FLAG="$STOP_BARRIER_FLAG"

# --- Helpers ---

shell_quote() {
  printf '%q' "$1"
}

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

canonical_dir() {
  local candidate=${1:?usage: canonical_dir <path>}
  [[ -d "$candidate" ]] || return 1
  (cd "$candidate" && pwd)
}

supervisor_workdir_collides_with_agent() {
  local candidate=${1:?usage: supervisor_workdir_collides_with_agent <path>}
  local candidate_real label pane workdir workdir_real

  candidate_real=$(canonical_dir "$candidate") || return 1
  while IFS='|' read -r label pane workdir; do
    [[ -n "$workdir" && -d "$workdir" ]] || continue
    workdir_real=$(canonical_dir "$workdir") || continue
    if [[ "$candidate_real" == "$workdir_real" ]]; then
      SUPERVISOR_WORKDIR_COLLISION_LABEL=$label
      SUPERVISOR_WORKDIR_COLLISION_PANE=$pane
      SUPERVISOR_WORKDIR_COLLISION_WORKDIR=$workdir_real
      return 0
    fi
  done < <(agent_inventory_entries 2>/dev/null || true)

  return 1
}

supervisor_workdir() {
  local candidate resolved
  for candidate in "$ORCH_SUPERVISOR_WORKDIR" "$TK" "${SUPERVISOR_REPO:-}" "${PROJECT_REPO_ROOT:-}"; do
    if [[ -n "$candidate" && -d "$candidate" ]]; then
      resolved=$(canonical_dir "$candidate") || continue
      if supervisor_workdir_collides_with_agent "$resolved"; then
        audit "ORCH_LOOP refused start project=$PROJECT reason=supervisor-workdir-collides agent=${SUPERVISOR_WORKDIR_COLLISION_LABEL:-unknown} pane=${SUPERVISOR_WORKDIR_COLLISION_PANE:-unknown} workdir=$(shell_quote "${SUPERVISOR_WORKDIR_COLLISION_WORKDIR:-$resolved}")"
        printf 'supervisor workdir collides with AGENT_PANES: agent=%s pane=%s workdir=%s\n' \
          "${SUPERVISOR_WORKDIR_COLLISION_LABEL:-unknown}" \
          "${SUPERVISOR_WORKDIR_COLLISION_PANE:-unknown}" \
          "${SUPERVISOR_WORKDIR_COLLISION_WORKDIR:-$resolved}" >&2
        return 1
      fi
      printf '%s\n' "$resolved"
      return 0
    fi
  done
  audit "ORCH_LOOP refused start project=$PROJECT reason=missing-supervisor-workdir"
  pwd
}

supervisor_cycle_timeout_sec() {
  local timeout_sec=${ORCH_SUPERVISOR_CYCLE_TIMEOUT_SEC:-900}
  if ! [[ "$timeout_sec" =~ ^[0-9]+$ ]] || (( timeout_sec < 1 )); then
    audit "ORCH_LOOP invalid supervisor timeout value=$(shell_quote "$timeout_sec") using=900"
    timeout_sec=900
  fi
  printf '%s\n' "$timeout_sec"
}

supervisor_cycle_kill_after_sec() {
  local kill_after_sec=${ORCH_SUPERVISOR_CYCLE_KILL_AFTER_SEC:-5}
  if ! [[ "$kill_after_sec" =~ ^[0-9]+$ ]] || (( kill_after_sec < 1 )); then
    audit "ORCH_LOOP invalid supervisor kill-after value=$(shell_quote "$kill_after_sec") using=5"
    kill_after_sec=5
  fi
  printf '%s\n' "$kill_after_sec"
}

supervisor_timeout_rc() {
  local rc=${1:?usage: supervisor_timeout_rc <rc>}
  [[ "$rc" -eq "$ORCH_TIMEOUT_EXIT_CODE" || "$rc" -eq 137 ]]
}

build_supervisor_args() {
  local task=${1:?usage: build_supervisor_args <task>}
  SUPERVISOR_ARGS=()
  case "$ORCH_CLI_BIN" in
    codex|*/codex)
      SUPERVISOR_ARGS=(
        exec
        --ephemeral
        -C "$(supervisor_workdir)"
        -m "$ORCH_CODEX_MODEL"
      )
      if [[ -n "$ORCH_CODEX_REASONING" ]]; then
        SUPERVISOR_ARGS+=(-c "model_reasoning_effort=$ORCH_CODEX_REASONING")
      fi
      if [[ "$ORCH_CODEX_APPROVAL" == "never" ]]; then
        SUPERVISOR_ARGS+=(--dangerously-bypass-approvals-and-sandbox)
      else
        SUPERVISOR_ARGS+=(-s "$ORCH_CODEX_SANDBOX")
      fi
      SUPERVISOR_ARGS+=("$(printf '%s\n\n%s\n' "$SYSTEM_PROMPT" "$task")")
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
  local ready_queue_count
  ready_queue_count=$(ORDO_READY_QUEUE_TIMEOUT_SEC="$ORCH_READY_QUEUE_TIMEOUT_SEC" \
    ordo_ready_queue_count "$PROJECT_ARG" 2>/dev/null || echo "?")

  if [[ "$cycle" -eq 1 ]]; then
    cat <<EOF
ORCH CYCLE 1 (cold start) for project=$PROJECT.

State:
- Agents: $n_agents total, $n_assigned currently assigned
- Backlog (dispatch_plan --ready-only): $ready_queue_count

Your toolkit is at \$TK=$TK. Source the config first:
  source ${ORCH_CONFIG_PATH:-\$TK/examples/$PROJECT.config.sh}

Required first actions:
1. bash \$TK/scripts/audit_state.sh $PROJECT   (snapshot what's running)
2. bash \$TK/scripts/project_meta_context.sh $PROJECT
3. Completed-run handoff before capacity accounting: inspect assigned
   agents at final report / idle prompt before any busy-capacity claim.
   Hand off committed branches through integration / PR policy, record
   submitted or no-op evidence, and release or park stale assignments
   according to policy.
4. Re-read assignments, agent pool status, and capacity after the handoff.
   Do not count pre-handoff assignment rows as busy capacity.
5. bash \$TK/scripts/dispatch_plan.sh $PROJECT --ready-only
6. Review the snapshot — are there agents stuck (idle but with WIP)?
7. If PR blockers show merge-ready, drain with bash \$TK/lib/pr_merge.sh <project> <pr> or emit a concrete no-merge reason.
8. If safe: bash \$TK/scripts/cycle.sh $PROJECT <wave>   (one full cycle)

Constraints:
- One issue per agent maximum.
- PR target = $DEFAULT_BRANCH only.
- Use pr_can_merge() before any merge attempt.
- Never push to a protected branch directly.

Report back: what you did, what's blocked, what you'll do next cycle.
EOF
  else
    cat <<EOF
ORCH CYCLE $cycle for project=$PROJECT.

State (pre-handoff snapshot only):
- Agents: $n_agents total, $n_assigned assignments recorded before completed-run handoff
- Backlog (dispatch_plan --ready-only): $ready_queue_count

Standard cycle actions:
1. bash \$TK/scripts/audit_state.sh $PROJECT
2. bash \$TK/scripts/project_meta_context.sh $PROJECT
3. Completed-run handoff before capacity accounting: inspect assigned
   agents at final report / idle prompt before any busy-capacity claim.
   If an assigned agent has committed work ahead of $DEFAULT_BRANCH, hand
   it off through the project integration / PR path before dispatching more
   work. If an assigned agent already has an open PR or the work is a
   verified no-op already contained in $DEFAULT_BRANCH, record the handoff
   evidence and release or park the stale assignment according to policy.
   Do not count pre-handoff assignment rows as busy capacity.
4. Re-read assignments, agent pool status, and capacity after completed-run
   handoff. Only then decide whether slots are busy, parkable, switchable,
   or free.
5. bash \$TK/scripts/dispatch_plan.sh $PROJECT --ready-only
6. For each remaining assigned agent, check if they committed since dispatch
   (compare agent_head vs assignments[agent].head_at_dispatch).
7. If committed AND PR exists AND CI green: approve_and_merge.
8. If PR blockers show merge-ready, drain with bash \$TK/lib/pr_merge.sh <project> <pr> or emit a concrete no-merge reason.
9. If agent idle with no assignment AND backlog > 0: dispatch next ready ticket.
10. If issue status is atomize: run dispatch_plan --atomize --dry-run first.
11. If agent stuck (no commit in 30+ min, pane shows error): bash \$TK/scripts/recover.sh <agent>.

Concise report (<300 chars): what merged, what dispatched, what's blocked.
EOF
  fi
}

orch_template_escape_value() {
  local value=${1:-}
  value=${value//\\/\\\\}
  value=${value//&/\\&}
  printf '%s' "$value"
}

orch_supervisor_pane_label() {
  local target

  for target in \
    "${ORCH_SUPERVISOR_TARGET:-}" \
    "${CI_WATCHER_ORCH_PANE:-}" \
    "${ORCH_TMUX_TARGET:-}"; do
    [[ -n "$target" ]] || continue
    case "$target" in
      *:*) printf '%s\n' "$target" ;;
      *) printf '%s:0.0\n' "$target" ;;
    esac
    return 0
  done

  printf '%s%s:0.0\n' "${AGENT_SESSION_PREFIX:-}" "${ORCH_PANE_NAME:-orchestrator}"
}

orch_agents_list() {
  local entry label pane workdir extra emitted=0

  while IFS='|' read -r label pane workdir extra; do
    [[ -n "${label:-}${pane:-}${workdir:-}" ]] || continue
    if [[ -n "${extra:-}" ]]; then
      continue
    fi
    printf '%s\n' "- \`$label\` | pane \`$pane\` | workdir \`$workdir\`"
    emitted=1
  done < <(agent_inventory_entries 2>/dev/null || true)

  if [[ "$emitted" -eq 0 ]]; then
    printf -- '- none configured\n'
  fi
}

orch_hot_spots_list() {
  local path emitted=0

  if [[ -n "${HOT_SPOTS+x}" && "${#HOT_SPOTS[@]}" -gt 0 ]]; then
    for path in "${HOT_SPOTS[@]}"; do
      [[ -n "$path" ]] || continue
      printf '%s\n' "- \`$path\`"
      emitted=1
    done
  fi

  if [[ "$emitted" -eq 0 ]]; then
    printf -- '- none configured\n'
  fi
}

orch_render_system_prompt() {
  local template_file=${1:?usage: orch_render_system_prompt <template-file>}
  local content key val n_agents agents_list hot_spots orch_pane
  declare -A replacements=()

  content=$(<"$template_file")
  n_agents=$(fleet_count)
  agents_list=$(orch_agents_list)
  hot_spots=$(orch_hot_spots_list)
  orch_pane=$(orch_supervisor_pane_label)

  replacements=(
    [project]="$PROJECT"
    [PROJECT]="$PROJECT"
    [repo]="$GH_REPO"
    [GH_REPO]="$GH_REPO"
    [default_branch]="$DEFAULT_BRANCH"
    [DEFAULT_BRANCH]="$DEFAULT_BRANCH"
    [n_agents]="$n_agents"
    [N_AGENTS]="$n_agents"
    [TK]="$TK"
    [orch_pane]="$orch_pane"
    [agents_list]="$agents_list"
    [hot_spots]="$hot_spots"
  )

  for key in "${!replacements[@]}"; do
    val=$(orch_template_escape_value "${replacements[$key]}")
    content=${content//\{\{${key}\}\}/$val}
  done

  if [[ "$content" =~ \{\{[A-Za-z_][A-Za-z0-9_]*\}\} ]]; then
    printf 'orch_loop: unresolved system prompt placeholder %s\n' \
      "${BASH_REMATCH[0]}" >&2
    return 1
  fi

  printf '%s\n' "$content"
}

# --- Auto-atomize step (#763) ---------------------------------------------
# Queue resolver phase B: when the supervisor's ready queue is empty AND no
# shipped_suspect rows remain AND the planner still carries needs-atomization
# parents, deterministically call dispatch_plan --atomize so the next cycle
# has dispatchable child issues. Capped per cycle (ORCH_AUTO_ATOMIZE_MAX_PER_CYCLE,
# default 2) AND per rolling hour (ORCH_AUTO_ATOMIZE_MAX_PER_HOUR, default 6)
# via the on-disk ledger so a runaway supervisor cannot mass-create issues.

orch_auto_atomize_budget_remaining() {
  local ledger=${1:?usage: orch_auto_atomize_budget_remaining <ledger>}
  local hourly_cap=${ORCH_AUTO_ATOMIZE_MAX_PER_HOUR:-6}
  local now used cutoff remaining
  now=$(date +%s)
  cutoff=$((now - 3600))
  used=0
  if [[ -f "$ledger" ]]; then
    used=$(awk -v cutoff="$cutoff" '$1 >= cutoff {n++} END{print n+0}' "$ledger")
  fi
  remaining=$((hourly_cap - used))
  if (( remaining < 0 )); then
    remaining=0
  fi
  printf '%s\n' "$remaining"
}

orch_auto_atomize_should_run() {
  local plan_json=${1:?usage: orch_auto_atomize_should_run <plan-json>}
  local ready_count atomize_count shipped_count
  if ! ready_count=$(jq -r '[.[]? | select(.status == "ready")] | length' <<<"$plan_json" 2>/dev/null); then
    return 1
  fi
  atomize_count=$(jq -r '[.[]? | select(.status == "atomize" or .status == "stale_parent")] | length' <<<"$plan_json" 2>/dev/null)
  shipped_count=$(jq -r '[.[]? | select(.status == "shipped_suspect")] | length' <<<"$plan_json" 2>/dev/null)
  AUTO_ATOMIZE_LAST_READY=$ready_count
  AUTO_ATOMIZE_LAST_ATOMIZE=$atomize_count
  AUTO_ATOMIZE_LAST_SHIPPED=$shipped_count
  [[ "$ready_count" -eq 0 && "$shipped_count" -eq 0 && "$atomize_count" -gt 0 ]]
}

orch_auto_atomize_step() {
  local cycle=${1:?usage: orch_auto_atomize_step <cycle>}
  local ledger=${ORCH_AUTO_ATOMIZE_LEDGER:-$(state_dir)/auto_atomize.ledger}
  local plan_json plan_rc
  plan_json=$(bash "$TK/scripts/dispatch_plan.sh" "$PROJECT_ARG" --json 2>/dev/null)
  plan_rc=$?
  if [[ "$plan_rc" -ne 0 ]]; then
    audit "AUTO_ATOMIZE skip cycle=$cycle project=$PROJECT reason=plan-failed rc=$plan_rc"
    return 0
  fi
  if ! orch_auto_atomize_should_run "$plan_json"; then
    audit "AUTO_ATOMIZE skip cycle=$cycle project=$PROJECT reason=conditions-unmet ready=${AUTO_ATOMIZE_LAST_READY:-?} atomize=${AUTO_ATOMIZE_LAST_ATOMIZE:-?} shipped_suspect=${AUTO_ATOMIZE_LAST_SHIPPED:-?}"
    return 0
  fi
  local hourly_cap=${ORCH_AUTO_ATOMIZE_MAX_PER_HOUR:-6}
  local cycle_cap=${ORCH_AUTO_ATOMIZE_MAX_PER_CYCLE:-2}
  local remaining budget
  remaining=$(orch_auto_atomize_budget_remaining "$ledger")
  if [[ "$remaining" -le 0 ]]; then
    audit "AUTO_ATOMIZE skip cycle=$cycle project=$PROJECT reason=hourly-cap-exhausted cap=$hourly_cap"
    return 0
  fi
  budget=$cycle_cap
  if (( budget > remaining )); then
    budget=$remaining
  fi
  local summary_file
  summary_file=$(mktemp)
  bash "$TK/scripts/dispatch_plan.sh" "$PROJECT_ARG" \
    --atomize --apply --max-children-per-cycle "$budget" \
    >/dev/null 2> "$summary_file" || true
  local now line parent children child
  now=$(date +%s)
  while IFS= read -r line; do
    case "$line" in
      AUTO_ATOMIZE_SUMMARY*)
        parent=$(printf '%s\n' "$line" | sed -n 's/.*parent=\([0-9][0-9]*\).*/\1/p')
        children=$(printf '%s\n' "$line" | sed -n 's/.*children=\([0-9,]*\).*/\1/p')
        [[ -n "$parent" ]] || continue
        audit "AUTO_ATOMIZE parent=#${parent} children=[$(printf '%s' "${children:-}" | sed 's/,/,#/g; s/^/#/; s/^#$//')] cycle=$cycle project=$PROJECT mode=apply max_per_cycle=$budget hourly_cap=$hourly_cap"
        if [[ -n "$children" ]]; then
          local IFS_old=$IFS
          IFS=,
          for child in $children; do
            [[ -n "$child" ]] || continue
            printf '%s %s %s %s\n' "$now" "$parent" "$child" "$cycle" >> "$ledger"
          done
          IFS=$IFS_old
        fi
        ;;
    esac
  done < "$summary_file"
  rm -f "$summary_file"
}

# --- Auto-close step (#770) -----------------------------------------------
# Queue resolver phase A wire-in. When the planner still carries
# `shipped_suspect` rows AND ORCH_AUTO_CLOSE_MODE is `dry-run` or `apply`,
# invoke scripts/auto_close_shipped_suspect.sh once per cycle. The lib
# (landed by #762) classifies each candidate through
# closure_acceptance_gate and only closes when the gate says yes; this
# wire-in adds the autonomous trigger so a queue-starvation cycle on
# shipped-suspect-review-required no longer requires an operator drain.
#
# Rate-limit (default 1/hour) is enforced via an on-disk ledger; one row
# per successful run regardless of candidate count, because closures
# persist and one drain per hour is plenty.
#
# Apply-mode close_failed records (typically rc=80 from the closed-issue
# mutation hook that refuses bot-account closes on pre-existing issues)
# surface OPERATOR_AUTHORIZATION_REQUIRED + one intervention_queue.md row
# per affected issue so an operator can re-run the same call from an
# account that bypasses the hook in one keystroke.

orch_auto_close_budget_remaining() {
  local ledger=${1:?usage: orch_auto_close_budget_remaining <ledger>}
  local hourly_cap=${ORCH_AUTO_CLOSE_MAX_PER_HOUR:-1}
  local now used cutoff remaining
  now=$(date +%s)
  cutoff=$((now - 3600))
  used=0
  if [[ -f "$ledger" ]]; then
    used=$(awk -v cutoff="$cutoff" '$1 >= cutoff {n++} END{print n+0}' "$ledger")
  fi
  remaining=$((hourly_cap - used))
  if (( remaining < 0 )); then
    remaining=0
  fi
  printf '%s\n' "$remaining"
}

orch_auto_close_should_run() {
  local plan_json=${1:?usage: orch_auto_close_should_run <plan-json>}
  local shipped_count
  if ! shipped_count=$(jq -r '[.[]? | select(.status == "shipped_suspect")] | length' <<<"$plan_json" 2>/dev/null); then
    return 1
  fi
  AUTO_CLOSE_LAST_SHIPPED=$shipped_count
  [[ "$shipped_count" -gt 0 ]]
}

orch_auto_close_append_intervention() {
  local queue_path=${1:?usage: orch_auto_close_append_intervention <queue> <issue> <pr> <reason>}
  local issue=${2:-unknown}
  local pr=${3:-unknown}
  local reason=${4:-}
  local ts
  ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  mkdir -p "$(dirname "$queue_path")" 2>/dev/null || true
  if [[ ! -s "$queue_path" ]]; then
    {
      printf '# ORDO intervention queue\n\n'
      printf '| timestamp | agent | ticket | blocker_excerpt | recommended_action |\n'
      printf '| --- | --- | --- | --- | --- |\n'
    } > "$queue_path"
  fi
  local clean_reason
  clean_reason=$(printf '%s' "$reason" | tr '\n' ' ' | tr '|' '/' | awk '{ sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }')
  [[ -n "$clean_reason" ]] || clean_reason='(no reason captured)'
  printf '| %s | auto_close_shipped_suspect | %s | merged-pr=%s reason=%s | re-run auto_close_shipped_suspect.sh %s --apply from an operator account that bypasses the closed-issue mutation hook |\n' \
    "$ts" "$issue" "$pr" "$clean_reason" "$PROJECT_ARG" >> "$queue_path"
}

orch_auto_close_step() {
  local cycle=${1:?usage: orch_auto_close_step <cycle>}
  local mode=${ORCH_AUTO_CLOSE_MODE:-dry-run}
  local ledger=${ORCH_AUTO_CLOSE_LEDGER:-$(state_dir)/auto_close.ledger}
  local queue_path=${ORCH_AUTO_CLOSE_QUEUE:-$(state_dir)/intervention_queue.md}
  case "$mode" in
    off)
      audit "AUTO_CLOSE skip cycle=$cycle project=$PROJECT reason=mode-off"
      return 0
      ;;
    dry-run|apply) ;;
    *)
      audit "AUTO_CLOSE skip cycle=$cycle project=$PROJECT reason=invalid-mode mode=$mode"
      return 0
      ;;
  esac
  local plan_json plan_rc
  plan_json=$(bash "$TK/scripts/dispatch_plan.sh" "$PROJECT_ARG" --include-shipped-suspect --json 2>/dev/null)
  plan_rc=$?
  if [[ "$plan_rc" -ne 0 ]]; then
    audit "AUTO_CLOSE skip cycle=$cycle project=$PROJECT reason=plan-failed rc=$plan_rc"
    return 0
  fi
  if ! orch_auto_close_should_run "$plan_json"; then
    audit "AUTO_CLOSE skip cycle=$cycle project=$PROJECT reason=no-shipped-suspect shipped_suspect=${AUTO_CLOSE_LAST_SHIPPED:-0}"
    return 0
  fi
  local hourly_cap=${ORCH_AUTO_CLOSE_MAX_PER_HOUR:-1}
  local remaining
  remaining=$(orch_auto_close_budget_remaining "$ledger")
  if [[ "$remaining" -le 0 ]]; then
    audit "AUTO_CLOSE skip cycle=$cycle project=$PROJECT reason=hourly-cap-exhausted cap=$hourly_cap"
    return 0
  fi

  local result_file
  result_file=$(mktemp)
  bash "$TK/scripts/auto_close_shipped_suspect.sh" "$PROJECT_ARG" \
    "--$mode" --json >"$result_file" 2>/dev/null || true

  local ac_candidates=0 closed=0 would_close=0 refused=0 close_failed=0
  if [[ -s "$result_file" ]] && jq -e 'type == "array"' >/dev/null 2>&1 <"$result_file"; then
    ac_candidates=$(jq -r 'length' "$result_file" 2>/dev/null || echo 0)
    closed=$(jq -r '[.[] | select(.action == "closed")] | length' "$result_file" 2>/dev/null || echo 0)
    would_close=$(jq -r '[.[] | select(.action == "would_close")] | length' "$result_file" 2>/dev/null || echo 0)
    refused=$(jq -r '[.[] | select(.action == "audit_only" or .action == "skip")] | length' "$result_file" 2>/dev/null || echo 0)
    close_failed=$(jq -r '[.[] | select(.action == "close_failed")] | length' "$result_file" 2>/dev/null || echo 0)
  fi

  local now
  now=$(date +%s)
  mkdir -p "$(dirname "$ledger")" 2>/dev/null || true
  printf '%s %s %s %s\n' "$now" "$cycle" "$mode" "$ac_candidates" >> "$ledger"

  audit "ORCH_LOOP AUTO_CLOSE_RAN cycle=$cycle project=$PROJECT mode=$mode candidates=$ac_candidates closed=$closed would_close=$would_close refused=$refused close_failed=$close_failed hourly_cap=$hourly_cap"

  if [[ "$mode" == "apply" && "$close_failed" -gt 0 ]]; then
    local affected_issues
    affected_issues=$(jq -r '[.[] | select(.action == "close_failed") | "#" + (.issue|tostring)] | join(",")' "$result_file" 2>/dev/null)
    audit "ORCH_LOOP OPERATOR_AUTHORIZATION_REQUIRED cycle=$cycle project=$PROJECT reason=close-failed-hook issues=${affected_issues:-none} queue_path=$queue_path"
    while IFS= read -r row_b64; do
      [[ -n "$row_b64" ]] || continue
      local row issue pr reason
      row=$(printf '%s' "$row_b64" | base64 -d)
      issue=$(jq -r '.issue' <<<"$row")
      pr=$(jq -r '.pr' <<<"$row")
      reason=$(jq -r '.reason' <<<"$row")
      orch_auto_close_append_intervention "$queue_path" "#${issue}" "#${pr}" "$reason"
    done < <(jq -r '[.[] | select(.action == "close_failed")] | .[] | @base64' "$result_file" 2>/dev/null)
  fi
  rm -f "$result_file"
}

# Capture the system prompt template
SYSTEM_PROMPT_FILE="$TK/templates/orch_briefing.md"
if [[ -f "$SYSTEM_PROMPT_FILE" ]]; then
  if ! SYSTEM_PROMPT=$(orch_render_system_prompt "$SYSTEM_PROMPT_FILE"); then
    audit "ORCH_LOOP refused start project=$PROJECT reason=unresolved-system-prompt-placeholder"
    exit 14
  fi
else
  n_agents=$(fleet_count)
  SYSTEM_PROMPT="You are the orchestrator for $PROJECT ($GH_REPO). Toolkit at $TK. Coordinate $n_agents agents. PR target=$DEFAULT_BRANCH. Never push direct. Mandatory ORDO operating rules: run readiness preflight before dispatch or after remediation; surface silent blockers as explicit unblock actions; verify after every apply/clone/switch/autofix; Completed-run handoff before capacity accounting: inspect final-report or idle assigned agents, hand off committed branches through integration/PR policy, release or park verified submitted/no-op assignments, then re-read structured capacity; Do not count pre-handoff assignment rows as busy capacity; run continuation_guard before any final/stop and continue when it says continue_required, dispatch_required, or rebalance_required; capacity with ready work requires dispatch, higher-priority merge/unblock, blocker marking, or explicit remediation before stopping; keep multi-product context isolated to the confirmed target workdir; prefer metadata before terminal capture; every operational finding promoted to product work must become a durable CAPA or self-improvement item with finding, impact, detection signal, safe remediation candidate, validation/POC plan, priority, and linked audit evidence; IQ/OQ/PQ reports must reference CAPA items they create, close, or rely on; live findings ledgers must stay outside active worktrees by default and be curated into tracked items."
fi

# Boot
mkdir -p "$(dirname "$LOOP_LOG")"
audit "ORCH_LOOP boot project=$PROJECT cli=$ORCH_CLI_BIN codex_model=$ORCH_CODEX_MODEL codex_reasoning=${ORCH_CODEX_REASONING:-default} codex_approval=$ORCH_CODEX_APPROVAL codex_sandbox=$ORCH_CODEX_SANDBOX claude_model=${ORCH_CLAUDE_MODEL:-default} dry=$ORCH_DRY_RUN"
# #653: a stale stop-barrier file from a previous run would otherwise refuse
# the very first cycle of a fresh, daemon-confirmed start. The daemon-confirm
# gate above already authorized this fresh start, so clear the flag and audit
# the clear so operators can see it in post-mortems.
if [[ -f "$STOP_BARRIER_FLAG" ]]; then
  audit "ORCH_LOOP clearing stale stop barrier on boot path=$STOP_BARRIER_FLAG"
  rm -f "$STOP_BARRIER_FLAG"
fi
if worktree_enabled; then
  worktree_cleanup_stale || audit "WORKTREE CLEANUP WARN project=$PROJECT"
fi
echo 0 > "$CYCLE_COUNT_FILE"

# --- Main loop ---
while true; do
  # #653: the stop barrier is the canonical no-new-dispatch gate. Check it
  # before SHUTDOWN so an externally-set flag (orch_ctl stop, fleet clean
  # script, operator `touch`) is honored even if no signal was delivered.
  if stop_requested; then
    audit "ORCH_LOOP shutdown clean reason=stop_barrier shutdown=$SHUTDOWN flag_present=$([[ -f "$STOP_BARRIER_FLAG" ]] && echo true || echo false)"
    exit 0
  fi

  # Pause check
  if [[ -f "$PAUSE_FLAG" ]]; then
    audit "ORCH_LOOP paused, sleeping 30s waiting for SIGUSR2"
    sleep 30
    continue
  fi

  # #653: re-check the stop barrier immediately after the pause sleep — a
  # SIGTERM during the 30s pause-wait must not bleed into a dispatch.
  if stop_requested; then
    audit_blocked_dispatch pre-cycle "$(cat "$CYCLE_COUNT_FILE" 2>/dev/null || echo 0)"
    audit "ORCH_LOOP shutdown clean reason=stop_barrier_after_pause"
    exit 0
  fi

  cycle=$(($(cat "$CYCLE_COUNT_FILE") + 1))
  echo "$cycle" > "$CYCLE_COUNT_FILE"
  cycle_start=$(date +%s)

  audit "ORCH_LOOP === cycle $cycle start ==="

  # Issue #350: opt-in prompt-unblock consumer hook. Default OFF (the
  # consumer is profile-gated audit-only — see lib/prompt_unblock_policy.sh).
  # When ORCH_PROMPT_UNBLOCK_ENABLED=1, refresh lane states + the
  # operator-action queue from the detector ledger before the per-cycle
  # task prompt is built so the supervisor sees fresh blocker context.
  # Live-grant requires a SECOND opt-in (ORCH_PROMPT_UNBLOCK_LIVE_GRANT=1)
  # so a stale prompt-unblock policy entry cannot silently answer
  # prompts on its own.
  if [[ "${ORCH_PROMPT_UNBLOCK_ENABLED:-0}" == "1" ]]; then
    prompt_unblock_consume_args=(--since-last)
    if [[ "${ORCH_PROMPT_UNBLOCK_LIVE_GRANT:-0}" == "1" ]]; then
      prompt_unblock_consume_args+=(--live-grant)
    fi
    if bash "$TK/scripts/prompt_unblock_consume.sh" "${prompt_unblock_consume_args[@]}" \
        >/dev/null 2>>"$LOOP_LOG"; then
      audit "ORCH_LOOP prompt-unblock consume cycle=$cycle live_grant=${ORCH_PROMPT_UNBLOCK_LIVE_GRANT:-0}"
    else
      audit "ORCH_LOOP prompt-unblock consume FAILED cycle=$cycle (continuing)"
    fi
  fi

  # #653: final pre-dispatch barrier check. The supervisor cycle is the
  # primary dispatch surface (ticket validation, dispatch, manual resubmit,
  # poll registration all live inside it). If the operator engaged the stop
  # barrier between cycles or during the prompt-unblock consume above, refuse
  # to start the supervisor and exit clean.
  if stop_requested; then
    audit_blocked_dispatch pre-supervisor-dispatch "$cycle"
    audit "ORCH_LOOP shutdown clean reason=stop_barrier_pre_dispatch cycle=$cycle"
    exit 0
  fi

  task=$(build_task_prompt "$cycle")

  if [[ "$ORCH_DRY_RUN" == "true" ]]; then
    audit "ORCH_LOOP DRY_RUN, would call $ORCH_CLI_BIN with task: $(head -c 200 <<< "$task")"
    rc=0
  else
    build_supervisor_args "$task"
    orch_log_rotate_if_needed "$LOOP_LOG"
    supervisor_timeout_sec=$(supervisor_cycle_timeout_sec)
    supervisor_kill_after_sec=$(supervisor_cycle_kill_after_sec)
    # #653: track the supervisor pipeline pid so the TERM trap can forward
    # the signal. Without forwarding, an operator's SIGTERM only sets the
    # in-memory flag — the in-progress supervisor invocation keeps running
    # until its full timeout, and any dispatch it issues lands AFTER the
    # operator engaged the clean stop.
    timeout -k "$supervisor_kill_after_sec" "$supervisor_timeout_sec" \
        "$ORCH_CLI_BIN" "${SUPERVISOR_ARGS[@]}" 2>&1 | tee -a "$LOOP_LOG" &
    SUPERVISOR_CHILD_PID=$!
    if wait "$SUPERVISOR_CHILD_PID"; then
      rc=0
    else
      rc=$?
    fi
    SUPERVISOR_CHILD_PID=
    if supervisor_timeout_rc "$rc"; then
      audit "ORCH_LOOP_SUPERVISOR_TIMEOUT cycle=$cycle rc=$rc timeout_sec=$supervisor_timeout_sec kill_after_sec=$supervisor_kill_after_sec action=killed"
    fi
    orch_log_rotate_if_needed "$LOOP_LOG"
  fi

  cycle_end=$(date +%s)
  cycle_duration=$((cycle_end - cycle_start))
  audit "ORCH_LOOP cycle $cycle ended rc=$rc duration=${cycle_duration}s"

  # #653: post-supervisor stop-barrier checkpoint. SIGTERM during the
  # supervisor cycle terminated the child; the loop must not advance to
  # sixsigma autofix dispatch or the heartbeat probe (which can set the
  # run-now flag) when the operator has engaged a clean stop.
  if stop_requested; then
    audit_blocked_dispatch post-supervisor "$cycle"
    audit "ORCH_LOOP shutdown clean reason=stop_barrier_post_supervisor cycle=$cycle"
    exit 0
  fi

  # Issue #670 — classify MCP auth noise from the recent supervisor cycle
  # so Cloudflare/Codex MCP `invalid_token` / `AuthRequired` lines do not
  # look like fatal startup failures unless the active assignment actually
  # needs that MCP server. Bound the scan with a tail so the work stays
  # constant per cycle even on a long-running loop log. The classifier
  # lives in lib/mcp_permission_preflight.sh which is optional in
  # sanitized test sandboxes — skip the block when the helper is absent.
  if [[ -f "$LOOP_LOG" ]]       && declare -F mcp_preflight_classify_startup_log >/dev/null 2>&1; then
    mcp_classify_tail_lines=${ORCH_MCP_AUTH_SCAN_LINES:-400}
    mcp_classify_tmp=$(mktemp 2>/dev/null) || mcp_classify_tmp=""
    if [[ -n "$mcp_classify_tmp" ]] \
        && tail -n "$mcp_classify_tail_lines" "$LOOP_LOG" >"$mcp_classify_tmp" 2>/dev/null; then
      while IFS= read -r mcp_classification; do
        [[ -n "$mcp_classification" ]] || continue
        case "$mcp_classification" in
          *severity=blocking*)
            audit_action ORCH_LOOP_MCP_AUTH_BLOCKING cycle="$cycle" \
              project="$PROJECT" detail="$mcp_classification"
            ;;
          *)
            audit_action ORCH_LOOP_MCP_AUTH_NONBLOCKING cycle="$cycle" \
              project="$PROJECT" detail="$mcp_classification"
            ;;
        esac
      done < <(mcp_preflight_classify_startup_log "$mcp_classify_tmp" \
                "${ORDO_MCP_REQUIRED_FOR_PROJECT:-}" \
                "${ORDO_MCP_DEGRADED_FOR_PROJECT:-}" || true)
    fi
    [[ -n "$mcp_classify_tmp" ]] && rm -f "$mcp_classify_tmp"
  fi

  # Update activity timestamp if cycle did something
  if grep -qE 'DISPATCH|merged|RECOVER' <<< "$(tail -200 "$ORCH_LOG_DIR/$PROJECT.log" 2>/dev/null)"; then
    date +%s > "$LAST_ACTIVITY_FILE"
  fi

  # Issue #764 — queue-resolver phase C: reclaim orphan GitHub assignees.
  # dispatch_plan marks rows as `status="assigned"` whenever a GitHub
  # assignee is present, which excludes them from --ready-only AND never
  # gets reclaimed when the login does not map to any active fleet slot
  # (AGENT_GH_LOGINS). When the ready queue is empty AND assigned rows
  # exist, invoke reclaim_orphan_assignments.sh --apply so the next
  # cycle's --ready-only scan can pick the row up. Opt-out via
  # ORCH_RECLAIM_ORPHAN_DISABLED=1 for hosts where the orphan policy is
  # owned by an external supervisor.
  if stop_requested; then
    audit_blocked_dispatch reclaim-orphan-assignments "$cycle"
  elif [[ "${ORCH_RECLAIM_ORPHAN_DISABLED:-0}" != "1" ]]; then
    reclaim_ready_count=$(ORDO_READY_QUEUE_TIMEOUT_SEC="$ORCH_READY_QUEUE_TIMEOUT_SEC" \
      ordo_ready_queue_count "$PROJECT_ARG" 2>/dev/null || printf '')
    if [[ "$reclaim_ready_count" =~ ^[0-9]+$ ]] && [[ "$reclaim_ready_count" -eq 0 ]]; then
      reclaim_dispatch_timeout=${ORCH_RECLAIM_DISPATCH_TIMEOUT_SEC:-${ORCH_READY_QUEUE_TIMEOUT_SEC}}
      reclaim_plan_json=$(orch_run_timeout "$reclaim_dispatch_timeout" \
          bash "$TK/scripts/dispatch_plan.sh" "$PROJECT_ARG" --json 2>/dev/null || printf '[]')
      reclaim_assigned_count=$(jq -r '[.[]? | select(.status == "assigned" and ((.assignees // []) | length > 0))] | length' <<< "$reclaim_plan_json" 2>/dev/null || printf '0')
      if [[ "$reclaim_assigned_count" =~ ^[0-9]+$ ]] && [[ "$reclaim_assigned_count" -gt 0 ]]; then
        reclaim_args=("$PROJECT_ARG")
        if [[ "$ORCH_DRY_RUN" == "true" ]]; then
          reclaim_args+=(--dry-run)
        else
          reclaim_args+=(--apply)
        fi
        if bash "$TK/scripts/reclaim_orphan_assignments.sh" "${reclaim_args[@]}" \
             >>"$LOOP_LOG" 2>&1; then
          audit "ORCH_LOOP RECLAIM_ORPHAN OK cycle=$cycle project=$PROJECT assigned_count=$reclaim_assigned_count mode=${reclaim_args[1]}"
        else
          audit "ORCH_LOOP RECLAIM_ORPHAN WARN cycle=$cycle project=$PROJECT assigned_count=$reclaim_assigned_count mode=${reclaim_args[1]} (cycle continues)"
        fi
      fi
    fi
  fi

  # Issue #757 — soft-block detection + rebalance. When the per-cycle pane
  # scan finds at least one soft-blocked agent AND at least one idle agent,
  # emit a structured REBALANCE_REQUIRED audit row and append a row per
  # soft-blocked agent to `$(state_dir)/intervention_queue.md`. The step is
  # opt-out (ORCH_SOFTBLOCK_DISABLED=1) so an operator that runs an
  # external monitor can suppress it. Failure is non-fatal: the helper
  # always returns 0 and the cycle continues.
  if stop_requested; then
    audit_blocked_dispatch softblock-rebalance "$cycle"
  else
    if agent_softblock_run_rebalance_step "$PROJECT" "$(state_dir)" \
         >>"$LOOP_LOG" 2>&1; then
      audit "ORCH_LOOP SOFTBLOCK OK cycle=$cycle project=$PROJECT"
    else
      audit "ORCH_LOOP SOFTBLOCK WARN cycle=$cycle project=$PROJECT (cycle continues)"
    fi
  fi

  # #245 — Six Sigma auto-upgrade is standard daemon cycle behavior. The
  # script observes the open PR pool, audits PR signals, and dispatches
  # CI autofix only for failed checks (capped by SIXSIGMA_MAX_AUTOFIX_*).
  # We run it after the supervisor's cycle completes and BEFORE the
  # heartbeat so the next snapshot captures any autofix-induced state
  # changes. Failure MUST warn + audit but never abort the daemon — the
  # supervisor cycle already advanced the pool, sixsigma is the
  # opportunistic upgrade. Output is appended to the loop log so the
  # main audit log keeps its single-line invariant. Operators who want to
  # opt out (e.g. on a constrained host) set ORCH_SIXSIGMA_DISABLED=1.
  if [[ "${ORCH_SIXSIGMA_DISABLED:-0}" != "1" ]]; then
    # #653: sixsigma autoupgrade can dispatch CI autofix jobs. Suppress the
    # invocation entirely when the stop barrier is engaged so a clean stop
    # request does not race with autofix dispatch.
    if stop_requested; then
      audit_blocked_dispatch sixsigma-autoupgrade "$cycle"
    else
      sixsigma_args=("$PROJECT_ARG")
      if [[ "$ORCH_DRY_RUN" == "true" ]]; then
        sixsigma_args+=(--dry-run)
      fi
      if bash "$TK/scripts/sixsigma_autoupgrade.sh" "${sixsigma_args[@]}" \
           >>"$LOOP_LOG" 2>&1; then
        audit "ORCH_LOOP SIXSIGMA OK cycle=$cycle project=$PROJECT"
      else
        audit "ORCH_LOOP SIXSIGMA WARN cycle=$cycle project=$PROJECT (cycle continues)"
      fi
    fi
  fi

  # #763 — queue resolver phase B: auto-atomize. When the ready queue is
  # empty AND no shipped_suspect rows remain AND atomize-needed parents
  # exist, deterministically invoke dispatch_plan --atomize so the next
  # cycle has dispatchable children. Capped per cycle and per rolling
  # hour by ORCH_AUTO_ATOMIZE_MAX_PER_CYCLE / ORCH_AUTO_ATOMIZE_MAX_PER_HOUR.
  # Opt out with ORCH_AUTO_ATOMIZE_DISABLED=1.
  if [[ "${ORCH_AUTO_ATOMIZE_DISABLED:-0}" != "1" ]]; then
    if stop_requested; then
      audit_blocked_dispatch auto-atomize "$cycle"
    else
      if orch_auto_atomize_step "$cycle" >>"$LOOP_LOG" 2>&1; then
        : # audit rows emitted inline; helper failures are non-fatal.
      else
        audit "ORCH_LOOP AUTO_ATOMIZE WARN cycle=$cycle project=$PROJECT (cycle continues)"
      fi
    fi
  fi

  # #770 — queue resolver phase A wire-in: auto-close shipped_suspect.
  # When the planner still carries shipped_suspect rows AND
  # ORCH_AUTO_CLOSE_MODE is dry-run or apply, invoke the auto-close lib
  # so the supervisor never blocks waiting for an operator drain.
  # Rate-limited by ORCH_AUTO_CLOSE_MAX_PER_HOUR (default 1). Apply-mode
  # close_failed records (rc=80 from the closed-issue mutation hook)
  # surface OPERATOR_AUTHORIZATION_REQUIRED + intervention_queue rows so
  # an operator can re-run the same call from a non-bot account.
  # Opt out with ORCH_AUTO_CLOSE_DISABLED=1.
  if [[ "${ORCH_AUTO_CLOSE_DISABLED:-0}" != "1" ]]; then
    if stop_requested; then
      audit_blocked_dispatch auto-close "$cycle"
    else
      if orch_auto_close_step "$cycle" >>"$LOOP_LOG" 2>&1; then
        : # audit rows emitted inline; helper failures are non-fatal.
      else
        audit "ORCH_LOOP AUTO_CLOSE WARN cycle=$cycle project=$PROJECT (cycle continues)"
      fi
    fi
  fi

  # #339 — monitor-loop heartbeat. Capture a fresh snapshot of in-flight
  # vs queued work, classify against the previous snapshot, and react:
  #   * `advance_queue`         → set the run-now flag so the next
  #                                cycle dispatches queued work without
  #                                waiting out the adaptive sleep.
  #   * `block_stale_at_prompt` → emit a structured blocker; the loop
  #                                still sleeps but the operator and
  #                                the audit trail both see the stall.
  #   * anything else           → no-op; sleep as usual.
  # Heartbeat is opt-out via `ORCH_MONITOR_HEARTBEAT_DISABLED=1` for
  # operators who run an external monitor instead.
  if [[ "${ORCH_MONITOR_HEARTBEAT_DISABLED:-0}" != "1" ]]; then
    # #653: the heartbeat probe can set the run-now flag, which would force
    # the next cycle to skip its adaptive sleep — effectively a poll-loop
    # registration. Skip the probe under stop barrier so the loop exits at
    # the top of the next iteration instead of being re-armed.
    if stop_requested; then
      audit_blocked_dispatch monitor-heartbeat "$cycle"
    elif heartbeat_decision=$(orch_run_timeout \
        "${ORCH_MONITOR_HEARTBEAT_TIMEOUT_SEC:-15}" \
        bash "$TK/scripts/monitor_heartbeat.sh" "$PROJECT" 2>/dev/null \
        | tail -1); then
      case "$heartbeat_decision" in
        advance_queue)
          touch "$RUN_NOW_FLAG"
          audit "ORCH_LOOP heartbeat decision=advance_queue cycle=$cycle action=run_now"
          ;;
        block_stale_at_prompt)
          audit_action ORCH_LOOP_STALE_AT_PROMPT \
            cycle="$cycle" \
            project="$PROJECT" \
            remediation="operator should nudge or send SIGUSR2"
          ;;
      esac
    else
      audit "ORCH_LOOP heartbeat skipped cycle=$cycle reason=probe-failed-or-timeout"
    fi
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
  # #653: chunk the adaptive sleep so an externally-set stop barrier file
  # (no signal delivered, e.g. fleet-clean script or operator `touch`) is
  # observed within ORCH_STOP_BARRIER_POLL_SEC seconds rather than waiting
  # the full cadence (which can be up to ORCH_CADENCE_BACKOFF=1800s).
  : "${ORCH_STOP_BARRIER_POLL_SEC:=5}"
  remaining=$sleep_for
  while (( remaining > 0 )); do
    if stop_requested; then
      audit "ORCH_LOOP stop barrier observed during adaptive sleep, exiting"
      exit 0
    fi
    chunk=$ORCH_STOP_BARRIER_POLL_SEC
    (( chunk > remaining )) && chunk=$remaining
    sleep "$chunk"
    remaining=$(( remaining - chunk ))
  done
done
