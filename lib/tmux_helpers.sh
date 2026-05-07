#!/usr/bin/env bash
# tmux_helpers.sh — safe tmux send-keys + pane introspection.
# Sourced by dispatch_ticket.sh, smart_poll_agents.sh, recover.sh.
#
# Why: tmux send-keys -l breaks on multi-line input ("not in a mode" error).
# We use load-buffer + paste-buffer for any text that could contain newlines.
# Always send a separate Enter after to actually submit the prompt.

_ORCH_TMUX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_ORCH_TMUX_LIB_DIR/agent_inventory.sh" ]]; then
  # shellcheck source=lib/agent_inventory.sh
  source "$_ORCH_TMUX_LIB_DIR/agent_inventory.sh"
fi
if [[ -f "$_ORCH_TMUX_LIB_DIR/process_safety.sh" ]]; then
  # shellcheck source=lib/process_safety.sh
  source "$_ORCH_TMUX_LIB_DIR/process_safety.sh"
fi

: "${ORCH_TMUX_TIMEOUT_SEC:=10}"

tmux_run_timeout() {
  local seconds=${1:-$ORCH_TMUX_TIMEOUT_SEC}
  shift
  if declare -F tmux >/dev/null 2>&1; then
    tmux "$@"
  elif declare -F orch_run_timeout >/dev/null 2>&1; then
    orch_run_timeout "$seconds" tmux "$@"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" tmux "$@"
  else
    tmux "$@"
  fi
}

# Send a (possibly multi-line) string to a pane, then submit with Enter.
#   send_to_pane TARGET TEXT
send_to_pane() {
  local target=$1
  local text=$2
  if [[ -z "$target" || -z "$text" ]]; then
    audit "send_to_pane: missing target or text"
    return 1
  fi
  local tmp; tmp=$(mktemp)
  printf '%s' "$text" > "$tmp"
  tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" load-buffer -b orch_send "$tmp"
  tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" paste-buffer -b orch_send -t "$target" -d
  rm -f "$tmp"
  sleep 0.5
  tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" send-keys -t "$target" Enter
}

# Capture last N lines of pane output (default 30).
#   capture_pane TARGET [N]
capture_pane() {
  local target=$1
  local n=${2:-30}
  tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" capture-pane -t "$target" -p -S "-$n" 2>/dev/null
}

# Return 0 if pane appears IDLE (Claude Code prompt visible).
# Heuristic: last 5 lines do not contain 'esc to interrupt' / 'cogitating' etc.
# and contain a recognizable prompt char.
#   agent_is_idle TARGET
agent_is_idle() {
  local target=$1
  local out; out=$(capture_pane "$target" 5) || return 1
  if grep -qiE 'esc to interrupt|cogitating|thinking|cancel' <<< "$out"; then
    return 1
  fi
  # Look for prompt indicators in any line: >, ❯, ╰, $
  if grep -qE '(^|[[:space:]])(>|❯|╰|\$)([[:space:]]*$)' <<< "$out"; then
    return 0
  fi
  return 1
}

