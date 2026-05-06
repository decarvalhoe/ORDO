#!/usr/bin/env bash
# examples/rbok.config.sh — orchestrator-toolkit project config for RBOK.

# --- Identity --------------------------------------------------------------
PROJECT="rbok"
GH_REPO="RBOKproject/RBOK"
DEFAULT_BRANCH="develop"

# --- GitHub credentials ----------------------------------------------------
GH_CONFIG_DIR="/root/.config/gh-orchestrator"

# --- Agents (tmux pane targeting) ------------------------------------------
# RBOK has TWO fleets active in parallel:
#   PRIMARY:   rbok-claude, rbok-codex, rbok-copilot, rbok-cursor, rbok-gemini
#              (sessions with rbok- prefix, all on window :0.0 since 2026-05-05)
#   SECONDARY: claude, codex, copilot, cursor, gemini, orch
#              (sessions with no prefix, all on window :0.0; ex-Nomos respawn)
#
# AGENT_PANES is the universal fleet form.
# Supported entries:
#   - "pane|workdir"                (legacy universal form; label = basename(workdir))
#   - "label|pane|workdir"          (recommended when logical labels should be explicit)
# All major scripts now consume AGENT_PANES across dispatch, recovery, polling,
# integration, merge orchestration, and orch_loop. The legacy AGENTS +
# AGENT_SESSION_PREFIX form remains below for compatibility.
AGENT_PANES=(
  "rbok-claude:0.0|/root/repos/RBOK-claude"
  "rbok-codex:0.0|/root/repos/RBOK-codex"
  "rbok-copilot:0.0|/root/repos/RBOK-copilot"
  "rbok-cursor:0.0|/root/repos/RBOK-cursor"
  "rbok-gemini:0.0|/root/repos/RBOK-gemini"
  "claude:0.0|/root/repos/RBOK-claude-2"
  "codex:0.0|/root/repos/RBOK-codex-2"
  "copilot:0.0|/root/repos/RBOK-copilot-2"
  "cursor:0.0|/root/repos/RBOK-cursor-2"
  "gemini:0.0|/root/repos/RBOK-gemini-2"
  "orch:0.0|/root/repos/RBOK-orch"
)

# Legacy form — kept for scripts that have not migrated to AGENT_PANES yet.
# Targets PRIMARY fleet only (rbok-* prefix, window :0).
AGENT_SESSION_PREFIX="rbok-"
AGENT_WINDOW_INDEX="0"
AGENTS=(claude codex copilot cursor gemini)

# --- Local repo layout -----------------------------------------------------
SUPERVISOR_REPO=""    # RBOK orchestrates directly via per-agent clones; no
                      # central supervisor mirror.
PROJECT_REPO_ROOT="${PROJECT_REPO_ROOT:-/root/repos/RBOK-orch}"
AGENT_REPO_PREFIX="/root/repos/RBOK-"
export AGENT_WORKDIR_TEMPLATE="/root/repos/RBOK-%s"

# --- Persistent project meta context --------------------------------------
# project_meta_context.sh indexes these docs once, then refreshes only when
# their content signature changes.
DOC_META_REPO="${DOC_META_REPO:-$PROJECT_REPO_ROOT}"
if [[ -z "${DOC_META_PATHS+x}" ]]; then
  DOC_META_PATHS=(
    AGENTS.md
    README.md
    INDEX.md
    docs
    .github/workflows
    backend/README.md
    backend/requirements.txt
    frontend/README.md
    frontend/package.json
  )
fi

# RBOK does not use a shared bare repo; agents push to GitHub directly via
# their per-agent gh credential.
SHARED_BARE_REPO=""

# --- Smart-poll trigger thresholds -----------------------------------------
# Use ${VAR:=default} so the operator can override any of these via env
# without editing the config file (e.g. for a single-agent test wave:
# SMART_POLL_TRIGGER_IDLE=1 SMART_POLL_TRIGGER_COMMITTED=1 bash cycle.sh ...).
: "${SMART_POLL_TRIGGER_IDLE:=4}"
: "${SMART_POLL_TRIGGER_COMMITTED:=4}"
: "${SMART_POLL_TIMEOUT_SEC:=900}"
: "${SMART_POLL_INTERVAL_SEC:=60}"
: "${SMART_POLL_DEBOUNCE_SEC:=60}"
: "${SMART_POLL_IDLE_MODE:=git}"
: "${SMART_POLL_CAPTURE_TIMEOUT_SEC:=3}"
: "${SMART_POLL_GIT_TIMEOUT_SEC:=5}"

# --- CI watcher tuning -----------------------------------------------------
: "${CI_WATCHER_INTERVAL_SEC:=180}"
: "${CI_WATCHER_LOOKBACK:=5}"
: "${CI_AUTOFIX_AGENT_CAN_PUSH:=1}"
: "${SIXSIGMA_AGENT_CAN_PUSH:=1}"
: "${SIXSIGMA_MAX_AUTOFIX_DISPATCHES:=4}"

# --- pr_merge.sh tuning ----------------------------------------------------
PR_MERGE_CI_INTERVAL_SEC=30
PR_MERGE_CI_TIMEOUT_SEC=600
# Admin merge fallback token. Resolution order (no plaintext in this file):
#   1. PR_MERGE_ADMIN_TOKEN env var (set explicitly by operator).
#   2. GH_ADMIN_TOKEN from $ORCH_TOKENS_FILE (default /root/.config/orch-tokens.env).
# When neither resolves, pr_merge.sh refuses admin bypass (exit 6); the
# plain `--squash --auto` path still works without the token.
: "${ORCH_TOKENS_FILE:=/root/.config/orch-tokens.env}"
if [ -z "${PR_MERGE_ADMIN_TOKEN:-}" ] && [ -f "$ORCH_TOKENS_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ORCH_TOKENS_FILE"
  PR_MERGE_ADMIN_TOKEN="${GH_ADMIN_TOKEN:-}"
fi

# --- Audit log -------------------------------------------------------------
AUDIT_LOG_FILE="/var/log/orch/${PROJECT}.log"

# --- File hot-spots --------------------------------------------------------
HOT_SPOTS=(
  "backend/app/main.py"
  "frontend/src/App.tsx"
  "deploy/docker-compose.yml"
)
