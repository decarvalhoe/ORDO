#!/usr/bin/env bash
# lib/ordo_runtime_adapter_tmux.sh — tmux backend of the runtime adapter (#811).
#
# Thin wrapper over lib/tmux_helpers.sh: every operation calls the existing
# helper (terminal_dispatch_submit, capture_pane, agent_is_idle,
# tmux_pane_values_batch, pane_acceptance_proof, tmux_run_timeout) and only
# adds the normalised JSON envelope and typed errors. Nothing here changes
# how the helpers behave; the existing scripts keep calling them directly.
#
# Loaded on demand by lib/ordo_runtime_adapter.sh; do not source directly.

_ORDO_RUNTIME_TMUX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! declare -F capture_pane >/dev/null 2>&1; then
  # shellcheck source=lib/tmux_helpers.sh
  source "$_ORDO_RUNTIME_TMUX_LIB_DIR/tmux_helpers.sh"
fi

_ordo_runtime_tmux_available() {
  declare -F tmux >/dev/null 2>&1 || command -v tmux >/dev/null 2>&1
}

_ordo_runtime_tmux_require() {
  if ! _ordo_runtime_tmux_available; then
    ordo_runtime_adapter_error missing_dependency "tmux is not available on PATH" false \
      "$(jq -cn '{"dependency": "tmux"}')"
    return $?
  fi
}

