#!/usr/bin/env bash
# Legacy compatibility filename with a neutral sample project profile.
# Keep live product topology in an external operator profile.

PROJECT="project-a"
GH_REPO="example-org/project-a"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/operator/gh/project-a"

AGENT_PANES=(
  "planner|terminal-a:0.0|/workspace/project-a-planner"
  "builder|terminal-b:0.0|/workspace/project-a-builder"
  "reviewer|terminal-c:0.0|/workspace/project-a-reviewer"
)

AGENT_GH_LOGINS=(
  "planner=planner-bot"
  "builder=builder-bot"
  "reviewer=reviewer-bot"
)

AGENT_SESSION_PREFIX=""
AGENT_WINDOW_INDEX="0"
AGENTS=(planner builder reviewer)

PROJECT_REPO_ROOT="${PROJECT_REPO_ROOT:-/workspace/project-a-supervisor}"
SUPERVISOR_REPO="$PROJECT_REPO_ROOT"
AGENT_REPO_PREFIX="/workspace/project-a-"
export AGENT_WORKDIR_TEMPLATE="/workspace/project-a-%s"

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

# ORDO core is CLI-neutral. Operators set the supervisor CLI externally.
: "${ORCH_CLI_BIN:=agent-cli}"
: "${ORCH_AGENT_CLI:=agent-cli}"

: "${CI_WATCHER_INTERVAL_SEC:=180}"
: "${CI_WATCHER_LOOKBACK:=5}"
: "${CI_AUTOFIX_AGENT_CAN_PUSH:=1}"
: "${SIXSIGMA_AGENT_CAN_PUSH:=1}"
: "${SIXSIGMA_MAX_AUTOFIX_DISPATCHES:=4}"

PR_MERGE_CI_INTERVAL_SEC=30
PR_MERGE_CI_TIMEOUT_SEC=600

: "${ORCH_TOKENS_FILE:=/operator/ordo-tokens.env}"
if [ -z "${PR_MERGE_ADMIN_TOKEN:-}" ] && [ -f "$ORCH_TOKENS_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ORCH_TOKENS_FILE"
  PR_MERGE_ADMIN_TOKEN="${GH_ADMIN_TOKEN:-}"
fi

AUDIT_LOG_FILE="/var/log/ordo/${PROJECT}.log"

HOT_SPOTS=(
  "service/main.py"
  "web/src/App.tsx"
  "deploy/compose.yml"
)
