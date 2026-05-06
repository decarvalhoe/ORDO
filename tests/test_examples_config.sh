#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

for cfg in "$ROOT"/examples/*.config.sh; do
  sanitized_cfg="$TEST_TMP/$(basename "$cfg")"
  tr -d '\r' < "$cfg" > "$sanitized_cfg"
  set +u
  AGENT_REPO_PREFIX_VALUE=$(
    unset AGENT_REPO_PREFIX PROJECT GH_REPO DEFAULT_BRANCH GH_CONFIG_DIR AGENT_SESSION_PREFIX AGENT_WORKDIR_TEMPLATE AUDIT_LOG_FILE
    # shellcheck disable=SC1090
    source "$sanitized_cfg"
    if [[ -n "${PORTFOLIO_PROJECTS+x}" ]]; then
      printf '__portfolio__'
    else
      printf '%s' "${AGENT_REPO_PREFIX:-}"
    fi
  )
  set -u

  [[ -n "$AGENT_REPO_PREFIX_VALUE" ]] || fail "$(basename "$cfg") missing AGENT_REPO_PREFIX"
done

printf 'ok - all example configs define AGENT_REPO_PREFIX\n'
