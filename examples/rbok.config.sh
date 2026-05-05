#!/usr/bin/env bash
# examples/rbok.config.sh — orchestrator-toolkit project config for RBOK.

# --- Identity --------------------------------------------------------------
PROJECT="rbok"
GH_REPO="RBOKproject/RBOK"
DEFAULT_BRANCH="develop"

# --- GitHub credentials ----------------------------------------------------
GH_CONFIG_DIR="/root/.config/gh-orchestrator"

# --- Agents (tmux pane targeting) ------------------------------------------
# RBOK uses prefixed panes: rbok-claude, rbok-codex, rbok-copilot,
# rbok-cursor, rbok-gemini. Orch pane: rbok-orchestrator.
AGENT_SESSION_PREFIX="rbok-"
AGENTS=(claude codex copilot cursor gemini)

# --- Local repo layout -----------------------------------------------------
SUPERVISOR_REPO=""    # RBOK orchestrates directly via per-agent clones; no
                      # central supervisor mirror.
AGENT_REPO_PREFIX="/root/repos/RBOK-"

# RBOK does not use a shared bare repo; agents push to GitHub directly via
# their per-agent gh credential.
SHARED_BARE_REPO=""

# --- Smart-poll trigger thresholds -----------------------------------------
SMART_POLL_TRIGGER_IDLE=4
SMART_POLL_TRIGGER_COMMITTED=4
SMART_POLL_TIMEOUT_SEC=900
SMART_POLL_INTERVAL_SEC=60
SMART_POLL_DEBOUNCE_SEC=60

# --- CI watcher tuning -----------------------------------------------------
CI_WATCHER_INTERVAL_SEC=180
CI_WATCHER_LOOKBACK=5

# --- pr_merge.sh tuning ----------------------------------------------------
PR_MERGE_CI_INTERVAL_SEC=30
PR_MERGE_CI_TIMEOUT_SEC=600
PR_MERGE_ADMIN_TOKEN="${PR_MERGE_ADMIN_TOKEN:-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}"

# --- Audit log -------------------------------------------------------------
AUDIT_LOG_FILE="/var/log/orch/${PROJECT}.log"

# --- File hot-spots --------------------------------------------------------
HOT_SPOTS=(
  "backend/app/main.py"
  "frontend/src/App.tsx"
  "deploy/docker-compose.yml"
)
