#!/usr/bin/env bash
# Neutral sample project profile.

PROJECT="project-c"
GH_REPO="example-org/project-c"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/operator/gh/project-c"

AGENT_REPO_PREFIX="/workspace/project-c-"
export AGENT_WORKDIR_TEMPLATE="/workspace/project-c-%s"

AGENT_PANES=(
  "planner|terminal-a:0.0|/workspace/project-c-planner"
  "builder|terminal-b:0.0|/workspace/project-c-builder"
  "reviewer|terminal-c:0.0|/workspace/project-c-reviewer"
)

AGENT_SESSION_PREFIX=""
AGENTS=(planner builder reviewer)

PROJECT_REPO_ROOT="/workspace/project-c-supervisor"
SUPERVISOR_REPO="$PROJECT_REPO_ROOT"
AUDIT_LOG_FILE="/var/log/ordo/${PROJECT}.log"

: "${SMART_POLL_TRIGGER_IDLE:=2}"
: "${SMART_POLL_TRIGGER_COMMITTED:=2}"
: "${SMART_POLL_TIMEOUT_SEC:=900}"
: "${SMART_POLL_INTERVAL_SEC:=60}"
: "${SMART_POLL_DEBOUNCE_SEC:=60}"

: "${PR_MERGE_CI_INTERVAL_SEC:=30}"
: "${PR_MERGE_CI_TIMEOUT_SEC:=600}"
