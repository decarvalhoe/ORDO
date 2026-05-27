#!/usr/bin/env bats

load './helpers.bash'

setup() {
  setup_orch_test

  FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/realisons-wordpress-drain"
  PROJECT_CFG="$BATS_TEST_TMPDIR/realisons-wordpress.config.sh"
  PORTFOLIO_CFG="$BATS_TEST_TMPDIR/portfolio.config.sh"

  for rel in \
    scripts/continuation_guard.sh \
    scripts/queue_starvation_surface.sh \
    lib/config_resolver.sh \
    lib/portfolio_config.sh \
    lib/audit_log.sh \
    lib/state_persist.sh \
    lib/config_check.sh \
    lib/log_bounds.sh; do
    toolkit_file "$rel" >/dev/null
  done
  chmod +x "$SANITIZED_TK/scripts/continuation_guard.sh"
  chmod +x "$SANITIZED_TK/scripts/queue_starvation_surface.sh"

  cat > "$PROJECT_CFG" <<EOF
PROJECT="realisons-wordpress"
GH_REPO="example/realisons-wordpress"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$BATS_TEST_TMPDIR/gh"
EOF

  cat > "$PORTFOLIO_CFG" <<EOF
PORTFOLIO_NAME="realisons-wordpress-drain"
PORTFOLIO_PROJECTS=(
  "realisons-wordpress|$PROJECT_CFG"
)
PORTFOLIO_PRIORITIES=(
  "realisons-wordpress=100"
)
EOF

  cat > "$SANITIZED_TK/scripts/portfolio_status.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

pr_json=$(cat "$RW_DRAIN_PR_SIGNALS")
agents_json=$(cat "$RW_DRAIN_AGENTS")

open_prs=$(jq -r 'length' <<< "$pr_json")
merge_ready=$(jq -r '[.[] | select((.signals // []) | index("merge-ready"))] | length' <<< "$pr_json")
checks_missing=$(jq -r '[.[] | select((.signals // []) | index("checks-missing"))] | length' <<< "$pr_json")
free=$(jq -r 'length' <<< "$agents_json")
free_agents=$(jq -c '[.[].label]' <<< "$agents_json")

jq -nc \
  --arg cfg "$RW_DRAIN_PROJECT_CFG" \
  --argjson prs "$pr_json" \
  --argjson free_agents "$free_agents" \
  --argjson open_prs "$open_prs" \
  --argjson merge_ready "$merge_ready" \
  --argjson checks_missing "$checks_missing" \
  --argjson free "$free" \
  '[{
    alias: "realisons-wordpress",
    priority: 100,
    config: $cfg,
    gate_state: "merge_ready",
    counts: {
      free: $free,
      parkable: 0,
      open_prs: $open_prs,
      merge_ready: $merge_ready,
      ci_failed: 0,
      ci_pending: 0,
      checks_missing: $checks_missing,
      needs_rebase: 0,
      conflicts: 0,
      review_required: 0
    },
    agents: {
      free: $free_agents,
      parkable: []
    },
    prs: $prs
  }]'
EOF
  chmod +x "$SANITIZED_TK/scripts/portfolio_status.sh"

  cat > "$SANITIZED_TK/scripts/dispatch_plan.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat "$RW_DRAIN_READY_CHILDREN"
EOF
  chmod +x "$SANITIZED_TK/scripts/dispatch_plan.sh"

  export FIXTURE_DIR PROJECT_CFG PORTFOLIO_CFG
  export RW_DRAIN_PROJECT_CFG="$PROJECT_CFG"
  export RW_DRAIN_RUNTIME="$FIXTURE_DIR/runtime_state.json"
  export RW_DRAIN_AGENTS="$FIXTURE_DIR/agents.json"
  export RW_DRAIN_ASSIGNMENTS="$FIXTURE_DIR/assignments.json"
  export RW_DRAIN_PR_SIGNALS="$FIXTURE_DIR/pr_signals.json"
  export RW_DRAIN_READY_CHILDREN="$FIXTURE_DIR/ready_children.json"
  unset PR_OPS_MODE ORDO_PR_OPS_MODE
}

