#!/usr/bin/env bash
# examples/nomos.config.sh — neutral worked example for the `nomos` slot.
#
# `orch_loop.sh nomos` resolves to this file when no external override is set
# via ORCH_CONFIG_PATH, so it must stay sourceable on a stock checkout. Live
# product topology, real GitHub orgs, and credentials live in an operator
# profile — see `profiles/nomos-live.config.example.sh` for the canonical
# template that operators copy to `/root/.config/ordo/nomos-live.config.sh`.
#
# Treat this file as a worked example, not a template (cf.
# docs/onboarding-multi-project.md). Values below are intentionally generic so
# preflight smoke tests (`tests/test_preflight.sh`) and the loading contract
# (`tests/test_nomos_profile_loading.sh`) can exercise the shape without
# binding to live infrastructure.

PROJECT="nomos"
GH_REPO="example-org/nomos"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/operator/gh/nomos"

AGENT_SESSION_PREFIX=""
AGENT_WINDOW_INDEX="0"
AGENTS=(planner builder reviewer)

# Neutral fleet slot shape: fleet-000 is reserved for the operator/supervisor
# loop (see docs/runbooks/fleet-preparation.md), so worker labels start at
# fleet-001. Operators wiring NOMOS into a TECHNAI-style neutral fleet should
# extend this list up to fleet-011 in their live profile rather than editing
# this worked example.
AGENT_PANES=(
  "fleet-001|fleet-001:0.0|/workspace/nomos-fleet-001"
  "fleet-002|fleet-002:0.0|/workspace/nomos-fleet-002"
  "fleet-003|fleet-003:0.0|/workspace/nomos-fleet-003"
)

AGENT_GH_LOGINS=(
  "fleet-001=fleet-001-bot"
  "fleet-002=fleet-002-bot"
  "fleet-003=fleet-003-bot"
)

AGENT_GIT_IDENTITIES=(
  "fleet-001|Neutral Fleet 001|fleet-001@example-org.invalid"
  "fleet-002|Neutral Fleet 002|fleet-002@example-org.invalid"
  "fleet-003|Neutral Fleet 003|fleet-003@example-org.invalid"
)

PROJECT_REPO_ROOT="${PROJECT_REPO_ROOT:-/workspace/nomos-supervisor}"
SUPERVISOR_REPO="$PROJECT_REPO_ROOT"
AGENT_REPO_PREFIX="/workspace/nomos-"
export AGENT_WORKDIR_TEMPLATE="/workspace/nomos-%s"

# NOMOS work is per-ticket worktree style: the supervisor clone stays at
# PROJECT_REPO_ROOT and per-agent worktrees materialise under
# ORCH_WORKTREES_DIR. The example points into /workspace so the worked example
# stays self-contained; operators override both in their live profile.
USE_WORKTREES=1
ORCH_WORKTREES_DIR="${ORCH_WORKTREES_DIR:-/workspace/nomos-worktrees}"

DOC_META_REPO="${DOC_META_REPO:-$PROJECT_REPO_ROOT}"
if [[ -z "${DOC_META_PATHS+x}" ]]; then
  DOC_META_PATHS=(
    README.md
    docs
    .github/workflows
  )
fi

SHARED_BARE_REPO=""

: "${SMART_POLL_TRIGGER_IDLE:=2}"
: "${SMART_POLL_TRIGGER_COMMITTED:=2}"
: "${SMART_POLL_TIMEOUT_SEC:=900}"
: "${SMART_POLL_INTERVAL_SEC:=60}"
: "${SMART_POLL_DEBOUNCE_SEC:=60}"
: "${SMART_POLL_IDLE_MODE:=git}"
: "${SMART_POLL_CAPTURE_TIMEOUT_SEC:=3}"
: "${SMART_POLL_GIT_TIMEOUT_SEC:=5}"

: "${ORCH_CLI_BIN:=agent-cli}"
: "${ORCH_AGENT_CLI:=agent-cli}"

: "${CI_WATCHER_INTERVAL_SEC:=180}"
: "${CI_WATCHER_LOOKBACK:=5}"

PR_MERGE_CI_INTERVAL_SEC=30
PR_MERGE_CI_TIMEOUT_SEC=600

: "${ORCH_TOKENS_FILE:=/operator/ordo-tokens.env}"
if [ -z "${PR_MERGE_ADMIN_TOKEN:-}" ] && [ -f "$ORCH_TOKENS_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ORCH_TOKENS_FILE"
  PR_MERGE_ADMIN_TOKEN="${GH_ADMIN_TOKEN:-}"
fi

AUDIT_LOG_FILE="/var/log/orch/${PROJECT}.log"

# Hot spots are deliberately generic so this worked example does not pin
# behaviour to any real product's source tree. Operators replace these with
# the actual NOMOS hot files in their live profile.
HOT_SPOTS=(
  "service/main.py"
  "policies/dor/control_pack.yaml"
  "evidence/manifest.json"
)
