#!/usr/bin/env bats
# tests/pr_ops_centralized.bats — coverage for ORDO #360 (centralized
# PR operations mode), part of the #357 epic.
#
# Validation contract from issue #360:
#   - Mode is explicit in project/portfolio profile.
#   - Centralized mode can coexist with delegated remediation
#     (i.e. preparation actions are always allowed).
#   - The controller refuses final mutation when required gates are
#     not satisfied.
#   - Operator override, when supported, is explicit and logged.
#
# Plus the universal-pattern requirement from the dispatch DoD:
# tests cover at least two project fixtures with different profiles.

load './helpers.bash'

setup() {
  setup_orch_test

  toolkit_file lib/audit_log.sh           >/dev/null
  toolkit_file lib/config_check.sh        >/dev/null
  toolkit_file lib/config_resolver.sh     >/dev/null
  toolkit_file lib/dry_run.sh             >/dev/null
  toolkit_file lib/log_bounds.sh          >/dev/null
  toolkit_file lib/portfolio_config.sh    >/dev/null
  toolkit_file lib/process_safety.sh      >/dev/null
  toolkit_file lib/pr_ops_mode.sh         >/dev/null
  toolkit_file scripts/pr_ops_controller.sh >/dev/null
  /usr/bin/chmod +x "$SANITIZED_TK/scripts/pr_ops_controller.sh"

  export PROJECT="ordo"
  mkdir -p "$BATS_TEST_TMPDIR/configs" "$BATS_TEST_TMPDIR/work"

  # Project A — centralized mode with override allowed. Models a
  # stricter portfolio where the operator owns final mutations but
  # may emergency-override.
  cat > "$BATS_TEST_TMPDIR/configs/centralized-with-override.config.sh" <<EOF
PROJECT="alpha"
GH_REPO="example/alpha"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$BATS_TEST_TMPDIR/gh"
AGENT_REPO_PREFIX="$BATS_TEST_TMPDIR/work/"
export AGENT_WORKDIR_TEMPLATE="$BATS_TEST_TMPDIR/work/%s"

PR_OPS_MODE="centralized"
ORDO_PR_OPS_OVERRIDE_ENABLED=1
EOF

  # Project B — observe mode (read-only). Models the default
  # least-privilege profile that this PR ships as the default.
  cat > "$BATS_TEST_TMPDIR/configs/observe-only.config.sh" <<EOF
PROJECT="beta"
GH_REPO="example/beta"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$BATS_TEST_TMPDIR/gh"
AGENT_REPO_PREFIX="$BATS_TEST_TMPDIR/work/"
export AGENT_WORKDIR_TEMPLATE="$BATS_TEST_TMPDIR/work/%s"

PR_OPS_MODE="observe"
ORDO_PR_OPS_OVERRIDE_ENABLED=0
EOF

  # Project C — centralized with NO override (test the
  # override-disabled refusal). Distinct file so each test stays
  # readable.
  cat > "$BATS_TEST_TMPDIR/configs/centralized-no-override.config.sh" <<EOF
PROJECT="gamma"
GH_REPO="example/gamma"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$BATS_TEST_TMPDIR/gh"
AGENT_REPO_PREFIX="$BATS_TEST_TMPDIR/work/"
export AGENT_WORKDIR_TEMPLATE="$BATS_TEST_TMPDIR/work/%s"

PR_OPS_MODE="centralized"
ORDO_PR_OPS_OVERRIDE_ENABLED=0
EOF
}

run_controller() {
  ORCH_LOG_DIR="$ORCH_LOG_DIR" \
  ORCH_STATE_BASE="$ORCH_STATE_BASE" \
    bash "$SANITIZED_TK/scripts/pr_ops_controller.sh" "$@"
}

# ---------------------------------------------------------------------------
# AC: centralized mode blocks agent-side merge authority
# ---------------------------------------------------------------------------

