#!/usr/bin/env bash
# examples/realisons-wp.config.sh — Realisons WordPress project.
# Placeholder reconstructed from the recovered ci_watcher_daemon.sh
# dispatcher (case "wp|realisons-wp"). Adjust GH_REPO / AGENTS as needed.

PROJECT="realisons-wp"
GH_REPO="RBOKproject/realisons-wordpress-orchestrator"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/root/.config/gh-orchestrator"

AGENT_SESSION_PREFIX="wp-"
AGENTS=(claude codex)

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
