#!/usr/bin/env bats
# tests/portfolio_status_capacity.bats — coverage for the capacity-report
# heuristics required by ORDO #283. The orchestrator must derive busy / free
# accounting from structured state (assignments.json, agent pool, profile
# metadata for reserved + supervisor sessions) rather than from anecdotal
# pane inspection.

load './helpers.bash'

setup() {
  setup_orch_test
  export PORTFOLIO_NAME="capacity-bats-${BATS_TEST_NUMBER}"
  export AGENT_SESSION_PREFIX="cap-bats-${BATS_TEST_NUMBER}-"
  export ORCH_TMUX_TIMEOUT_SEC=3

  # Sanitize the toolkit files we exercise.
  toolkit_file scripts/portfolio_status.sh >/dev/null
  toolkit_file lib/config_resolver.sh >/dev/null
  toolkit_file lib/portfolio_config.sh >/dev/null
  toolkit_file lib/process_safety.sh >/dev/null
  toolkit_file lib/lane_registry.sh >/dev/null
  toolkit_file lib/capacity_report.sh >/dev/null
  chmod +x "$SANITIZED_TK/scripts/portfolio_status.sh"

  # Stub agent_pool_status.sh: alpha has free=copilot, parkable=cursor, free=orch.
  # The "orch" label MUST come back as a regular free agent — it is reserved
  # only when explicit profile metadata says so.
  cat > "$SANITIZED_TK/scripts/agent_pool_status.sh" <<'EOF'
#!/usr/bin/env bash
cfg=$1
case "$cfg" in
  *alpha* )
    cat <<'JSON'
[
  {"label":"copilot","pane":"alpha-copilot:0.0","workdir":"/tmp/a/copilot","branch":"main","dirty":"0","pr":"","signals":[]},
  {"label":"cursor","pane":"alpha-cursor:0.0","workdir":"/tmp/a/cursor","branch":"feat/cursor","dirty":"0","pr":"99","signals":[]},
  {"label":"orch","pane":"alpha-orch:0.0","workdir":"/tmp/a/orch","branch":"main","dirty":"0","pr":"","signals":[]},
  {"label":"busybee","pane":"alpha-busybee:0.0","workdir":"/tmp/a/busybee","branch":"feat/busy","dirty":"3","pr":"","signals":["dirty"]}
]
JSON
    ;;
  *fullbusy* )
    cat <<'JSON'
[
  {"label":"a1","pane":"fb-a1:0.0","workdir":"/tmp/fb/a1","branch":"feat/a1","dirty":"2","pr":"","signals":["dirty"]},
  {"label":"a2","pane":"fb-a2:0.0","workdir":"/tmp/fb/a2","branch":"feat/a2","dirty":"1","pr":"","signals":["dirty","dirty_after_pr"]}
]
JSON
    ;;
esac
EOF
  chmod +x "$SANITIZED_TK/scripts/agent_pool_status.sh"

  cat > "$SANITIZED_TK/scripts/pr_block_signals.sh" <<'EOF'
#!/usr/bin/env bash
cfg=$1
case "$cfg" in
  *alpha* )
    cat <<'JSON'
[
  {"pr":"99","branch":"feat/cursor","agent":"cursor","merge_state":"BLOCKED","mergeable":"MERGEABLE","ci_fail":0,"ci_pending":1,"deploy_gate_pending":0,"base_current":"1","signals":["ci-pending"]}
]
JSON
    ;;
  *fullbusy* )
    printf '[]\n'
    ;;
esac
EOF
  chmod +x "$SANITIZED_TK/scripts/pr_block_signals.sh"

  mkdir -p "$BATS_TEST_TMPDIR/configs"
  cat > "$BATS_TEST_TMPDIR/configs/alpha.config.sh" <<'EOF'
PROJECT="alpha"
GH_REPO="example/alpha"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
AGENT_REPO_PREFIX="/tmp/a-"
export AGENT_WORKDIR_TEMPLATE="/tmp/a-%s"
EOF
  cat > "$BATS_TEST_TMPDIR/configs/fullbusy.config.sh" <<'EOF'
PROJECT="fullbusy"
GH_REPO="example/fullbusy"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
AGENT_REPO_PREFIX="/tmp/fb-"
export AGENT_WORKDIR_TEMPLATE="/tmp/fb-%s"
EOF

  cat > "$BATS_TEST_TMPDIR/configs/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="capacity-bats"
PORTFOLIO_PROJECTS=(
  "alpha|$BATS_TEST_TMPDIR/configs/alpha.config.sh"
  "fullbusy|$BATS_TEST_TMPDIR/configs/fullbusy.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "alpha=20"
  "fullbusy=10"
)
EOF

  # state/<project>/assignments.json — used for stale-assignment scenario.
  mkdir -p "$ORCH_STATE_BASE/alpha" "$ORCH_STATE_BASE/fullbusy"
}

run_status_json() {
  ORCH_STATE_BASE="$ORCH_STATE_BASE" \
    bash "$SANITIZED_TK/scripts/portfolio_status.sh" \
      "$BATS_TEST_TMPDIR/configs/portfolio.config.sh" --json
}

