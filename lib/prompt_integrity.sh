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
#   ORCH_PROMPT_STRIPPED_LITERAL_RE
#                            — regex of empty grammar left after required
#                              shell/backtick literals were stripped

: "${ORCH_PROMPT_MIN_BYTES:=256}"
: "${ORCH_PROMPT_FORBID_RE:=command not found|syntax error near unexpected token|unbound variable|: cannot open|No such file or directory$}"
: "${ORCH_PROMPT_STRIPPED_LITERAL_RE:=Use[[:space:]]*,|PR target:[[:space:]]*\.|No direct push to[[:space:]]*,[[:space:]]*no[[:space:]]*,|references[[:space:]]*\.}"

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

  # Unquoted heredocs can evaluate backtick literals and leave canonical
  # sections structurally present but operationally blank, e.g. "PR target: .".
  if grep -Eq "$ORCH_PROMPT_STRIPPED_LITERAL_RE" "$prompt_file"; then
    local match
    match=$(grep -E -m1 "$ORCH_PROMPT_STRIPPED_LITERAL_RE" "$prompt_file")
    printf 'prompt integrity: stripped required literal detected: %s\n' "$match" >&2
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

prompt_sha256_text() {
  local text=${1:-}
  printf '%s' "$text" | sha256sum | awk '{print $1}'
}

prompt_escape_source_appendix_text() {
  sed -e 's/{{/{ {/g' -e 's/}}/} }/g'
}

prompt_source_substance_appendix() {
  local source_url=${1:-}
  local source_title=${2:-}
  local source_body=${3:-}
  local source_hash="unavailable"
  local escaped_body=""

  if [[ -n "$source_body" ]]; then
    source_hash="sha256:$(prompt_sha256_text "$source_body")"
    escaped_body=$(printf '%s' "$source_body" | prompt_escape_source_appendix_text)
  fi

  cat <<EOF

## Source ticket substance appendix - mandatory

Source URL: ${source_url:-unavailable}
Source title: ${source_title:-unavailable}
Source body hash: ${source_hash}

The source body below is copied into the dispatch prompt so mandatory
requirements, evidence links, acceptance criteria, non-goals, validation gates,
and linked context remain available to the agent. Template braces are spaced
inside this appendix only, so prompt-integrity checks do not mistake quoted
source text for unresolved renderer placeholders.

### Source body

\`\`\`markdown
${escaped_body:-source body unavailable; agent read-proof required before implementation}
\`\`\`
EOF
}

prompt_mandatory_source_lines() {
  local source_body=${1:-}
  printf '%s\n' "$source_body" \
    | grep -Ein '(^|[^[:alpha:]])(obligatoire|required|must|shall)([^[:alpha:]]|$)' || true
}

prompt_line_has_optional_language() {
  local line=${1:-}
  grep -Eiq 'if applicable|if suitable|optionally|optional|as needed|si adaptée|si adaptee|si besoin|le cas échéant|le cas echeant' \
    <<< "$line"
}

prompt_line_shares_keyword() {
  local source_line=${1:-}
  local rendered_line=${2:-}
  local rendered_lower word
  rendered_lower=$(printf '%s' "$rendered_line" | tr '[:upper:]' '[:lower:]')

  while IFS= read -r word; do
    [[ ${#word} -ge 4 ]] || continue
    case "$word" in
      must|required|shall|obligatoire|with|from|this|that|dans|pour|avec|plus|source|ticket)
        continue ;;
    esac
    case "$rendered_lower" in
      *"$word"*) return 0 ;;
    esac
  done < <(
    printf '%s' "$source_line" \
      | tr '[:upper:]' '[:lower:]' \
      | tr -cs '[:alnum:]_' '\n'
  )

  return 1
}

prompt_fidelity_audit() {
  local source_hash=${1:-unavailable}
  local rendered_hash=${2:-unavailable}
  local status=${3:-unknown}
  local dropped_count=${4:-0}
  local softened_count=${5:-0}

  if declare -F audit >/dev/null 2>&1; then
    audit "PROMPT_FIDELITY source_hash=$source_hash rendered_prompt_hash=$rendered_hash fidelity_status=$status dropped_mandatory=$dropped_count softened_mandatory=$softened_count"
  else
    printf 'PROMPT_FIDELITY source_hash=%s rendered_prompt_hash=%s fidelity_status=%s dropped_mandatory=%s softened_mandatory=%s\n' \
      "$source_hash" "$rendered_hash" "$status" "$dropped_count" "$softened_count" >&2
  fi
}

prompt_validate_source_fidelity() {
  local source_url=${1:-}
  local source_title=${2:-}
  local source_body=${3:-}
  local rendered_prompt=${4:-}
  local source_hash rendered_hash mandatory_entry mandatory_line escaped_line
  local dropped_count=0 softened_count=0 main_prompt optional_line

  [[ -n "$source_body" ]] || {
    rendered_hash="sha256:$(prompt_sha256_text "$rendered_prompt")"
    prompt_fidelity_audit "unavailable" "$rendered_hash" "source-unavailable" 0 0
    return 0
  }

  source_hash="sha256:$(prompt_sha256_text "$source_body")"
  rendered_hash="sha256:$(prompt_sha256_text "$rendered_prompt")"
  main_prompt=${rendered_prompt%%$'\n## Source ticket substance appendix - mandatory'*}

  while IFS= read -r mandatory_entry; do
    [[ -n "$mandatory_entry" ]] || continue
    mandatory_line=${mandatory_entry#*:}
    escaped_line=$(printf '%s' "$mandatory_line" | prompt_escape_source_appendix_text)

    if ! grep -Fq -- "$escaped_line" <<< "$rendered_prompt"; then
      dropped_count=$((dropped_count + 1))
      printf 'prompt fidelity: dropped mandatory source requirement from %s: %s\n' \
        "${source_url:-source}" "$mandatory_line" >&2
    fi

    while IFS= read -r optional_line; do
      [[ -n "$optional_line" ]] || continue
      if prompt_line_has_optional_language "$optional_line" \
        && prompt_line_shares_keyword "$mandatory_line" "$optional_line"; then
        softened_count=$((softened_count + 1))
        printf 'prompt fidelity: softened mandatory source requirement from %s: source=%s rendered=%s\n' \
          "${source_url:-source}" "$mandatory_line" "$optional_line" >&2
      fi
    done <<< "$main_prompt"
  done < <(prompt_mandatory_source_lines "$source_body")

  if [[ "$dropped_count" -gt 0 || "$softened_count" -gt 0 ]]; then
    prompt_fidelity_audit "$source_hash" "$rendered_hash" "fail" "$dropped_count" "$softened_count"
    return 1
  fi

  prompt_fidelity_audit "$source_hash" "$rendered_hash" "pass" 0 0
  return 0
}
