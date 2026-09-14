#!/usr/bin/env bash
# lib/ordo_runtime_adapter_ssh.sh — SSH backend of the runtime adapter (#811).
#
# Runs the same tmux operations as the tmux backend, but on a remote host:
# the adapter builds a small bash snippet and ships it through the CRLF-safe
# transport already used by scripts/windows_ssh_dispatch.sh:
#
#   ssh <host> "tr -d '\r' | bash -s" < snippet
#
# The remote command literal is identical to windows_ssh_dispatch.sh so
# Windows-originated hosts keep working (carriage returns are stripped
# before bash sees argv). Nothing is executed locally except ssh.
#
# Knobs (profile-level, all optional except the host):
#   ORDO_SSH_HOST            ssh target (user@host or ssh_config alias); or --host
#   ORDO_SSH_BIN             ssh binary (default: ssh)
#   ORDO_SSH_OPTS            extra ssh options, whitespace-separated (e.g. "-o BatchMode=yes")
#   ORDO_SSH_TIMEOUT_SEC     local timeout around ssh (default 30)
#   ORDO_SSH_REMOTE_COMMAND  remote reader (default: tr -d '\r' | bash -s)
#   ORDO_SSH_REMOTE_TMUX     remote tmux binary (default: tmux)
#
# Remote snippet exit codes: 0 ok, 4 target not found, 6 tmux missing,
# 1 other. ssh transport failure (255) is reported as runtime_error with
# details.retryable=true.
#
# Loaded on demand by lib/ordo_runtime_adapter.sh; do not source directly.

: "${ORDO_SSH_BIN:=ssh}"
: "${ORDO_SSH_TIMEOUT_SEC:=30}"
: "${ORDO_SSH_REMOTE_COMMAND:=tr -d '\\r' | bash -s}"
: "${ORDO_SSH_REMOTE_TMUX:=tmux}"

_ordo_runtime_ssh_host() {
  local host="${ORDO_RT_HOST:-${ORDO_SSH_HOST:-}}"
  if [[ -z "$host" ]]; then
    ordo_runtime_adapter_error bad_argument "ssh runtime adapter needs a host: set ORDO_SSH_HOST or pass --host" false \
      "$(jq -cn '{"missing": "ORDO_SSH_HOST"}')"
    return $?
  fi
  printf '%s\n' "$host"
}

# _ordo_runtime_ssh_exec <host> <snippet-file> <stdout-file> <stderr-file>
#   Returns the remote exit code (255 = transport failure).
_ordo_runtime_ssh_exec() {
  local host="$1" snippet="$2" out="$3" err="$4"
  local -a opts=()
  if [[ -n "${ORDO_SSH_OPTS:-}" ]]; then
    # shellcheck disable=SC2206 # intentional word-splitting of operator-provided options
    opts=(${ORDO_SSH_OPTS})
  fi
  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    # shellcheck disable=SC2029 # the remote command is a fixed client-defined literal, like windows_ssh_dispatch.sh
    timeout "$ORDO_SSH_TIMEOUT_SEC" "$ORDO_SSH_BIN" "${opts[@]}" "$host" "$ORDO_SSH_REMOTE_COMMAND" \
      < "$snippet" > "$out" 2> "$err" || rc=$?
  else
    # shellcheck disable=SC2029
    "$ORDO_SSH_BIN" "${opts[@]}" "$host" "$ORDO_SSH_REMOTE_COMMAND" < "$snippet" > "$out" 2> "$err" || rc=$?
  fi
  return "$rc"
}

