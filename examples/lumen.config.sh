#!/usr/bin/env bash
# examples/lumen.config.sh — neutral worked example for the `lumen` slot.
#
# `orch_loop.sh lumen` resolves to this file when no external override is set
# via ORCH_CONFIG_PATH, so it must stay sourceable on a stock checkout. Live
# product topology, real GitHub orgs, and credentials live in an operator
# profile — copy this file to `/root/.config/ordo/lumen-live.config.sh` and
# replace `example-org/lumen` with the live repo, neutral fleet slots with the
# deployment-specific tmux pane coordinates, and `/workspace/...` paths with
# the operator-owned workspace roots.
#
# Treat this file as a worked example, not a template (cf.
# docs/onboarding-multi-project.md). Values below are intentionally generic so
# the dispatch planner contract (`scripts/dispatch_plan.sh <path> --ready-only
# --json`) can be exercised against the shape without binding to any live
# infrastructure.

PROJECT="lumen"
GH_REPO="example-org/lumen"
DEFAULT_BRANCH="develop"
GH_CONFIG_DIR="/operator/gh/lumen"

AGENT_SESSION_PREFIX=""
AGENT_WINDOW_INDEX="0"
AGENTS=(planner builder reviewer)

# Neutral fleet slot shape: fleet-000 is reserved for the operator/supervisor
# loop (see docs/runbooks/fleet-preparation.md), so worker labels start at
# fleet-001. The full eleven-slot list mirrors the TECHNAI-style neutral fleet
# the live LUMEN profile is expected to bind against; operators trim or
# extend this list in their live profile rather than editing this worked
# example.
AGENT_PANES=(
  "fleet-001|fleet-001:0.0|/workspace/lumen-fleet-001"
  "fleet-002|fleet-002:0.0|/workspace/lumen-fleet-002"
  "fleet-003|fleet-003:0.0|/workspace/lumen-fleet-003"
  "fleet-004|fleet-004:0.0|/workspace/lumen-fleet-004"
  "fleet-005|fleet-005:0.0|/workspace/lumen-fleet-005"
  "fleet-006|fleet-006:0.0|/workspace/lumen-fleet-006"
  "fleet-007|fleet-007:0.0|/workspace/lumen-fleet-007"
  "fleet-008|fleet-008:0.0|/workspace/lumen-fleet-008"
  "fleet-009|fleet-009:0.0|/workspace/lumen-fleet-009"
  "fleet-010|fleet-010:0.0|/workspace/lumen-fleet-010"
  "fleet-011|fleet-011:0.0|/workspace/lumen-fleet-011"
)

AGENT_GH_LOGINS=(
  "fleet-001=fleet-001-bot"
  "fleet-002=fleet-002-bot"
  "fleet-003=fleet-003-bot"
  "fleet-004=fleet-004-bot"
  "fleet-005=fleet-005-bot"
  "fleet-006=fleet-006-bot"
  "fleet-007=fleet-007-bot"
  "fleet-008=fleet-008-bot"
  "fleet-009=fleet-009-bot"
  "fleet-010=fleet-010-bot"
  "fleet-011=fleet-011-bot"
)

AGENT_GIT_IDENTITIES=(
  "fleet-001|Neutral Fleet 001|fleet-001@example-org.invalid"
  "fleet-002|Neutral Fleet 002|fleet-002@example-org.invalid"
  "fleet-003|Neutral Fleet 003|fleet-003@example-org.invalid"
  "fleet-004|Neutral Fleet 004|fleet-004@example-org.invalid"
  "fleet-005|Neutral Fleet 005|fleet-005@example-org.invalid"
  "fleet-006|Neutral Fleet 006|fleet-006@example-org.invalid"
  "fleet-007|Neutral Fleet 007|fleet-007@example-org.invalid"
  "fleet-008|Neutral Fleet 008|fleet-008@example-org.invalid"
  "fleet-009|Neutral Fleet 009|fleet-009@example-org.invalid"
  "fleet-010|Neutral Fleet 010|fleet-010@example-org.invalid"
  "fleet-011|Neutral Fleet 011|fleet-011@example-org.invalid"
)

PROJECT_REPO_ROOT="${PROJECT_REPO_ROOT:-/workspace/lumen-supervisor}"
SUPERVISOR_REPO="$PROJECT_REPO_ROOT"
AGENT_REPO_PREFIX="/workspace/lumen-"
export AGENT_WORKDIR_TEMPLATE="/workspace/lumen-%s"

# LUMEN work is per-ticket worktree style: the supervisor clone stays at
# PROJECT_REPO_ROOT and per-agent worktrees materialise under
# ORCH_WORKTREES_DIR. The example points into /workspace so the worked example
# stays self-contained; operators override both in their live profile.
USE_WORKTREES=1
ORCH_WORKTREES_DIR="${ORCH_WORKTREES_DIR:-/workspace/lumen-worktrees}"

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
# behaviour to any real product's source tree. LUMEN payment-flow work centres
# on reward tier selection, payment intent surfaces, and the checkout
# frontend; operators replace these with the actual LUMEN hot files in their
# live profile.
HOT_SPOTS=(
  "frontend/src/checkout/RewardTierSelector.tsx"
  "frontend/src/checkout/PaymentFlow.tsx"
  "backend/payments/intents.py"
)
