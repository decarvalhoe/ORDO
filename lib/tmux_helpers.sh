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
  local tmp
  tmp=$(mktemp)
  printf '%s' "$text" > "$tmp"
  if ! tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" load-buffer -b orch_send "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" paste-buffer -b orch_send -t "$target" -d; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
  sleep "${ORCH_TMUX_SEND_ENTER_DELAY_SEC:-0.5}" 2>/dev/null || true
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

terminal_dispatch_pane_not_consumed() {
  local target=${1:?usage: terminal_dispatch_pane_not_consumed <target> <submitted-text>}
  local submitted_text=${2:-}
  local out active_pattern idle_pattern visible_prefix_chars visible_min_chars submitted_compact out_compact visible_fragment

  out=$(capture_pane "$target" "${ORCH_DISPATCH_CONSUME_CAPTURE_LINES:-12}" 2>/dev/null || true)
  # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
  DISPATCH_SUBMIT_LAST_CAPTURE="$out"
  [[ -n "$out" ]] || return 1

  active_pattern=${ORCH_DISPATCH_ACTIVE_PATTERN:-'(esc to interrupt|interrupt|running|working|thinking|processing|busy|executing)'}
  if grep -qiE "$active_pattern" <<< "$out" 2>/dev/null; then
    return 1
  fi

  idle_pattern=${ORCH_DISPATCH_IDLE_PROMPT_PATTERN:-'(^|[[:space:]])(>|›|❯|╰|\$)([[:space:]]*)$'}
  if grep -qE "$idle_pattern" <<< "$out" 2>/dev/null; then
    # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
    DISPATCH_SUBMIT_LAST_REASON="idle-prompt"
    # shellcheck disable=SC2034
    DISPATCH_SUBMIT_LAST_DETAIL="pane=${target} appears idle after dispatch submit"
    return 0
  fi

  if [[ -n "$submitted_text" ]] && grep -Fq "$submitted_text" <<< "$out"; then
    # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
    DISPATCH_SUBMIT_LAST_REASON="submission-still-visible"
    # shellcheck disable=SC2034
    DISPATCH_SUBMIT_LAST_DETAIL="pane=${target} still shows submitted text"
    return 0
  fi

  visible_prefix_chars=${ORCH_DISPATCH_VISIBLE_TEXT_PREFIX_CHARS:-48}
  visible_min_chars=${ORCH_DISPATCH_VISIBLE_TEXT_MIN_CHARS:-24}
  if [[ -n "$submitted_text" ]] \
    && [[ "$visible_prefix_chars" =~ ^[0-9]+$ ]] \
    && [[ "$visible_min_chars" =~ ^[0-9]+$ ]] \
    && [[ "$visible_prefix_chars" -ge "$visible_min_chars" ]]; then
    submitted_compact=$(tr -s '[:space:]' ' ' <<< "$submitted_text")
    out_compact=$(tr -s '[:space:]' ' ' <<< "$out")
    visible_fragment=${submitted_compact:0:$visible_prefix_chars}
    if [[ "${#visible_fragment}" -ge "$visible_min_chars" ]] \
      && grep -Fq "$visible_fragment" <<< "$out_compact"; then
      # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
      DISPATCH_SUBMIT_LAST_REASON="submission-still-visible"
      # shellcheck disable=SC2034
      DISPATCH_SUBMIT_LAST_DETAIL="pane=${target} still shows submitted text prefix"
      return 0
    fi
  fi

  return 1
}

terminal_dispatch_clear_input() {
  local target=${1:?usage: terminal_dispatch_clear_input <target>}
  local key
  # shellcheck disable=SC2206
  local keys=(${ORCH_DISPATCH_RETRY_CLEAR_KEYS:-Escape C-u})

  for key in "${keys[@]}"; do
    [[ -n "$key" ]] || continue
    tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" send-keys -t "$target" "$key" 2>/dev/null || true
    sleep "${ORCH_DISPATCH_RETRY_CLEAR_DELAY_SEC:-0.2}" 2>/dev/null || true
  done
}

