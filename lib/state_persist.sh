#!/usr/bin/env bash
# state_persist.sh — file I/O helpers for the per-project state dir.
#
# state_dir() lives in audit_log.sh (source it FIRST). This file adds:
#   state_file <name>                       — echo path inside state_dir
#   state_persist <name> <content-string>   — atomic write
#   state_append <name> <line>              — append line
#   state_append_unique <name> <line>       — append only if not already present
#   state_read <name>                       — cat (empty if absent)
#   state_trim <name> <max-lines>           — keep only the last N lines
#   state_get <name>                        — cat JSON state file (<name>.json)
#   state_update <name> <jq-filter>         — locked JSON update
#
# Required env: PROJECT (asserted by audit_log.sh at source time)

state_file() {
  local name="${1:?usage: state_file <name>}"
  printf '%s/%s' "$(state_dir)" "$name"
}

_state_json_file() {
  local name="${1:?usage: _state_json_file <name>}"
  if [[ "$name" == *.json ]]; then
    state_file "$name"
  else
    state_file "${name}.json"
  fi
}

state_persist() {
  local name="${1:?usage: state_persist <name> <content>}"
  local content="${2-}"
  local target tmp
  target=$(state_file "$name")
  tmp="${target}.tmp.$$"
  printf '%s' "$content" > "$tmp"
  mv "$tmp" "$target"
  if command -v audit >/dev/null 2>&1; then
    local bytes
    bytes=$(wc -c < "$target" | tr -d ' ')
    audit "state file ${name} persisted at ${target} (${bytes} bytes)"
  fi
}

state_append() {
  local name="${1:?usage: state_append <name> <line>}"
  local line="${2-}"
  local target
  target=$(state_file "$name")
  printf '%s\n' "$line" >> "$target"
}

state_append_unique() {
  local name="${1:?usage: state_append_unique <name> <line>}"
  local line="${2-}"
  local target
  target=$(state_file "$name")
  touch "$target"
  if ! grep -qxF "$line" "$target"; then
    printf '%s\n' "$line" >> "$target"
  fi
}

state_read() {
  local name="${1:?usage: state_read <name>}"
  local target
  target=$(state_file "$name")
  [ -f "$target" ] && cat "$target" || true
}

state_trim() {
  local name="${1:?usage: state_trim <name> <max-lines>}"
  local max="${2:?}"
  local target
  target=$(state_file "$name")
  [ -f "$target" ] || return 0
  tail -n "$max" "$target" > "${target}.tmp.$$" && mv "${target}.tmp.$$" "$target"
}

state_get() {
  local name="${1:?usage: state_get <name>}"
  local target
  target=$(_state_json_file "$name")
  if [[ -s "$target" ]]; then
    cat "$target"
  else
    printf '{}\n'
  fi
}

state_update() {
  local name="${1:?usage: state_update <name> <jq-filter>}"
  local filter="${2:?usage: state_update <name> <jq-filter>}"
  local target lock tmp
  target=$(_state_json_file "$name")
  lock="${target}.lock"
  tmp="${target}.tmp.$$"

  mkdir -p "$(dirname "$target")"
  (
    flock 9
    if [[ -s "$target" ]]; then
      jq "$filter" "$target" > "$tmp"
    else
      printf '{}\n' | jq "$filter" > "$tmp"
    fi
    mv "$tmp" "$target"
  ) 9>"$lock"
}
