#!/usr/bin/env bash
# scripts/smart_poll_agents.sh — wait for agents to commit a wave's worth of
# work, then return so the orchestrator can integrate.
#
# Usage: smart_poll_agents.sh <project_short|config_path> [wave_label]
#
# Surviving log signatures:
#   POLL start project=<id> main=<sha> agents=<N> trigger=<idle>+<committed> timeout=<sec>s
#   POLL TRIGGER idle=<X> committed=<Y> elapsed=<sec>s
#   POLL TIMEOUT idle=<X> committed=<Y> elapsed=<sec>s
#
# Trigger semantics (from the log lines + the recovered behaviour):
#   - "idle"      = agent's tmux pane appears at the prompt (no spinner / running task)
#   - "committed" = agent's feature branch has ≥1 commit ahead of DEFAULT_BRANCH
#   - When BOTH counters reach the configured trigger AND that condition has held
#     for SMART_POLL_DEBOUNCE_SEC, return 0 (TRIGGER).
#   - On SMART_POLL_TIMEOUT_SEC elapsed without trigger, return 1 (TIMEOUT).
#
# Required env (from project config):
#   PROJECT, AGENTS, AGENT_SESSION_PREFIX, AGENT_REPO_PREFIX, DEFAULT_BRANCH
#   SMART_POLL_TRIGGER_IDLE, SMART_POLL_TRIGGER_COMMITTED
#   SMART_POLL_TIMEOUT_SEC, SMART_POLL_INTERVAL_SEC, SMART_POLL_DEBOUNCE_SEC
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

CFG_ARG=${1:?usage: smart_poll_agents.sh <project_short|config_path> [wave_label]}
WAVE_LABEL=${2:-default}
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
source "$TK/lib/quota_detect.sh"

: "${DEFAULT_BRANCH:=main}" "${AGENT_SESSION_PREFIX:=}"
: "${AGENT_REPO_PREFIX:?}"
: "${SMART_POLL_TRIGGER_IDLE:=4}"
: "${SMART_POLL_TRIGGER_COMMITTED:=4}"
: "${SMART_POLL_TIMEOUT_SEC:=900}"
: "${SMART_POLL_INTERVAL_SEC:=60}"
: "${SMART_POLL_DEBOUNCE_SEC:=60}"
: "${QUOTA_SWAP_COOLDOWN_SEC:=300}"

# Resolve current main sha for the log header (best-effort: use the
# supervisor repo if present, else the first agent clone).
main_sha="?"
if [ -n "${SUPERVISOR_REPO:-}" ] && [ -d "$SUPERVISOR_REPO/.git" ]; then
  main_sha=$(git -C "$SUPERVISOR_REPO" rev-parse --short "$DEFAULT_BRANCH" 2>/dev/null || echo "?")
elif [ -d "${AGENT_REPO_PREFIX}${AGENTS[0]}/.git" ]; then
  main_sha=$(git -C "${AGENT_REPO_PREFIX}${AGENTS[0]}" rev-parse --short "$DEFAULT_BRANCH" 2>/dev/null || echo "?")
fi

audit "POLL start project=$PROJECT main=$main_sha agents=${#AGENTS[@]} trigger=${SMART_POLL_TRIGGER_IDLE}+${SMART_POLL_TRIGGER_COMMITTED} timeout=${SMART_POLL_TIMEOUT_SEC}s wave=$WAVE_LABEL"

