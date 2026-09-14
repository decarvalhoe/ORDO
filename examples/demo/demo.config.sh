#!/usr/bin/env bash
# shellcheck disable=SC2034  # profile variables are consumed by the scripts that source this file
# examples/demo/demo.config.sh — zero-credential demo profile for the agentic
# control plane (docs/architecture/demo.md, epic #806 / #814).
#
# Everything this profile points at is fake or scratch:
#   - the forge is the fake provider adapter served from a copy of
#     tests/fixtures/adapters/fake (repo acme/widgets, PRs #12-#16);
#   - the runtime is the fake runtime adapter (no tmux);
#   - state, logs and fixtures live under ORDO_DEMO_DIR (default
#     ${TMPDIR:-/tmp}/ordo-demo), never under the host's orch-state.
# No gh, curl, ssh or tmux is needed and none is called. Nothing here is live
# topology: do not copy this file as the basis of an operator profile — use
# examples/ordo.config.sh and an external ORDO_PROJECT_PROFILE for that.
#
# Usage (see docs/architecture/demo.md for the full walkthrough):
#   export ORDO_DEMO_DIR=$(mktemp -d)
#   cp -r tests/fixtures/adapters/fake "$ORDO_DEMO_DIR/fake"
#   bash scripts/ordo_scheduler.sh examples/demo/demo.config.sh enqueue --title "demo" --json

: "${ORDO_DEMO_DIR:=${TMPDIR:-/tmp}/ordo-demo}"
export ORDO_DEMO_DIR

PROJECT="ordo-demo"
DEFAULT_BRANCH="main"

# Forge: the fake adapter reads fixtures from ORDO_FAKE_ADAPTER_DIR; the repo
# name matches the fixture dataset. GH_REPO is only the legacy fallback name
# of ORDO_FORGE_REPO and no GitHub call is ever made.
GH_REPO="acme/widgets"
GH_CONFIG_DIR="$ORDO_DEMO_DIR/gh-unused"
: "${ORDO_PROVIDER_ADAPTER:=fake}"
: "${ORDO_RUNTIME_ADAPTER:=fake}"
: "${ORDO_FORGE_REPO:=acme/widgets}"
: "${ORDO_FAKE_ADAPTER_DIR:=$ORDO_DEMO_DIR/fake}"
export ORDO_PROVIDER_ADAPTER ORDO_RUNTIME_ADAPTER ORDO_FORGE_REPO ORDO_FAKE_ADAPTER_DIR

# Fleet shape (never dispatched to: the runtime adapter is fake).
AGENT_REPO_PREFIX="$ORDO_DEMO_DIR/work/"
export AGENT_WORKDIR_TEMPLATE="$ORDO_DEMO_DIR/work/%s"
AGENT_PANES=(
  "fleet-001|fleet-001:0.0|$ORDO_DEMO_DIR/work/fleet-001"
)
PROJECT_REPO_ROOT="$ORDO_DEMO_DIR/work/supervisor"
SUPERVISOR_REPO="$PROJECT_REPO_ROOT"

# State and logs stay in the scratch directory (an exported value wins).
: "${ORCH_STATE_BASE:=$ORDO_DEMO_DIR/state}"
: "${ORCH_LOG_DIR:=$ORDO_DEMO_DIR/log}"
export ORCH_STATE_BASE ORCH_LOG_DIR
AUDIT_LOG_FILE="$ORCH_LOG_DIR/$PROJECT.log"

# Approval policy of the demo: one operator may approve pr.merge; the policy
# version is pinned so scoping the mutation gate mid-demo does not invalidate
# an approval that was requested before (docs/architecture/approvals.md).
: "${ORDO_OPERATOR:=demo-operator}"
: "${ORDO_APPROVAL_PRINCIPALS:=demo-operator=pr.merge}"
: "${ORDO_POLICY_VERSION:=demo-policy-v1}"
export ORDO_OPERATOR ORDO_APPROVAL_PRINCIPALS ORDO_POLICY_VERSION

# Deterministic scheduler: no jitter, a named worker.
: "${ORDO_SCHED_JITTER:=0}"
: "${ORDO_SCHED_WORKER_ID:=demo}"
export ORDO_SCHED_JITTER ORDO_SCHED_WORKER_ID
