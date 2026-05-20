#!/usr/bin/env bash
# tests/test_dispatch_ticket_submit_policy.sh
#
# Issue #758: claude CLI's terminal input editor consumes the trailing
# `Enter` from `tmux send-keys "<brief>" Enter` as a line terminator,
# NOT as the submit action. The brief sits at `❯ <brief...>` and the
# dispatcher's prompt-execution-proof check classifies the dispatch as
# `submission-still-visible` even though the pane and CLI are healthy.
#
# This test covers the patched submit-policy contract:
#
#   1. `agent_submit_policy claude` returns `double-enter`.
#   2. `agent_submit_policy codex`  returns `single-enter`.
#   3. `agent_submit_policy_apply <pane> claude` issues the extra
#      `send-keys Enter` after the configured millisecond delay.
#   4. `agent_submit_policy_apply <pane> codex` is a no-op (single-Enter
#      CLIs preserve historical behavior).
#   5. End-to-end through `terminal_dispatch_submit_once` with cli=claude
#      a `tmux send-keys recorder` observes TWO Enter keystrokes
#      (one from `send_to_pane`, one from the policy).
#   6. End-to-end through `terminal_dispatch_submit_once` with cli=codex
#      only ONE Enter keystroke is observed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------------
# Source the helpers under test. tmux_helpers.sh must be sourced first
# so worktree_helpers.sh sees `terminal_dispatch_submit_once` and the
# `send_to_pane` symbol it relies on, then installs the per-CLI wrapper.
# ---------------------------------------------------------------------
# shellcheck source=../lib/audit_log.sh
audit() { :; }
# shellcheck source=../lib/tmux_helpers.sh
source "$ROOT/lib/tmux_helpers.sh"
# shellcheck source=../lib/worktree_helpers.sh
source "$ROOT/lib/worktree_helpers.sh"

# Run the second Enter immediately so the test does not stall on sleep.
export ORCH_CLAUDE_SUBMIT_SECOND_ENTER_MS=0
# Keep send_to_pane's intra-call delay zero so the test is fast.
export ORCH_TMUX_SEND_ENTER_DELAY_SEC=0

# --- Case 1 & 2 : pure policy lookup ---------------------------------
policy=$(agent_submit_policy claude)
[[ "$policy" == "double-enter" ]] \
  || fail "expected agent_submit_policy claude=double-enter, got=$policy"

policy=$(agent_submit_policy codex)
[[ "$policy" == "single-enter" ]] \
  || fail "expected agent_submit_policy codex=single-enter, got=$policy"

# Unknown CLIs preserve historical single-Enter behavior.
policy=$(agent_submit_policy mysteryctl)
[[ "$policy" == "single-enter" ]] \
  || fail "expected agent_submit_policy mysteryctl=single-enter, got=$policy"

printf 'ok - agent_submit_policy returns expected gestures per CLI\n'

# --- Recorder tmux stub ----------------------------------------------
# Replaces the real tmux binary in-process. Every invocation appends
# its arguments to TMUX_RECORDER so assertions can count Enter
# keystrokes after each scenario. The stub responds successfully to
# load-buffer / paste-buffer / send-keys / delete-buffer so the helpers
# proceed past their tmux_run_timeout checks.
TMUX_RECORDER="$TEST_TMP/tmux.log"
: > "$TMUX_RECORDER"

tmux() {
  printf '%s\n' "$*" >> "$TMUX_RECORDER"
  case "${1:-}" in
    capture-pane)
      printf '%s\n' "stub-pane idle"
      ;;
  esac
  return 0
}
export -f tmux

reset_recorder() { : > "$TMUX_RECORDER"; }
enter_count() {
  # `grep -c` exits 1 (with stdout "0") when there are zero matches, so
  # swallow that exit to keep the helper safe under `set -e`.
  local n
  n=$(grep -c '^send-keys -t test-pane:0.0 Enter$' "$TMUX_RECORDER" 2>/dev/null) || n=0
  printf '%s' "$n"
}

# --- Case 3 : double-enter policy issues the trailing Enter ----------
reset_recorder
agent_submit_policy_apply 'test-pane:0.0' claude
n=$(enter_count)
[[ "$n" -eq 1 ]] \
  || fail "double-enter policy should send 1 trailing Enter on its own, got $n"

# --- Case 4 : single-enter policy is a no-op -------------------------
reset_recorder
agent_submit_policy_apply 'test-pane:0.0' codex
n=$(enter_count)
[[ "$n" -eq 0 ]] \
  || fail "single-enter policy should send 0 trailing Enters, got $n"

reset_recorder
agent_submit_policy_apply 'test-pane:0.0' unknown
n=$(enter_count)
[[ "$n" -eq 0 ]] \
  || fail "unknown CLI must default to single-enter (0 trailing Enters), got $n"

# Operator/test override via the env var is honoured.
reset_recorder
ORCH_DISPATCH_SUBMIT_CLI=claude agent_submit_policy_apply 'test-pane:0.0'
n=$(enter_count)
[[ "$n" -eq 1 ]] \
  || fail "ORCH_DISPATCH_SUBMIT_CLI=claude should drive double-enter, got $n"

printf 'ok - agent_submit_policy_apply honours per-CLI gesture and override\n'

# --- Case 5 : end-to-end via terminal_dispatch_submit_once (claude) --
# send_to_pane always sends ONE Enter. With cli=claude the wrapper
# adds the policy's trailing Enter. Net: 2 Enter keystrokes on the
# recorder for a single submit_once invocation.
reset_recorder
ORCH_DISPATCH_SUBMIT_CLI=claude \
  terminal_dispatch_submit_once 'test-pane:0.0' 'hello world claude'
n=$(enter_count)
[[ "$n" -eq 2 ]] \
  || fail "claude submit_once should emit 2 Enter keystrokes (paste-Enter + policy-Enter), got $n"
grep -qE '^load-buffer ' "$TMUX_RECORDER" \
  || fail "claude submit_once should still use load-buffer for the brief"
grep -qE '^paste-buffer ' "$TMUX_RECORDER" \
  || fail "claude submit_once should still use paste-buffer for the brief"

# --- Case 6 : end-to-end via terminal_dispatch_submit_once (codex) ---
reset_recorder
ORCH_DISPATCH_SUBMIT_CLI=codex \
  terminal_dispatch_submit_once 'test-pane:0.0' 'hello world codex'
n=$(enter_count)
[[ "$n" -eq 1 ]] \
  || fail "codex submit_once should emit exactly 1 Enter keystroke, got $n"

printf 'ok - terminal_dispatch_submit_once obeys per-CLI submit policy (claude=2 Enter, codex=1 Enter)\n'

# --- Case 7 : configurable second-Enter delay ------------------------
# The MS env var is honoured even when non-zero; we only need to verify
# the path does not crash and still emits the Enter.
reset_recorder
ORCH_CLAUDE_SUBMIT_SECOND_ENTER_MS=1 agent_submit_policy_apply 'test-pane:0.0' claude
n=$(enter_count)
[[ "$n" -eq 1 ]] \
  || fail "non-zero ORCH_CLAUDE_SUBMIT_SECOND_ENTER_MS should still emit the second Enter, got $n"

printf 'ok - ORCH_CLAUDE_SUBMIT_SECOND_ENTER_MS delay is honoured\n'
printf 'ok - test_dispatch_ticket_submit_policy.sh passed\n'
