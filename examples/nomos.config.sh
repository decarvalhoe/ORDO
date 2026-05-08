#!/usr/bin/env bash
# Legacy compatibility filename with a neutral sample project profile.
# Sourced by ORDO scripts; keep this file side-effect free.

PROJECT="project-b"
GH_REPO="example-org/project-b"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/operator/gh/project-b"

AGENT_SESSION_PREFIX=""
AGENTS=(planner builder reviewer)

AGENT_PANES=(
  "planner|terminal-a:0.0|/workspace/project-b-planner"
  "builder|terminal-b:0.0|/workspace/project-b-builder"
  "reviewer|terminal-c:0.0|/workspace/project-b-reviewer"
)

SUPERVISOR_REPO="/workspace/project-b-supervisor"
AGENT_REPO_PREFIX="/workspace/project-b-"
export AGENT_WORKDIR_TEMPLATE="/workspace/project-b-%s"

SHARED_BARE_REPO="/tmp/project-b.git"

SMART_POLL_TRIGGER_IDLE=2
SMART_POLL_TRIGGER_COMMITTED=2
SMART_POLL_TIMEOUT_SEC=900
SMART_POLL_INTERVAL_SEC=60
SMART_POLL_DEBOUNCE_SEC=60

CI_WATCHER_INTERVAL_SEC=180
CI_WATCHER_LOOKBACK=5

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
  "cli/internal/app/app.go"
  "cli/internal/app/strict_gate.go"
  "cli/internal/corpus/feed.go"
)
