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
#
# Issue #595: parallel dispatch_ticket.sh invocations were cross-pasting
# briefs because every caller wrote into the SAME shared tmux buffer
# (`orch_send`). Between one caller's load-buffer and its paste-buffer,
# a sibling caller's load-buffer could overwrite the buffer, so the
# first paste-buffer pasted the sibling's brief into the first pane.
# Fix: derive a per-invocation unique buffer name from $BASHPID +
# $RANDOM + epoch nanoseconds, and `tmux delete-buffer -b <name>` after
# paste to keep the tmux server clean. The `-d` flag on paste-buffer
# already deletes-after-paste; the explicit delete-buffer covers
# error paths where paste-buffer fails after load-buffer succeeded.
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

  local buf_name
  # BASHPID is the current process PID (vs $$ parent shell PID); RANDOM
  # gives a 0..32767 nonce; epoch-nanoseconds is a final tiebreaker on
  # ultra-fast spawns. Together this is collision-safe across any
  # realistic parallel dispatch wave.
  buf_name="orch_send_${BASHPID:-$$}_${RANDOM}_$(date -u +%s%N 2>/dev/null || date -u +%s)"

  if ! tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" load-buffer -b "$buf_name" "$tmp"; then
    rm -f "$tmp"
    tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" delete-buffer -b "$buf_name" 2>/dev/null || true
    return 1
  fi
  if ! tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" paste-buffer -b "$buf_name" -t "$target" -d; then
    rm -f "$tmp"
    # paste-buffer failed but load-buffer succeeded — explicitly clean up.
    tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" delete-buffer -b "$buf_name" 2>/dev/null || true
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

