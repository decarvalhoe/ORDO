#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TEST_TMP/bin"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/recover.sh \
  scripts/state_rollback.sh \
  scripts/orch_ctl.sh \
  scripts/audit_state.sh \
  examples/web.config.sh \
  examples/rbok.config.sh

chmod +x \
  "$SANITIZED_ROOT/scripts/recover.sh" \
  "$SANITIZED_ROOT/scripts/state_rollback.sh" \
  "$SANITIZED_ROOT/scripts/orch_ctl.sh" \
  "$SANITIZED_ROOT/scripts/audit_state.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="cfg-resolve-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_WINDOW_INDEX=0
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "has-session" ]]; then
  exit 0
fi
if [[ "\${1:-}" == "capture-pane" ]]; then
  printf 'idle\n'
  exit 0
fi
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '[]\n'
EOF
chmod +x "$TEST_TMP/bin/gh"

mkdir -p "$TEST_TMP/state/cfg-resolve-test" "$TEST_TMP/logs" "$TEST_TMP/repos/claude"
cat > "$TEST_TMP/state/cfg-resolve-test/assignments.json" <<'JSON'
{"claude":{"issue":42},"codex":{"issue":7}}
JSON

set +e
recover_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/recover.sh" "$TEST_TMP/test.config.sh" claude --reset-state 2>&1
)
recover_status=$?
set -e

[[ "$recover_status" -eq 0 ]] || fail "recover should accept a config path, got: $recover_output"
jq -e '(has("claude") | not) and (.codex.issue == 7)' \
  "$TEST_TMP/state/cfg-resolve-test/assignments.json" >/dev/null || fail "recover path mode should clear the targeted assignment"

snapshot_dir="$TEST_TMP/state/snapshots"
mkdir -p "$snapshot_dir"
printf 'dummy\n' > "$snapshot_dir/cfg-resolve-test-20260506T100000Z.tar.gz"
(cd "$snapshot_dir" && sha256sum "cfg-resolve-test-20260506T100000Z.tar.gz" > "cfg-resolve-test-20260506T100000Z.tar.gz.sha256")

set +e
rollback_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/state_rollback.sh" "$TEST_TMP/test.config.sh" --list 2>&1
)
rollback_status=$?
set -e

[[ "$rollback_status" -eq 0 ]] || fail "state_rollback should accept a config path, got: $rollback_output"
[[ "$rollback_output" == *"cfg-resolve-test-20260506T100000Z.tar.gz"* ]] || fail "state_rollback path mode should list snapshots"

set +e
ctl_output=$(
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/orch_ctl.sh" wp status 2>&1
)
ctl_status=$?
set -e

[[ "$ctl_status" -eq 0 ]] || fail "orch_ctl should accept wp alias, got: $ctl_output"
[[ "$ctl_output" == *"project:        project-web"* ]] || fail "orch_ctl alias mode should resolve web sample config"

operator_home="$TEST_TMP/home"
mkdir -p "$operator_home/.config/ordo"
cat > "$operator_home/.config/ordo/rbok" <<EOF
#!/usr/bin/env bash
PROJECT="rbok"
GH_REPO="RBOKproject/RBOK"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
AGENT_PANES=("RBOK-live|rbok-live:0.0|$TEST_TMP/repos/rbok-live")
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

set +e
operator_resolved=$(
  HOME="$operator_home" bash -c "
    source '$SANITIZED_ROOT/lib/config_resolver.sh'
    resolve_config_path rbok
  " 2>&1
)
operator_status=$?
set -e

[[ "$operator_status" -eq 0 ]] || fail "resolve_config_path rbok should accept operator profile, got: $operator_resolved"
[[ "$operator_resolved" == "$operator_home/.config/ordo/rbok" ]] || fail "rbok shorthand should prefer operator profile, got: $operator_resolved"

set +e
operator_loaded=$(
  HOME="$operator_home" bash -c "
    source '$SANITIZED_ROOT/lib/config_resolver.sh'
    load_project_config rbok
    printf '%s|%s\n' \"\$PROJECT\" \"\$ORCH_CONFIG_PATH\"
  " 2>&1
)
operator_loaded_status=$?
set -e

[[ "$operator_loaded_status" -eq 0 ]] || fail "load_project_config rbok should load operator profile, got: $operator_loaded"
[[ "$operator_loaded" == "rbok|$operator_home/.config/ordo/rbok" ]] || fail "load_project_config rbok loaded wrong profile: $operator_loaded"

sample_rbok="$SANITIZED_ROOT/examples/rbok.config.sh"
set +e
sample_resolved=$(
  HOME="$operator_home" bash -c "
    source '$SANITIZED_ROOT/lib/config_resolver.sh'
    resolve_config_path '$sample_rbok'
  " 2>&1
)
sample_status=$?
set -e

[[ "$sample_status" -eq 0 ]] || fail "explicit sample config path should still resolve, got: $sample_resolved"
[[ "$sample_resolved" == "$sample_rbok" ]] || fail "explicit sample config path changed unexpectedly: $sample_resolved"

set +e
audit_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  HOME="$operator_home" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/audit_state.sh" rbok 2>&1
)
audit_status=$?
set -e

[[ "$audit_status" -eq 0 ]] || fail "audit_state rbok should run with operator profile, got: $audit_output"
[[ "$audit_output" == *"project:        rbok"* ]] || fail "audit_state should print loaded project, got: $audit_output"
[[ "$audit_output" == *"config:         $operator_home/.config/ordo/rbok"* ]] || fail "audit_state should print resolved config path, got: $audit_output"

printf 'ok - config resolver preserves legacy behavior and supports universal config args\n'
