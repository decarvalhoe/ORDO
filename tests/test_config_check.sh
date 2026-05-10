#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  printf 'test_config_check: %s\n' "$1" >&2
  exit 1
}

write_profile() {
  local path="$1"
  local identity_block="$2"

  cat >"$path" <<PROFILE
PROJECT="ordo"
GH_REPO="RBOKproject/ORDO"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/operator/gh/ordo"
AGENT_REPO_PREFIX="/workspace/ordo-"
export AGENT_WORKDIR_TEMPLATE="/workspace/ordo-%s"

AGENT_PANES=(
  "RBOK-claude|rbok-claude:3|/workspace/ordo-claude"
  "RBOK-orch|rbok-orchestrator:3|/workspace/ordo-orch"
)

${identity_block}
PROFILE
}

run_ordo_config() {
  local profile="$1"
  local output="$2"

  (
    cd "$ROOT"
    ORDO_PROJECT_PROFILE="$profile" bash -c 'source examples/ordo.config.sh'
  ) >"$output" 2>&1
}

duplicate_profile="$TMP_DIR/duplicate.config.sh"
duplicate_output="$TMP_DIR/duplicate.out"
write_profile "$duplicate_profile" 'AGENT_GIT_IDENTITIES=(
  "RBOK-claude|RBOKCLIclaude|RBOKCLI_claude@virgilian.com"
  "RBOK-orch|RBOKCLIclaude|RBOKCLI_claude@virgilian.com"
)'

if run_ordo_config "$duplicate_profile" "$duplicate_output"; then
  fail "undocumented shared RBOK-orch git identity should be rejected"
fi
grep -q 'shared git identity requires AGENT_GIT_IDENTITY_ALIASES' "$duplicate_output" \
  || fail "duplicate identity rejection should explain the alias documentation requirement"

distinct_profile="$TMP_DIR/distinct.config.sh"
distinct_output="$TMP_DIR/distinct.out"
write_profile "$distinct_profile" 'AGENT_GIT_IDENTITIES=(
  "RBOK-claude|RBOKCLIclaude|RBOKCLI_claude@virgilian.com"
  "RBOK-orch|RBOKCLIorch|RBOKCLI_orch@virgilian.com"
)'

if ! run_ordo_config "$distinct_profile" "$distinct_output"; then
  cat "$distinct_output" >&2
  fail "distinct RBOK-orch git identity should be accepted"
fi

alias_profile="$TMP_DIR/alias.config.sh"
alias_output="$TMP_DIR/alias.out"
write_profile "$alias_profile" 'AGENT_GIT_IDENTITIES=(
  "RBOK-claude|RBOKCLIclaude|RBOKCLI_claude@virgilian.com"
  "RBOK-orch|RBOKCLIclaude|RBOKCLI_claude@virgilian.com"
)
AGENT_GIT_IDENTITY_ALIASES=(
  "RBOK-orch|RBOK-claude|documented temporary orchestrator alias"
)'

if ! run_ordo_config "$alias_profile" "$alias_output"; then
  cat "$alias_output" >&2
  fail "documented RBOK-orch git identity alias should be accepted"
fi
grep -q 'documented git identity alias: RBOK-orch shares identity with RBOK-claude' \
  "$alias_output" \
  || fail "documented alias should be recorded in config output"

printf 'test_config_check: PASS\n'