# _ordo_runtime_ssh_run <op> <target> <snippet-body>
#   Prints remote stdout; maps remote/transport failures to typed errors.
_ordo_runtime_ssh_run() {
  local op="$1" target="$2" body="$3"
  local host snippet out err rc=0
  host=$(_ordo_runtime_ssh_host) || return $?
  snippet=$(mktemp) out=$(mktemp) err=$(mktemp)
  {
    printf 'set -u\n'
    printf 'T=%q\n' "$target"
    printf 'TMUX_BIN=%q\n' "$ORDO_SSH_REMOTE_TMUX"
    # shellcheck disable=SC2016 # remote snippet, expanded on the remote host
    printf 'command -v "$TMUX_BIN" >/dev/null 2>&1 || exit 6\n'
    printf '%s\n' "$body"
  } > "$snippet"
  _ordo_runtime_ssh_exec "$host" "$snippet" "$out" "$err" || rc=$?
  local stderr_text
  stderr_text=$(head -c 400 "$err" | ordo_runtime_adapter_redact_text | tr '\n' ' ')
  rm -f "$snippet" "$err"
  case "$rc" in
    0) cat "$out"; rm -f "$out"; return 0 ;;
    4)
      rm -f "$out"
      ordo_runtime_adapter_error not_found "remote tmux target not found: ${target} on ${host}" false \
        "$(jq -cn --arg t "$target" --arg h "$host" --arg op "$op" '{"target": $t, "host": $h, "op": $op}')"
      return $?
      ;;
    6)
      rm -f "$out"
      ordo_runtime_adapter_error missing_dependency "tmux is not available on remote host ${host}" false \
        "$(jq -cn --arg h "$host" '{"dependency": "tmux", "host": $h}')"
      return $?
      ;;
    124|255)
      rm -f "$out"
      ordo_runtime_adapter_error runtime_error "ssh transport failed (exit ${rc}) for ${host}" true \
        "$(jq -cn --arg h "$host" --arg op "$op" --argjson rc "$rc" --arg e "$stderr_text" \
            '{"host": $h, "op": $op, "exit": $rc, "stderr": $e}')"
      return $?
      ;;
    *)
      rm -f "$out"
      ordo_runtime_adapter_error runtime_error "remote ${op} failed (exit ${rc}) on ${host}" false \
        "$(jq -cn --arg h "$host" --arg op "$op" --argjson rc "$rc" --arg e "$stderr_text" \
            '{"host": $h, "op": $op, "exit": $rc, "stderr": $e}')"
      return $?
      ;;
  esac
}

# Same heuristic as agent_is_idle (lib/tmux_helpers.sh), applied to a
# capture that was taken remotely.
_ordo_runtime_ssh_idle_from_capture() {
  local tail5
  tail5=$(printf '%s\n' "$1" | tail -n 5)
  if grep -qiE 'esc to interrupt|cogitating|thinking|cancel' <<< "$tail5"; then
    return 1
  fi
  grep -qE '(^|[[:space:]])(>|❯|╰|\$)([[:space:]]*$)' <<< "$tail5"
}

_ordo_runtime_ssh_resolve_snippet() {
  cat <<'EOF'
"$TMUX_BIN" display-message -p -t "$T" '#{pane_dead}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null || exit 4
EOF
}

ordo_runtime_adapter_ssh_start() {
  ordo_runtime_adapter_parse_args start "$@" || return $?
  local target="$ORDO_RT_TARGET" delim body
  delim="ORDO_RT_EOF_${RANDOM}_${RANDOM}"
  body=$(cat <<EOF
$(_ordo_runtime_ssh_resolve_snippet)
tmp=\$(mktemp)
cat > "\$tmp" <<'${delim}'
${ORDO_RT_TEXT}
${delim}
buf="ordo_rt_\$\$_\${RANDOM}"
"\$TMUX_BIN" load-buffer -b "\$buf" "\$tmp" || { rm -f "\$tmp"; exit 1; }
"\$TMUX_BIN" paste-buffer -b "\$buf" -t "\$T" -d || { rm -f "\$tmp"; "\$TMUX_BIN" delete-buffer -b "\$buf" 2>/dev/null; exit 1; }
rm -f "\$tmp"
sleep ${ORCH_TMUX_SEND_ENTER_DELAY_SEC:-0.5}
"\$TMUX_BIN" send-keys -t "\$T" Enter
EOF
)
  _ordo_runtime_ssh_run start "$target" "$body" >/dev/null || return $?
  ordo_runtime_adapter_result start "$(jq -cn --arg t "$target" --arg h "$(_ordo_runtime_ssh_host)" --argjson bytes "${#ORDO_RT_TEXT}" \
    '{"target": $t, "host": $h, "submitted": true, "bytes": $bytes, "reason": "submitted", "acceptance": null}')"
}