# Per-agent helpers.
agent_idle() {
  local a=$1
  local pane="${AGENT_SESSION_PREFIX}${a}"
  tmux has-session -t "$pane" 2>/dev/null || return 1
  # Heuristic: capture the last non-empty 5 lines; the agent is "idle" if
  # there is NO active spinner indicator (✻/✽/✶/✷/✸/✹/⠋/⠙/⠹/⠸/⠼/⠴/⠦/⠧/⠇/⠏)
  # AND no Codex/Claude "Working (...)" / "Pouncing (...)" / "Cooked (...)" line
  # AND a known prompt sentinel is visible.
  local cap
  cap=$(tmux capture-pane -t "$pane" -p 2>/dev/null | tail -10 | tr -d '\r')
  # 1. Spinner glyph at line start = busy.
  if printf '%s' "$cap" | grep -qE '^[[:space:]]*[✻✽✶✷✸✹◦⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]' ; then
    return 1
  fi
  # 2. Active task line (codex "Working (Xm Ys • esc to interrupt)",
  #    Claude Code "Cooked for ...s · 1 shell still running", "Pouncing...").
  if printf '%s' "$cap" | grep -qE 'Working \([0-9].*esc to interrupt|Pouncing|Cogitated|Brewed.*esc to interrupt'; then
    return 1
  fi
  # 3. Idle prompt sentinel — Claude Code 2.x = "❯ " (line start),
  #    Codex TUI = "› " (line start) typically followed by help placeholder text.
  if printf '%s' "$cap" | grep -qE '^❯ ?$|^❯ +$|^› '; then
    return 0
  fi
  return 1
}

agent_committed() {
  local a=$1
  local d="${AGENT_REPO_PREFIX}${a}"
  [ -d "$d/.git" ] || return 1
  local branch
  branch=$(git -C "$d" branch --show-current 2>/dev/null) || return 1
  [ "$branch" = "$DEFAULT_BRANCH" ] && return 1   # not on a feature branch yet
  # ≥1 commit ahead of DEFAULT_BRANCH.
  local ahead
  ahead=$(git -C "$d" rev-list --count "${DEFAULT_BRANCH}..${branch}" 2>/dev/null || echo 0)
  [ "$ahead" -ge 1 ]
}

quota_autoswap_agent() {
  local agent=$1
  local pane="${AGENT_SESSION_PREFIX}${agent}"
  local cap pattern

  tmux has-session -t "$pane" 2>/dev/null || return 1
  cap=$(tmux capture-pane -t "$pane" -p 2>/dev/null | tail -20 | tr -d '\r')

  if ! quota_content_matches "$cap"; then
    return 1
  fi

  pattern=$QUOTA_MATCH_PATTERN
  if quota_swap_cooldown_active "$agent"; then
    audit "QUOTA_DETECT cooldown agent=$agent pattern=$pattern cooldown=${QUOTA_SWAP_COOLDOWN_SEC}s"
    return 0
  fi

  audit "QUOTA_DETECT agent=$agent pattern=$pattern action=cli_swap:auto wave=$WAVE_LABEL"
  if bash "$TK/scripts/cli_swap.sh" "$CFG" "$agent" auto; then
    quota_mark_swap "$agent"
    audit "QUOTA_SWAP agent=$agent mode=auto pattern=$pattern"
  else
    audit "QUOTA_SWAP FAILED agent=$agent mode=auto pattern=$pattern"
  fi
}

start_ts=$(date +%s)
debounce_started=0

while true; do
  idle=0
  committed=0
  for a in "${AGENTS[@]}"; do
    quota_autoswap_agent "$a" || true
    if agent_idle "$a";      then idle=$((idle+1)); fi
    if agent_committed "$a"; then committed=$((committed+1)); fi
  done

  now=$(date +%s)
  elapsed=$((now-start_ts))

  # Debounce window: both thresholds must hold continuously for
  # SMART_POLL_DEBOUNCE_SEC before TRIGGER fires.
  if [ "$idle" -ge "$SMART_POLL_TRIGGER_IDLE" ] && [ "$committed" -ge "$SMART_POLL_TRIGGER_COMMITTED" ]; then
    if [ "$debounce_started" -eq 0 ]; then
      debounce_started=$now
    elif [ $((now - debounce_started)) -ge "$SMART_POLL_DEBOUNCE_SEC" ]; then
      audit "POLL TRIGGER idle=$idle committed=$committed elapsed=${elapsed}s"
      exit 0
    fi
  else
    debounce_started=0
  fi

  if [ "$elapsed" -ge "$SMART_POLL_TIMEOUT_SEC" ]; then
    audit "POLL TIMEOUT idle=$idle committed=$committed elapsed=${elapsed}s"
    exit 1
  fi

  sleep "$SMART_POLL_INTERVAL_SEC"
done
