#!/usr/bin/env bash
# examples/ordo.config.sh - ORDO project config for dogfooding the toolkit.

PROJECT="ordo"
GH_REPO="RBOKproject/ORDO"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/root/.config/gh-orchestrator"

AGENT_PANES=(
  "ordo-orch|orch:0.0|/root/repos/RBOK-orchestrator/orchestrator-toolkit"
)

AGENT_SESSION_PREFIX="ordo-"
AGENT_WINDOW_INDEX="0"
AGENTS=(orch)
AGENT_REPO_PREFIX="/root/repos/ORDO-"
export AGENT_WORKDIR_TEMPLATE="/root/repos/ORDO-%s"

PROJECT_REPO_ROOT="/root/repos/RBOK-orchestrator/orchestrator-toolkit"
SUPERVISOR_REPO="$PROJECT_REPO_ROOT"
AUDIT_LOG_FILE="/var/log/orch/${PROJECT}.log"

: "${SMART_POLL_TRIGGER_IDLE:=1}"
: "${SMART_POLL_TRIGGER_COMMITTED:=1}"
: "${SMART_POLL_TIMEOUT_SEC:=900}"
: "${SMART_POLL_INTERVAL_SEC:=60}"
: "${SMART_POLL_DEBOUNCE_SEC:=60}"

: "${PR_MERGE_CI_INTERVAL_SEC:=30}"
: "${PR_MERGE_CI_TIMEOUT_SEC:=600}"
