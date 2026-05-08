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

# Live current working directory of TARGET pane, or empty string when tmux is
# unavailable/timeout. Single source of truth for #{pane_current_path} reads —
# callers that want to compare live cwd against the assigned workdir should
# go through this helper rather than re-implementing the tmux call.
#   pane_current_path TARGET
pane_current_path() {
  local target=${1:?usage: pane_current_path <target>}
  local out
  out=$(tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null) || return 0
  printf '%s' "${out%$'\n'}"
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

# Batched pane introspection — read multiple pane variables in one
# tmux display-message call instead of N separate calls. Used by
# agent_pool_status (capacity scan) and agent_pane_ready (dispatch
# readiness handshake) to keep wall-clock low on slow tmux servers
# and large fleets (issue #322).
#
# `tmux display-message` accepts an arbitrary format string with any
# mix of literal text and format variables, so two reads collapse to
# one round-trip. We join with a single ASCII US separator (\x1f) to
# avoid collisions with any character that can appear in a real
# command name or filesystem path.
#
# Usage:
#   tmux_pane_values_batch TARGET CMD_OUT_VAR PATH_OUT_VAR [TIMEOUT_SEC]
#
# CMD_OUT_VAR and PATH_OUT_VAR are caller-owned variable names; this
# helper writes the pane_current_command and pane_current_path values
# into them via bash namerefs. Returns the underlying tmux exit
# status, with both outputs cleared on non-zero so callers do not
# accidentally treat a stale value as fresh.
tmux_pane_values_batch() {
  # Argument names use a `_orch_tmpv_` prefix so they cannot collide
  # with the caller-owned variable names passed as $2 and $3. Bash
  # namerefs resolve through the function's local scope first; if the
  # argument variable shared a name with the caller's variable, the
  # nameref would bind to the local instead and the writeback would
  # never reach the caller (issue #322 regression seen during dev).
  local target=${1:?usage: tmux_pane_values_batch <target> <cmd_var> <path_var> [timeout]}
  local _orch_tmpv_cmd_name=${2:?usage: tmux_pane_values_batch <target> <cmd_var> <path_var> [timeout]}
  local _orch_tmpv_path_name=${3:?usage: tmux_pane_values_batch <target> <cmd_var> <path_var> [timeout]}
  local timeout_sec=${4:-${ORCH_TMUX_TIMEOUT_SEC:-10}}
  # shellcheck disable=SC2178  # nameref to caller-owned scalar
  local -n _cmd_ref=$_orch_tmpv_cmd_name
  # shellcheck disable=SC2178  # nameref to caller-owned scalar
  local -n _path_ref=$_orch_tmpv_path_name
  local sep=$'\x1f'
  local format="#{pane_current_command}${sep}#{pane_current_path}"
  local raw status
  set +e
  raw=$(tmux_run_timeout "$timeout_sec" display-message -p -t "$target" "$format" 2>/dev/null)
  status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    _cmd_ref=""
    _path_ref=""
    return "$status"
  fi
  raw=${raw%$'\n'}
  # Split on the separator. Bash parameter expansion handles missing
  # separators gracefully (cmd would equal raw, path would be empty),
  # which keeps the helper safe against very old tmux versions that
  # might silently drop the literal byte.
  #
  # Issue #386: some tmux installs return the separator as the literal
  # 4-character escape sequence `\037` instead of the raw 0x1f byte.
  # When that happens the raw output looks like
  # `claude\037/repos/foo` and the 0x1f split leaves the whole string
  # in cmd with an empty path — which is exactly the live-cwd evidence
  # gap that broke fleet readiness detection. Fall back to splitting
  # on the literal escape when the raw byte is absent.
  if [[ "$raw" != *"$sep"* && "$raw" == *'\037'* ]]; then
    _cmd_ref=${raw%%'\037'*}
    _path_ref=${raw#*'\037'}
    return 0
  fi
  _cmd_ref=${raw%%"$sep"*}
  _path_ref=${raw#*"$sep"}
  if [[ "$_path_ref" == "$raw" && "$raw" != *"$sep"* ]]; then
    _path_ref=""
  fi
  return 0
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
    # Issue #322: one display-message round-trip for both pane values
    # instead of two; halves wall-clock on slow tmux servers.
    set +e
    tmux_pane_values_batch "$target" current_command current_path "$ORCH_TMUX_TIMEOUT_SEC"
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
      AGENT_READY_REASON="pane-introspection-failed"
      AGENT_READY_DETAIL="display-message exited with $status for pane=$target"
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

# Live pane context proof (issue #112, extended #286): after dispatch, verify
# that the recorded WORKDIR is consistent with the multi-project dispatch
# contract. Server-side checks gate the decision (workdir exists, origin remote
# resolvable, branch matches); live pane content is captured for audit. As of
# #286, the live pane current_path is also compared against WORKDIR — without
# that comparison ORDO could record CONTEXT_PROOF_OK while the physical pane
# was still running in another product workdir.
#
#   pane_context_proof PANE_TARGET WORKDIR [EXPECTED_REMOTE_SUBSTR] [EXPECTED_BRANCH] [SOFT_ROUTING_MODE]
#
# SOFT_ROUTING_MODE values:
#   strict (default): a live cwd that does not equal WORKDIR fails with
#     `live-cwd-mismatch`. A live cwd that cannot be read fails with
#     `live-cwd-unreadable` unless ORCH_CONTEXT_PROOF_REQUIRE_LIVE_CWD=0.
#   accept-soft-routed: a live cwd that does not equal WORKDIR is recorded
#     and the proof still returns 0, but the audit line carries
#     `route=soft-routed`. Used when an absolute-path dispatch (no
#     `agent_product_switch.sh` hard-respawn) is intentional.
#
# Returns 0 on consistent context, 1 on mismatch. Side-channel exposes
# diagnostics for callers (audit + stderr): PANE_CONTEXT_PROOF_REASON,
# PANE_CONTEXT_PROOF_REMOTE, PANE_CONTEXT_PROOF_BRANCH,
# PANE_CONTEXT_PROOF_PANE, PANE_CONTEXT_PROOF_LIVE_PATH,
# PANE_CONTEXT_PROOF_ROUTE.
#
# Knobs:
#   ORCH_CONTEXT_PROOF_WAIT_SEC         Sleep before capture (default 7; "0" skips).
#   ORCH_CONTEXT_PROOF_PANE_LINES       Pane lines to capture for audit (default 30).
#   ORCH_CONTEXT_PROOF_REQUIRE_LIVE_CWD When 1 (default), an unreadable live
#                                       cwd fails strict mode. Set 0 to fall
#                                       back to the legacy server-side-only
#                                       behavior on a degraded tmux server.
#   PANE_CONTEXT_PROOF_SOFT_ROUTING     Default soft-routing mode if the
#                                       caller does not pass arg 5.
pane_context_proof() {
  local pane_target=${1:-}
  local workdir=${2:-}
  local expected_remote=${3:-}
  local expected_branch=${4:-}
  local soft_routing=${5:-${PANE_CONTEXT_PROOF_SOFT_ROUTING:-strict}}
  # shellcheck disable=SC2034 # consumed by callers (dispatch_ticket.sh, tests)
  PANE_CONTEXT_PROOF_REASON=""
  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_REMOTE=""
  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_BRANCH=""
  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_PANE=""
  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_LIVE_PATH=""
  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_ROUTE=""

  case "$soft_routing" in
    strict|accept-soft-routed) ;;
    *)
      PANE_CONTEXT_PROOF_REASON="invalid-soft-routing-mode"
      audit "DISPATCH CONTEXT_PROOF status=mismatch:invalid-soft-routing-mode pane=${pane_target} workdir=${workdir} soft_routing=${soft_routing}"
      return 1
      ;;
  esac

  if [[ -z "$pane_target" || -z "$workdir" ]]; then
    PANE_CONTEXT_PROOF_REASON="missing-args"
    audit "DISPATCH CONTEXT_PROOF status=mismatch:missing-args pane=${pane_target} workdir=${workdir}"
    return 1
  fi

  local agent=${pane_target%%:*}
  local sleep_sec=${ORCH_CONTEXT_PROOF_WAIT_SEC:-7}
  local pane_lines=${ORCH_CONTEXT_PROOF_PANE_LINES:-30}
  local require_live_cwd=${ORCH_CONTEXT_PROOF_REQUIRE_LIVE_CWD:-1}

  if [[ -n "$sleep_sec" && "$sleep_sec" != "0" ]]; then
    sleep "$sleep_sec" 2>/dev/null || true
  fi

  if [[ ! -d "$workdir" ]]; then
    PANE_CONTEXT_PROOF_REASON="workdir-missing"
    audit "DISPATCH CONTEXT_PROOF agent=${agent} pane=${pane_target} workdir=${workdir} status=mismatch:workdir-missing"
    return 1
  fi

  # Live pane cwd check (#286). Compare the pane's current_path with the
  # expected workdir. The dispatched agent may not yet have updated its own
  # cwd via `cd`, but the pane process cwd is the single source of truth for
  # which product the physical session is currently operating in.
  local live_path live_status
  set +e
  live_path=$(tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" display-message -p -t "$pane_target" '#{pane_current_path}' 2>/dev/null)
  live_status=$?
  set -e
  live_path=${live_path%$'\n'}
  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_LIVE_PATH=$live_path

  local live_route="hard"
  if [[ "$live_status" -ne 0 || -z "$live_path" ]]; then
    if [[ "$soft_routing" == "strict" && "$require_live_cwd" == "1" ]]; then
      PANE_CONTEXT_PROOF_REASON="live-cwd-unreadable"
      audit "DISPATCH CONTEXT_PROOF agent=${agent} pane=${pane_target} workdir=${workdir} live_workdir= status=mismatch:live-cwd-unreadable"
      return 1
    fi
    live_route="cwd-unreadable"
  elif [[ "$live_path" != "$workdir" ]]; then
    if [[ "$soft_routing" == "strict" ]]; then
      PANE_CONTEXT_PROOF_REASON="live-cwd-mismatch"
      audit "DISPATCH CONTEXT_PROOF agent=${agent} pane=${pane_target} workdir=${workdir} live_workdir=${live_path} status=mismatch:live-cwd-mismatch"
      return 1
    fi
    live_route="soft-routed"
  fi
  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_ROUTE=$live_route

  local remote branch
  remote=$(git -C "$workdir" remote get-url origin 2>/dev/null || echo '')
  branch=$(git -C "$workdir" branch --show-current 2>/dev/null || echo '')
  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_REMOTE="$remote"
  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_BRANCH="$branch"

  if [[ -z "$remote" ]]; then
    PANE_CONTEXT_PROOF_REASON="remote-missing"
    audit "DISPATCH CONTEXT_PROOF agent=${agent} pane=${pane_target} workdir=${workdir} live_workdir=${live_path} status=mismatch:remote-missing"
    return 1
  fi

  if [[ -n "$expected_remote" && "$remote" != *"$expected_remote"* ]]; then
    PANE_CONTEXT_PROOF_REASON="remote-mismatch"
    audit "DISPATCH CONTEXT_PROOF agent=${agent} pane=${pane_target} workdir=${workdir} live_workdir=${live_path} remote=${remote} expected_remote=${expected_remote} status=mismatch:remote-mismatch"
    return 1
  fi

  if [[ -n "$expected_branch" && -n "$branch" && "$branch" != "$expected_branch" ]]; then
    # shellcheck disable=SC2034
    PANE_CONTEXT_PROOF_REASON="branch-mismatch"
    audit "DISPATCH CONTEXT_PROOF agent=${agent} pane=${pane_target} workdir=${workdir} live_workdir=${live_path} branch=${branch} expected_branch=${expected_branch} status=mismatch:branch-mismatch"
    return 1
  fi

  # shellcheck disable=SC2034
  PANE_CONTEXT_PROOF_PANE=$(capture_pane "$pane_target" "$pane_lines" 2>/dev/null || echo '')

  audit "DISPATCH CONTEXT_PROOF agent=${agent} pane=${pane_target} workdir=${workdir} live_workdir=${live_path} remote=${remote} branch=${branch} route=${live_route} status=ok"
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

# Echo a tmux pane's live `#{pane_current_path}` on stdout.
#
# Returns 0 when a non-empty path is echoed. Returns 1 when the pane is
# unreachable (tmux server down, pane missing, or the introspection call
# times out via `tmux_run_timeout`). Callers MUST distinguish 1 from 0
# with an empty path: an empty path with a 0 status would mean the pane
# reports an empty cwd, which is not a normal state and should be treated
# as "unknown" rather than a match against an empty assigned workdir.
#
#   tmux_pane_current_path PANE_TARGET
tmux_pane_current_path() {
  local target=${1:?usage: tmux_pane_current_path <pane-target>}
  local result status
  set +e
  result=$(tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null)
  status=$?
  set -e
  result=${result%$'\n'}
  if [[ "$status" -ne 0 || -z "$result" ]]; then
    return 1
  fi
  printf '%s\n' "$result"
}

# Decorate `agent_inventory_entries` rows with the live pane cwd so callers
# can distinguish the assigned workdir (declarative configuration) from the
# pane's current_path (live runtime context).
#
# Output schema (one line per agent):
#
#   label|pane|assigned_workdir|live_pane_cwd|live_cwd_match
#
# - `assigned_workdir` is the workdir declared by the operator in
#   `AGENT_PANES` or derived from `AGENT_WORKDIR_TEMPLATE` /
#   `AGENT_REPO_PREFIX`.
# - `live_pane_cwd` is the pane's `#{pane_current_path}` at call time, or
#   an empty string when tmux cannot introspect the pane.
# - `live_cwd_match` is one of:
#     * `true`     — live pane cwd equals the assigned workdir.
#     * `false`    — live pane cwd differs from the assigned workdir.
#     * `unknown`  — tmux could not introspect the pane (server down,
#                    pane missing, or timeout).
#
# This helper exists because consumers of `agent_inventory_entries` have
# historically conflated the assigned workdir with the live pane cwd (see
# issue #321 finding `agent-inventory-live-cwd-helper` and the prior
# incidents fixed by #286/#295). Migrate consumers to this helper when
# they need a live context proof; keep using `agent_inventory_entries`
# when only the declarative assignment is needed (no tmux dependency).
#
# Returns 0 unless the underlying `agent_inventory_entries` call fails.
# Errors from `tmux_pane_current_path` are NOT fatal — they are reported
# via `live_cwd_match=unknown` and an empty `live_pane_cwd` so callers can
# still see the assigned workdir.
agent_inventory_entries_with_live_cwd() {
  local label pane workdir live match
  while IFS='|' read -r label pane workdir; do
    [[ -n "$label$pane$workdir" ]] || continue
    if live=$(tmux_pane_current_path "$pane" 2>/dev/null); then
      if [[ "$live" == "$workdir" ]]; then
        match="true"
      else
        match="false"
      fi
    else
      live=""
      match="unknown"
    fi
    printf '%s|%s|%s|%s|%s\n' "$label" "$pane" "$workdir" "$live" "$match"
  done < <(agent_inventory_entries)
}
