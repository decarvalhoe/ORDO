#!/usr/bin/env bash
# Legacy compatibility filename with a neutral training/sample profile.

PROJECT="project-training"
GH_REPO="example-org/project-training"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/operator/gh/project-training"

AGENT_SESSION_PREFIX="training-"
AGENTS=(planner builder reviewer)
AGENT_REPO_PREFIX="/workspace/project-training-"
export AGENT_WORKDIR_TEMPLATE="/workspace/project-training-%s"

AGENT_PANES=(
  "planner|training-planner:0.0|/workspace/project-training-planner"
  "builder|training-builder:0.0|/workspace/project-training-builder"
  "reviewer|training-reviewer:0.0|/workspace/project-training-reviewer"
)

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
