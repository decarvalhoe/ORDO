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

mkdir -p "$TEST_TMP/bin"
mkdir -p "$TEST_TMP/tmp"
cat > "$TEST_TMP/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JOURNALCTL_ARGS_FILE"
case "${JOURNALCTL_MODE:-ok}" in
  timeout)
    sleep 5
    ;;
  fail)
    printf 'journal failure\n' >&2
    exit 2
    ;;
  *)
    printf 'line-one\n'
    printf 'line-two\n'
    printf 'line-three\n'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/journalctl"

args_file="$TEST_TMP/journal.args"

bounded_output=$(
  TMPDIR="$TEST_TMP/tmp" \
  PATH="$TEST_TMP/bin:$PATH" \
  JOURNALCTL_ARGS_FILE="$args_file" \
  ORCH_HOST_FORENSICS_TIMEOUT_SEC=2 \
  ORCH_HOST_FORENSICS_JOURNAL_LINES=2 \
  ORCH_HOST_FORENSICS_JOURNAL_MAX_LINES=4 \
  ORCH_HOST_FORENSICS_JOURNAL_SINCE="-20 min" \
  ORCH_HOST_FORENSICS_JOURNAL_UNTIL="now" \
    bash "$ROOT/scripts/host_forensics_probe.sh" journal -u demo.service
)

[[ "$bounded_output" == $'line-one\nline-two' ]] \
  || fail "expected output to be capped at two lines, got: $bounded_output"
if compgen -G "$TEST_TMP/tmp/host-forensics.*" >/dev/null; then
  fail "expected host_forensics_probe cleanup trap to remove temp directories"
fi
args=$(cat "$args_file")
[[ "$args" == *"--no-pager"* ]] || fail "expected --no-pager, got: $args"
[[ "$args" == *"--since -20 min"* ]] || fail "expected default since window, got: $args"
[[ "$args" == *"--until now"* ]] || fail "expected default until window, got: $args"
[[ "$args" == *"-n 2"* ]] || fail "expected default line cap, got: $args"
[[ "$args" == *"-u demo.service"* ]] || fail "expected journal filter to pass through, got: $args"

set +e
wildcard_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  JOURNALCTL_ARGS_FILE="$args_file" \
  ORCH_HOST_FORENSICS_JOURNAL_LINES=2 \
  ORCH_HOST_FORENSICS_JOURNAL_MAX_LINES=4 \
    bash "$ROOT/scripts/host_forensics_probe.sh" journal --user-unit '*' 2>&1
)
wildcard_status=$?
set -e
[[ "$wildcard_status" -eq 75 ]] \
  || fail "expected wildcard user-unit refusal exit 75, got $wildcard_status: $wildcard_output"
[[ "$wildcard_output" == *"host_forensics_degraded"* && "$wildcard_output" == *"wildcard_user_unit"* ]] \
  || fail "expected wildcard degraded output, got: $wildcard_output"

set +e
line_limit_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  JOURNALCTL_ARGS_FILE="$args_file" \
  ORCH_HOST_FORENSICS_JOURNAL_LINES=2 \
  ORCH_HOST_FORENSICS_JOURNAL_MAX_LINES=4 \
    bash "$ROOT/scripts/host_forensics_probe.sh" journal --lines 9 2>&1
)
line_limit_status=$?
set -e
[[ "$line_limit_status" -eq 75 ]] \
  || fail "expected line limit refusal exit 75, got $line_limit_status: $line_limit_output"
[[ "$line_limit_output" == *"line_limit_exceeded"* ]] \
  || fail "expected line limit degraded output, got: $line_limit_output"

set +e
timeout_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  JOURNALCTL_ARGS_FILE="$args_file" \
  JOURNALCTL_MODE=timeout \
  ORCH_HOST_FORENSICS_TIMEOUT_SEC=1 \
  ORCH_HOST_FORENSICS_JOURNAL_LINES=2 \
  ORCH_HOST_FORENSICS_JOURNAL_MAX_LINES=4 \
    bash "$ROOT/scripts/host_forensics_probe.sh" journal -u demo.service 2>&1
)
timeout_status=$?
set -e
[[ "$timeout_status" -eq 75 ]] \
  || fail "expected timeout refusal exit 75, got $timeout_status: $timeout_output"
[[ "$timeout_output" == *"host_forensics_degraded"* && "$timeout_output" == *"reason=timeout"* ]] \
  || fail "expected timeout degraded output, got: $timeout_output"

printf 'ok - host_forensics_probe bounds journal probes\n'
