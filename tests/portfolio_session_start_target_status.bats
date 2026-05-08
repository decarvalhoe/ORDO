#!/usr/bin/env bats

# Coverage for #279: portfolio_preflight_target_status must scope readiness by
# project alias and (when provided) expected workdir, so duplicate labels
# across projects do not satisfy readiness for the wrong target.

load './helpers.bash'

setup() {
  setup_orch_test
  toolkit_file lib/config_check.sh >/dev/null
  toolkit_file lib/log_bounds.sh >/dev/null
  toolkit_file lib/audit_log.sh >/dev/null
  PORTFOLIO_LIB=$(toolkit_file lib/portfolio_config.sh)
  export PORTFOLIO_LIB

  # All test cases work off a single portfolio state dir. Each case writes its
  # own session_start.json under that path.
  PORTFOLIO_STATE_DIR="$ORCH_STATE_BASE/_portfolio"
  mkdir -p "$PORTFOLIO_STATE_DIR"
  REPORT_PATH="$PORTFOLIO_STATE_DIR/session_start.json"
  export PORTFOLIO_STATE_DIR REPORT_PATH
}

write_two_project_report() {
  # Two projects (`product-a`, `product-b`) share the agent labels `codex`
  # and `cursor`. Only product-a/codex is ready; product-b/codex is dirty.
  cat > "$REPORT_PATH" <<'JSON'
[
  {
    "alias": "product-a",
    "project": "product-a",
    "label": "codex",
    "workdir": "/work/a/codex",
    "ready": 1,
    "status": "ready"
  },
  {
    "alias": "product-a",
    "project": "product-a",
    "label": "cursor",
    "workdir": "/work/a/cursor",
    "ready": 0,
    "status": "dirty_worktree"
  },
  {
    "alias": "product-b",
    "project": "product-b",
    "label": "codex",
    "workdir": "/work/b/codex",
    "ready": 0,
    "status": "dirty_worktree"
  },
  {
    "alias": "product-b",
    "project": "product-b",
    "label": "cursor",
    "workdir": "/work/b/cursor",
    "ready": 1,
    "status": "ready"
  }
]
JSON
  touch "$REPORT_PATH"
}

run_status() {
  # Source the helpers under a fresh shell, scope the report path through
  # ORCH_STATE_BASE, then run the function. set +e so non-zero returns can
  # be inspected without exiting the bats run.
  bash -lc "$(orch_env_exports)
    source '$PORTFOLIO_LIB'
    set +e
    portfolio_preflight_target_status $*
    rc=\$?
    set -e
    echo rc=\$rc
  "
}

@test "label-only single-arg path stays backward compatible (any project counts)" {
  write_two_project_report

  run run_status codex
  [ "$status" -eq 0 ]
  # codex is ready under product-a, so single-arg call is satisfied.
  [[ "$output" == *"ok"* ]]
  [[ "$output" == *"rc=0"* ]]
}

@test "label-only single-arg path returns not_ready when no record is ready" {
  cat > "$REPORT_PATH" <<'JSON'
[
  {"alias":"product-a","label":"codex","workdir":"/work/a/codex","ready":0,"status":"dirty_worktree"},
  {"alias":"product-b","label":"codex","workdir":"/work/b/codex","ready":0,"status":"dirty_worktree"}
]
JSON
  touch "$REPORT_PATH"

  run run_status codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"not_ready"* ]]
  [[ "$output" == *"rc=1"* ]]
}

@test "alias scope: codex ready in product-a does NOT satisfy product-b" {
  write_two_project_report

  run run_status codex product-b
  [ "$status" -eq 0 ]
  # product-b/codex is dirty even though product-a/codex is ready.
  [[ "$output" == *"not_ready"* ]]
  [[ "$output" == *"rc=1"* ]]
}

@test "alias scope: codex ready in product-a satisfies product-a" {
  write_two_project_report

  run run_status codex product-a
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
  [[ "$output" == *"rc=0"* ]]
}

@test "alias scope: cursor ready in product-b does NOT satisfy product-a" {
  write_two_project_report

  run run_status cursor product-a
  [ "$status" -eq 0 ]
  [[ "$output" == *"not_ready"* ]]
  [[ "$output" == *"rc=1"* ]]
}

@test "wrong_project: label only present under another alias" {
  cat > "$REPORT_PATH" <<'JSON'
[
  {"alias":"product-a","label":"codex","workdir":"/work/a/codex","ready":1,"status":"ready"}
]
JSON
  touch "$REPORT_PATH"

  run run_status codex product-b
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrong_project"* ]]
  [[ "$output" == *"rc=1"* ]]
}

@test "workdir scope: matched label+alias but wrong workdir returns wrong_workdir" {
  write_two_project_report

  run run_status codex product-a /work/a/codex-OTHER
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrong_workdir"* ]]
  [[ "$output" == *"rc=1"* ]]
}

@test "workdir scope: matched label+alias+workdir+ready returns ok" {
  write_two_project_report

  run run_status codex product-a /work/a/codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
  [[ "$output" == *"rc=0"* ]]
}

@test "workdir scope: matched scope but ready=0 returns not_ready not wrong_workdir" {
  write_two_project_report

  run run_status codex product-b /work/b/codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"not_ready"* ]]
  [[ "$output" == *"rc=1"* ]]
}

@test "missing report returns missing" {
  rm -f "$REPORT_PATH"

  run run_status codex product-a /work/a/codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing"* ]]
  [[ "$output" == *"rc=1"* ]]
}

@test "stale report returns stale" {
  write_two_project_report
  touch -d "@$(($(date +%s) - 7200))" "$REPORT_PATH"

  run bash -lc "$(orch_env_exports)
    export PORTFOLIO_PREFLIGHT_MAX_AGE_SEC=3600
    source '$PORTFOLIO_LIB'
    set +e
    portfolio_preflight_target_status codex product-a /work/a/codex
    rc=\$?
    set -e
    echo rc=\$rc
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale"* ]]
  [[ "$output" == *"rc=1"* ]]
}

@test "alias matches via .project field even when .alias is absent" {
  cat > "$REPORT_PATH" <<'JSON'
[
  {"project":"product-a","label":"codex","workdir":"/work/a/codex","ready":1,"status":"ready"}
]
JSON
  touch "$REPORT_PATH"

  run run_status codex product-a /work/a/codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
  [[ "$output" == *"rc=0"* ]]
}
