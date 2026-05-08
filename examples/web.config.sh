#!/usr/bin/env bash
# Neutral web-project sample profile.

PROJECT="project-web"
GH_REPO="example-org/project-web"
DEFAULT_BRANCH="develop"
GH_CONFIG_DIR="/operator/gh/project-web"

AGENT_REPO_PREFIX="/workspace/project-web-"
export AGENT_WORKDIR_TEMPLATE="/workspace/project-web-%s"

AGENT_PANES=(
  "planner|terminal-a:0.0|/workspace/project-web-planner"
  "builder|terminal-b:0.0|/workspace/project-web-builder"
  "reviewer|terminal-c:0.0|/workspace/project-web-reviewer"
)

AGENT_SESSION_PREFIX=""
AGENTS=(planner builder reviewer)

AUDIT_LOG_FILE="/var/log/ordo/${PROJECT}.log"

CI_WATCHER_INTERVAL_SEC=180
CI_WATCHER_LOOKBACK=5

SMART_POLL_TRIGGER_IDLE=2
SMART_POLL_TRIGGER_COMMITTED=2
SMART_POLL_TIMEOUT_SEC=900
SMART_POLL_INTERVAL_SEC=60
SMART_POLL_DEBOUNCE_SEC=60

PR_MERGE_CI_INTERVAL_SEC=30
PR_MERGE_CI_TIMEOUT_SEC=600