terminal_dispatch_submit_once() {
  local target=${1:?usage: terminal_dispatch_submit_once <target> <text>}
  local text=${2:?usage: terminal_dispatch_submit_once <target> <text>}

  send_to_pane "$target" "$text"
}

terminal_dispatch_submit() {
  local target=${1:?usage: terminal_dispatch_submit <target> <text>}
  local text=${2:?usage: terminal_dispatch_submit <target> <text>}
  local attempts=${ORCH_DISPATCH_SUBMIT_ATTEMPTS:-2}
  local delay=${ORCH_DISPATCH_CONSUME_WAIT_SEC:-1}
  local attempt

  if ! [[ "$attempts" =~ ^[0-9]+$ ]] || [[ "$attempts" -lt 1 ]]; then
    attempts=1
  fi

  # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
  DISPATCH_SUBMIT_LAST_REASON=""
  # shellcheck disable=SC2034
  DISPATCH_SUBMIT_LAST_DETAIL=""
  # shellcheck disable=SC2034
  DISPATCH_SUBMIT_LAST_CAPTURE=""
  # shellcheck disable=SC2034
  DISPATCH_SUBMIT_ATTEMPT=0

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
    DISPATCH_SUBMIT_ATTEMPT=$attempt
    if [[ "$attempt" -gt 1 ]]; then
      terminal_dispatch_clear_input "$target"
    fi

    if ! terminal_dispatch_submit_once "$target" "$text"; then
      # shellcheck disable=SC2034
      DISPATCH_SUBMIT_LAST_REASON="tmux-submit-failed"
      # shellcheck disable=SC2034
      DISPATCH_SUBMIT_LAST_DETAIL="pane=${target} attempt=${attempt}"
      return 1
    fi

    if [[ "${ORCH_DISPATCH_VERIFY_CONSUMED:-1}" != "1" ]]; then
      return 0
    fi

    sleep "$delay" 2>/dev/null || true
    if terminal_dispatch_pane_not_consumed "$target" "$text"; then
      continue
    fi

    # shellcheck disable=SC2034
    DISPATCH_SUBMIT_LAST_REASON=""
    # shellcheck disable=SC2034
    DISPATCH_SUBMIT_LAST_DETAIL=""
    return 0
  done

  [[ -n "${DISPATCH_SUBMIT_LAST_REASON:-}" ]] || {
    # shellcheck disable=SC2034
    DISPATCH_SUBMIT_LAST_REASON="not-consumed"
    # shellcheck disable=SC2034
    DISPATCH_SUBMIT_LAST_DETAIL="pane=${target} did not show dispatch consumption"
  }
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
# we wrote into a pane that was still showing a shell prompt. This gate
# fires BEFORE send-keys; the post-dispatch `pane_context_proof` (#112,
# below) is the after-the-fact audit that verifies the dispatched agent
# is operating in the right project context.
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

# Live pane context proof (issue #112): after dispatch, verify that the
# recorded WORKDIR is consistent with the multi-project dispatch contract.
# Server-side checks gate the decision (workdir exists, origin remote
# resolvable); live pane content is captured for audit only because the
# dispatched agent may not have printed pre-flight output yet.
#
#   pane_context_proof PANE_TARGET WORKDIR [EXPECTED_REMOTE_SUBSTR] [EXPECTED_BRANCH]
#
# Returns 0 on consistent context, 1 on mismatch. Side-channel exposes
# diagnostics for callers (audit + stderr): PANE_CONTEXT_PROOF_REASON,
# PANE_CONTEXT_PROOF_REMOTE, PANE_CONTEXT_PROOF_BRANCH,
# PANE_CONTEXT_PROOF_PANE.
#
# Knobs:
#   ORCH_CONTEXT_PROOF_WAIT_SEC   Sleep before capture (default 7; "0" skips).
#   ORCH_CONTEXT_PROOF_PANE_LINES Pane lines to capture for audit (default 30).
pane_context_proof() {
  local pane_target=${1:-}
  local workdir=${2:-}
  local expected_remote=${3:-}
  local expected_branch=${4:-}
  # shellcheck disable=SC2034 # consumed by callers (dispatch_ticket.sh, tests)
  PANE_CONTEXT_PROOF_REASON=""
  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_REMOTE=""
  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_BRANCH=""
  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_PANE=""

  if [[ -z "$pane_target" || -z "$workdir" ]]; then
    PANE_CONTEXT_PROOF_REASON="missing-args"
    audit "DISPATCH CONTEXT_PROOF status=mismatch:missing-args pane=${pane_target} workdir=${workdir}"
    return 1
  fi

  local agent=${pane_target%%:*}
  local sleep_sec=${ORCH_CONTEXT_PROOF_WAIT_SEC:-7}
  local pane_lines=${ORCH_CONTEXT_PROOF_PANE_LINES:-30}

  if [[ -n "$sleep_sec" && "$sleep_sec" != "0" ]]; then
    sleep "$sleep_sec" 2>/dev/null || true
  fi

  if [[ ! -d "$workdir" ]]; then
    PANE_CONTEXT_PROOF_REASON="workdir-missing"
    audit "DISPATCH CONTEXT_PROOF agent=${agent} pane=${pane_target} workdir=${workdir} status=mismatch:workdir-missing"
    return 1
  fi

  local remote branch
  remote=$(git -C "$workdir" remote get-url origin 2>/dev/null || echo '')
  branch=$(git -C "$workdir" branch --show-current 2>/dev/null || echo '')
  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_REMOTE="$remote"
  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_BRANCH="$branch"

  if [[ -z "$remote" ]]; then
    PANE_CONTEXT_PROOF_REASON="remote-missing"
    audit "DISPATCH CONTEXT_PROOF agent=${agent} pane=${pane_target} workdir=${workdir} status=mismatch:remote-missing"
    return 1
  fi

  if [[ -n "$expected_remote" && "$remote" != *"$expected_remote"* ]]; then
    PANE_CONTEXT_PROOF_REASON="remote-mismatch"
    audit "DISPATCH CONTEXT_PROOF agent=${agent} pane=${pane_target} workdir=${workdir} remote=${remote} expected_remote=${expected_remote} status=mismatch:remote-mismatch"
    return 1
  fi

  if [[ -n "$expected_branch" && -n "$branch" && "$branch" != "$expected_branch" ]]; then
    # shellcheck disable=SC2034
    PANE_CONTEXT_PROOF_REASON="branch-mismatch"
    audit "DISPATCH CONTEXT_PROOF agent=${agent} pane=${pane_target} workdir=${workdir} branch=${branch} expected_branch=${expected_branch} status=mismatch:branch-mismatch"
    return 1
  fi

  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_PANE=$(capture_pane "$pane_target" "$pane_lines" 2>/dev/null || echo '')

  audit "DISPATCH CONTEXT_PROOF agent=${agent} pane=${pane_target} workdir=${workdir} remote=${remote} branch=${branch} status=ok"
  return 0
}

# Resolve the tmux target for an agent (for example "terminal-b:0").
#
# Resolution order:
#   1. UNIVERSAL — if AGENT_PANES is set and $1 matches the label or basename
#      of an entry's workdir, return that entry's pane.
#      Lets a project drive multiple fleets that don't share an
#      AGENT_SESSION_PREFIX through the same dispatch_ticket / recover code.
#   2. LEGACY — fall back to "${AGENT_SESSION_PREFIX}${agent}:${AGENT_WINDOW_INDEX:-0}".
#      Preserves the legacy prefix contract.
#
#   agent_target AGENT
agent_target() {
  local agent=$1
  if declare -F agent_inventory_find >/dev/null 2>&1 \
    && [ -n "${AGENT_PANES+x}" ] \
    && [ "${#AGENT_PANES[@]}" -gt 0 ]; then
    local entry pane
    entry=$(agent_inventory_find "$agent" 2>/dev/null || true)
    if [[ -n "$entry" ]]; then
      IFS='|' read -r _ pane _ <<< "$entry"
      printf '%s\n' "$pane"
      return 0
    fi
  fi
  printf '%s%s:%s' "${AGENT_SESSION_PREFIX:-}" "$agent" "${AGENT_WINDOW_INDEX:-0}"
}