# Best-effort acknowledgement of common Claude Code permission prompts.
# Sends Down+Enter (typical "approve this action" affirmative).
# Return 0 if pane content includes a destructive command pattern.
# Sets AUTO_UNBLOCK_REFUSED_PATTERN to the matched pattern.
#   _auto_unblock_is_dangerous CONTENT
_auto_unblock_is_dangerous() {
  local content=$1
  AUTO_UNBLOCK_REFUSED_PATTERN=''

  local -a patterns=(
    'rm\s+-rf\s+/'
    'rm\s+-rf\s+~'
    'rm\s+-rf\s+\.'
    'git\s+push\s+.*--force'
    'git\s+push\s+-f'
    'git\s+branch\s+-D'
    'gh\s+(pr|issue|repo)\s+delete'
    'chmod\s+-R\s+777'
    'sudo\s+'
    'curl\s+.*\|\s*sh'
    'wget\s+.*\|\s*sh'
  )

  local blacklist_file=${AUTO_UNBLOCK_BLACKLIST_FILE:-}
  if [[ -z "$blacklist_file" && -n "${TK:-}" ]]; then
    blacklist_file="$TK/config/auto_unblock_blacklist.txt"
  fi
  if [[ -n "$blacklist_file" && -f "$blacklist_file" ]]; then
    local file_pattern
    while IFS= read -r file_pattern || [[ -n "$file_pattern" ]]; do
      [[ -z "$file_pattern" || "$file_pattern" =~ ^[[:space:]]*# ]] && continue
      patterns+=("$file_pattern")
    done < "$blacklist_file"
  fi

  local pattern
  for pattern in "${patterns[@]}"; do
    if grep -qE -- "$pattern" <<< "$content" 2>/dev/null; then
      AUTO_UNBLOCK_REFUSED_PATTERN=$pattern
      return 0
    else
      local rc=$?
      if [[ $rc -gt 1 ]]; then
        AUTO_UNBLOCK_REFUSED_PATTERN=$pattern
        return 0
      fi
    fi
  done

  return 1
}

#   auto_unblock TARGET
auto_unblock() {
  local target=$1
  local out; out=$(capture_pane "$target" 10) || return 0
  if grep -qiE 'allow this|allow tool|approve.*action|do you want|permission' <<< "$out"; then
    if _auto_unblock_is_dangerous "$out"; then
      local pattern=${AUTO_UNBLOCK_REFUSED_PATTERN:-unknown}
      local agent=${target%%:*}
      audit "AUTO_UNBLOCK REFUSED pattern=${pattern} agent=${agent} pane=${target}"
      return 0
    fi
    tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" send-keys -t "$target" Down 2>/dev/null
    sleep 0.2
    tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" send-keys -t "$target" Enter 2>/dev/null
    audit "auto_unblock fired on $target"
  fi
}

# Return last commit SHA on agent's repo (uses AGENT_WORKDIR_TEMPLATE from config).
#   agent_head AGENT
agent_head() {
  local agent=$1
  local repo
  if declare -F agent_effective_workdir >/dev/null 2>&1; then
    repo=$(agent_effective_workdir "$agent")
  else
    # shellcheck disable=SC2059
    repo=$(printf "$AGENT_WORKDIR_TEMPLATE" "$agent")
  fi
  [[ -d "$repo" ]] || { echo ''; return; }
  git -C "$repo" rev-parse HEAD 2>/dev/null || echo ''
}

# Return current branch on agent's repo.
#   agent_branch AGENT
agent_branch() {
  local agent=$1
  local repo
  if declare -F agent_effective_workdir >/dev/null 2>&1; then
    repo=$(agent_effective_workdir "$agent")
  else
    # shellcheck disable=SC2059
    repo=$(printf "$AGENT_WORKDIR_TEMPLATE" "$agent")
  fi
  [[ -d "$repo" ]] || { echo ''; return; }
  git -C "$repo" branch --show-current 2>/dev/null || echo ''
}

# Switch-and-dispatch readiness handshake (issue #123).
#
# After a hard product switch (`respawn-pane -k`) or a worktree-driven
# respawn the orchestrator must not assume the agent CLI is back online —
# previous incidents (issue #89 comment 19:34Z) lost dispatches because
# we wrote into a pane that was still showing a shell prompt.
#
# `agent_pane_ready` returns 0 only if every check passes:
#   1. tmux can introspect the pane (proves the server is responsive).
#   2. The pane's current_path equals the expected workdir.
#   3. The pane's current_command matches the agent-CLI allowlist
#      (`AGENT_READY_COMMAND_PATTERN`, default covers `claude` plus common
#       wrappers like `node`/`bash` while a shell launcher boots the CLI).
#
# On failure the function sets `AGENT_READY_REASON` and
# `AGENT_READY_DETAIL` for the caller to surface in unblock tasks. The
# function retries up to `AGENT_READY_RETRIES` times with
# `AGENT_READY_DELAY_SEC` between attempts so transient post-respawn races
# do not falsely trip the gate.
#
#   agent_pane_ready TARGET EXPECTED_WORKDIR [RETRIES] [DELAY_SEC]
agent_pane_ready() {
  local target=${1:?usage: agent_pane_ready <pane-target> <expected-workdir> [retries] [delay]}
  local expected_workdir=${2:?usage: agent_pane_ready <pane-target> <expected-workdir> [retries] [delay]}
  local retries=${3:-${AGENT_READY_RETRIES:-5}}
  local delay=${4:-${AGENT_READY_DELAY_SEC:-1}}
  # shellcheck disable=SC2034  # consumed by callers after sourcing
  AGENT_READY_REASON=""
  # shellcheck disable=SC2034  # consumed by callers after sourcing
  AGENT_READY_DETAIL=""
  # shellcheck disable=SC2034  # consumed by callers after sourcing
  AGENT_READY_LAST_PATH=""
  # shellcheck disable=SC2034  # consumed by callers after sourcing
  AGENT_READY_LAST_COMMAND=""

  local allow_pattern="${AGENT_READY_COMMAND_PATTERN:-^(claude|node|bash|zsh|sh|tmux|login|fish)$}"

  local attempt=0
  local current_path current_command status
  while [[ "$attempt" -lt "$retries" ]]; do
    attempt=$((attempt + 1))
    set +e
    current_path=$(tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null)
    status=$?
    set -e
    current_path=${current_path%$'\n'}
    if [[ "$status" -ne 0 ]]; then
      AGENT_READY_REASON="pane-introspection-failed"
      AGENT_READY_DETAIL="display-message exited with $status for pane=$target"
      [[ "$attempt" -lt "$retries" ]] && sleep "$delay"
      continue
    fi
    set +e
    current_command=$(tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null)
    status=$?
    set -e
    current_command=${current_command%$'\n'}
    if [[ "$status" -ne 0 ]]; then
      AGENT_READY_REASON="pane-introspection-failed"
      AGENT_READY_DETAIL="display-message #{pane_current_command} exited with $status for pane=$target"
      [[ "$attempt" -lt "$retries" ]] && sleep "$delay"
      continue
    fi
    # shellcheck disable=SC2034  # consumed by callers after sourcing
    AGENT_READY_LAST_PATH=$current_path
    # shellcheck disable=SC2034  # consumed by callers after sourcing
    AGENT_READY_LAST_COMMAND=$current_command
    if [[ -n "$expected_workdir" && "$current_path" != "$expected_workdir" ]]; then
      # shellcheck disable=SC2034  # consumed by callers after sourcing
      AGENT_READY_REASON="workdir-mismatch"
      # shellcheck disable=SC2034  # consumed by callers after sourcing
      AGENT_READY_DETAIL="pane=$target current=$current_path expected=$expected_workdir"
      [[ "$attempt" -lt "$retries" ]] && sleep "$delay"
      continue
    fi
    if ! [[ "$current_command" =~ $allow_pattern ]]; then
      # shellcheck disable=SC2034  # consumed by callers after sourcing
      AGENT_READY_REASON="cli-not-alive"
      # shellcheck disable=SC2034  # consumed by callers after sourcing
      AGENT_READY_DETAIL="pane=$target command=$current_command pattern=$allow_pattern"
      [[ "$attempt" -lt "$retries" ]] && sleep "$delay"
      continue
    fi
    # shellcheck disable=SC2034  # consumed by callers after sourcing
    AGENT_READY_REASON=""
    # shellcheck disable=SC2034  # consumed by callers after sourcing
    AGENT_READY_DETAIL=""
    return 0
  done
  return 1
}

# Resolve the tmux target for an agent (e.g. "rbok-claude:0").
#
# Resolution order:
#   1. UNIVERSAL — if AGENT_PANES is set and $1 matches the basename of an
#      entry's workdir (e.g. "RBOK-claude-2"), return that entry's pane.
#      Lets a project drive multiple fleets that don't share an
#      AGENT_SESSION_PREFIX through the same dispatch_ticket / recover code.
#   2. LEGACY — fall back to "${AGENT_SESSION_PREFIX}${agent}:${AGENT_WINDOW_INDEX:-0}".
#      Preserves the historical contract for nomos/wp/42t.
#
#   agent_target AGENT
agent_target() {
  local agent=$1
  if declare -F agent_inventory_find >/dev/null 2>&1 \
    && [ -n "${AGENT_PANES+x}" ] \
    && [ "${#AGENT_PANES[@]}" -gt 0 ]; then
    local entry label pane workdir
    entry=$(agent_inventory_find "$agent" 2>/dev/null || true)
    if [[ -n "$entry" ]]; then
      IFS='|' read -r label pane workdir <<< "$entry"
      printf '%s\n' "$pane"
      return 0
    fi
  fi
  printf '%s%s:%s' "${AGENT_SESSION_PREFIX:-}" "$agent" "${AGENT_WINDOW_INDEX:-0}"
}