@test "observe mode (default) refuses final merge from any actor" {
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/observe-only.config.sh" merge 42 \
    --gates ci,review --actor operator
  [ "$status" -eq 90 ]
  decision=$(printf '%s' "$output" | head -1 | jq -r '.decision')
  reason=$(printf '%s' "$output" | head -1 | jq -r '.reason')
  [ "$decision" = "refused" ]
  [ "$reason" = "observe_mode_refuses_final_mutation" ]
}

@test "centralized mode refuses agent-actor merge with exit 90" {
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/centralized-with-override.config.sh" merge 42 \
    --gates ci,review --actor agent
  [ "$status" -eq 90 ]
  decision=$(printf '%s' "$output" | head -1 | jq -r '.decision')
  reason=$(printf '%s' "$output" | head -1 | jq -r '.reason')
  [ "$decision" = "refused" ]
  [ "$reason" = "centralized_mode_agent_actor" ]
}

@test "centralized mode refuses ready-for-review from agent actor" {
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/centralized-with-override.config.sh" \
    ready-for-review 99 --gates ci --actor agent
  [ "$status" -eq 90 ]
  reason=$(printf '%s' "$output" | head -1 | jq -r '.reason')
  [ "$reason" = "centralized_mode_agent_actor" ]
}

@test "centralized mode refuses operator merge when required gate is missing" {
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/centralized-with-override.config.sh" merge 42 \
    --gates ci --actor operator
  [ "$status" -eq 91 ]
  reason=$(printf '%s' "$output" | head -1 | jq -r '.reason')
  [ "$reason" = "missing_required_gate" ]
}

# ---------------------------------------------------------------------------
# AC: centralized mode accepts agent evidence then performs allowed mutation
# ---------------------------------------------------------------------------

@test "centralized mode allows preparation action from agent (evidence-record)" {
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/centralized-with-override.config.sh" \
    evidence-record 42 --actor agent
  [ "$status" -eq 0 ]
  decision=$(printf '%s' "$output" | head -1 | jq -r '.decision')
  reason=$(printf '%s' "$output" | head -1 | jq -r '.reason')
  [ "$decision" = "allowed" ]
  [ "$reason" = "preparation_action" ]
}

@test "centralized mode allows preparation action even in observe mode" {
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/observe-only.config.sh" \
    prepare-fix 42 --actor agent
  [ "$status" -eq 0 ]
  reason=$(printf '%s' "$output" | head -1 | jq -r '.reason')
  [ "$reason" = "preparation_action" ]
}

@test "centralized mode allows operator merge once every required gate passes" {
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/centralized-with-override.config.sh" merge 42 \
    --gates ci,review --actor operator
  [ "$status" -eq 0 ]
  decision=$(printf '%s' "$output" | head -1 | jq -r '.decision')
  reason=$(printf '%s' "$output" | head -1 | jq -r '.reason')
  [ "$decision" = "allowed" ]
  [ "$reason" = "operator_authorized" ]
}

# ---------------------------------------------------------------------------
# AC: operator override is explicit and logged
# ---------------------------------------------------------------------------

@test "explicit operator override allowed when profile permits it" {
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/centralized-with-override.config.sh" merge 42 \
    --override "hotfix-cve-2026-001" --actor operator
  [ "$status" -eq 0 ]
  reason=$(printf '%s' "$output" | head -1 | jq -r '.reason')
  override=$(printf '%s' "$output" | head -1 | jq -r '.override_reason')
  [ "$reason" = "operator_override" ]
  [ "$override" = "hotfix-cve-2026-001" ]
}

@test "override refused with exit 92 when profile disables it" {
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/centralized-no-override.config.sh" merge 42 \
    --override "hotfix" --actor agent
  [ "$status" -eq 92 ]
  reason=$(printf '%s' "$output" | head -1 | jq -r '.reason')
  [ "$reason" = "override_disabled" ]
}

@test "decision is logged via audit (AUDIT LOG line on stderr)" {
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/centralized-with-override.config.sh" merge 42 \
    --gates ci,review --actor operator 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUDIT LOG"*"PR_OPS_CONTROLLER"*"action=merge"*"pr=#42"*"decision=allowed"* ]] || {
    echo "$output"; false;
  }
}

