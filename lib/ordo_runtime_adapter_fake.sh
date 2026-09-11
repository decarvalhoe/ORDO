#!/usr/bin/env bash
# lib/ordo_runtime_adapter_fake.sh — fake backend of the runtime adapter (#811).
#
# In-memory-on-disk runtime for tests and the eval harness (#813). State is
# one JSON file per target under $ORDO_FAKE_ADAPTER_DIR/runtime/:
#
#   runtime/<safe-target>.json
#     {"target","alive":bool,"idle":bool,"cwd","command","capture","history":[...]}
#   runtime/events.jsonl        one line per op that changed state
#
# Semantics mirror the tmux backend: a missing target is not_found (exit 4)
# for start/inspect/signal/stop/collect_evidence; `recover` creates it.
# No tmux, no ssh, no network.
#
# Loaded on demand by lib/ordo_runtime_adapter.sh; do not source directly.

_ordo_runtime_fake_dir() {
  if [[ -z "${ORDO_FAKE_ADAPTER_DIR:-}" ]]; then
    ordo_runtime_adapter_error bad_argument "ORDO_FAKE_ADAPTER_DIR must be set for the fake runtime adapter" false \
      "$(jq -cn '{"missing": "ORDO_FAKE_ADAPTER_DIR"}')"
    return $?
  fi
  mkdir -p "$ORDO_FAKE_ADAPTER_DIR/runtime"
  printf '%s\n' "$ORDO_FAKE_ADAPTER_DIR/runtime"
}

_ordo_runtime_fake_state_file() {
  printf '%s/%s.json\n' "$1" "$(ordo_runtime_adapter_safe_name "$2")"
}

_ordo_runtime_fake_load() {
  local dir="$1" target="$2" file
  file=$(_ordo_runtime_fake_state_file "$dir" "$target")
  if [[ ! -f "$file" ]]; then
    ordo_runtime_adapter_error not_found "fake runtime target not found: ${target}" false \
      "$(jq -cn --arg t "$target" --arg f "$file" '{"target": $t, "state_file": $f, "hint": "run ordo_runtime recover to create it"}')"
    return $?
  fi
  jq -c . "$file"
}

# _ordo_runtime_fake_save <dir> <target> <op> <jq-update-filter> [extra-json]
_ordo_runtime_fake_save() {
  local dir="$1" target="$2" op="$3" filter="$4" extra="${5:-{\}}"
  local file tmp ts
  file=$(_ordo_runtime_fake_state_file "$dir" "$target")
  ts=$(ordo_contracts_now)
  tmp=$(mktemp)
  jq -c --arg ts "$ts" --arg op "$op" --argjson extra "$extra" \
    "${filter} | .history += [{\"ts\": \$ts, \"op\": \$op} + \$extra]" "$file" > "$tmp" && mv "$tmp" "$file"
  jq -cn --arg ts "$ts" --arg op "$op" --arg t "$target" --argjson extra "$extra" \
    '{"ts": $ts, "op": $op, "target": $t} + $extra' >> "$dir/events.jsonl"
}

ordo_runtime_adapter_fake_start() {
  ordo_runtime_adapter_parse_args start "$@" || return $?
  local dir target="$ORDO_RT_TARGET" first_line
  dir=$(_ordo_runtime_fake_dir) || return $?
  _ordo_runtime_fake_load "$dir" "$target" >/dev/null || return $?
  first_line=$(printf '%s\n' "$ORDO_RT_TEXT" | head -n 1)
  # shellcheck disable=SC2016 # jq program
  _ordo_runtime_fake_save "$dir" "$target" start \
    '.idle = false | .capture = ((.capture // "") + "\n> " + $extra.text_head)' \
    "$(jq -cn --arg h "$first_line" --argjson bytes "${#ORDO_RT_TEXT}" --arg w "$ORDO_RT_WORKDIR" \
        '{"text_head": $h, "bytes": $bytes, "workdir": $w}')"
  ordo_runtime_adapter_result start "$(jq -cn --arg t "$target" --argjson bytes "${#ORDO_RT_TEXT}" \
    '{"target": $t, "submitted": true, "bytes": $bytes, "reason": "submitted", "acceptance": null}')"
}