# Issue #573: verify the dispatched agent is actually working on the
# assigned ticket — not just "active" (PROMPT_EXECUTION_PROOF_OK from
# #612) or "in the right workdir" (CONTEXT_PROOF_OK from #112).
#
# Live evidence on 2026-05-10 showed pane scrollback still on a prior
# ORDO transcript while the ledger marked the agent busy on a fresh
# RBOK ticket (#3208 / #3232 / #3366 / #3404). The promotion was a
# false positive — capacity hidden, redispatch blocked.
#
# Acceptance signal: the dispatched brief filename
# `dispatch-<agent>-<ticket>.md` is unique per (agent, ticket) and
# lands in the pane scrollback as soon as the agent prints / reads
# the `Read /tmp/dispatch-<agent>-<ticket>.md` ONELINER. We accept
# either the brief filename match OR a literal ticket-number
# reference (e.g. `#3208`) anywhere in the recent scrollback.
#
#   pane_acceptance_proof TARGET AGENT TICKET [TIMEOUT_SEC] [LINES]
#
# Returns 0 on accept, 1 on no-evidence within the timeout window.
# Side-effect: sets `PANE_ACCEPTANCE_PROOF_REASON` (`brief-filename`,
# `ticket-reference`, or `no-acceptance-evidence`) for caller audit.
pane_acceptance_proof() {
  local target=${1:?usage: pane_acceptance_proof <target> <agent> <ticket> [timeout] [lines]}
  local agent=${2:?usage: pane_acceptance_proof <target> <agent> <ticket> [timeout] [lines]}
  local ticket=${3:?usage: pane_acceptance_proof <target> <agent> <ticket> [timeout] [lines]}
  local timeout=${4:-${ORCH_DISPATCH_ACCEPTANCE_TIMEOUT_SEC:-15}}
  local lines=${5:-${ORCH_DISPATCH_ACCEPTANCE_LINES:-50}}
  ticket=${ticket#\#}

  local brief_marker="dispatch-${agent}-${ticket}.md"
  local elapsed=0
  local poll_interval=${ORCH_DISPATCH_ACCEPTANCE_POLL_SEC:-2}
  while [ "$elapsed" -lt "$timeout" ]; do
    local capture
    capture=$(capture_pane "$target" "$lines" 2>/dev/null || printf '')
    if [ -n "$capture" ]; then
      if grep -Fq "$brief_marker" <<< "$capture"; then
        # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
        PANE_ACCEPTANCE_PROOF_REASON="brief-filename"
        return 0
      fi
      # Word-boundary ticket reference: accept `#3208`, ` 3208 `,
      # `(3208)`, but reject substrings like `132080` or `103208`.
      if grep -qE "(^|[^0-9])#?${ticket}([^0-9]|$)" <<< "$capture"; then
        # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
        PANE_ACCEPTANCE_PROOF_REASON="ticket-reference"
        return 0
      fi
    fi
    sleep "$poll_interval" 2>/dev/null || true
    elapsed=$((elapsed + poll_interval))
  done
  # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
  PANE_ACCEPTANCE_PROOF_REASON="no-acceptance-evidence"
  return 1
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

git_remote_url_for_audit() {
  local url=${1:-}
  if [[ "$url" =~ ^([^:/?#]+://)([^/@]+@)(.*)$ ]]; then
    printf '%s<redacted>@%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  printf '%s\n' "$url"
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

terminal_dispatch_submitted_text_visible() {
  local submitted_text=${1:-}
  local out=${2:-}
  local visible_prefix_chars visible_min_chars fragment_chars fragment_stride
  local submitted_compact out_compact visible_fragment start max_start final_start

  [[ -n "$submitted_text" && -n "$out" ]] || return 1

  if grep -Fq -- "$submitted_text" <<< "$out"; then
    return 0
  fi

  visible_prefix_chars=${ORCH_DISPATCH_VISIBLE_TEXT_PREFIX_CHARS:-48}
  visible_min_chars=${ORCH_DISPATCH_VISIBLE_TEXT_MIN_CHARS:-24}
  if ! [[ "$visible_prefix_chars" =~ ^[0-9]+$ ]] \
    || ! [[ "$visible_min_chars" =~ ^[0-9]+$ ]] \
    || [[ "$visible_prefix_chars" -lt "$visible_min_chars" ]]; then
    return 1
  fi

  submitted_compact=$(tr -s '[:space:]' ' ' <<< "$submitted_text")
  out_compact=$(tr -s '[:space:]' ' ' <<< "$out")

  visible_fragment=${submitted_compact:0:$visible_prefix_chars}
  if [[ "${#visible_fragment}" -ge "$visible_min_chars" ]] \
    && grep -Fq -- "$visible_fragment" <<< "$out_compact"; then
    return 0
  fi
  visible_fragment=${submitted_compact:0:$visible_min_chars}
  if [[ "${#visible_fragment}" -ge "$visible_min_chars" ]] \
    && grep -Fq -- "$visible_fragment" <<< "$out_compact"; then
    return 0
  fi

  # Issue #639, after #612: a terminal may wrap or duplicate only a later
  # line of the submitted one-liner. Search deterministic interior/suffix
  # windows so footer text cannot hide a still-visible submitted prompt.
  fragment_chars=${ORCH_DISPATCH_VISIBLE_TEXT_FRAGMENT_CHARS:-36}
  fragment_stride=${ORCH_DISPATCH_VISIBLE_TEXT_FRAGMENT_STRIDE:-24}
  if ! [[ "$fragment_chars" =~ ^[0-9]+$ ]] || [[ "$fragment_chars" -lt "$visible_min_chars" ]]; then
    fragment_chars=$visible_min_chars
  fi
  if ! [[ "$fragment_stride" =~ ^[0-9]+$ ]] || [[ "$fragment_stride" -lt 1 ]]; then
    fragment_stride=$fragment_chars
  fi

  max_start=$((${#submitted_compact} - fragment_chars))
  if [[ "$max_start" -lt 0 ]]; then
    return 1
  fi
  for ((start = 0; start <= max_start; start += fragment_stride)); do
    visible_fragment=${submitted_compact:start:fragment_chars}
    if [[ "${#visible_fragment}" -ge "$visible_min_chars" ]] \
      && grep -Fq -- "$visible_fragment" <<< "$out_compact"; then
      return 0
    fi
  done
  final_start=$max_start
  visible_fragment=${submitted_compact:final_start:fragment_chars}
  if [[ "${#visible_fragment}" -ge "$visible_min_chars" ]] \
    && grep -Fq -- "$visible_fragment" <<< "$out_compact"; then
    return 0
  fi

  return 1
}

# Issue #700: Claude Code (and other modern terminal agents) render an
# active CLI state via a spinner glyph followed by a gerund descriptor,
# an ellipsis, and an elapsed-seconds counter — for example:
#
#   ✢ Spelunking… (31s)
#
# and reply / tool-call lines prefixed with a filled-circle bullet:
#
#   ● Bash(git log --oneline -10)
#   ● Identity matches agent-002.
#
# `terminal_dispatch_activity_after_visible_submission` and the
# legacy `active_pattern` enumerate verbs like `working|running|git|...`
# but CANNOT enumerate every gerund spinner word the CLI cycles
# through, and they ignore the bullet prefix that is itself a strong
# "this is the agent's reply, not the user's input" marker. The
# helper below detects either marker family in a CLI-vocabulary
# -agnostic way so the proof gate can recognise positive execution
# evidence the legacy patterns would otherwise miss.
#
# Returns 0 when the captured output contains an agent-activity
# marker, 1 otherwise. The pattern is operator-overridable through
# ORCH_DISPATCH_AGENT_ACTIVITY_PATTERN.
terminal_dispatch_agent_activity_visible() {
  local out=${1:-}
  [[ -n "$out" ]] || return 1
  local pattern=${ORCH_DISPATCH_AGENT_ACTIVITY_PATTERN:-'(…|\.\.\.)[[:space:]]*\(([0-9]+)[[:space:]]*s\)|(^|[[:space:]])●[[:space:]]+[A-Za-z]|(^|[[:space:]])⏺[[:space:]]+[A-Za-z]'}
  grep -qE "$pattern" <<< "$out" 2>/dev/null
}

# Issue #700: cross-check that the live pane cwd matches the workdir
# the dispatcher intended for this agent. Used as a strict gate on the
# "submission still visible but agent appears active" recovery path:
# a paste-buffer echo is forgivable as proof of consumption ONLY when
# the pane is also operating in the assigned worktree. An empty
# `expected` argument disables the check (returns 1) so callers can
# opt-in by passing a non-empty value.
terminal_dispatch_pane_cwd_matches() {
  local target=${1:-}
  local expected=${2:-}
  [[ -n "$target" && -n "$expected" ]] || return 1
  local live
  live=$(pane_current_path "$target" 2>/dev/null || printf '')
  [[ -n "$live" && "$live" == "$expected" ]]
}

terminal_dispatch_activity_after_visible_submission() {
  local submitted_text=${1:-}
  local out=${2:-}
  local active_pattern=${3:-}
  local line seen_submission=0 after_submission=""

  [[ -n "$submitted_text" && -n "$out" && -n "$active_pattern" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    if terminal_dispatch_submitted_text_visible "$submitted_text" "$line"; then
      seen_submission=1
      after_submission=""
      continue
    fi
    if [[ "$seen_submission" -eq 1 ]]; then
      after_submission+="${line}"$'\n'
    fi
  done <<< "$out"

  [[ -n "$after_submission" ]] || return 1
  grep -qiE "$active_pattern" <<< "$after_submission" 2>/dev/null
}

# ORDO #652 helper: return 0 when CAPTURE contains an active-pattern line
# that is NOT a substring of SUBMITTED (after stripping leading prompt
# chrome). Used by terminal_dispatch_pane_not_consumed to tell apart:
#   - "prompt visible AND new agent activity below it" → consumed,
#   - "prompt visible AND only generic footer chrome below it" → not
#     consumed (preserves #569/#638 closed-failure behavior).
terminal_dispatch_capture_has_residual_activity() {
  local submitted=${1:-}
  local capture=${2:-}
  local active_pattern=${3:-}
  local submitted_compact line line_compact stripped

  [[ -n "$capture" && -n "$active_pattern" ]] || return 1
  submitted_compact=$(tr -s '[:space:]' ' ' <<< "$submitted")

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    line_compact=$(tr -s '[:space:]' ' ' <<< "$line")
    line_compact=${line_compact# }
    line_compact=${line_compact% }
    [[ -n "$line_compact" ]] || continue
    stripped=$(sed -E 's/^[[:space:]>›❯╰$]+//' <<< "$line_compact")
    [[ -n "$stripped" ]] || continue
    if [[ -n "$submitted_compact" ]] \
      && grep -Fq -- "$stripped" <<< "$submitted_compact"; then
      continue
    fi
    if grep -qiE "$active_pattern" <<< "$stripped" 2>/dev/null; then
      return 0
    fi
  done <<< "$capture"

  return 1
}

terminal_dispatch_pane_not_consumed() {
  local target=${1:?usage: terminal_dispatch_pane_not_consumed <target> <submitted-text> [expected-workdir]}
  local submitted_text=${2:-}
  local expected_workdir=${3:-${ORCH_DISPATCH_EXPECTED_WORKDIR:-}}
  local out active_pattern idle_pattern

  out=$(capture_pane "$target" "${ORCH_DISPATCH_CONSUME_CAPTURE_LINES:-12}" 2>/dev/null || true)
  # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
  DISPATCH_SUBMIT_LAST_CAPTURE="$out"
  if [[ -z "$out" ]]; then
    # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
    DISPATCH_SUBMIT_LAST_REASON="no-positive-execution-proof"
    # shellcheck disable=SC2034
    DISPATCH_SUBMIT_LAST_DETAIL="pane=${target} produced empty capture after dispatch submit"
    # shellcheck disable=SC2034  # ORDO #652: which heuristic fired
    DISPATCH_SUBMIT_LAST_SIGNAL="no-positive-execution-proof"
    return 0
  fi

  active_pattern=${ORCH_DISPATCH_ACTIVE_PATTERN:-'(^|[[:space:]])(running|working|thinking|processing|busy|executing)([[:space:]]|$)|(^|[[:space:]])(bash|shell|tool|read|reading|edit|editing|opened|opening|grep|rg|sed|git|test|pytest|npm)([[:space:]:().-]|$)'}

  # A visible submitted prompt is normally not consumed, even if the agent UI
  # also renders an "esc to interrupt" or similar active footer. The exception
  # is positive command/output activity below the prompt (#652) or a modern
  # agent activity marker in the expected workdir (#700).
  if terminal_dispatch_submitted_text_visible "$submitted_text" "$out"; then
    if terminal_dispatch_capture_has_residual_activity \
      "$submitted_text" "$out" "$active_pattern"; then
      # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
      DISPATCH_SUBMIT_LAST_PROOF="prompt-visible-with-activity-below"
      # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
      DISPATCH_SUBMIT_LAST_SIGNAL="prompt-visible-with-activity-below"
      return 1
    fi
    if terminal_dispatch_activity_after_visible_submission "$submitted_text" "$out" "$active_pattern"; then
      # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
      DISPATCH_SUBMIT_LAST_PROOF="post-submit-activity-after-visible-submission"
      # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
      DISPATCH_SUBMIT_LAST_SIGNAL="post-submit-activity-after-visible-submission"
      return 1
    fi
    # Issue #700: Claude Code paste echo can leave the submitted text in the
    # pane scrollback even though the agent has already consumed the prompt
    # and is actively producing work. When an agent-activity marker is
    # present (spinner glyph + elapsed-seconds, or `●` reply prefix) AND
    # the pane is operating in the dispatched workdir, treat the visible
    # submission as benign paste echo rather than a stuck input line.
    if terminal_dispatch_agent_activity_visible "$out" \
      && terminal_dispatch_pane_cwd_matches "$target" "$expected_workdir"; then
      # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
      DISPATCH_SUBMIT_LAST_PROOF="agent-activity-with-matching-workdir"
      # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
      DISPATCH_SUBMIT_LAST_SIGNAL="agent-activity-with-matching-workdir"
      return 1
    fi
    # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
    DISPATCH_SUBMIT_LAST_REASON="submission-still-visible"
    # shellcheck disable=SC2034
    DISPATCH_SUBMIT_LAST_DETAIL="pane=${target} still shows submitted text"
    # shellcheck disable=SC2034  # ORDO #652: which heuristic fired
    DISPATCH_SUBMIT_LAST_SIGNAL="submission-still-visible"
    return 0
  fi

  idle_pattern=${ORCH_DISPATCH_IDLE_PROMPT_PATTERN:-'(^|[[:space:]])(>|›|❯|╰|\$)([[:space:]]*)$'}
  if grep -qE "$idle_pattern" <<< "$out" 2>/dev/null; then
    # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
    DISPATCH_SUBMIT_LAST_REASON="idle-prompt"
    # shellcheck disable=SC2034
    DISPATCH_SUBMIT_LAST_DETAIL="pane=${target} appears idle after dispatch submit"
    # shellcheck disable=SC2034  # ORDO #652: which heuristic fired
    DISPATCH_SUBMIT_LAST_SIGNAL="idle-prompt"
    return 0
  fi

  if grep -qiE "$active_pattern" <<< "$out" 2>/dev/null; then
    # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
    DISPATCH_SUBMIT_LAST_PROOF="post-submit-action-pattern"
    # shellcheck disable=SC2034  # ORDO #652: which heuristic fired
    DISPATCH_SUBMIT_LAST_SIGNAL="post-submit-action-pattern"
    return 1
  fi

  # Issue #700: vocabulary-agnostic agent-activity proof. Claude Code cycles
  # through dozens of gerund spinner words ("Spelunking", "Cogitating",
  # "Wibbling", ...) that the active_pattern cannot enumerate; the spinner
  # glyph + ellipsis + elapsed-seconds shape (and the `●` / `⏺` reply
  # prefixes) are CLI-stable proof the agent is processing the brief.
  if terminal_dispatch_agent_activity_visible "$out"; then
    # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
    DISPATCH_SUBMIT_LAST_PROOF="post-submit-agent-activity"
    return 1
  fi

  # The submitted text is gone, but promotion still needs positive evidence
  # that the agent accepted it. A neutral repaint can otherwise masquerade as
  # successful prompt consumption.
  # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
  DISPATCH_SUBMIT_LAST_REASON="no-positive-execution-proof"
  # shellcheck disable=SC2034
  DISPATCH_SUBMIT_LAST_DETAIL="pane=${target} lacks active execution signal after dispatch submit"
  # shellcheck disable=SC2034  # ORDO #652: which heuristic fired
  DISPATCH_SUBMIT_LAST_SIGNAL="no-positive-execution-proof"
  return 0
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
  local target=${1:?usage: terminal_dispatch_submit <target> <text> [expected-workdir]}
  local text=${2:?usage: terminal_dispatch_submit <target> <text> [expected-workdir]}
  local expected_workdir=${3:-${ORCH_DISPATCH_EXPECTED_WORKDIR:-}}
  local attempts=${ORCH_DISPATCH_SUBMIT_ATTEMPTS:-2}
  local delay=${ORCH_DISPATCH_CONSUME_WAIT_SEC:-1}
  local attempt staged_enter_recovered=0

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
  DISPATCH_SUBMIT_LAST_PROOF=""
  # shellcheck disable=SC2034  # ORDO #652: which heuristic fired
  DISPATCH_SUBMIT_LAST_SIGNAL=""
  # shellcheck disable=SC2034
  DISPATCH_SUBMIT_ATTEMPT=0

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    # shellcheck disable=SC2034  # consumed by dispatch_ticket diagnostics
    DISPATCH_SUBMIT_ATTEMPT=$attempt
    # shellcheck disable=SC2034
    DISPATCH_SUBMIT_LAST_PROOF=""
    # shellcheck disable=SC2034  # ORDO #652
    DISPATCH_SUBMIT_LAST_SIGNAL=""
    if [[ "$attempt" -gt 1 ]]; then
      terminal_dispatch_clear_input "$target"
    fi

    if ! terminal_dispatch_submit_once "$target" "$text"; then
      # shellcheck disable=SC2034
      DISPATCH_SUBMIT_LAST_REASON="tmux-submit-failed"
      # shellcheck disable=SC2034
      DISPATCH_SUBMIT_LAST_DETAIL="pane=${target} attempt=${attempt}"
      # shellcheck disable=SC2034  # ORDO #652
      DISPATCH_SUBMIT_LAST_SIGNAL="tmux-submit-failed"
      return 1
    fi

    if [[ "${ORCH_DISPATCH_VERIFY_CONSUMED:-1}" != "1" ]]; then
      return 0
    fi

    sleep "$delay" 2>/dev/null || true
    if terminal_dispatch_pane_not_consumed "$target" "$text" "$expected_workdir"; then
      if [[ "${DISPATCH_SUBMIT_LAST_REASON:-}" == "submission-still-visible" ]] \
        && [[ "$staged_enter_recovered" -eq 0 ]]; then
        staged_enter_recovered=1
        tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" send-keys -t "$target" Enter 2>/dev/null || true
        sleep "$delay" 2>/dev/null || true
        if terminal_dispatch_pane_not_consumed "$target" "$text" "$expected_workdir"; then
          return 1
        fi
        # shellcheck disable=SC2034
        DISPATCH_SUBMIT_LAST_REASON=""
        # shellcheck disable=SC2034
        DISPATCH_SUBMIT_LAST_DETAIL=""
        return 0
      fi
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
    local audit_remote audit_expected_remote
    audit_remote=$(git_remote_url_for_audit "$remote")
    audit_expected_remote=$(git_remote_url_for_audit "$expected_remote")
    audit "DISPATCH CONTEXT_PROOF agent=${agent} pane=${pane_target} workdir=${workdir} live_workdir=${live_path} remote=${audit_remote} expected_remote=${audit_expected_remote} status=mismatch:remote-mismatch"
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

  local audit_remote
  audit_remote=$(git_remote_url_for_audit "$remote")
  audit "DISPATCH CONTEXT_PROOF agent=${agent} pane=${pane_target} workdir=${workdir} live_workdir=${live_path} remote=${audit_remote} branch=${branch} route=${live_route} status=ok"
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
