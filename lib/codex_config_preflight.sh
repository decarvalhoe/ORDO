#!/usr/bin/env bash
# codex_config_preflight.sh — validate Codex runtime config before spawning the
# supervisor CLI. Catches the failure mode where embedded quotes turn a valid
# variant like `xhigh` into `'xhigh'`, which Codex rejects at config load and
# burns supervisor cycles without ever reaching steady state.
#
# Provided functions:
#   codex_config_validate_value <field> <value>
#       Returns 0 when the value is well-formed for the field; otherwise
#       returns non-zero and writes a single-line diagnostic on stdout. The
#       caller is responsible for emitting the diagnostic via audit/die.
#
#   codex_config_preflight <model> <reasoning> <approval> <sandbox>
#       Validates every field. Each empty argument is treated as "unset" and
#       skipped (so callers can pass through whichever fields are actually
#       wired). On the first invalid field, audits a structured failure line
#       and exits via die(). On success, audits a redacted summary so the
#       supervisor boot trace records the resolved config without exposing
#       any potential secret content the caller may have routed through.
#
#   codex_config_render_redacted <model> <reasoning> <approval> <sandbox>
#       Echoes a single redacted, debug-safe summary line suitable for
#       inclusion in audit logs or operator output.

set -o pipefail

CODEX_REASONING_EFFORT_VALID="none minimal low medium high xhigh"
CODEX_APPROVAL_VALID="untrusted on-failure on-request never"
CODEX_SANDBOX_VALID="read-only workspace-write danger-full-access"

codex_config_value_is_quoted() {
  local value=${1-}
  case "$value" in
    \'*\'|\"*\")
      return 0
      ;;
  esac
  case "$value" in
    *\'*|*\"*)
      return 0
      ;;
  esac
  return 1
}

codex_config_value_has_whitespace() {
  local value=${1-}
  case "$value" in
    *[[:space:]]*) return 0 ;;
  esac
  return 1
}

codex_config_value_in_set() {
  local value=$1
  shift
  local allowed
  for allowed in "$@"; do
    [[ "$value" == "$allowed" ]] && return 0
  done
  return 1
}

codex_config_validate_value() {
  local field=${1:?usage: codex_config_validate_value <field> <value>}
  local value=${2-}

  if [[ -z "$value" ]]; then
    printf '%s\n' "codex config field=${field} empty"
    return 1
  fi
  if codex_config_value_is_quoted "$value"; then
    printf '%s\n' "codex config field=${field} value contains literal quote characters — Codex rejects quoted variants; pass the bare token (e.g. xhigh, not 'xhigh')"
    return 1
  fi
  if codex_config_value_has_whitespace "$value"; then
    printf '%s\n' "codex config field=${field} value contains whitespace — Codex config tokens must be single bare words"
    return 1
  fi

  case "$field" in
    model)
      case "$value" in
        *[!A-Za-z0-9._:/+-]*)
          printf '%s\n' "codex config field=model value contains characters outside [A-Za-z0-9._:/+-]"
          return 1
          ;;
      esac
      ;;
    model_reasoning_effort)
      # shellcheck disable=SC2086
      if ! codex_config_value_in_set "$value" $CODEX_REASONING_EFFORT_VALID; then
        printf '%s\n' "codex config field=model_reasoning_effort value=${value} not in {${CODEX_REASONING_EFFORT_VALID// /, }}"
        return 1
      fi
      ;;
    approval)
      # shellcheck disable=SC2086
      if ! codex_config_value_in_set "$value" $CODEX_APPROVAL_VALID; then
        printf '%s\n' "codex config field=approval value=${value} not in {${CODEX_APPROVAL_VALID// /, }}"
        return 1
      fi
      ;;
    sandbox)
      # shellcheck disable=SC2086
      if ! codex_config_value_in_set "$value" $CODEX_SANDBOX_VALID; then
        printf '%s\n' "codex config field=sandbox value=${value} not in {${CODEX_SANDBOX_VALID// /, }}"
        return 1
      fi
      ;;
    *)
      printf '%s\n' "codex config field=${field} unknown — extend codex_config_validate_value"
      return 1
      ;;
  esac
  return 0
}

codex_config_render_redacted() {
  local model=${1-}
  local reasoning=${2-}
  local approval=${3-}
  local sandbox=${4-}
  printf 'codex_config model=%s model_reasoning_effort=%s approval=%s sandbox=%s' \
    "${model:-<unset>}" \
    "${reasoning:-<unset>}" \
    "${approval:-<unset>}" \
    "${sandbox:-<unset>}"
}

codex_config_preflight_fail() {
  local diag=$1
  if declare -F audit >/dev/null 2>&1; then
    audit "CODEX_CONFIG_PREFLIGHT FAIL ${diag}"
  else
    printf 'CODEX_CONFIG_PREFLIGHT FAIL %s\n' "$diag" >&2
  fi
  if declare -F die >/dev/null 2>&1; then
    die "codex config preflight failed: ${diag}"
  else
    printf 'codex config preflight failed: %s\n' "$diag" >&2
    exit 1
  fi
}

# codex_config_preflight <model> <reasoning> <approval> <sandbox>
#   model/approval/sandbox are required for a codex supervisor; reasoning is
#   optional (only validated when non-empty so callers can leave it unset).
codex_config_preflight() {
  local model=${1-}
  local reasoning=${2-}
  local approval=${3-}
  local sandbox=${4-}

  local field value diag
  for pair in \
    "model|$model" \
    "approval|$approval" \
    "sandbox|$sandbox"
  do
    field=${pair%%|*}
    value=${pair#*|}
    if ! diag=$(codex_config_validate_value "$field" "$value"); then
      codex_config_preflight_fail "$diag"
    fi
  done

  if [[ -n "$reasoning" ]]; then
    if ! diag=$(codex_config_validate_value model_reasoning_effort "$reasoning"); then
      codex_config_preflight_fail "$diag"
    fi
  fi

  if declare -F audit >/dev/null 2>&1; then
    audit "CODEX_CONFIG_PREFLIGHT OK $(codex_config_render_redacted "$model" "$reasoning" "$approval" "$sandbox")"
  fi
}
