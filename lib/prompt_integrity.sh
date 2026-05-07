#!/usr/bin/env bash
# prompt_integrity.sh — detect corrupted staged dispatch prompts.
#
# Sourced by dispatch_ticket.sh before sending a prompt to a tmux pane.
# Catches the failure modes documented in issue #89 comment 19:14Z:
#   - unquoted heredocs that ran command substitution and shrank/garbled
#     the prompt before it ever reached the agent;
#   - prompts truncated to a few bytes by a failed pipe;
#   - non-UTF-8 bytes injected when shell-error stderr leaked into the
#     prompt path.
#
# Functions:
#   validate_prompt_integrity <file>
#     Returns 0 when the prompt looks intact, 1 otherwise. On failure,
#     prints a one-line reason to stderr ("prompt integrity: <reason>").
#
# Tunable via env (defaults match observed-good prompts):
#   ORCH_PROMPT_MIN_BYTES   — minimum acceptable size (default 256)
#   ORCH_PROMPT_FORBID_RE   — regex of shell-error markers (default below)

: "${ORCH_PROMPT_MIN_BYTES:=256}"
: "${ORCH_PROMPT_FORBID_RE:=command not found|syntax error near unexpected token|unbound variable|: cannot open|No such file or directory$}"

validate_prompt_integrity() {
  local prompt_file=${1:?usage: validate_prompt_integrity <prompt-file>}

  if [ ! -f "$prompt_file" ]; then
    printf 'prompt integrity: file not found: %s\n' "$prompt_file" >&2
    return 1
  fi

  local size
  size=$(wc -c < "$prompt_file" | tr -d '[:space:]')
  if [ "${size:-0}" -lt "$ORCH_PROMPT_MIN_BYTES" ]; then
    printf 'prompt integrity: file too small (%s bytes < %s)\n' \
      "$size" "$ORCH_PROMPT_MIN_BYTES" >&2
    return 1
  fi

  # UTF-8 validity. iconv is part of every libc image we target; if it's
  # absent fall back to a python3 check, then to a permissive skip with a
  # warning so we never silently regress to no-check.
  if command -v iconv >/dev/null 2>&1; then
    if ! iconv -f UTF-8 -t UTF-8 "$prompt_file" >/dev/null 2>&1; then
      printf 'prompt integrity: invalid UTF-8 bytes in %s\n' "$prompt_file" >&2
      return 1
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if ! python3 -c 'import sys; open(sys.argv[1],"rb").read().decode("utf-8")' "$prompt_file" >/dev/null 2>&1; then
      printf 'prompt integrity: invalid UTF-8 bytes in %s\n' "$prompt_file" >&2
      return 1
    fi
  else
    printf 'prompt integrity: warning — no iconv/python3 to check UTF-8\n' >&2
  fi

  if grep -Eq "$ORCH_PROMPT_FORBID_RE" "$prompt_file"; then
    local match
    match=$(grep -E -m1 "$ORCH_PROMPT_FORBID_RE" "$prompt_file")
    printf 'prompt integrity: shell-error contamination detected: %s\n' "$match" >&2
    return 1
  fi

  # Unresolved template placeholder — sign the renderer was interrupted
  # mid-stream (failed heredoc, partial pipe). Cheaper to refuse here
  # than to ship a broken brief to the agent.
  if grep -Eq '\{\{[a-zA-Z_][a-zA-Z0-9_]*\}\}' "$prompt_file"; then
    local match
    match=$(grep -E -m1 -o '\{\{[a-zA-Z_][a-zA-Z0-9_]*\}\}' "$prompt_file")
    printf 'prompt integrity: unresolved template placeholder %s\n' "$match" >&2
    return 1
  fi

  return 0
}