# _ordo_runtime_tmux_resolve <target>
#   Prints "<dead>|<command>|<path>" for the pane, or returns 4 when tmux
#   cannot resolve the target (server down or pane missing).
_ordo_runtime_tmux_resolve() {
  local target="$1" out
  out=$(tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" display-message -p -t "$target" \
    '#{pane_dead}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null) || return 4
  [[ -n "$out" ]] || return 4
  printf '%s\n' "${out%$'\n'}"
}

_ordo_runtime_tmux_not_found() {
  local target="$1"
  ordo_runtime_adapter_error not_found "tmux target not found: ${target}" false \
    "$(jq -cn --arg t "$target" '{"target": $t, "hint": "run ordo_runtime recover to recreate it"}')"
}

ordo_runtime_adapter_tmux_start() {
  ordo_runtime_adapter_parse_args start "$@" || return $?
  _ordo_runtime_tmux_require || return $?
  local target="$ORDO_RT_TARGET"
  _ordo_runtime_tmux_resolve "$target" >/dev/null || { _ordo_runtime_tmux_not_found "$target"; return $?; }
  local rc=0
  terminal_dispatch_submit "$target" "$ORDO_RT_TEXT" "$ORDO_RT_WORKDIR" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    ordo_runtime_adapter_error runtime_error "dispatch text was not consumed by ${target}" true \
      "$(jq -cn --arg t "$target" --arg reason "${DISPATCH_SUBMIT_LAST_REASON:-}" --arg detail "${DISPATCH_SUBMIT_LAST_DETAIL:-}" \
          '{"target": $t, "reason": $reason, "detail": $detail}')"
    return $?
  fi
  local acceptance='null'
  if [[ -n "$ORDO_RT_AGENT" && -n "$ORDO_RT_TICKET" ]]; then
    local accepted=true
    pane_acceptance_proof "$target" "$ORDO_RT_AGENT" "$ORDO_RT_TICKET" "${ORDO_RT_ACCEPT_TIMEOUT:-}" || accepted=false
    acceptance=$(jq -cn --argjson ok "$accepted" --arg reason "${PANE_ACCEPTANCE_PROOF_REASON:-}" '{"accepted": $ok, "reason": $reason}')
  fi
  ordo_runtime_adapter_result start "$(jq -cn --arg t "$target" --argjson bytes "${#ORDO_RT_TEXT}" \
    --arg reason "${DISPATCH_SUBMIT_LAST_REASON:-submitted}" --argjson acceptance "$acceptance" \
    '{"target": $t, "submitted": true, "bytes": $bytes, "reason": (if $reason == "" then "submitted" else $reason end), "acceptance": $acceptance}')"
}

ordo_runtime_adapter_tmux_inspect() {
  ordo_runtime_adapter_parse_args inspect "$@" || return $?
  _ordo_runtime_tmux_require || return $?
  local target="$ORDO_RT_TARGET" meta
  meta=$(_ordo_runtime_tmux_resolve "$target") || { _ordo_runtime_tmux_not_found "$target"; return $?; }
  local dead command path
  IFS='|' read -r dead command path <<< "$meta"
  local lines="${ORDO_RT_LINES:-$ORDO_RUNTIME_INSPECT_LINES}"
  local capture idle=false alive=true
  [[ "$dead" == "1" ]] && alive=false
  capture=$(capture_pane "$target" "$lines" 2>/dev/null || true)
  if [[ "$alive" == true ]] && agent_is_idle "$target" 2>/dev/null; then
    idle=true
  fi
  ordo_runtime_adapter_result inspect "$(jq -cn --arg t "$target" --argjson alive "$alive" --argjson idle "$idle" \
    --arg cwd "$path" --arg cmd "$command" --arg capture "$capture" --argjson lines "$lines" \
    '{"target": $t, "alive": $alive, "idle": $idle, "cwd": $cwd, "command": $cmd, "capture": $capture, "lines": $lines}')"
}

ordo_runtime_adapter_tmux_signal() {
  ordo_runtime_adapter_parse_args signal "$@" || return $?
  _ordo_runtime_tmux_require || return $?
  local target="$ORDO_RT_TARGET"
  _ordo_runtime_tmux_resolve "$target" >/dev/null || { _ordo_runtime_tmux_not_found "$target"; return $?; }
  local key
  if [[ "$ORDO_RT_SIGNAL" == "clear" ]]; then
    terminal_dispatch_clear_input "$target"
  else
    while IFS= read -r key; do
      [[ -n "$key" ]] || continue
      if ! tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" send-keys -t "$target" "$key"; then
        ordo_runtime_adapter_error runtime_error "send-keys ${key} failed for ${target}" true \
          "$(jq -cn --arg t "$target" --arg k "$key" '{"target": $t, "key": $k}')"
        return $?
      fi
    done < <(ordo_runtime_adapter_signal_keys "$ORDO_RT_SIGNAL")
  fi
  ordo_runtime_adapter_result signal "$(jq -cn --arg t "$target" --arg s "$ORDO_RT_SIGNAL" \
    '{"target": $t, "signal": $s, "delivered": true}')"
}

ordo_runtime_adapter_tmux_stop() {
  ordo_runtime_adapter_parse_args stop "$@" || return $?
  _ordo_runtime_tmux_require || return $?
  local target="$ORDO_RT_TARGET" action
  _ordo_runtime_tmux_resolve "$target" >/dev/null || { _ordo_runtime_tmux_not_found "$target"; return $?; }
  if [[ "$ORDO_RT_KILL" -eq 1 ]]; then
    action='kill'
    if ! tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" kill-pane -t "$target"; then
      ordo_runtime_adapter_error runtime_error "kill-pane failed for ${target}" true \
        "$(jq -cn --arg t "$target" '{"target": $t}')"
      return $?
    fi
  else
    action='interrupt'
    if ! tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" send-keys -t "$target" C-c; then
      ordo_runtime_adapter_error runtime_error "interrupt (C-c) failed for ${target}" true \
        "$(jq -cn --arg t "$target" '{"target": $t}')"
      return $?
    fi
  fi
  ordo_runtime_adapter_result stop "$(jq -cn --arg t "$target" --arg a "$action" \
    '{"target": $t, "action": $a, "delivered": true}')"
}

ordo_runtime_adapter_tmux_collect_evidence() {
  ordo_runtime_adapter_parse_args collect_evidence "$@" || return $?
  _ordo_runtime_tmux_require || return $?
  local target="$ORDO_RT_TARGET"
  _ordo_runtime_tmux_resolve "$target" >/dev/null || { _ordo_runtime_tmux_not_found "$target"; return $?; }
  local lines="${ORDO_RT_LINES:-$ORDO_RUNTIME_EVIDENCE_LINES}" tmp evidence
  tmp=$(mktemp)
  capture_pane "$target" "$lines" > "$tmp" 2>/dev/null || true
  evidence=$(ordo_runtime_adapter_write_evidence "$target" "${ORDO_RT_LABEL:-capture}" "$tmp")
  rm -f "$tmp"
  if [[ -n "$ORDO_RT_OUT" ]]; then
    cp "$(printf '%s' "$evidence" | jq -r .path)" "$ORDO_RT_OUT"
  fi
  ordo_runtime_adapter_result collect_evidence "$(printf '%s' "$evidence" | jq -c --arg t "$target" --argjson lines "$lines" \
    '{"target": $t, "requested_lines": $lines} + .')"
}

ordo_runtime_adapter_tmux_recover() {
  ordo_runtime_adapter_parse_args recover "$@" || return $?
  _ordo_runtime_tmux_require || return $?
  local target="$ORDO_RT_TARGET" session="${ORDO_RT_TARGET%%:*}" action=none
  local launch="${ORDO_RT_COMMAND:-}"
  if [[ -z "$launch" ]] && declare -F agent_launch_command >/dev/null 2>&1; then
    launch=$(agent_launch_command "$target" 2>/dev/null || true)
  fi
  [[ -n "$launch" ]] || launch="${ORDO_RUNTIME_LAUNCH_COMMAND:-}"
  local -a extra=()
  [[ -n "$ORDO_RT_WORKDIR" ]] && extra+=(-c "$ORDO_RT_WORKDIR")
  if ! tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" has-session -t "$session" 2>/dev/null; then
    action=session_created
    local -a cmd=(new-session -d -s "$session" "${extra[@]}")
    [[ -n "$launch" ]] && cmd+=("$launch")
    if ! tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" "${cmd[@]}"; then
      ordo_runtime_adapter_error runtime_error "could not create tmux session ${session}" true \
        "$(jq -cn --arg s "$session" --arg w "$ORDO_RT_WORKDIR" '{"session": $s, "workdir": $w}')"
      return $?
    fi
  else
    local meta dead
    meta=$(_ordo_runtime_tmux_resolve "$target" || true)
    dead="${meta%%|*}"
    if [[ -z "$meta" || "$dead" == "1" ]]; then
      action=pane_respawned
      local -a cmd=(respawn-pane -k -t "$target" "${extra[@]}")
      [[ -n "$launch" ]] && cmd+=("$launch")
      if ! tmux_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" "${cmd[@]}"; then
        ordo_runtime_adapter_error runtime_error "could not respawn pane ${target}" true \
          "$(jq -cn --arg t "$target" '{"target": $t}')"
        return $?
      fi
    fi
  fi
  ordo_runtime_adapter_result recover "$(jq -cn --arg t "$target" --arg s "$session" --arg a "$action" \
    --arg w "$ORDO_RT_WORKDIR" --arg c "$launch" \
    '{"target": $t, "session": $s, "action": $a, "alive": true, "workdir": $w, "command": $c}')"
}
