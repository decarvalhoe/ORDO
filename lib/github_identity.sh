#!/usr/bin/env bash
# github_identity.sh - guard GitHub writes against active gh account drift.
#
# This file is sourced by scripts/helpers before GitHub write operations. It is
# intentionally project-neutral: callers either pass an expected login directly,
# set ORCH_EXPECTED_GH_LOGIN/ORCH_GH_EXPECTED_LOGIN, or source
# config_resolver.sh and use orch_github_identity_guard_for_agent <label>.

: "${ORCH_GITHUB_IDENTITY_MISMATCH_EXIT_CODE:=78}"
: "${ORCH_GITHUB_IDENTITY_GH_BIN:=gh}"

orch_github_expected_login() {
  local agent=${1:-}

  if [[ -n "${ORCH_EXPECTED_GH_LOGIN:-}" ]]; then
    printf '%s\n' "$ORCH_EXPECTED_GH_LOGIN"
    return 0
  fi

  if [[ -n "${ORCH_GH_EXPECTED_LOGIN:-}" ]]; then
    printf '%s\n' "$ORCH_GH_EXPECTED_LOGIN"
    return 0
  fi

  if [[ -n "$agent" ]] && declare -F resolve_agent_github_login >/dev/null 2>&1; then
    resolve_agent_github_login "$agent"
    return $?
  fi

  return 1
}

orch_github_active_login() {
  local gh_bin=${ORCH_GITHUB_IDENTITY_GH_BIN:-gh}
  if [[ -n "${GH_CONFIG_DIR:-}" ]]; then
    GH_CONFIG_DIR="$GH_CONFIG_DIR" "$gh_bin" api user --jq .login 2>/dev/null
  else
    "$gh_bin" api user --jq .login 2>/dev/null
  fi
}

orch_github_token_override_names() {
  local -a names=()
  [[ -n "${GH_TOKEN:-}" ]] && names+=("GH_TOKEN")
  [[ -n "${GITHUB_TOKEN:-}" ]] && names+=("GITHUB_TOKEN")

  if [[ "${#names[@]}" -eq 0 ]]; then
    printf '%s\n' "none"
    return 0
  fi

  local old_ifs=$IFS
  IFS=,
  printf '%s\n' "${names[*]}"
  IFS=$old_ifs
}

orch_github_identity_guard() {
  local expected=${1:-}
  local context=${2:-github_write}
  local active token_override

  if [[ -z "$expected" ]]; then
    expected=$(orch_github_expected_login 2>/dev/null || true)
  fi
  [[ -n "$expected" ]] || return 0

  active=$(orch_github_active_login || true)
  token_override=$(orch_github_token_override_names)
  if [[ "$active" != "$expected" ]]; then
    printf 'github_identity_mismatch: expected=%s active=%s context=%s gh_config_dir=%s token_override=%s action=refuse\n' \
      "$expected" "${active:-unknown}" "$context" "${GH_CONFIG_DIR:-unset}" "$token_override" >&2
    return "$ORCH_GITHUB_IDENTITY_MISMATCH_EXIT_CODE"
  fi

  return 0
}

orch_github_identity_guard_for_agent() {
  local agent=${1:?usage: orch_github_identity_guard_for_agent <agent> [context]}
  local context=${2:-agent_github_write}
  local expected

  expected=$(orch_github_expected_login "$agent") || {
    printf 'github_identity_mismatch: expected=unresolved active=unknown context=%s agent=%s action=refuse\n' \
      "$context" "$agent" >&2
    return "$ORCH_GITHUB_IDENTITY_MISMATCH_EXIT_CODE"
  }

  orch_github_identity_guard "$expected" "$context"
}

orch_github_command_is_write() {
  local topic=${1:-}
  local action=${2:-}
  local arg method

  case "$topic $action" in
    issue\ create|issue\ comment|issue\ edit|issue\ close|issue\ reopen|\
pr\ create|pr\ comment|pr\ review|pr\ ready|pr\ merge|pr\ close|pr\ reopen|pr\ edit)
      return 0
      ;;
  esac

  if [[ "$topic" == "api" ]]; then
    while [[ "$#" -gt 0 ]]; do
      arg=$1
      case "$arg" in
        -X|--method)
          method=${2:-}
          case "$method" in
            POST|PATCH|PUT|DELETE) return 0 ;;
          esac
          shift
          ;;
        -XPOST|-XPATCH|-XPUT|-XDELETE|--method=POST|--method=PATCH|--method=PUT|--method=DELETE)
          return 0
          ;;
      esac
      shift
    done
  fi

  return 1
}

orch_github_identity_guard_for_command() {
  local context=${1:?usage: orch_github_identity_guard_for_command <context> <gh-args...>}
  shift

  if orch_github_command_is_write "$@"; then
    orch_github_identity_guard "" "$context:${1:-gh}:${2:-}"
  fi
}