ordo_runtime_adapter_ssh_inspect() {
  ordo_runtime_adapter_parse_args inspect "$@" || return $?
  local target="$ORDO_RT_TARGET" lines="${ORDO_RT_LINES:-$ORDO_RUNTIME_INSPECT_LINES}" body out
  body=$(cat <<EOF
meta=\$("\$TMUX_BIN" display-message -p -t "\$T" '#{pane_dead}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null) || exit 4
printf 'ORDO_RT_META:%s\n' "\$meta"
"\$TMUX_BIN" capture-pane -t "\$T" -p -S -${lines} 2>/dev/null || true
EOF
)
  out=$(_ordo_runtime_ssh_run inspect "$target" "$body") || return $?
  local meta capture dead command path alive=true idle=false
  meta=$(printf '%s\n' "$out" | sed -n 's/^ORDO_RT_META://p' | head -1)
  capture=$(printf '%s\n' "$out" | sed '1{/^ORDO_RT_META:/d}')
  IFS='|' read -r dead command path <<< "$meta"
  [[ "$dead" == "1" ]] && alive=false
  if [[ "$alive" == true ]] && _ordo_runtime_ssh_idle_from_capture "$capture"; then
    idle=true
  fi
  ordo_runtime_adapter_result inspect "$(jq -cn --arg t "$target" --arg h "$(_ordo_runtime_ssh_host)" --argjson alive "$alive" --argjson idle "$idle" \
    --arg cwd "$path" --arg cmd "$command" --arg capture "$capture" --argjson lines "$lines" \
    '{"target": $t, "host": $h, "alive": $alive, "idle": $idle, "cwd": $cwd, "command": $cmd, "capture": $capture, "lines": $lines}')"
}

ordo_runtime_adapter_ssh_signal() {
  ordo_runtime_adapter_parse_args signal "$@" || return $?
  local target="$ORDO_RT_TARGET" body key
  body=$(_ordo_runtime_ssh_resolve_snippet)
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    body+=$'\n'"\"\$TMUX_BIN\" send-keys -t \"\$T\" $(printf '%q' "$key") || exit 1"
  done < <(ordo_runtime_adapter_signal_keys "$ORDO_RT_SIGNAL")
  _ordo_runtime_ssh_run signal "$target" "$body" >/dev/null || return $?
  ordo_runtime_adapter_result signal "$(jq -cn --arg t "$target" --arg h "$(_ordo_runtime_ssh_host)" --arg s "$ORDO_RT_SIGNAL" \
    '{"target": $t, "host": $h, "signal": $s, "delivered": true}')"
}

ordo_runtime_adapter_ssh_stop() {
  ordo_runtime_adapter_parse_args stop "$@" || return $?
  local target="$ORDO_RT_TARGET" body action
  body=$(_ordo_runtime_ssh_resolve_snippet)
  if [[ "$ORDO_RT_KILL" -eq 1 ]]; then
    action='kill'
    # shellcheck disable=SC2016 # remote snippet
    body+=$'\n''"$TMUX_BIN" kill-pane -t "$T" || exit 1'
  else
    action='interrupt'
    # shellcheck disable=SC2016 # remote snippet
    body+=$'\n''"$TMUX_BIN" send-keys -t "$T" C-c || exit 1'
  fi
  _ordo_runtime_ssh_run stop "$target" "$body" >/dev/null || return $?
  ordo_runtime_adapter_result stop "$(jq -cn --arg t "$target" --arg h "$(_ordo_runtime_ssh_host)" --arg a "$action" \
    '{"target": $t, "host": $h, "action": $a, "delivered": true}')"
}

ordo_runtime_adapter_ssh_collect_evidence() {
  ordo_runtime_adapter_parse_args collect_evidence "$@" || return $?
  local target="$ORDO_RT_TARGET" lines="${ORDO_RT_LINES:-$ORDO_RUNTIME_EVIDENCE_LINES}" body tmp evidence
  body=$(cat <<EOF
$(_ordo_runtime_ssh_resolve_snippet) >/dev/null
"\$TMUX_BIN" capture-pane -t "\$T" -p -S -${lines} 2>/dev/null || true
EOF
)
  tmp=$(mktemp)
  if ! _ordo_runtime_ssh_run collect_evidence "$target" "$body" > "$tmp"; then
    local rc=$?
    rm -f "$tmp"
    return "$rc"
  fi
  evidence=$(ordo_runtime_adapter_write_evidence "$target" "${ORDO_RT_LABEL:-capture}" "$tmp")
  rm -f "$tmp"
  if [[ -n "$ORDO_RT_OUT" ]]; then
    cp "$(printf '%s' "$evidence" | jq -r .path)" "$ORDO_RT_OUT"
  fi
  ordo_runtime_adapter_result collect_evidence "$(printf '%s' "$evidence" | jq -c --arg t "$target" --arg h "$(_ordo_runtime_ssh_host)" --argjson lines "$lines" \
    '{"target": $t, "host": $h, "requested_lines": $lines} + .')"
}

ordo_runtime_adapter_ssh_recover() {
  ordo_runtime_adapter_parse_args recover "$@" || return $?
  local target="$ORDO_RT_TARGET" session="${ORDO_RT_TARGET%%:*}" body out
  local launch="${ORDO_RT_COMMAND:-${ORDO_RUNTIME_LAUNCH_COMMAND:-}}"
  body=$(cat <<EOF
S=$(printf '%q' "$session")
W=$(printf '%q' "$ORDO_RT_WORKDIR")
L=$(printf '%q' "$launch")
extra=()
[ -n "\$W" ] && extra=(-c "\$W")
if ! "\$TMUX_BIN" has-session -t "\$S" 2>/dev/null; then
  if [ -n "\$L" ]; then "\$TMUX_BIN" new-session -d -s "\$S" "\${extra[@]}" "\$L" || exit 1
  else "\$TMUX_BIN" new-session -d -s "\$S" "\${extra[@]}" || exit 1; fi
  echo session_created; exit 0
fi
meta=\$("\$TMUX_BIN" display-message -p -t "\$T" '#{pane_dead}' 2>/dev/null || echo missing)
if [ "\$meta" = "1" ] || [ "\$meta" = "missing" ]; then
  if [ -n "\$L" ]; then "\$TMUX_BIN" respawn-pane -k -t "\$T" "\${extra[@]}" "\$L" || exit 1
  else "\$TMUX_BIN" respawn-pane -k -t "\$T" "\${extra[@]}" || exit 1; fi
  echo pane_respawned; exit 0
fi
echo none
EOF
)
  out=$(_ordo_runtime_ssh_run recover "$target" "$body") || return $?
  local action
  action=$(printf '%s\n' "$out" | tail -n 1)
  [[ -n "$action" ]] || action=none
  ordo_runtime_adapter_result recover "$(jq -cn --arg t "$target" --arg h "$(_ordo_runtime_ssh_host)" --arg s "$session" --arg a "$action" \
    --arg w "$ORDO_RT_WORKDIR" --arg c "$launch" \
    '{"target": $t, "host": $h, "session": $s, "action": $a, "alive": true, "workdir": $w, "command": $c}')"
}
