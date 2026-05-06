#!/usr/bin/env bash
# examples/realisons-wp.config.sh — Realisons WordPress project.

PROJECT="realisons-wp"
GH_REPO="RBOKproject/realisons-wordpress"
# ORDO uses DEFAULT_BRANCH as the integration/PR target for orchestration.
# Realisons WordPress keeps main as production, but day-to-day agent PRs target
# develop before manual staging/production promotion.
DEFAULT_BRANCH="develop"
GH_CONFIG_DIR="/root/.config/gh-orchestrator"

AGENT_REPO_PREFIX="/root/repos/realisons-wordpress-"
export AGENT_WORKDIR_TEMPLATE="/root/repos/realisons-wordpress-%s"

AGENT_PANES=(
  "claude|claude:0.0|/root/repos/realisons-wordpress-claude"
  "codex|codex:0.0|/root/repos/realisons-wordpress-codex"
  "copilot|copilot:0.0|/root/repos/realisons-wordpress-copilot"
  "cursor|cursor:0.0|/root/repos/realisons-wordpress-cursor"
  "gemini|gemini:0.0|/root/repos/realisons-wordpress-gemini"
)

# Legacy form kept for scripts that have not migrated to AGENT_PANES.
AGENT_SESSION_PREFIX=""
AGENTS=(claude codex copilot cursor gemini)

AUDIT_LOG_FILE="/var/log/orch/${PROJECT}.log"

CI_WATCHER_INTERVAL_SEC=180
CI_WATCHER_LOOKBACK=5

SMART_POLL_TRIGGER_IDLE=2
SMART_POLL_TRIGGER_COMMITTED=2
SMART_POLL_TIMEOUT_SEC=900
SMART_POLL_INTERVAL_SEC=60
SMART_POLL_DEBOUNCE_SEC=60

PR_MERGE_CI_INTERVAL_SEC=30
PR_MERGE_CI_TIMEOUT_SEC=600
