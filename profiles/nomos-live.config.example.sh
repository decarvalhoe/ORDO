#!/usr/bin/env bash
# profiles/nomos-live.config.example.sh — non-canonical example fragment for
# wiring NOMOS into ORDO dispatch on a TECHNAI neutral fleet host.
#
# Background (#681): NOMOS work was stranded because no live ORDO profile
# pointed at `RBOKproject/NOMOS`. Without `PROJECT`, `GH_REPO`, and a fleet
# topology, `scripts/dispatch_plan.sh` had no way to surface the 34 open
# DOR-XXX issues to the orchestrator.
#
# This file is NOT consumed directly. It is the canonical worked example an
# operator copies and edits to produce
# `/root/.config/ordo/nomos-live.config.sh`. The copied file is then loaded
# either via `ORDO_PROJECT_PROFILE=/root/.config/ordo/nomos-live.config.sh`
# (through `examples/ordo.config.sh`) or by passing the path directly to
# `scripts/dispatch_plan.sh` and `scripts/orch_loop.sh`.
#
# Only the values that diverge from `examples/nomos.config.sh` are commented
# in detail; everything else mirrors that worked example so the loading
# contract checked by `tests/test_nomos_profile_loading.sh` stays stable.
#
# Conflict matrix vs sibling products on the same neutral fleet host
# (RBOK / ORDO / WordPress / NOMOS):
#   - Worker slots `fleet-001..fleet-011` are shared physical tmux panes.
#     Only one product may hold a given slot at a time. The portfolio helper
#     (see `examples/portfolio.config.sh` and `scripts/portfolio_session_start.sh`)
#     arbitrates which project owns which slot per cycle.
#   - `ORCH_WORKTREES_DIR` is per-product so worktrees never collide.
#   - `AUDIT_LOG_FILE` is per-product so log rotation stays scoped.
#   - `SHARED_BARE_REPO` is empty here: NOMOS clones happen lazily per
#     worktree off `GH_REPO` rather than from a shared bare clone.

PROJECT="nomos"
GH_REPO="RBOKproject/NOMOS"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/operator/gh/nomos"

AGENT_SESSION_PREFIX=""
AGENT_WINDOW_INDEX="0"
AGENTS=(planner builder reviewer)

# Reuse the neutral fleet-001..fleet-011 slot labels documented in
# docs/runbooks/fleet-preparation.md. fleet-000 stays reserved for the
# operator/supervisor loop and MUST NOT appear here.
AGENT_PANES=(
  "fleet-001|fleet-001:0.0|/root/repos/fleet-worktrees/nomos/fleet-001"
  "fleet-002|fleet-002:0.0|/root/repos/fleet-worktrees/nomos/fleet-002"
  "fleet-003|fleet-003:0.0|/root/repos/fleet-worktrees/nomos/fleet-003"
  "fleet-004|fleet-004:0.0|/root/repos/fleet-worktrees/nomos/fleet-004"
  "fleet-005|fleet-005:0.0|/root/repos/fleet-worktrees/nomos/fleet-005"
  "fleet-006|fleet-006:0.0|/root/repos/fleet-worktrees/nomos/fleet-006"
  "fleet-007|fleet-007:0.0|/root/repos/fleet-worktrees/nomos/fleet-007"
  "fleet-008|fleet-008:0.0|/root/repos/fleet-worktrees/nomos/fleet-008"
  "fleet-009|fleet-009:0.0|/root/repos/fleet-worktrees/nomos/fleet-009"
  "fleet-010|fleet-010:0.0|/root/repos/fleet-worktrees/nomos/fleet-010"
  "fleet-011|fleet-011:0.0|/root/repos/fleet-worktrees/nomos/fleet-011"
)

# AGENT_GH_LOGINS and AGENT_GIT_IDENTITIES are placeholders — the operator
# replaces each `<...>` token with the real provider login and the canonical
# git author identity for that fleet slot. Leaving placeholders unresolved
# will fail dispatch preflight rather than silently using the wrong account.
AGENT_GH_LOGINS=(
  "fleet-001=<fleet-001-login>"
  "fleet-002=<fleet-002-login>"
  "fleet-003=<fleet-003-login>"
  "fleet-004=<fleet-004-login>"
  "fleet-005=<fleet-005-login>"
  "fleet-006=<fleet-006-login>"
  "fleet-007=<fleet-007-login>"
  "fleet-008=<fleet-008-login>"
  "fleet-009=<fleet-009-login>"
  "fleet-010=<fleet-010-login>"
  "fleet-011=<fleet-011-login>"
)

