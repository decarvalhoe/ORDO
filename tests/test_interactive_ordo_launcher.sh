#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$ROOT/examples/start-ordo-loop.sh"
TEST_TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

[[ -x "$WRAPPER" ]] || fail "interactive ORDO launcher template must be executable"

wrapper_code=$(grep -Ev '^[[:space:]]*(#|$)' "$WRAPPER")

if grep -Eq '(^|[[:space:]])exec[[:space:]]+' <<< "$wrapper_code"; then
  fail "interactive ORDO launcher must not exec-replace the operator session"
fi

if grep -Eq 'tmux[[:space:]]+run-shell|tmux[[:space:]]+(display-popup|split-window|new-window)|(^|[[:space:]])(nohup|setsid)[[:space:]]+' <<< "$wrapper_code"; then
  fail "interactive ORDO launcher must not detach ORDO through tmux/nohup/setsid"
fi

if grep -Eq '&[[:space:]]*($|#)' <<< "$wrapper_code"; then
  fail "interactive ORDO launcher must run ORDO in the foreground"
fi

mkdir -p "$TEST_TMP/supervisor"
full_config="$TEST_TMP/full.config.sh"
cat > "$full_config" <<'CFG'
#!/usr/bin/env bash
AGENT_PANES=(
  "agent-001|fleet-001:0.0|/tmp/fleet-001"
  "agent-002|fleet-002:0.0|/tmp/fleet-002"
)
CFG
stub_loop="$TEST_TMP/full-loop.sh"
cat > "$stub_loop" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'stub-loop-cwd=%s\n' "$PWD"
printf 'stub-loop-parent=%s\n' "$PPID"
STUB
chmod +x "$stub_loop"

output=$(
  ORDO_SUPERVISOR_ROOT="$TEST_TMP/supervisor" \
  ORDO_FULL_LOOP="$stub_loop" \
  ORDO_FULL_CONFIG="$full_config" \
  ORDO_FULL_MIN_AGENTS=2 \
  "$WRAPPER"
)

[[ "$output" == *"foreground interactive"* ]] || \
  fail "launcher should identify the foreground interactive path: $output"
[[ "$output" == *"stub-loop-cwd=$TEST_TMP/supervisor"* ]] || \
  fail "launcher should execute the loop from the supervisor root: $output"

set +e
partial_output=$(
  ORDO_SUPERVISOR_ROOT="$TEST_TMP/supervisor" \
  ORDO_FULL_LOOP="$stub_loop" \
  ORDO_FULL_CONFIG="$full_config" \
  ORDO_FULL_MIN_AGENTS=3 \
  "$WRAPPER" 2>&1
)
partial_status=$?
set -e
[[ "$partial_status" -eq 14 ]] || \
  fail "launcher should refuse partial fleet config, got status=$partial_status output=$partial_output"
[[ "$partial_output" == *"refused partial fleet"* ]] || \
  fail "launcher should explain partial fleet refusal: $partial_output"

set +e
selector_output=$(
  ORDO_SUPERVISOR_ROOT="$TEST_TMP/supervisor" \
  ORDO_FULL_LOOP="$stub_loop" \
  ORDO_FULL_CONFIG="$full_config" \
  ORDO_AGENT_ALLOWLIST=agent-001 \
  "$WRAPPER" 2>&1
)
selector_status=$?
set -e
[[ "$selector_status" -eq 14 ]] || \
  fail "launcher should refuse agent selectors, got status=$selector_status output=$selector_output"
[[ "$selector_output" == *"refused agent cherry-pick selector ORDO_AGENT_ALLOWLIST"* ]] || \
  fail "launcher should name the refused selector: $selector_output"

set +e
args_output=$(
  ORDO_SUPERVISOR_ROOT="$TEST_TMP/supervisor" \
  ORDO_FULL_LOOP="$stub_loop" \
  ORDO_FULL_CONFIG="$full_config" \
  "$WRAPPER" agent-001 2>&1
)
args_status=$?
set -e
[[ "$args_status" -eq 14 ]] || \
  fail "launcher should refuse positional partial launch args, got status=$args_status output=$args_output"

printf 'ok - interactive ORDO launcher preserves the operator session contract\n'
