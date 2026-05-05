#!/usr/bin/env bash
# config_check.sh — fail-fast checks for sourced project config.

config_check_fail() {
  printf '%s\n' "$1" >&2
  if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    exit 1
  fi
  return 1
}

if [[ -z "${AGENT_WORKDIR_TEMPLATE:-}" ]]; then
  config_check_fail "AGENT_WORKDIR_TEMPLATE must be set in the project config (see examples/*.config.sh)"
fi