AGENT_GIT_IDENTITIES=(
  "fleet-001|<TECHNAI Fleet 001>|<fleet-001@operator.invalid>"
  "fleet-002|<TECHNAI Fleet 002>|<fleet-002@operator.invalid>"
  "fleet-003|<TECHNAI Fleet 003>|<fleet-003@operator.invalid>"
  "fleet-004|<TECHNAI Fleet 004>|<fleet-004@operator.invalid>"
  "fleet-005|<TECHNAI Fleet 005>|<fleet-005@operator.invalid>"
  "fleet-006|<TECHNAI Fleet 006>|<fleet-006@operator.invalid>"
  "fleet-007|<TECHNAI Fleet 007>|<fleet-007@operator.invalid>"
  "fleet-008|<TECHNAI Fleet 008>|<fleet-008@operator.invalid>"
  "fleet-009|<TECHNAI Fleet 009>|<fleet-009@operator.invalid>"
  "fleet-010|<TECHNAI Fleet 010>|<fleet-010@operator.invalid>"
  "fleet-011|<TECHNAI Fleet 011>|<fleet-011@operator.invalid>"
)

PROJECT_REPO_ROOT="${PROJECT_REPO_ROOT:-/root/repos/nomos}"
SUPERVISOR_REPO="$PROJECT_REPO_ROOT"
AGENT_REPO_PREFIX="/root/repos/fleet-worktrees/nomos/"
export AGENT_WORKDIR_TEMPLATE="/root/repos/fleet-worktrees/nomos/%s"

# Per-ticket worktrees off PROJECT_REPO_ROOT (ticket #681 proposed action 3).
USE_WORKTREES=1
ORCH_WORKTREES_DIR="${ORCH_WORKTREES_DIR:-/root/repos/fleet-worktrees/nomos}"

DOC_META_REPO="${DOC_META_REPO:-$PROJECT_REPO_ROOT}"
if [[ -z "${DOC_META_PATHS+x}" ]]; then
  DOC_META_PATHS=(
    README.md
    docs
    .github/workflows
  )
fi

SHARED_BARE_REPO=""

: "${SMART_POLL_TRIGGER_IDLE:=2}"
: "${SMART_POLL_TRIGGER_COMMITTED:=2}"
: "${SMART_POLL_TIMEOUT_SEC:=900}"
: "${SMART_POLL_INTERVAL_SEC:=60}"
: "${SMART_POLL_DEBOUNCE_SEC:=60}"
: "${SMART_POLL_IDLE_MODE:=git}"
: "${SMART_POLL_CAPTURE_TIMEOUT_SEC:=3}"
: "${SMART_POLL_GIT_TIMEOUT_SEC:=5}"

: "${ORCH_CLI_BIN:=agent-cli}"
: "${ORCH_AGENT_CLI:=agent-cli}"

: "${CI_WATCHER_INTERVAL_SEC:=180}"
: "${CI_WATCHER_LOOKBACK:=5}"
: "${CI_AUTOFIX_AGENT_CAN_PUSH:=1}"
: "${SIXSIGMA_AGENT_CAN_PUSH:=1}"
: "${SIXSIGMA_MAX_AUTOFIX_DISPATCHES:=4}"

PR_MERGE_CI_INTERVAL_SEC=30
PR_MERGE_CI_TIMEOUT_SEC=600

: "${ORCH_TOKENS_FILE:=/operator/ordo-tokens.env}"
if [ -z "${PR_MERGE_ADMIN_TOKEN:-}" ] && [ -f "$ORCH_TOKENS_FILE" ]; then
  # shellcheck disable=SC1090
  source "$ORCH_TOKENS_FILE"
  PR_MERGE_ADMIN_TOKEN="${GH_ADMIN_TOKEN:-}"
fi

AUDIT_LOG_FILE="/var/log/orch/${PROJECT}.log"

# Real NOMOS hot spots (DOR-XXX control packs, compliance evidence, etc.).
# Operators tighten this list as the NOMOS surface area stabilises.
HOT_SPOTS=(
  "policies/dor/control_pack.yaml"
  "evidence/manifest.json"
  "service/main.py"
)
