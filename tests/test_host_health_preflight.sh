#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TEST_TMP/log/journal" "$TEST_TMP/bin"
printf 'alpha\n' > "$TEST_TMP/log/wtmp"
printf 'beta\n' > "$TEST_TMP/log/wtmp.1"
printf 'demo\n' > "$TEST_TMP/log/journal/demo.journal"
cat > "$TEST_TMP/sessions.txt" <<'EOF'
1 alpha seat0
2 beta seat0
3 demo seat0
EOF
: > "$TEST_TMP/empty-sessions.txt"

warning_output=$(
  TK="$ROOT" \
  HOST_HEALTH_LOG_DIR="$TEST_TMP/log" \
  HOST_HEALTH_SESSION_COUNT_FILE="$TEST_TMP/sessions.txt" \
  HOST_HEALTH_WTMP_WARN_MB=0 \
  HOST_HEALTH_WTMP_MAX_MB=99 \
  HOST_HEALTH_JOURNAL_WARN_MB=0 \
  HOST_HEALTH_JOURNAL_MAX_MB=99 \
  HOST_HEALTH_VAR_LOG_WARN_MB=0 \
  HOST_HEALTH_VAR_LOG_MAX_MB=99 \
  HOST_HEALTH_VAR_LOG_PCT=81 \
  HOST_HEALTH_VAR_LOG_WARN_PCT=80 \
  HOST_HEALTH_VAR_LOG_MAX_PCT=90 \
  HOST_HEALTH_SESSION_WARN=2 \
  HOST_HEALTH_SESSION_MAX=99 \
    bash "$ROOT/scripts/host_health_preflight.sh"
)

[[ "$warning_output" == *"metric=wtmp_mb"*"status=warning"* || "$warning_output" == *"status=warning metric=wtmp_mb"* ]] \
  || fail "expected wtmp warning, got: $warning_output"
[[ "$warning_output" == *"metric=host_sessions value=3"*"status=warning"* || "$warning_output" == *"status=warning metric=host_sessions value=3"* ]] \
  || fail "expected session warning, got: $warning_output"
[[ "$warning_output" == *"HOST_HEALTH summary=warning"* ]] \
  || fail "expected warning summary, got: $warning_output"
[[ "$warning_output" == *"host_sessions_warning"* ]] \
  || fail "expected session signal, got: $warning_output"

set +e
critical_output=$(
  TK="$ROOT" \
  HOST_HEALTH_LOG_DIR="$TEST_TMP/log" \
  HOST_HEALTH_SESSION_COUNT_FILE="$TEST_TMP/sessions.txt" \
  HOST_HEALTH_WTMP_WARN_MB=0 \
  HOST_HEALTH_WTMP_MAX_MB=0 \
  HOST_HEALTH_JOURNAL_WARN_MB=99 \
  HOST_HEALTH_JOURNAL_MAX_MB=100 \
  HOST_HEALTH_VAR_LOG_WARN_MB=99 \
  HOST_HEALTH_VAR_LOG_MAX_MB=100 \
  HOST_HEALTH_VAR_LOG_PCT=91 \
  HOST_HEALTH_VAR_LOG_WARN_PCT=80 \
  HOST_HEALTH_VAR_LOG_MAX_PCT=90 \
  HOST_HEALTH_SESSION_WARN=1 \
  HOST_HEALTH_SESSION_MAX=2 \
    bash "$ROOT/scripts/host_health_preflight.sh" --refuse
)
critical_status=$?
set -e

[[ "$critical_status" -eq 7 ]] || fail "expected --refuse critical exit 7, got $critical_status: $critical_output"
[[ "$critical_output" == *"status=critical metric=wtmp_mb"* ]] \
  || fail "expected critical wtmp metric, got: $critical_output"
[[ "$critical_output" == *"status=critical metric=host_sessions value=3"* ]] \
  || fail "expected critical session metric, got: $critical_output"
[[ "$critical_output" == *"wtmp_mb_critical"* ]] \
  || fail "expected critical signal, got: $critical_output"

ok_output=$(
  TK="$ROOT" \
  HOST_HEALTH_LOG_DIR="$TEST_TMP/missing-log-dir" \
  HOST_HEALTH_SESSION_COUNT_FILE="$TEST_TMP/empty-sessions.txt" \
  HOST_HEALTH_VAR_LOG_PCT=1 \
  HOST_HEALTH_WTMP_WARN_MB=10 \
  HOST_HEALTH_WTMP_MAX_MB=20 \
  HOST_HEALTH_JOURNAL_WARN_MB=10 \
  HOST_HEALTH_JOURNAL_MAX_MB=20 \
  HOST_HEALTH_VAR_LOG_WARN_MB=10 \
  HOST_HEALTH_VAR_LOG_MAX_MB=20 \
  HOST_HEALTH_VAR_LOG_WARN_PCT=80 \
  HOST_HEALTH_VAR_LOG_MAX_PCT=90 \
  HOST_HEALTH_SESSION_WARN=10 \
  HOST_HEALTH_SESSION_MAX=20 \
    bash "$ROOT/scripts/host_health_preflight.sh"
)

[[ "$ok_output" == *"HOST_HEALTH summary=ok"* ]] || fail "expected ok summary, got: $ok_output"

printf 'ok - host_health_preflight detects bounded log and session thresholds\n'
