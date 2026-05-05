#!/usr/bin/env bash
# quota_detect.sh — quota / rate-limit detection helpers for agent panes.

: "${QUOTA_SWAP_COOLDOWN_SEC:=300}"

quota_patterns_file() {
  if [[ -n "${QUOTA_PATTERNS_FILE:-}" ]]; then
    printf '%s\n' "$QUOTA_PATTERNS_FILE"
  elif [[ -n "${TK:-}" ]]; then
    printf '%s\n' "$TK/config/quota_patterns.txt"
  else
    printf '%s\n' "config/quota_patterns.txt"
  fi
}

quota_content_matches() {
  local content=${1:-}
  local patterns_file
  local pattern

  # shellcheck disable=SC2034
  QUOTA_MATCH_PATTERN=''
  patterns_file=$(quota_patterns_file)
  [[ -f "$patterns_file" ]] || return 1

  while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    [[ -z "$pattern" || "$pattern" =~ ^[[:space:]]*# ]] && continue
    if grep -qiE -- "$pattern" <<< "$content" 2>/dev/null; then
      # shellcheck disable=SC2034
      QUOTA_MATCH_PATTERN=$pattern
      return 0
    fi
  done < "$patterns_file"

  return 1
}

quota_swap_state_file() {
  local agent=${1:?usage: quota_swap_state_file <agent>}
  printf '%s\n' "$(state_dir)/quota-swap-${agent}.ts"
}

quota_mark_swap() {
  local agent=${1:?usage: quota_mark_swap <agent>}
  local state_file
  state_file=$(quota_swap_state_file "$agent")
  mkdir -p "$(dirname "$state_file")"
  date +%s > "$state_file"
}

quota_swap_cooldown_active() {
  local agent=${1:?usage: quota_swap_cooldown_active <agent>}
  local state_file last_swap now
  state_file=$(quota_swap_state_file "$agent")
  [[ -f "$state_file" ]] || return 1

  last_swap=$(cat "$state_file" 2>/dev/null || echo 0)
  now=$(date +%s)

  [[ $((now - last_swap)) -lt "${QUOTA_SWAP_COOLDOWN_SEC}" ]]
}
