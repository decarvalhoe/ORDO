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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$SANITIZED_ROOT/examples" "$TEST_TMP/bin"

for rel in \
  scripts/recover.sh \
  scripts/state_rollback.sh \
  scripts/orch_ctl.sh \
  lib/audit_log.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/process_safety.sh \
  lib/state_persist.sh \
  lib/tmux_helpers.sh \
  lib/worktree_helpers.sh \
  examples/realisons-wp.config.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

chmod +x \
  "$SANITIZED_ROOT/scripts/recover.sh" \
  "$SANITIZED_ROOT/scripts/state_rollback.sh" \
  "$SANITIZED_ROOT/scripts/orch_ctl.sh"

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
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

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
[[ "$ctl_output" == *"project:        realisons-wp"* ]] || fail "orch_ctl alias mode should resolve realisons-wp config"

printf 'ok - config resolver preserves legacy behavior and supports universal config args\n'
