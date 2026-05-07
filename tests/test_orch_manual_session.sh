#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"
CALL_LOG="$TEST_TMP/calls.log"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts"
tr -d '\r' < "$ROOT/scripts/orch_manual_session.sh" > "$SANITIZED_ROOT/scripts/orch_manual_session.sh"
chmod +x "$SANITIZED_ROOT/scripts/orch_manual_session.sh"

for script_name in audit_state.sh project_meta_context.sh check_ci_health.sh dispatch_plan.sh; do
  cat > "$SANITIZED_ROOT/scripts/$script_name" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$script_name \$*" >> "$CALL_LOG"
EOF
  chmod +x "$SANITIZED_ROOT/scripts/$script_name"
done

bash "$SANITIZED_ROOT/scripts/orch_manual_session.sh" demo

expected=$'audit_state.sh demo\nproject_meta_context.sh demo\ncheck_ci_health.sh demo\ndispatch_plan.sh demo --ready-only'
actual=$(cat "$CALL_LOG")
[[ "$actual" == "$expected" ]] || fail "manual session should run the documented one-shot sequence, got: $actual"
[[ "$actual" != *"orch_loop.sh"* ]] || fail "manual session must not invoke orch_loop"

printf 'ok - orch_manual_session runs the in-session checklist only\n'