@test "decision is appended to the ledger when --ledger is supplied" {
  ledger="$BATS_TEST_TMPDIR/ledger.json"
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/centralized-with-override.config.sh" merge 42 \
    --gates ci,review --actor operator --ledger "$ledger"
  [ "$status" -eq 0 ]
  [ -s "$ledger" ]
  count=$(jq 'length' "$ledger")
  [ "$count" = "1" ]

  # Append a second decision and confirm the ledger grows.
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/centralized-with-override.config.sh" \
    rerun 99 --actor operator --ledger "$ledger"
  [ "$status" -eq 0 ]
  count2=$(jq 'length' "$ledger")
  [ "$count2" = "2" ]

  # Each ledger entry carries the augmented context (pr, project,
  # decided_at) so audit consumers can reconstruct who/what.
  has_pr=$(jq '.[0].pr' "$ledger")
  has_project=$(jq '.[0].project' "$ledger")
  has_ts=$(jq '.[0].decided_at' "$ledger")
  [ "$has_pr" = '"42"' ]
  [ "$has_project" = '"alpha"' ]
  [ "$has_ts" != "null" ]
}

# ---------------------------------------------------------------------------
# Universal pattern (DoD): two distinct project profiles, same controller
# ---------------------------------------------------------------------------

@test "universal pattern: centralized vs observe profiles produce different decisions" {
  # Same action (merge), same actor (operator), same gates passed —
  # but two different project profiles. Confirms the controller is
  # truly profile-driven and contains no project-name hardcoding.
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/centralized-with-override.config.sh" merge 1 \
    --gates ci,review --actor operator
  [ "$status" -eq 0 ]
  alpha_reason=$(printf '%s' "$output" | head -1 | jq -r '.reason')
  alpha_project=$(printf '%s' "$output" | head -1 | jq -r '.project')
  [ "$alpha_reason" = "operator_authorized" ]
  [ "$alpha_project" = "alpha" ]

  run run_controller \
    "$BATS_TEST_TMPDIR/configs/observe-only.config.sh" merge 1 \
    --gates ci,review --actor operator
  [ "$status" -eq 90 ]
  beta_reason=$(printf '%s' "$output" | head -1 | jq -r '.reason')
  beta_project=$(printf '%s' "$output" | head -1 | jq -r '.project')
  [ "$beta_reason" = "observe_mode_refuses_final_mutation" ]
  [ "$beta_project" = "beta" ]
}

@test "universal pattern: third project (gamma) inherits its own override policy" {
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/centralized-no-override.config.sh" merge 1 \
    --override "hotfix" --actor agent
  [ "$status" -eq 92 ]
  gamma_project=$(printf '%s' "$output" | head -1 | jq -r '.project')
  [ "$gamma_project" = "gamma" ]
}

# ---------------------------------------------------------------------------
# Negative / robustness
# ---------------------------------------------------------------------------

@test "invalid action returns exit 2 with unknown_action reason" {
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/centralized-with-override.config.sh" \
    not-a-real-action 42 --actor operator
  [ "$status" -eq 2 ]
  reason=$(printf '%s' "$output" | head -1 | jq -r '.reason')
  [ "$reason" = "unknown_action" ]
}

@test "decision JSON shape is stable: required fields always present" {
  run run_controller \
    "$BATS_TEST_TMPDIR/configs/centralized-with-override.config.sh" merge 7 \
    --gates ci,review --actor operator
  [ "$status" -eq 0 ]
  payload=$(printf '%s' "$output" | head -1)
  for field in action mode actor required_gates passed_gates override_reason \
               decision reason pr project decided_at; do
    val=$(printf '%s' "$payload" | jq "has(\"$field\")")
    [ "$val" = "true" ] || {
      echo "missing field: $field in $payload"
      false
    }
  done
}
