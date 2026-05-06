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
#   POLL CYCLE idle=<X> committed=<Y> elapsed=<sec>s <pane>=<state> ...   (verbose only)
#
# Trigger semantics (from the log lines + the recovered behaviour):
#   - "idle"      = agent's tmux pane appears at the prompt (no spinner / running task)
#   - "committed" = agent's feature branch has ≥1 commit ahead of DEFAULT_BRANCH
#   - When BOTH counters reach the configured trigger AND that condition has held
#     for SMART_POLL_DEBOUNCE_SEC, return 0 (TRIGGER).
#   - On SMART_POLL_TIMEOUT_SEC elapsed without trigger, return 1 (TIMEOUT).
#   - In SMART_POLL_OBSERVE=1 mode, neither TRIGGER nor TIMEOUT fire — the loop
#     runs forever and only emits CYCLE log lines (use for background monitoring).
#
# Fleet declaration (two forms supported, AGENT_PANES takes precedence):
#
#   1. UNIVERSAL (multi-fleet projects):
#      AGENT_PANES=(
#        "rbok-claude:0.0|/root/repos/RBOK-claude"
#        "claude:0.0|/root/repos/RBOK-claude-2"
#        "orch:0.0|/root/repos/RBOK-orch"
#      )
#      Each entry is "pane_target|workdir_absolute_path".
#      No common prefix or naming convention assumed.
#
#   2. LEGACY (single fleet, unchanged):
#      AGENTS=(claude codex copilot cursor gemini)
#      AGENT_SESSION_PREFIX="rbok-"            # default ""
#      AGENT_REPO_PREFIX="/root/repos/RBOK-"
#      AGENT_WINDOW_INDEX="0"                  # default "0"
#      → pane    = "${AGENT_SESSION_PREFIX}${a}:${AGENT_WINDOW_INDEX}.0"
#      → workdir = "${AGENT_REPO_PREFIX}${a}"
#
# Required env (from project config):
#   PROJECT, DEFAULT_BRANCH, plus one of the two fleet forms above.
#   SMART_POLL_TRIGGER_IDLE, SMART_POLL_TRIGGER_COMMITTED
#   SMART_POLL_TIMEOUT_SEC, SMART_POLL_INTERVAL_SEC, SMART_POLL_DEBOUNCE_SEC
#
# Optional env (script-level overrides):
#   SMART_POLL_OBSERVE   (0|1, default 0)  — never trigger/timeout, loop forever
#   SMART_POLL_VERBOSE   (0|1, default 0)  — emit per-agent state on each cycle
#   SMART_POLL_AUTOSWAP  (0|1, default: 1 if AGENTS legacy, 0 if AGENT_PANES universal)
#                        — enable cli_swap.sh on quota detection
set -uo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TK/lib/config_resolver.sh"
source "$TK/lib/agent_inventory.sh"

CFG_ARG=${1:?usage: smart_poll_agents.sh <project_short|config_path> [wave_label]}
WAVE_LABEL=${2:-default}
load_project_config "$CFG_ARG"
CFG=${ORCH_CONFIG_PATH:?}

source "$TK/lib/audit_log.sh"
source "$TK/lib/quota_detect.sh"

: "${DEFAULT_BRANCH:=main}" "${AGENT_SESSION_PREFIX:=}" "${AGENT_WINDOW_INDEX:=0}"
: "${SMART_POLL_TRIGGER_IDLE:=4}"
: "${SMART_POLL_TRIGGER_COMMITTED:=4}"
: "${SMART_POLL_TIMEOUT_SEC:=900}"
: "${SMART_POLL_INTERVAL_SEC:=60}"
: "${SMART_POLL_DEBOUNCE_SEC:=60}"
: "${QUOTA_SWAP_COOLDOWN_SEC:=300}"
: "${SMART_POLL_OBSERVE:=0}"
: "${SMART_POLL_VERBOSE:=0}"
: "${SMART_POLL_IDLE_MODE:=pane}"     # pane | git; git avoids slow/hung TUI capture-pane
: "${SMART_POLL_CAPTURE_TIMEOUT_SEC:=3}"
: "${SMART_POLL_GIT_TIMEOUT_SEC:=5}"

