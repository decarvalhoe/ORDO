#!/usr/bin/env bats
# tests/mcp_permission_preflight_dispatch_ticket.bats — coverage for
# ORDO #342 / dispatch_ticket.sh integration.
#
# `scripts/dispatch_ticket.sh` MUST exit
# `ORCH_MCP_PERMISSION_BLOCKED_EXIT_CODE` (default 80) when the MCP
# preflight blocks. This is the policy-style denial that the wave
# dispatcher (#327) maps to status=denied and that the orchestrator
# matrix should route to "needs_operator_permission" instead of "active
# work".
#
# We exercise the end-to-end script in dry-run mode against a stubbed
# project config and a controlled permissions ledger.

load './helpers.bash'

setup() {
  setup_orch_test

  # Sanitize toolkit pieces dispatch_ticket.sh sources transitively.
  toolkit_file scripts/dispatch_ticket.sh >/dev/null
  toolkit_file lib/audit_log.sh >/dev/null
  toolkit_file lib/agent_inventory.sh >/dev/null
  toolkit_file lib/config_check.sh >/dev/null
  toolkit_file lib/config_resolver.sh >/dev/null
  toolkit_file lib/dry_run.sh >/dev/null
  toolkit_file lib/github_identity.sh >/dev/null
  toolkit_file lib/host_load_gate.sh >/dev/null
  toolkit_file lib/log_bounds.sh >/dev/null
  toolkit_file lib/mcp_permission_preflight.sh >/dev/null
  toolkit_file lib/portfolio_config.sh >/dev/null
  toolkit_file lib/process_safety.sh >/dev/null
  toolkit_file lib/prompt_integrity.sh >/dev/null
  toolkit_file lib/state_persist.sh >/dev/null
  toolkit_file lib/tmux_helpers.sh >/dev/null
  toolkit_file lib/worktree_helpers.sh >/dev/null
  /usr/bin/chmod +x "$SANITIZED_TK/scripts/dispatch_ticket.sh"

  export PROJECT="ordo"
  export AGENT_SESSION_PREFIX="cap-${BATS_TEST_NUMBER}-"
  export AGENT_WINDOW_INDEX=0
  export AGENT_WORKDIR_TEMPLATE="$BATS_TEST_TMPDIR/work/%s"
  export GH_REPO="example/ordo"
  export GH_CONFIG_DIR="$BATS_TEST_TMPDIR/gh"
  export DEFAULT_BRANCH="main"
  export USE_WORKTREES=0
  export ORCH_VALIDATOR_FORK_PREFLIGHT=0
  export ORCH_VALIDATOR_SEMAPHORE_HELD=1
  mkdir -p "$BATS_TEST_TMPDIR/work/claude" "$BATS_TEST_TMPDIR/work/copilot" "$GH_CONFIG_DIR"

  cat > "$BATS_TEST_TMPDIR/ordo.config.sh" <<EOF
PROJECT="ordo"
GH_REPO="example/ordo"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$GH_CONFIG_DIR"
AGENT_REPO_PREFIX="$BATS_TEST_TMPDIR/work/"
export AGENT_WORKDIR_TEMPLATE="$BATS_TEST_TMPDIR/work/%s"
AGENT_PANES=(
  "claude|cap-${BATS_TEST_NUMBER}-claude:0.0|$BATS_TEST_TMPDIR/work/claude"
  "copilot|cap-${BATS_TEST_NUMBER}-copilot:0.0|$BATS_TEST_TMPDIR/work/copilot"
)
EOF

  # Canonical-prompt sentinels expected by dispatch_ticket.sh's validator
  # plus padding so the prompt-integrity check (>=256 bytes by default)
  # passes — the integrity checker is unrelated to MCP preflight, but we
  # need a real-shaped prompt to drive the script end-to-end.
  cat > "$BATS_TEST_TMPDIR/prompt.md" <<EOF
# Dispatch canonique

## Objectif
Audit the Figma design at
https://www.figma.com/design/JjE4BI3JXEghjU4svSrf0R/audit-target?node-id=48-268
to verify component-level traceability against the implementation. This
prompt deliberately mentions the Figma URL so the MCP permission
preflight will detect that the figma MCP is required for this dispatch.

## Format de sortie attendu
Status block consistent with prior waves.

## Tools / sources autorises
- gh issue view 100 --repo example/ordo

## Boundaries / interdictions
- Stay strictly in scope.

## Definition of Done verifiable
- [ ] Audit completed.
- [ ] Findings filed.

## Preuves attendues
- pwd post-cd
- audit log entries
EOF

  # Ledger blocks claude, grants copilot.
  export ORDO_MCP_PERMISSIONS_FILE="$BATS_TEST_TMPDIR/mcp-permissions.json"
  cat > "$ORDO_MCP_PERMISSIONS_FILE" <<EOF
{
  "by_workdir": {
    "$BATS_TEST_TMPDIR/work/claude":  {"figma": "needs_operator_permission"},
    "$BATS_TEST_TMPDIR/work/copilot": {"figma": "granted"}
  }
}
EOF
}

run_dispatch_ticket() {
  ORCH_LOG_DIR="$ORCH_LOG_DIR" \
  ORCH_STATE_BASE="$ORCH_STATE_BASE" \
  ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE=off \
  ORCH_HOST_GATE_MODE=off \
  ORCH_VALIDATOR_FORK_PREFLIGHT=0 \
  ORCH_VALIDATOR_SEMAPHORE_HELD=1 \
  ORCH_DRY_RUN=1 \
    bash "$SANITIZED_TK/scripts/dispatch_ticket.sh" \
      "$BATS_TEST_TMPDIR/ordo.config.sh" "$1" "$2" "$BATS_TEST_TMPDIR/prompt.md" --dry-run
}

@test "dispatch_ticket exits 80 when MCP preflight blocks the wave" {
  run run_dispatch_ticket claude 100
  [ "$status" -eq 80 ]
  # The audit message should explicitly identify the blocking MCP.
  [[ "$output" == *"MCP_BLOCKED"* ]]
  [[ "$output" == *"blocking=figma:needs_operator_permission"* ]] || {
    echo "$output"; false;
  }
}

@test "dispatch_ticket succeeds when every required MCP is granted" {
  run run_dispatch_ticket copilot 101
  [ "$status" -eq 0 ]
  [[ "$output" == *"MCP_OK"* ]]
}

@test "ORCH_MCP_PREFLIGHT_DISABLE bypasses preflight (escape hatch for legacy)" {
  ORCH_MCP_PREFLIGHT_DISABLE=1 run run_dispatch_ticket claude 102
  [ "$status" -eq 0 ]
  [[ "$output" != *"MCP_BLOCKED"* ]]
}
