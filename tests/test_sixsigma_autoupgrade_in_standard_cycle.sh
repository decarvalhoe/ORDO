#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"
PROMPT_FILE="/tmp/dispatch-cursor-9437.md"

cleanup() {
  rm -rf "$TEST_TMP"
  rm -f "$PROMPT_FILE"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/logs" "$TEST_TMP/state"

for rel in \
  scripts/cycle.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/host_load_gate.sh \
  lib/process_safety.sh \
  lib/host_forensics.sh \
  lib/state_persist.sh
do
  mkdir -p "$SANITIZED_ROOT/$(dirname "$rel")"
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/cycle.sh"

for stub in check_ci_health audit_state smart_poll_agents dispatch_ticket integrate_wave; do
  cat > "$SANITIZED_ROOT/scripts/${stub}.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$stub" "\$*" >> "$TEST_TMP/logs/cycle-calls.log"
exit 0
EOF
  chmod +x "$SANITIZED_ROOT/scripts/${stub}.sh"
done

cat > "$TEST_TMP/ordo.config.sh" <<EOF
PROJECT="standard-cycle-sixsigma-test"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

printf '# stub dispatch prompt\n' > "$PROMPT_FILE"

write_sixsigma_stub() {
  local exit_status=${1:?usage: write_sixsigma_stub <exit-status>}
  cat > "$SANITIZED_ROOT/scripts/sixsigma_autoupgrade.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'sixsigma_autoupgrade %s\n' "\$*" >> "$TEST_TMP/logs/cycle-calls.log"
exit $exit_status
EOF
  chmod +x "$SANITIZED_ROOT/scripts/sixsigma_autoupgrade.sh"
}

run_standard_cycle() {
  local cycle_id=${1:?usage: run_standard_cycle <cycle-id>}
  : > "$TEST_TMP/logs/cycle-calls.log"
  : > "$TEST_TMP/logs/standard-cycle-sixsigma-test.log"
  env -u ORCH_DRY_RUN \
    ORCH_LOG_DIR="$TEST_TMP/logs" \
    ORCH_STATE_BASE="$TEST_TMP/state" \
    bash "$SANITIZED_ROOT/scripts/cycle.sh" "$TEST_TMP/ordo.config.sh" \
      "$cycle_id" 9437:cursor --dry-run 2>&1
}

assert_sixsigma_evidence_row() {
  local cycle_id=${1:?usage: assert_sixsigma_evidence_row <cycle-id> <status-word>}
  local status_word=${2:?usage: assert_sixsigma_evidence_row <cycle-id> <status-word>}
  local audit_log="$TEST_TMP/logs/standard-cycle-sixsigma-test.log"

  grep -q '^sixsigma_autoupgrade .*--dry-run' "$TEST_TMP/logs/cycle-calls.log" \
    || fail "standard-cycle exit must invoke sixsigma_autoupgrade dry-run; no entrypoint call was recorded for cycle id $cycle_id"
  grep -Eq "CYCLE ${cycle_id} SIXSIGMA ${status_word} .*project=standard-cycle-sixsigma-test" "$audit_log" \
    || fail "standard-cycle exit must emit a sixsigma evidence row tagged with cycle id $cycle_id and status $status_word"
}

write_sixsigma_stub 0
set +e
output=$(run_standard_cycle "STD437A")
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "standard cycle should exit 0 when sixsigma succeeds (got: $status, output: $output)"
assert_sixsigma_evidence_row "STD437A" "OK"

write_sixsigma_stub 9
set +e
output=$(run_standard_cycle "STD437B")
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "standard cycle should continue when sixsigma fails (got: $status, output: $output)"
assert_sixsigma_evidence_row "STD437B" "WARN"
grep -q '^integrate_wave ' "$TEST_TMP/logs/cycle-calls.log" \
  || fail "standard cycle must continue to integrate after sixsigma WARN"

printf 'ok - standard cycle emits sixsigma autoupgrade evidence tagged with cycle id\n'