ordo_runtime_adapter_fake_inspect() {
  ordo_runtime_adapter_parse_args inspect "$@" || return $?
  local dir target="$ORDO_RT_TARGET" state lines="${ORDO_RT_LINES:-$ORDO_RUNTIME_INSPECT_LINES}"
  dir=$(_ordo_runtime_fake_dir) || return $?
  state=$(_ordo_runtime_fake_load "$dir" "$target") || return $?
  ordo_runtime_adapter_result inspect "$(printf '%s' "$state" | jq -c --arg t "$target" --argjson lines "$lines" '
    {"target": $t,
     "alive": (.alive // false),
     "idle": (if (.alive // false) then (.idle // false) else false end),
     "cwd": (.cwd // ""),
     "command": (.command // ""),
     "capture": ((.capture // "") | split("\n") | .[-($lines):] | join("\n")),
     "lines": $lines}')"
}

ordo_runtime_adapter_fake_signal() {
  ordo_runtime_adapter_parse_args signal "$@" || return $?
  local dir target="$ORDO_RT_TARGET"
  dir=$(_ordo_runtime_fake_dir) || return $?
  _ordo_runtime_fake_load "$dir" "$target" >/dev/null || return $?
  local filter='.'
  case "$ORDO_RT_SIGNAL" in
    interrupt|escape|clear) filter='.idle = true' ;;
  esac
  _ordo_runtime_fake_save "$dir" "$target" signal "$filter" "$(jq -cn --arg s "$ORDO_RT_SIGNAL" '{"signal": $s}')"
  ordo_runtime_adapter_result signal "$(jq -cn --arg t "$target" --arg s "$ORDO_RT_SIGNAL" \
    '{"target": $t, "signal": $s, "delivered": true}')"
}

ordo_runtime_adapter_fake_stop() {
  ordo_runtime_adapter_parse_args stop "$@" || return $?
  local dir target="$ORDO_RT_TARGET" action filter
  dir=$(_ordo_runtime_fake_dir) || return $?
  _ordo_runtime_fake_load "$dir" "$target" >/dev/null || return $?
  if [[ "$ORDO_RT_KILL" -eq 1 ]]; then
    action='kill'; filter='.alive = false | .idle = false'
  else
    action='interrupt'; filter='.idle = true'
  fi
  _ordo_runtime_fake_save "$dir" "$target" stop "$filter" "$(jq -cn --arg a "$action" '{"action": $a}')"
  ordo_runtime_adapter_result stop "$(jq -cn --arg t "$target" --arg a "$action" \
    '{"target": $t, "action": $a, "delivered": true}')"
}

ordo_runtime_adapter_fake_collect_evidence() {
  ordo_runtime_adapter_parse_args collect_evidence "$@" || return $?
  local dir target="$ORDO_RT_TARGET" state tmp evidence lines="${ORDO_RT_LINES:-$ORDO_RUNTIME_EVIDENCE_LINES}"
  dir=$(_ordo_runtime_fake_dir) || return $?
  state=$(_ordo_runtime_fake_load "$dir" "$target") || return $?
  tmp=$(mktemp)
  printf '%s' "$state" | jq -r --argjson lines "$lines" '(.capture // "") | split("\n") | .[-($lines):] | join("\n")' > "$tmp"
  evidence=$(ordo_runtime_adapter_write_evidence "$target" "${ORDO_RT_LABEL:-capture}" "$tmp")
  rm -f "$tmp"
  if [[ -n "$ORDO_RT_OUT" ]]; then
    cp "$(printf '%s' "$evidence" | jq -r .path)" "$ORDO_RT_OUT"
  fi
  _ordo_runtime_fake_save "$dir" "$target" collect_evidence '.' "$(printf '%s' "$evidence" | jq -c '{"path": .path}')"
  ordo_runtime_adapter_result collect_evidence "$(printf '%s' "$evidence" | jq -c --arg t "$target" --argjson lines "$lines" \
    '{"target": $t, "requested_lines": $lines} + .')"
}

ordo_runtime_adapter_fake_recover() {
  ordo_runtime_adapter_parse_args recover "$@" || return $?
  local dir target="$ORDO_RT_TARGET" session="${ORDO_RT_TARGET%%:*}" file action=none
  local launch="${ORDO_RT_COMMAND:-${ORDO_RUNTIME_LAUNCH_COMMAND:-claude}}"
  dir=$(_ordo_runtime_fake_dir) || return $?
  file=$(_ordo_runtime_fake_state_file "$dir" "$target")
  if [[ ! -f "$file" ]]; then
    action=session_created
    jq -cn --arg t "$target" --arg w "$ORDO_RT_WORKDIR" --arg c "$launch" \
      '{"target": $t, "alive": true, "idle": true, "cwd": $w, "command": $c, "capture": "", "history": []}' > "$file"
    _ordo_runtime_fake_save "$dir" "$target" recover '.' "$(jq -cn --arg a "$action" '{"action": $a}')"
  elif ! jq -e '.alive // false' "$file" >/dev/null; then
    action=pane_respawned
    # shellcheck disable=SC2016 # jq program
    _ordo_runtime_fake_save "$dir" "$target" recover \
      '.alive = true | .idle = true | .cwd = (if $extra.workdir == "" then .cwd else $extra.workdir end) | .command = $extra.command' \
      "$(jq -cn --arg a "$action" --arg w "$ORDO_RT_WORKDIR" --arg c "$launch" '{"action": $a, "workdir": $w, "command": $c}')"
  fi
  ordo_runtime_adapter_result recover "$(jq -cn --arg t "$target" --arg s "$session" --arg a "$action" \
    --arg w "$ORDO_RT_WORKDIR" --arg c "$launch" \
    '{"target": $t, "session": $s, "action": $a, "alive": true, "workdir": $w, "command": $c}')"
}
