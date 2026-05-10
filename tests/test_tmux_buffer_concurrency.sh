#!/usr/bin/env bash
# tests/test_tmux_buffer_concurrency.sh — coverage for ORDO #595.
#
# `lib/tmux_helpers.sh::send_to_pane` MUST use a per-invocation unique
# tmux buffer name so concurrent calls don't cross-paste briefs into
# the wrong panes. The bug: a single shared buffer (`orch_send`) was
# overwritten between load-buffer and paste-buffer when two dispatchers
# raced.
#
# Approach: stub `tmux` to record every load-buffer + paste-buffer call
# with a timestamp, run two concurrent send_to_pane invocations, and
# assert that:
#   1. Each invocation uses a DISTINCT buffer name (no `orch_send` shared
#      buffer remains in the call sequence).
#   2. The buffer name passed to load-buffer matches the one passed to
#      paste-buffer for the SAME pane (correct text→pane pairing).

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

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/logs"

# tmux stub: record every invocation with epoch-ns timestamp +
# attempted buffer name (-b flag value).
cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
# Tag every tmux call with a nanosecond timestamp + the args.
ts=\$(date -u +%s%N 2>/dev/null || date -u +%s)
printf '%s tmux %s\n' "\$ts" "\$*" >> "$TEST_TMP/logs/tmux.log"
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

# Source the helper and tmux_helpers.sh so send_to_pane is in scope.
# audit() is defined in audit_log.sh which itself requires PROJECT;
# we provide a minimal stub directly to avoid pulling the whole
# audit subsystem into a unit test.
cat > "$TEST_TMP/run.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
audit() { :; }  # silence audit_log calls inside the helper
ORCH_TMUX_TIMEOUT_SEC=5
ORCH_TMUX_SEND_ENTER_DELAY_SEC=0
# shellcheck source=/dev/null
source "$ROOT/lib/tmux_helpers.sh"

PATH="$TEST_TMP/bin:\$PATH" send_to_pane "\$1" "\$2"
EOF
chmod +x "$TEST_TMP/run.sh"

# Race two dispatches in parallel, each into a distinct pane with a
# distinct payload. Without the fix they'd cross-paste because the
# shared buffer would be overwritten between load-buffer (pane A) and
# paste-buffer (pane A).
"$TEST_TMP/run.sh" "pane-A" "PAYLOAD-A-${RANDOM}" &
PID_A=$!
"$TEST_TMP/run.sh" "pane-B" "PAYLOAD-B-${RANDOM}" &
PID_B=$!

wait "$PID_A" || fail "send_to_pane A exited non-zero"
wait "$PID_B" || fail "send_to_pane B exited non-zero"

# 1. The shared buffer name `orch_send` (without suffix) must NOT
#    appear as a buffer argument on its own. The fix uses
#    `orch_send_<pid>_<rand>_<ns>`. We accept the prefix but not
#    the bare token.
if grep -E ' load-buffer -b orch_send ' "$TEST_TMP/logs/tmux.log" >/dev/null; then
  fail "shared buffer 'orch_send' detected in load-buffer call : $(cat "$TEST_TMP/logs/tmux.log")"
fi
if grep -E ' paste-buffer -b orch_send -t' "$TEST_TMP/logs/tmux.log" >/dev/null; then
  fail "shared buffer 'orch_send' detected in paste-buffer call : $(cat "$TEST_TMP/logs/tmux.log")"
fi

# 2. Extract the buffer names used per pane and assert they are unique
#    and that load/paste pairs match. We expect exactly two distinct
#    buffer names, each used twice: once for load-buffer, once for
#    paste-buffer.
mapfile -t buffer_names < <(grep -oE 'orch_send_[0-9_]+' "$TEST_TMP/logs/tmux.log" | sort -u)
if [ "${#buffer_names[@]}" -lt 2 ]; then
  fail "expected >=2 distinct buffer names, got ${#buffer_names[@]}: ${buffer_names[*]} | log: $(cat "$TEST_TMP/logs/tmux.log")"
fi

# Pair check: each unique buffer name should appear exactly once in a
# load-buffer line and exactly once in a paste-buffer line.
for name in "${buffer_names[@]}"; do
  load_count=$(grep -cE " load-buffer -b ${name} " "$TEST_TMP/logs/tmux.log" || true)
  paste_count=$(grep -cE " paste-buffer -b ${name} -t" "$TEST_TMP/logs/tmux.log" || true)
  if [ "$load_count" -ne 1 ] || [ "$paste_count" -ne 1 ]; then
    fail "buffer $name expected 1 load + 1 paste, got load=$load_count paste=$paste_count"
  fi
done

printf 'ok - send_to_pane uses unique tmux buffer per invocation (concurrency-safe)\n'
