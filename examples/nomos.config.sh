#!/usr/bin/env bash
# examples/nomos.config.sh — orchestrator-toolkit project config for Nomos.
#
# Sourced by every orchestrator-toolkit script (cycle.sh, dispatch_ticket.sh,
# smart_poll_agents.sh, integrate_wave.sh, ci_watcher_daemon.sh, ...).
#
# Convention: this file MUST be a pure assignment list — no side effects.

# --- Identity --------------------------------------------------------------
PROJECT="nomos"
GH_REPO="RBOKproject/Nomos"

# Default branch the smart-poll, integrate, and ci-watcher target.
DEFAULT_BRANCH="main"

# --- GitHub credentials ----------------------------------------------------
# Use the agent-orchestrator account (one of RBOKCLIclaude/codex/copilot/
# cursor/gemini) for routine ops. Admin token (gho_OJeP...) is used by
# pr_merge.sh as a fallback when a PR is BLOCKED on review and CI=SUCCESS.
GH_CONFIG_DIR="/root/.config/gh-orchestrator"

# --- Agents (tmux pane targeting) ------------------------------------------
# Bare-name panes for Nomos: claude, codex, copilot, cursor, gemini.
AGENT_SESSION_PREFIX=""

# Ordered list — also drives smart_poll_agents.sh per-pane capture.
AGENTS=(claude codex copilot cursor gemini)

# Orch pane name. Convention: <prefix>orchestrator if prefix non-empty,
# else "orch". For Nomos, ci_watcher uses the "orch" tmux session.
# (See ci_watcher_daemon.sh: ORCH_PANE="${AGENT_SESSION_PREFIX}orchestrator"
# with a fallback to "orch".)

# --- Local repo layout -----------------------------------------------------
# Each agent has a clone at /root/repos/Nomos-<agent>.
# The supervisor lives at /root/repos/Nomos-supervisor.
SUPERVISOR_REPO="/root/repos/Nomos-supervisor"
AGENT_REPO_PREFIX="/root/repos/Nomos-"
export AGENT_WORKDIR_TEMPLATE="/root/repos/Nomos-%s"

# Shared remote (supervisor pushes to /tmp/Nomos which pushes to GitHub).
SHARED_BARE_REPO="/tmp/Nomos"

# --- Smart-poll trigger thresholds -----------------------------------------
# Trigger an integrate_wave when:
#   - at least SMART_POLL_TRIGGER_IDLE agents are at the prompt, AND
#   - at least SMART_POLL_TRIGGER_COMMITTED agents have ≥1 fresh commit on
#     their feature branch, AND
#   - at least one of those conditions has been continuously true for
#     SMART_POLL_DEBOUNCE_SEC seconds.
# Surviving log line: "trigger=4+4 timeout=900s".
SMART_POLL_TRIGGER_IDLE=4
SMART_POLL_TRIGGER_COMMITTED=4
SMART_POLL_TIMEOUT_SEC=900
SMART_POLL_INTERVAL_SEC=60
SMART_POLL_DEBOUNCE_SEC=60

# --- CI watcher tuning -----------------------------------------------------
CI_WATCHER_INTERVAL_SEC=180
CI_WATCHER_LOOKBACK=5

# --- pr_merge.sh tuning ----------------------------------------------------
# Wait for CI on a PR up to PR_MERGE_CI_TIMEOUT_SEC, polling every
# PR_MERGE_CI_INTERVAL_SEC. Surviving log: "wait 30s (X/600)".
PR_MERGE_CI_INTERVAL_SEC=30
PR_MERGE_CI_TIMEOUT_SEC=600

# Admin merge token override (only used by pr_merge.sh). Leave empty to
# rely on $GH_CONFIG_DIR's stored token. Doctrine: never bypass on
# IN_PROGRESS or FAILURE — only use --admin when CI=SUCCESS and the only
# block is "approving review required".
PR_MERGE_ADMIN_TOKEN="${PR_MERGE_ADMIN_TOKEN:-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}"

# --- Audit log -------------------------------------------------------------
AUDIT_LOG_FILE="/var/log/orch/${PROJECT}.log"

# --- File hot-spots (collision avoidance during dispatch) ------------------
# Dispatching two tickets that touch the same hot-spot file in the same
# wave is forbidden by check_conflicts logic in cycle.sh.
HOT_SPOTS=(
  "cli/internal/app/app.go"
  "cli/internal/app/strict_gate.go"
  "cli/internal/corpus/feed.go"
)
