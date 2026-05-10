#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/ci.yml"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP/logs" ]]; then
    for log_file in "$TEST_TMP"/logs/*; do
      [[ -s "$log_file" ]] || continue
      printf -- '--- %s ---\n' "$(basename "$log_file")" >&2
      sed -n '1,80p' "$log_file" >&2
    done
  fi
  exit 1
}

[[ -f "$WORKFLOW" ]] || fail "expected $WORKFLOW to exist"

content=$(tr -d '\r' < "$WORKFLOW")

[[ "$content" == *"pull_request:"* ]] || fail "workflow must run on pull_request"
[[ "$content" == *"push:"* ]] || fail "workflow must run on push"
[[ "$content" == *"scripts/run_shellcheck.sh"* ]] || fail "workflow must run the shellcheck runner"
[[ "$content" == *"scripts/run_shell_tests.sh"* ]] || fail "workflow must run the shell test runner"
[[ "$content" == *"scripts/run_bats.sh"* ]] || fail "workflow must run the bats runner"

TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/logs" "$TEST_TMP/state" "$TEST_TMP/gh"

for rel in \
  scripts/ci_watcher_daemon.sh \
  lib/audit_log.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/log_bounds.sh \
  lib/state_persist.sh
do
  mkdir -p "$(dirname "$SANITIZED_ROOT/$rel")"
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/ci_watcher_daemon.sh"

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "run list")
    printf '[{"databaseId":1001,"name":"toolkit-ci","conclusion":"failure","status":"completed","headSha":"abcdef1234567890"}]\n'
    ;;
  *)
    printf 'unexpected gh invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

cat > "$TEST_TMP/bin/jq" <<'EOF'
#!/usr/bin/env bash
printf '1001|toolkit-ci|failure|abcdef1\n'
EOF
chmod +x "$TEST_TMP/bin/jq"

cat > "$TEST_TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >> "${SLEEP_LOG:?}"
case "${1:-}" in
  0.3|0.5)
    exit 0
    ;;
  *)
    exit 42
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/sleep"

cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TMUX_LOG:?}"
target=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "-t" ]]; then
    next=$((i + 1))
    target="${!next:-}"
  fi
done
case "${1:-}" in
  has-session)
    exit 0
    ;;
  display-message)
    if [[ "${*: -1}" == "#{pane_current_path}" ]]; then
      printf '%s\n' "${TMUX_PANE_CWD:-$TEST_TMP/supervisor}"
    else
      printf '%s\n' "$target"
    fi
    ;;
  send-keys)
    exit 0
    ;;
  *)
    printf 'unexpected tmux invocation: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/tmux"

write_watcher_config() {
  local name=${1:?usage: write_watcher_config <name> <prefix> <supervisor>}
  local prefix=${2-}
  local supervisor=${3-}
  cat > "$TEST_TMP/$name.config.sh" <<EOF
PROJECT="ci-watcher-$name"
GH_REPO="example/repo"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$TEST_TMP/gh"
ORCH_LOG_DIR="$TEST_TMP/logs"
ORCH_STATE_BASE="$TEST_TMP/state"
AGENT_SESSION_PREFIX="$prefix"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/work/%s"
SUPERVISOR_REPO="$supervisor"
PROJECT_REPO_ROOT="$supervisor"
AUDIT_LOG_FILE="$TEST_TMP/logs/$name.log"
EOF
  printf '%s\n' "$TEST_TMP/$name.config.sh"
}

run_watcher_once() {
  local config=${1:?usage: run_watcher_once <config>}
  local name=${2:?usage: run_watcher_once <config> <name> [target] [cwd]}
  local target=${3-}
  local cwd=${4:-$TEST_TMP/supervisor}
  : > "$TEST_TMP/logs/$name.tmux.log"
  : > "$TEST_TMP/logs/$name.sleep.log"
  set +e
  PATH="$TEST_TMP/bin:$PATH" \
    CI_WATCHER_ORCH_PANE="$target" \
    TMUX_LOG="$TEST_TMP/logs/$name.tmux.log" \
    SLEEP_LOG="$TEST_TMP/logs/$name.sleep.log" \
    TMUX_PANE_CWD="$cwd" \
    timeout 5 bash "$SANITIZED_ROOT/scripts/ci_watcher_daemon.sh" "$config" \
      > "$TEST_TMP/logs/$name.out" 2>&1
  local status=$?
  set -e
  [[ "$status" -ne 124 ]] || fail "watcher timed out in $name"
}

legacy_cfg=$(write_watcher_config legacy "" "$TEST_TMP/supervisor")
run_watcher_once "$legacy_cfg" legacy "orch"
grep -q '^send-keys -t orch:0 C-u$' "$TEST_TMP/logs/legacy.tmux.log" \
  || fail "session-only watcher target should keep legacy orch:0 send target"
grep -q 'CI WATCHER notification sent to orch:0' "$TEST_TMP/logs/legacy.out" \
  || fail "session-only watcher audit should record normalized target"

exact_cfg=$(write_watcher_config exact "" "$TEST_TMP/supervisor")
run_watcher_once "$exact_cfg" exact "rbok-orchestrator:1.0"
grep -q '^send-keys -t rbok-orchestrator:1.0 C-u$' "$TEST_TMP/logs/exact.tmux.log" \
  || fail "exact watcher target should be used verbatim"
if grep -q 'rbok-orchestrator:1.0:0' "$TEST_TMP/logs/exact.tmux.log"; then
  fail "exact watcher target must not append :0"
fi
grep -q 'CI WATCHER notification sent to rbok-orchestrator:1.0' "$TEST_TMP/logs/exact.out" \
  || fail "exact watcher audit should record exact tmux target"

unsafe_default_cfg=$(write_watcher_config unsafe-default "" "$TEST_TMP/ordo-supervisor")
run_watcher_once "$unsafe_default_cfg" unsafe-default "" "$TEST_TMP/RBOK-orch"
if grep -q '^send-keys ' "$TEST_TMP/logs/unsafe-default.tmux.log"; then
  fail "unsafe default orch target should be refused before send-keys"
fi
grep -q 'CI WATCHER WARN: default orch target refused' "$TEST_TMP/logs/unsafe-default.out" \
  || fail "unsafe default orch target should audit refusal"

printf 'ok - ci workflow wires repo runners and ci watcher targets exact panes\n'
