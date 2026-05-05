#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_CHECK="$ROOT/lib/config_check.sh"

test_missing_agent_workdir_template_fails() {
  local output status
  set +e
  output=$(bash -c "unset AGENT_WORKDIR_TEMPLATE; source '$CONFIG_CHECK'" 2>&1)
  status=$?
  set -e

  [[ "$status" -eq 1 ]]
  [[ "$output" == *"AGENT_WORKDIR_TEMPLATE must be set in the project config"* ]]
}

test_agent_workdir_template_printf_path() {
  local output
  output=$(
    AGENT_WORKDIR_TEMPLATE="/root/repos/RBOK-%s" \
      bash -c "source '$CONFIG_CHECK'; printf \"\$AGENT_WORKDIR_TEMPLATE\" claude"
  )

  [[ "$output" == "/root/repos/RBOK-claude" ]]
}

test_missing_agent_workdir_template_fails
test_agent_workdir_template_printf_path

printf 'PASS test_config_check\n'