# --- Fleet resolution: build parallel arrays UNIT_PANES / UNIT_WORKDIRS / UNIT_NAMES ---
declare -a UNIT_PANES=()
declare -a UNIT_WORKDIRS=()
declare -a UNIT_NAMES=()  # logical names (used by cli_swap.sh in legacy mode only)

# Detect AGENT_PANES (universal mode) without tripping `set -u`:
# `${VAR+x}` expands to "x" if VAR is set (even to empty), to "" otherwise.
if [ -n "${AGENT_PANES+x}" ] && [ "${#AGENT_PANES[@]}" -gt 0 ]; then
  FLEET_MODE="universal"
  while IFS='|' read -r label pane workdir; do
    UNIT_PANES+=("$pane")
    UNIT_WORKDIRS+=("$workdir")
    UNIT_NAMES+=("$label")
  done < <(agent_inventory_entries)
else
  FLEET_MODE="legacy"
  : "${AGENT_REPO_PREFIX:?need AGENT_PANES (universal) or AGENT_REPO_PREFIX (legacy)}"
  if [ -z "${AGENTS+x}" ] || [ "${#AGENTS[@]}" -eq 0 ]; then
    echo "neither AGENT_PANES nor AGENTS array is set in $CFG" >&2
    exit 1
  fi
  for a in "${AGENTS[@]}"; do
    UNIT_PANES+=("${AGENT_SESSION_PREFIX}${a}:${AGENT_WINDOW_INDEX}.0")
    UNIT_WORKDIRS+=("${AGENT_REPO_PREFIX}${a}")
    UNIT_NAMES+=("$a")
  done
fi

# Default auto-swap on in legacy mode (preserves prior behaviour),
# off in universal mode (cli_swap.sh expects a logical agent name keyed
# in the project config, not a free-form pane target).
if [ -z "${SMART_POLL_AUTOSWAP:-}" ]; then
  if [ "$FLEET_MODE" = "legacy" ]; then SMART_POLL_AUTOSWAP=1; else SMART_POLL_AUTOSWAP=0; fi
fi

