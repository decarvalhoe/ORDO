#!/usr/bin/env bash
# examples/42t.config.sh — 42-training project.
# Placeholder reconstructed from the recovered ci_watcher_daemon.sh
# dispatcher (case "42t|42-training").

PROJECT="42t"
GH_REPO="RBOKproject/42-training"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/root/.config/gh-orchestrator"

AGENT_SESSION_PREFIX="42t-"
AGENTS=(claude codex copilot cursor gemini)

AUDIT_LOG_FILE="/var/log/orch/${PROJECT}.log"

CI_WATCHER_INTERVAL_SEC=180
CI_WATCHER_LOOKBACK=5

SMART_POLL_TRIGGER_IDLE=4
SMART_POLL_TRIGGER_COMMITTED=4
SMART_POLL_TIMEOUT_SEC=900
SMART_POLL_INTERVAL_SEC=60
SMART_POLL_DEBOUNCE_SEC=60

PR_MERGE_CI_INTERVAL_SEC=30
PR_MERGE_CI_TIMEOUT_SEC=600
