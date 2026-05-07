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

external_profile="$TEST_TMP/external-project.config.sh"
cat > "$external_profile" <<EOF
PROJECT="external-project"
GH_REPO="example/project"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=(
  "agent|agent:0.0|$TEST_TMP/repos/agent"
)
PROJECT_REPO_ROOT="$TEST_TMP/repos/orchestrator"
SUPERVISOR_REPO="$TEST_TMP/repos/orchestrator"
AUDIT_LOG_FILE="$TEST_TMP/external-project.log"
EOF

for cfg in "$ROOT"/examples/*.config.sh; do
  sanitized_cfg="$TEST_TMP/$(basename "$cfg")"
  tr -d '\r' < "$cfg" > "$sanitized_cfg"
  set +u
  AGENT_REPO_PREFIX_VALUE=$(
    unset AGENT_REPO_PREFIX PROJECT GH_REPO DEFAULT_BRANCH GH_CONFIG_DIR AGENT_SESSION_PREFIX AGENT_WORKDIR_TEMPLATE AUDIT_LOG_FILE
    # shellcheck disable=SC1090
    ORDO_PROJECT_PROFILE="$external_profile" source "$sanitized_cfg"
    if [[ -n "${PORTFOLIO_PROJECTS+x}" ]]; then
      printf '__portfolio__'
    else
      printf '%s' "${AGENT_REPO_PREFIX:-}"
    fi
  )
  set -u

  [[ -n "$AGENT_REPO_PREFIX_VALUE" ]] || fail "$(basename "$cfg") missing AGENT_REPO_PREFIX"
done

if grep -Eq 'RBOKproject|/root/repos|RBOK-|ORDO-' "$ROOT/examples/ordo.config.sh"; then
  fail "ordo.config.sh must load external topology instead of hardcoding repository names, fleet labels, or host paths"
fi

printf 'ok - all example configs define AGENT_REPO_PREFIX\n'
