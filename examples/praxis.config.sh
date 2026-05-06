#!/usr/bin/env bash
# examples/praxis.config.sh — PRAXIS product config.

PROJECT="praxis"
GH_REPO="RBOKproject/PRAXIS"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/root/.config/gh-orchestrator"

AGENT_REPO_PREFIX="/root/repos/praxis-"
export AGENT_WORKDIR_TEMPLATE="/root/repos/praxis-%s"

AGENT_PANES=(
  "claude|claude:0.0|/root/repos/praxis-claude"
  "codex|codex:0.0|/root/repos/praxis-codex"
  "copilot|copilot:0.0|/root/repos/praxis-copilot"
  "cursor|cursor:0.0|/root/repos/praxis-cursor"
  "gemini|gemini:0.0|/root/repos/praxis-gemini"
  "praxis-orch|orch:0.0|/root/repos/praxis-orchestrator"
)

# Legacy form kept for scripts that have not migrated to AGENT_PANES.
AGENT_SESSION_PREFIX=""
AGENTS=(claude codex copilot cursor gemini)

PROJECT_REPO_ROOT="/root/repos/praxis-orchestrator"
SUPERVISOR_REPO="$PROJECT_REPO_ROOT"
AUDIT_LOG_FILE="/var/log/orch/${PROJECT}.log"

: "${SMART_POLL_TRIGGER_IDLE:=4}"
: "${SMART_POLL_TRIGGER_COMMITTED:=4}"
: "${SMART_POLL_TIMEOUT_SEC:=900}"
: "${SMART_POLL_INTERVAL_SEC:=60}"
: "${SMART_POLL_DEBOUNCE_SEC:=60}"

: "${PR_MERGE_CI_INTERVAL_SEC:=30}"
: "${PR_MERGE_CI_TIMEOUT_SEC:=600}"