@test "realisons-wordpress drain does not stop silently with merge-ready PRs and free agents" {
  jq -e '
    .orch_loop == "stopped"
    and .profile_paused == false
    and .pr_ops_mode == null
  ' "$RW_DRAIN_RUNTIME" >/dev/null

  jq -e '
    length == 4
    and ([.[] | select(.pr != null and .state == "active")] | length == 4)
  ' "$RW_DRAIN_ASSIGNMENTS" >/dev/null

  jq -e '
    length == 4
    and ([.[] | select((.signals // []) | index("merge-ready") and index("ci-pass"))] | length == 3)
    and ([.[] | select((.signals // []) | index("checks-missing"))] | length == 1)
  ' "$RW_DRAIN_PR_SIGNALS" >/dev/null

  jq -e '
    length == 7
    and ([.[].label] == ["agent-005","agent-006","agent-007","agent-008","agent-009","agent-010","agent-011"])
    and all(.[]; .dirty == "0" and .branch == "main" and .capacity_class == "available")
  ' "$RW_DRAIN_AGENTS" >/dev/null

  jq -e '
    length == 23
    and ([.[].parent_issue] | unique | length == 4)
    and all(.[]; .status == "ready" and .priority == "P1")
  ' "$RW_DRAIN_READY_CHILDREN" >/dev/null

  run env \
    RW_DRAIN_PROJECT_CFG="$RW_DRAIN_PROJECT_CFG" \
    RW_DRAIN_AGENTS="$RW_DRAIN_AGENTS" \
    RW_DRAIN_PR_SIGNALS="$RW_DRAIN_PR_SIGNALS" \
    RW_DRAIN_READY_CHILDREN="$RW_DRAIN_READY_CHILDREN" \
    bash "$SANITIZED_TK/scripts/continuation_guard.sh" "$PORTFOLIO_CFG" --json

  [ "$status" -eq 10 ]
  guard_json="$output"
  guard_file="$BATS_TEST_TMPDIR/continuation_guard.json"
  printf '%s\n' "$guard_json" > "$guard_file"

  jq -e '
    .decision == "dispatch_required"
    and (.queues_evaluated | index("pr") != null)
    and (.queues_evaluated | index("issue") != null)
    and ([.reasons[] | select(.alias == "realisons-wordpress" and .reason == "merge-ready" and .count == 3)] | length == 1)
    and ([.reasons[] | select(.alias == "realisons-wordpress" and .reason == "dispatch-required")] | length == 7)
    and ([.reasons[] | select(.reason == "dispatch-required" and (.detail | contains("available_capacity=7 ready_issues=23")))] | length == 7)
    and ([.reasons[] | select(.reason == "dispatch-required" and (.detail | contains("agent=agent-005 issue=#9001 Ready realisons child 01")))] | length == 1)
    and ([.reasons[] | select(.reason == "dispatch-required" and (.detail | contains("agent=agent-011 issue=#9007 Ready realisons child 07")))] | length == 1)
    and ([.reasons[] | select(.reason == "dispatch-required" and (.detail | contains("issue=#9008")))] | length == 0)
    and ([.warnings[]? | select(.reason == "idle-ready-agent-blocker")] | length == 0)
  ' "$guard_file" >/dev/null

  run bash -c "ORCH_QUEUE_STARVATION_ALERT_CYCLES=1 bash '$SANITIZED_TK/scripts/queue_starvation_surface.sh' '$PROJECT_CFG' --cycle 12 --continuation-guard-json '$guard_file' --apply --json 2>'$BATS_TEST_TMPDIR/surface.err'"

  [ "$status" -eq 0 ]
  jq -e '
    .project == "realisons-wordpress"
    and .cycle == 12
    and .state == "not-starved"
    and .action == "reset"
    and .decision == "dispatch_required"
  ' <<< "$output" >/dev/null

  grep -Eq 'QUEUE_STARVATION_SURFACE .*state=not-starved .*action=reset .*decision=dispatch_required .*project=realisons-wordpress' \
    "$ORCH_LOG_DIR/realisons-wordpress.log"
}
