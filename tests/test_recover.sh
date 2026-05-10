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

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/logs" "$TEST_TMP/state" "$TEST_TMP/gh" "$TEST_TMP/workdir"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/recover.sh \
  scripts/dispatch_ticket.sh

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="recover-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_WINDOW_INDEX=0
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
ORCH_AGENT_CLI=claude
USE_WORKTREES=1
ORCH_WORKTREES_DIR="$TEST_TMP/worktrees"
EOF
ln -s "$TEST_TMP/test.config.sh" "$TEST_TMP/recover-test.config.sh"

cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/tmux.log"
case "\${1:-}" in
  has-session|list-panes)
    exit 0
    ;;
  display-message)
    printf '%s\n' "\${LIVE_PANE_CWD:-$TEST_TMP/workdir}"
    exit 0
    ;;
  load-buffer)
    src=\${@: -1}
    cat "\$src" >> "$TEST_TMP/logs/buffer.log"
    printf '\n' >> "$TEST_TMP/logs/buffer.log"
    exit 0
    ;;
  paste-buffer|send-keys|new-session)
    exit 0
    ;;
  capture-pane)
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
chmod +x "$TEST_TMP/bin/gh"

prompt_file="$TEST_TMP/dispatch-claude-5001.md"
cat > "$prompt_file" <<'EOF'
# Dispatch canonique -- recover test

## Objectif

Exercise recover rehydration behavior for a live pane already sitting in the
same assignment workdir. This prompt is intentionally long enough to pass the
prompt integrity minimum byte threshold used by the dispatcher.

## Format de sortie attendu

Report a compact status.

## Tools / sources autorises

Use only the local shell fixture.

## Boundaries / interdictions

Do not mutate anything outside the fixture.

## Definition of Done verifiable

- [ ] Rehydration was submitted.

## Preuves attendues

Audit and tmux log entries.
EOF

write_current_assignment() {
  local workdir=${1:?usage: write_current_assignment <workdir>}
  mkdir -p "$TEST_TMP/state/recover-test" "$workdir"
  cat > "$TEST_TMP/state/recover-test/assignments.json" <<JSON
{
  "claude": {
    "ticket": "5001",
    "issue": 5001,
    "workdir": "$workdir",
    "branch": "feat/issue-5001",
    "prompt_file": "$prompt_file"
  }
}
JSON
}

run_recover() {
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_CONFIG_DIR="$TEST_TMP" \
  LIVE_PANE_CWD="$TEST_TMP/workdir" \
  ORCH_TMUX_SEND_ENTER_DELAY_SEC=0 \
  ORCH_DISPATCH_CONSUME_WAIT_SEC=0 \
  bash "$SANITIZED_ROOT/scripts/recover.sh" "$TEST_TMP/test.config.sh" claude
}

write_conflicting_assignment() {
  local agent=${1:?usage: write_conflicting_assignment <agent> <issue> <workdir>}
  local issue=${2:?usage: write_conflicting_assignment <agent> <issue> <workdir>}
  local workdir=${3:?usage: write_conflicting_assignment <agent> <issue> <workdir>}
  mkdir -p "$TEST_TMP/state/aaa-conflict"
  cat > "$TEST_TMP/state/aaa-conflict/assignments.json" <<JSON
{
  "$agent": {
    "ticket": "$issue",
    "issue": $issue,
    "workdir": "$workdir",
    "branch": "feat/issue-$issue"
  }
}
JSON
}

rm -f "$TEST_TMP/logs/"*.log "$TEST_TMP/logs/buffer.log"
write_current_assignment "$TEST_TMP/workdir"

same_output=$(run_recover 2>&1) || fail "same-assignment recover should succeed, got: $same_output"
grep -q 'RECOVER SAME_ASSIGNMENT_REHYDRATE agent=claude ticket=#5001' "$TEST_TMP/logs/recover-test.log" \
  || fail "same-assignment rehydrate should be audited"
grep -Fq "Read $prompt_file and execute it end-to-end" "$TEST_TMP/logs/buffer.log" \
  || fail "same-assignment rehydrate should submit the recorded prompt path"
jq -e --arg prompt "$prompt_file" --arg workdir "$TEST_TMP/workdir" \
  '.claude.issue == 5001 and .claude.prompt_file == $prompt and .claude.workdir == $workdir' \
  "$TEST_TMP/state/recover-test/assignments.json" >/dev/null \
  || fail "same-assignment rehydrate must not mutate the assignment ledger"

rm -f "$TEST_TMP/logs/"*.log "$TEST_TMP/logs/buffer.log"
rm -rf "$TEST_TMP/state"
mkdir -p "$TEST_TMP/state"
write_current_assignment "$TEST_TMP/workdir"
write_conflicting_assignment claude 7000 "$TEST_TMP/workdir"
set +e
different_ticket_output=$(run_recover 2>&1)
different_ticket_status=$?
set -e
[[ "$different_ticket_status" -eq 77 ]] \
  || fail "different-ticket occupation should still refuse with 77, got $different_ticket_status: $different_ticket_output"
[[ "$different_ticket_output" == *"pane-occupied:aaa-conflict#7000"* ]] \
  || fail "different-ticket refusal should report the conflicting assignment, got: $different_ticket_output"

rm -f "$TEST_TMP/logs/"*.log "$TEST_TMP/logs/buffer.log"
rm -rf "$TEST_TMP/state"
mkdir -p "$TEST_TMP/state"
write_current_assignment "$TEST_TMP/workdir"
write_conflicting_assignment other-agent 5001 "$TEST_TMP/workdir"
set +e
different_agent_output=$(run_recover 2>&1)
different_agent_status=$?
set -e
[[ "$different_agent_status" -eq 77 ]] \
  || fail "different-agent occupation should still refuse with 77, got $different_agent_status: $different_agent_output"
[[ "$different_agent_output" == *"occupied_agent=other-agent"* ]] \
  || fail "different-agent refusal should report the conflicting agent, got: $different_agent_output"

printf 'ok - recover same-assignment rehydrate\n'