@test "free panes drive busy_claim_valid=false even with one open PR" {
  # No assignments file at all — simulate fresh dispatch state.
  output=$(run_status_json)
  alpha=$(jq -c 'map(select(.alias == "alpha"))[0].capacity_report' <<< "$output")
  [ "$(jq -r '.busy_claim_valid' <<< "$alpha")" = "false" ]
  [ "$(jq -r '.free_pane_ready_count' <<< "$alpha")" = "2" ]
  [ "$(jq -c '.free_pane_ready | sort' <<< "$alpha")" = '["copilot","orch"]' ]
  [ "$(jq -c '.parkable_pr_owners' <<< "$alpha")" = '["cursor"]' ]
  [ "$(jq -r '.evidence_sources.assignments_path' <<< "$alpha")" = "$ORCH_STATE_BASE/alpha/assignments.json" ]
}

@test "stale open-PR assignments do not flip busy_claim_valid to true" {
  # An assignment record points at cursor (open PR #99). The pool reports
  # cursor as parkable (clean, has PR). That record is NOT proof of physical
  # occupancy; capacity_report must surface it under switchable, not busy.
  cat > "$ORCH_STATE_BASE/alpha/assignments.json" <<'JSON'
{
  "cursor": {"issue": 99, "ticket": "99", "branch": "feat/cursor", "workdir": "/tmp/a/cursor", "dispatched_at": "2026-05-08T08:00:00Z"}
}
JSON

  output=$(run_status_json)
  alpha=$(jq -c 'map(select(.alias == "alpha"))[0].capacity_report' <<< "$output")
  [ "$(jq -r '.busy_claim_valid' <<< "$alpha")" = "false" ]
  [ "$(jq -r '.active_assignments_count' <<< "$alpha")" = "1" ]
  [ "$(jq -c '.switchable | map(.agent)' <<< "$alpha")" = '["cursor"]' ]
  [ "$(jq -r '.switchable[0].source' <<< "$alpha")" = "parkable-pr" ]
  # The assigned cursor must NOT be counted as a pane-with-work — only the
  # locally-dirty busybee shows up in that set.
  [ "$(jq -c '.panes_with_work | sort' <<< "$alpha")" = '["busybee"]' ]
  [ "$(jq '.panes_with_work | index("cursor") == null' <<< "$alpha")" = "true" ]
}

@test "supervisor sessions reported separately from agent slots" {
  export ORDO_SUPERVISOR_SESSIONS="rbok-orchestrator:0.0"
  output=$(run_status_json)
  alpha=$(jq -c 'map(select(.alias == "alpha"))[0].capacity_report' <<< "$output")
  [ "$(jq -c '.supervisor_sessions' <<< "$alpha")" = '["rbok-orchestrator:0.0"]' ]
  [ "$(jq -r '.supervisor_sessions_count' <<< "$alpha")" = "1" ]
  # configured_slots reflects only the agent pool, never the supervisor.
  [ "$(jq -r '.configured_slots' <<< "$alpha")" = "4" ]
  # The supervisor session label must NOT leak into free / parkable counts.
  [ "$(jq -r '.free_pane_ready_count' <<< "$alpha")" = "2" ]
}

@test "orch slot is free by default; reserved only via explicit profile metadata" {
  # Default: orch is a regular free agent.
  output=$(run_status_json)
  alpha=$(jq -c 'map(select(.alias == "alpha"))[0].capacity_report' <<< "$output")
  [ "$(jq -c '.free_pane_ready | sort' <<< "$alpha")" = '["copilot","orch"]' ]
  [ "$(jq -c '.reserved_agents' <<< "$alpha")" = '[]' ]

  # Explicit reservation via profile metadata removes orch from dispatch_free.
  export ORDO_RESERVED_AGENTS_ALPHA="orch"
  output=$(run_status_json)
  alpha=$(jq -c 'map(select(.alias == "alpha"))[0].capacity_report' <<< "$output")
  [ "$(jq -c '.reserved_agents' <<< "$alpha")" = '["orch"]' ]
  [ "$(jq -c '.free_pane_ready' <<< "$alpha")" = '["copilot"]' ]
  # parkable_pr_owners surfaces the raw label set; dispatch_parkable filters
  # out reserved labels (cursor not reserved here, so unchanged).
  [ "$(jq -c '.parkable_pr_owners' <<< "$alpha")" = '["cursor"]' ]
}

@test "busy_claim_valid=true only when free + parkable + switchable all empty" {
  # fullbusy: every agent is dirty (blocked), no PRs, no assignments.
  output=$(run_status_json)
  fb=$(jq -c 'map(select(.alias == "fullbusy"))[0].capacity_report' <<< "$output")
  [ "$(jq -r '.busy_claim_valid' <<< "$fb")" = "true" ]
  [ "$(jq -r '.free_pane_ready_count' <<< "$fb")" = "0" ]
  [ "$(jq -c '.parkable_pr_owners' <<< "$fb")" = '[]' ]
  [ "$(jq -c '.switchable' <<< "$fb")" = '[]' ]
  [ "$(jq -c '.panes_with_work | sort' <<< "$fb")" = '["a1","a2"]' ]
}

@test "evidence_sources point at structured-state files for audit" {
  output=$(run_status_json)
  alpha=$(jq -c 'map(select(.alias == "alpha"))[0].capacity_report' <<< "$output")
  [ "$(jq -r '.evidence_sources.portfolio_status' <<< "$alpha")" = "scripts/portfolio_status.sh" ]
  [ "$(jq -r '.evidence_sources.agent_inventory' <<< "$alpha")" = "lib/agent_inventory.sh" ]
  [ "$(jq -r '.evidence_sources.assignments_path' <<< "$alpha")" = "$ORCH_STATE_BASE/alpha/assignments.json" ]
}