N_UNITS=${#UNIT_PANES[@]}

# Resolve current default-branch SHA for the log header.
main_sha="?"
if [ -n "${SUPERVISOR_REPO:-}" ] && [ -d "$SUPERVISOR_REPO/.git" ]; then
  main_sha=$(git -C "$SUPERVISOR_REPO" rev-parse --short "$DEFAULT_BRANCH" 2>/dev/null || echo "?")
elif [ -d "${UNIT_WORKDIRS[0]}/.git" ]; then
  main_sha=$(git -C "${UNIT_WORKDIRS[0]}" rev-parse --short "$DEFAULT_BRANCH" 2>/dev/null || echo "?")
fi

audit "POLL start project=$PROJECT main=$main_sha agents=$N_UNITS mode=$FLEET_MODE trigger=${SMART_POLL_TRIGGER_IDLE}+${SMART_POLL_TRIGGER_COMMITTED} timeout=${SMART_POLL_TIMEOUT_SEC}s observe=$SMART_POLL_OBSERVE autoswap=$SMART_POLL_AUTOSWAP wave=$WAVE_LABEL"

# --- Per-unit helpers (operate on pane + workdir, not logical agent name) ---

unit_idle() {
  local pane=$1
  local workdir=${2:-}

  # Non-blocking mode for Codex/Claude TUI panes. Some panes can make
  # `tmux capture-pane` or even tmux metadata calls stall for minutes.
  # Git mode deliberately avoids tmux and treats an existing clone as idle;
  # unit_committed() independently detects branches ahead of DEFAULT_BRANCH.
  if [ "$SMART_POLL_IDLE_MODE" = "git" ]; then
    # Avoid `git status`: on the RBOK host it can block on every clone.
    # In this mode idle means the clone is present; readiness is gated by
    # unit_committed() below, which checks commits ahead of DEFAULT_BRANCH.
    [ -n "$workdir" ] && [ -d "$workdir/.git" ]
    return
  fi

  tmux has-session -t "${pane%%:*}" 2>/dev/null || return 1
  local cap
  if command -v timeout >/dev/null 2>&1; then
    cap=$(timeout "$SMART_POLL_CAPTURE_TIMEOUT_SEC" tmux capture-pane -t "$pane" -p 2>/dev/null | tail -10 | tr -d '\r') || return 1
  else
    cap=$(tmux capture-pane -t "$pane" -p 2>/dev/null | tail -10 | tr -d '\r') || return 1
  fi
  # 1. Spinner glyph at line start = busy.
  if printf '%s' "$cap" | grep -qE '^[[:space:]]*[✻✽✶✷✸✹◦⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]' ; then
    return 1
  fi
  # 2. Active task line (codex / Claude Code working states).
  if printf '%s' "$cap" | grep -qE 'Working \([0-9].*esc to interrupt|Pouncing|Cogitated|Brewed.*esc to interrupt'; then
    return 1
  fi
  # 3. Idle prompt sentinel — Claude Code 2.x = "❯ " / Codex TUI = "› ".
  if printf '%s' "$cap" | grep -qE '^❯ ?$|^❯ +$|^› '; then
    return 0
  fi
  return 1
}
unit_committed() {
  local d=$1
  [ -d "$d/.git" ] || return 1
  local branch
  branch=$(timeout "$SMART_POLL_GIT_TIMEOUT_SEC" git -C "$d" branch --show-current 2>/dev/null) || return 1
  [ "$branch" = "$DEFAULT_BRANCH" ] && return 1   # not on a feature branch yet
  local ahead
  ahead=$(timeout "$SMART_POLL_GIT_TIMEOUT_SEC" git -C "$d" rev-list --count "${DEFAULT_BRANCH}..${branch}" 2>/dev/null || echo 0)
  [ "$ahead" -ge 1 ]
}

quota_autoswap_unit() {
  # Only callable in legacy mode — needs a logical agent name to invoke cli_swap.
  local agent=$1 pane=$2
  local cap pattern
  tmux has-session -t "${pane%%:*}" 2>/dev/null || return 1
  cap=$(tmux capture-pane -t "$pane" -p 2>/dev/null | tail -20 | tr -d '\r') || return 1

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

# --- Main loop ---

start_ts=$(date +%s)
debounce_started=0

while true; do
  idle=0
  committed=0
  per_agent_log=""
  for i in "${!UNIT_PANES[@]}"; do
    pane=${UNIT_PANES[$i]}
    workdir=${UNIT_WORKDIRS[$i]}

    if [ "$SMART_POLL_AUTOSWAP" = "1" ] && [ "$FLEET_MODE" = "legacy" ]; then
      quota_autoswap_unit "${UNIT_NAMES[$i]}" "$pane" || true
    fi

    state=""
    if unit_idle "$pane" "$workdir"; then idle=$((idle+1));         state+="i"; fi
    if unit_committed "$workdir"; then committed=$((committed+1)); state+="c"; fi
    [ -z "$state" ] && state="-"
    per_agent_log+=" ${pane}=${state}"
  done

  now=$(date +%s)
  elapsed=$((now-start_ts))

  if [ "$SMART_POLL_VERBOSE" = "1" ]; then
    audit "POLL CYCLE idle=$idle committed=$committed elapsed=${elapsed}s${per_agent_log}"
  fi

  # In observe mode, never trigger or timeout — pure background monitor.
  if [ "$SMART_POLL_OBSERVE" = "1" ]; then
    sleep "$SMART_POLL_INTERVAL_SEC"
    continue
  fi

  # Debounce window: both thresholds must hold continuously for
  # SMART_POLL_DEBOUNCE_SEC before TRIGGER fires.
  if [ "$idle" -ge "$SMART_POLL_TRIGGER_IDLE" ] && [ "$committed" -ge "$SMART_POLL_TRIGGER_COMMITTED" ]; then
    if [ "$debounce_started" -eq 0 ]; then
      debounce_started=$now
      if [ "$SMART_POLL_DEBOUNCE_SEC" -le 0 ]; then
        audit "POLL TRIGGER idle=$idle committed=$committed elapsed=${elapsed}s"
        exit 0
      fi
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
