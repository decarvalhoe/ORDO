#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
  rm -f /tmp/dispatch-terminal-worker-8001.md \
    /tmp/dispatch-terminal-worker-8002.md \
    /tmp/dispatch-terminal-worker-8003.md \
    /tmp/dispatch-terminal-worker-8004.md \
    /tmp/dispatch-terminal-worker-8005.md \
    /tmp/dispatch-terminal-worker-8006.md \
    /tmp/dispatch-terminal-worker-8007.md \
    /tmp/dispatch-terminal-worker-8008.md \
    /tmp/dispatch-terminal-worker-8009.md \
    /tmp/dispatch-terminal-worker-8010.md \
    /tmp/dispatch-terminal-worker-8011.md \
    /tmp/dispatch-terminal-worker-8012.md \
    /tmp/dispatch-terminal-worker-8013.md \
    /tmp/dispatch-terminal-worker-8014.md \
    /tmp/dispatch-terminal-worker-8015.md \
    /tmp/dispatch-terminal-worker-8016.md \
    /tmp/dispatch-terminal-worker-8017.md
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/dispatch_ticket.sh \
  templates/dispatch-canonical.md.tpl
chmod +x "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/logs" "$TEST_TMP/repos"

cat > "$TEST_TMP/bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TMUX_LOG"

case "${1:-}" in
  has-session|list-panes|load-buffer|paste-buffer|send-keys)
    exit 0
    ;;
  display-message)
    for arg in "$@"; do
      case "$arg" in
        '#{pane_current_path}')
          printf '%s\n' "$TMUX_PANE_PATH"
          exit 0
          ;;
        '#{pane_current_command}')
          printf '%s\n' "terminal-agent"
          exit 0
          ;;
      esac
    done
    exit 0
    ;;
  capture-pane)
    count=0
    if [[ -s "$TMUX_CAPTURE_COUNT" ]]; then
      count=$(cat "$TMUX_CAPTURE_COUNT")
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$TMUX_CAPTURE_COUNT"
    case "${TMUX_CAPTURE_MODE:-active}" in
      active)
        printf '%s\n' "working on dispatch"
        ;;
      idle-once)
        if [[ "$count" -eq 1 ]]; then
          printf '%s\n' "> "
        else
          printf '%s\n' "working on dispatch"
        fi
        ;;
      idle-always)
        printf '%s\n' "> "
        ;;
      idle-chevron-always)
        printf '%s\n' "› "
        ;;
      pasted-idle-always)
        printf '%s\n' "› Read /tmp/dispatch-terminal-worker-${TMUX_TICKET:-8006}.md and execute it"
        ;;
      pasted-active-always)
        printf '%s\n' "› Read /tmp/dispatch-terminal-worker-${TMUX_TICKET:-8008}.md and execute it end-to-end. Stay strictly in scope."
        printf '%s\n' "esc to interrupt"
        ;;
      pasted-visible-then-command)
        printf '%s\n' "› Read /tmp/dispatch-terminal-worker-${TMUX_TICKET:-8014}.md and execute it end-to-end. Stay strictly in scope."
        printf '%s\n' "git status --short"
        printf '%s\n' "running tests"
        ;;
      pasted-then-active)
        if [[ "$count" -eq 1 ]]; then
          printf '%s\n' "› Read /tmp/dispatch-terminal-worker-${TMUX_TICKET:-8011}.md and execute it end-to-end. Stay strictly in scope."
        else
          printf '%s\n' "working on dispatch"
        fi
        ;;
      pasted-short-prefix-active-always)
        printf '%s\n' "› Read /tmp/dispatch-terminal-worker-${TMUX_TICKET:-8009}.md"
        printf '%s\n' "esc to interrupt"
        ;;
      pasted-suffix-footer-always)
        printf '%s\n' "› Verify your git identity matches the agent name before commit. Report final status."
        printf '%s\n' "esc to interrupt"
        ;;
      codex-footer-only)
        printf '%s\n' "gpt-5.5-codex"
        printf '%s\n' "workdir: $TMUX_PANE_PATH"
        printf '%s\n' "esc to interrupt"
        ;;
      pasted-claude-spinner-matching-workdir-always)
        # Issue #700 reproduction: paste-buffer echo of the brief is still
        # visible in the pane scrollback, but Claude Code has already
        # consumed the prompt and is actively reasoning (spinner glyph +
        # elapsed seconds) and emitting reply markers ('● ...').
        printf '%s\n' "› Read /tmp/dispatch-terminal-worker-${TMUX_TICKET:-8015}.md and execute it end-to-end. Stay strictly in scope."
        printf '%s\n' "● Identity matches terminal-worker."
        printf '%s\n' "✢ Spelunking… (31s)"
        ;;
      pasted-claude-spinner-wrong-workdir-always)
        # Issue #700 negative path: agent-activity markers are present but
        # the pane is operating in a different workdir than the dispatcher
        # intended. Must NOT promote — paste-buffer echo plus activity in
        # the wrong workdir is the cross-pane race the proof gate exists
        # to catch.
        printf '%s\n' "› Read /tmp/dispatch-terminal-worker-${TMUX_TICKET:-8016}.md and execute it end-to-end. Stay strictly in scope."
        printf '%s\n' "● Identity matches terminal-worker."
        printf '%s\n' "✢ Spelunking… (12s)"
        ;;
      claude-spinner-only-always)
        # Issue #700: the submitted text has scrolled out of the capture
        # window but the agent is visibly working (gerund spinner the
        # legacy active_pattern cannot enumerate).
        printf '%s\n' "✢ Cogitating… (7s)"
        ;;
      no-proof-always)
        printf '%s\n' "screen repainted after paste"
        ;;
    esac
    exit 0
    ;;
esac

exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

git init --bare "$TEST_TMP/origin.git" >/dev/null
git init "$TEST_TMP/seed" >/dev/null
git -C "$TEST_TMP/seed" config user.name "Terminal Test"
git -C "$TEST_TMP/seed" config user.email "terminal@test.local"
git -C "$TEST_TMP/seed" checkout -b main >/dev/null
printf 'seed\n' > "$TEST_TMP/seed/README.md"
git -C "$TEST_TMP/seed" add README.md
git -C "$TEST_TMP/seed" commit -m "seed" >/dev/null
git -C "$TEST_TMP/seed" remote add origin "$TEST_TMP/origin.git"
git -C "$TEST_TMP/seed" push -u origin main >/dev/null

git clone "$TEST_TMP/origin.git" "$TEST_TMP/repos/terminal-worker" >/dev/null 2>&1
git -C "$TEST_TMP/repos/terminal-worker" checkout main >/dev/null
git -C "$TEST_TMP/repos/terminal-worker" config user.name "Terminal Worker"
git -C "$TEST_TMP/repos/terminal-worker" config user.email "worker@test.local"

cat > "$TEST_TMP/project.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="terminal-dispatch"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
REPO_URL="$TEST_TMP/origin.git"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
# This legacy terminal-submission fixture predates #573's post-dispatch pane
# acceptance gate. The gate itself is covered by test_pane_acceptance_proof.sh.
export REQUIRE_ACCEPTANCE_PROOF="${REQUIRE_ACCEPTANCE_PROOF:-0}"
AGENT_PANES=(
  "terminal-worker|terminal-pane:0.0|$TEST_TMP/repos/terminal-worker"
)
EOF

prompt="$TEST_TMP/prompt.md"
cat > "$prompt" <<'EOF'
## Objectif
Verify terminal dispatch submission.

## Format de sortie attendu
Report status.

## Tools / sources autorises
Use only local fixtures.

## Boundaries / interdictions
No live external writes.

## Definition of Done verifiable
The prompt is submitted to the configured terminal pane.

## Preuves attendues
Tmux call log and state files.

This prompt includes enough filler for prompt integrity validation. It is a
generic local fixture and does not represent a live project, host, account, or
provider. The remaining text exists only to exceed the minimum byte threshold
used by dispatch prompt integrity checks in tests.
EOF

invalid_prompt="$TEST_TMP/invalid.md"
printf '# broken\n' > "$invalid_prompt"

run_dispatch() {
  local mode=${1:?usage: run_dispatch <capture-mode> <ticket> <prompt>}
  local ticket=${2:?usage: run_dispatch <capture-mode> <ticket> <prompt>}
  local prompt_file=${3:?usage: run_dispatch <capture-mode> <ticket> <prompt>}
  : > "$TEST_TMP/logs/tmux.log"
  : > "$TEST_TMP/logs/capture-count"
  TMUX='' \
    PATH="$TEST_TMP/bin:$PATH" \
    TMUX_LOG="$TEST_TMP/logs/tmux.log" \
    TMUX_CAPTURE_COUNT="$TEST_TMP/logs/capture-count" \
    TMUX_CAPTURE_MODE="$mode" \
    TMUX_TICKET="$ticket" \
    TMUX_PANE_PATH="${TMUX_PANE_PATH_OVERRIDE:-$TEST_TMP/repos/terminal-worker}" \
    ORCH_LOG_DIR="$TEST_TMP/logs" \
    ORCH_STATE_BASE="$TEST_TMP/state" \
    ORCH_CONTEXT_PROOF_WAIT_SEC=0 \
    ORCH_DISPATCH_CONSUME_WAIT_SEC=0 \
    ORCH_DISPATCH_VERIFY_CONSUMED="${ORCH_DISPATCH_VERIFY_CONSUMED:-1}" \
    ORCH_TMUX_SEND_ENTER_DELAY_SEC=0 \
    ORCH_DISPATCH_RETRY_CLEAR_DELAY_SEC=0 \
    AGENT_READY_COMMAND_PATTERN='^terminal-agent$' \
    bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
      "$TEST_TMP/project.config.sh" terminal-worker "$ticket" "$prompt_file"
}

reset_assignment_state() {
  mkdir -p "$TEST_TMP/state/terminal-dispatch"
  printf '{}\n' > "$TEST_TMP/state/terminal-dispatch/assignments.json"
}

set +e
invalid_output=$(run_dispatch active 8001 "$invalid_prompt" 2>&1)
invalid_status=$?
set -e
[[ "$invalid_status" -ne 0 ]] || fail "invalid prompt should be refused"
[[ "$invalid_output" == *"missing canonical sections"* ]] \
  || fail "invalid prompt should fail prompt validation, got: $invalid_output"
! grep -Eq '^(load-buffer|paste-buffer|send-keys)' "$TEST_TMP/logs/tmux.log" \
  || fail "invalid prompt must fail before terminal submission"

run_dispatch active 8002 "$prompt" >/dev/null
# Issue #595: send_to_pane now uses a per-invocation unique buffer name
# (orch_send_<pid>_<rand>_<ns>) instead of the shared `orch_send`. Match
# the prefix to keep the assertion stable across the rotation.
grep -qE '^load-buffer -b orch_send_[0-9_]+ ' "$TEST_TMP/logs/tmux.log" \
  || fail "dispatch should load text through tmux buffer"
grep -qE '^paste-buffer -b orch_send_[0-9_]+ -t terminal-pane:0.0 -d$' "$TEST_TMP/logs/tmux.log" \
  || fail "dispatch should paste into the configured universal pane"
grep -q '^send-keys -t terminal-pane:0.0 Enter$' "$TEST_TMP/logs/tmux.log" \
  || fail "dispatch should submit with Enter as a separate call"
grep -q 'DISPATCH PROMPT_EXECUTION_PROOF_OK agent=terminal-worker ticket=#8002' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "dispatch should audit prompt execution proof separately"
grep -q 'DISPATCH CONTEXT_PROOF_OK agent=terminal-worker ticket=#8002' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "dispatch should still audit context proof separately"

reset_assignment_state
run_dispatch idle-once 8003 "$prompt" >/dev/null
paste_count=$(grep -cE '^paste-buffer -b orch_send_[0-9_]+ -t terminal-pane:0.0 -d$' "$TEST_TMP/logs/tmux.log")
[[ "$paste_count" -eq 2 ]] || fail "idle first attempt should retry paste once, got $paste_count"
grep -q '^send-keys -t terminal-pane:0.0 Escape$' "$TEST_TMP/logs/tmux.log" \
  || fail "retry should send an interrupt key before resubmitting"
grep -q '^send-keys -t terminal-pane:0.0 C-u$' "$TEST_TMP/logs/tmux.log" \
  || fail "retry should clear stale terminal input before resubmitting"

reset_assignment_state
set +e
idle_output=$(run_dispatch idle-always 8004 "$prompt" 2>&1)
idle_status=$?
set -e
[[ "$idle_status" -eq 79 ]] \
  || fail "persistent idle pane should exit 79, got $idle_status: $idle_output"
[[ "$idle_output" == *"dispatch-not-consumed"* ]] \
  || fail "persistent idle pane should report dispatch-not-consumed, got: $idle_output"
blockers="$TEST_TMP/state/terminal-dispatch/dispatch_blockers.json"
jq -e '
  (.open // {})
  | to_entries
  | map(select(.value.code == "dispatch-not-consumed"
      and .value.agent == "terminal-worker"
      and .value.pane == "terminal-pane:0.0"
      and .value.reason == "idle-prompt"))
  | length == 1
' "$blockers" >/dev/null || fail "dispatch-not-consumed blocker not recorded: $(cat "$blockers" 2>/dev/null || true)"
grep -q 'code=dispatch-not-consumed agent=terminal-worker' \
  "$TEST_TMP/state/terminal-dispatch/ORCH_TASKS.md" \
  || fail "dispatch-not-consumed task should be visible in ORCH_TASKS"

reset_assignment_state
set +e
chevron_output=$(run_dispatch idle-chevron-always 8005 "$prompt" 2>&1)
chevron_status=$?
set -e
[[ "$chevron_status" -eq 79 ]] \
  || fail "idle chevron pane should exit 79, got $chevron_status: $chevron_output"
[[ "$chevron_output" == *"dispatch-not-consumed"* ]] \
  || fail "idle chevron pane should report dispatch-not-consumed, got: $chevron_output"
jq -e '
  (.open // {})
  | to_entries
  | map(select(.value.code == "dispatch-not-consumed"
      and .value.agent == "terminal-worker"
      and .value.pane == "terminal-pane:0.0"
      and .value.ticket == "8005"
      and .value.reason == "idle-prompt"))
  | length == 1
' "$blockers" >/dev/null || fail "idle chevron blocker not recorded: $(cat "$blockers" 2>/dev/null || true)"

reset_assignment_state
set +e
pasted_output=$(run_dispatch pasted-idle-always 8006 "$prompt" 2>&1)
pasted_status=$?
set -e
[[ "$pasted_status" -eq 79 ]] \
  || fail "pasted idle pane should exit 79, got $pasted_status: $pasted_output"
[[ "$pasted_output" == *"dispatch-not-consumed"* ]] \
  || fail "pasted idle pane should report dispatch-not-consumed, got: $pasted_output"
jq -e '
  (.open // {})
  | to_entries
  | map(select(.value.code == "dispatch-not-consumed"
      and .value.agent == "terminal-worker"
      and .value.pane == "terminal-pane:0.0"
      and .value.ticket == "8006"
      and .value.reason == "submission-still-visible"))
  | length == 1
' "$blockers" >/dev/null || fail "pasted-content blocker not recorded: $(cat "$blockers" 2>/dev/null || true)"

reset_assignment_state
set +e
pasted_active_output=$(run_dispatch pasted-active-always 8008 "$prompt" 2>&1)
pasted_active_status=$?
set -e
[[ "$pasted_active_status" -eq 79 ]] \
  || fail "pasted active pane should exit 79, got $pasted_active_status: $pasted_active_output"
[[ "$pasted_active_output" == *"dispatch-not-consumed"* ]] \
  || fail "pasted active pane should report dispatch-not-consumed, got: $pasted_active_output"
jq -e '
  (.open // {})
  | to_entries
  | map(select(.value.code == "dispatch-not-consumed"
      and .value.agent == "terminal-worker"
      and .value.pane == "terminal-pane:0.0"
      and .value.ticket == "8008"
      and .value.reason == "submission-still-visible"))
  | length == 1
' "$blockers" >/dev/null || fail "pasted-active blocker not recorded: $(cat "$blockers" 2>/dev/null || true)"
! grep -q 'DISPATCH ASSIGNMENT_PROMOTED agent=terminal-worker ticket=#8008' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "pasted active pane must not audit assignment promotion"

reset_assignment_state
run_dispatch pasted-visible-then-command 8014 "$prompt" >/dev/null
grep -q 'DISPATCH PROMPT_EXECUTION_PROOF_OK agent=terminal-worker ticket=#8014' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "visible prompt followed by command output should pass prompt execution proof"
grep -q 'proof=prompt-visible-with-activity-below' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "visible prompt activity proof should name the residual activity recovery path"
grep -q 'DISPATCH ASSIGNMENT_PROMOTED agent=terminal-worker ticket=#8014' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "visible prompt followed by command output should promote assignment"

# Issue #700: paste-buffer echo of the brief stays visible while the agent
# is already reasoning. When agent-activity markers are present (Claude
# Code spinner glyph + elapsed seconds, '●' reply prefix) AND the pane is
# operating in the dispatched workdir, the visible submission is benign
# echo, not a stuck input line — promote the assignment.
reset_assignment_state
run_dispatch pasted-claude-spinner-matching-workdir-always 8015 "$prompt" >/dev/null
grep -q 'DISPATCH PROMPT_EXECUTION_PROOF_OK agent=terminal-worker ticket=#8015' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "#700 spinner+reply marker in matching workdir should pass prompt execution proof"
grep -q 'proof=agent-activity-with-matching-workdir' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "#700 recovery path should be named agent-activity-with-matching-workdir"
grep -q 'DISPATCH ASSIGNMENT_PROMOTED agent=terminal-worker ticket=#8015' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "#700 spinner+reply marker in matching workdir should promote assignment"

# Issue #700 negative path: same scrollback shape, but the pane is in a
# DIFFERENT workdir than the dispatcher intended. The workdir gate must
# refuse the recovery path so a cross-pane race cannot masquerade as a
# successful dispatch.
reset_assignment_state
set +e
wrong_workdir_output=$(TMUX_PANE_PATH_OVERRIDE="$TEST_TMP/repos/other-product" \
  run_dispatch pasted-claude-spinner-wrong-workdir-always 8016 "$prompt" 2>&1)
wrong_workdir_status=$?
set -e
[[ "$wrong_workdir_status" -eq 79 ]] \
  || fail "#700 spinner in wrong workdir should exit 79, got $wrong_workdir_status: $wrong_workdir_output"
[[ "$wrong_workdir_output" == *"dispatch-not-consumed"* ]] \
  || fail "#700 spinner in wrong workdir should report dispatch-not-consumed, got: $wrong_workdir_output"
jq -e '
  (.open // {})
  | to_entries
  | map(select(.value.code == "dispatch-not-consumed"
      and .value.agent == "terminal-worker"
      and .value.pane == "terminal-pane:0.0"
      and .value.ticket == "8016"
      and .value.reason == "submission-still-visible"))
  | length == 1
' "$blockers" >/dev/null || fail "#700 wrong-workdir blocker not recorded: $(cat "$blockers" 2>/dev/null || true)"
! grep -q 'DISPATCH ASSIGNMENT_PROMOTED agent=terminal-worker ticket=#8016' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "#700 spinner in wrong workdir must not promote assignment"

# Issue #700: the submitted text has already scrolled out of the capture
# window but the agent's spinner makes consumption obvious. The legacy
# active_pattern cannot enumerate every gerund the CLI cycles through;
# the spinner glyph + ellipsis + elapsed-seconds shape is vocabulary-
# agnostic proof and must be accepted.
reset_assignment_state
run_dispatch claude-spinner-only-always 8017 "$prompt" >/dev/null
grep -q 'DISPATCH PROMPT_EXECUTION_PROOF_OK agent=terminal-worker ticket=#8017' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "#700 spinner-only capture should pass prompt execution proof"
grep -q 'proof=post-submit-agent-activity' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "#700 spinner-only recovery path should be named post-submit-agent-activity"
grep -q 'DISPATCH ASSIGNMENT_PROMOTED agent=terminal-worker ticket=#8017' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "#700 spinner-only capture should promote assignment"

reset_assignment_state
set +e
pasted_short_output=$(run_dispatch pasted-short-prefix-active-always 8009 "$prompt" 2>&1)
pasted_short_status=$?
set -e
[[ "$pasted_short_status" -eq 79 ]] \
  || fail "pasted short-prefix pane should exit 79, got $pasted_short_status: $pasted_short_output"
[[ "$pasted_short_output" == *"dispatch-not-consumed"* ]] \
  || fail "pasted short-prefix pane should report dispatch-not-consumed, got: $pasted_short_output"
jq -e '
  (.open // {})
  | to_entries
  | map(select(.value.code == "dispatch-not-consumed"
      and .value.agent == "terminal-worker"
      and .value.pane == "terminal-pane:0.0"
      and .value.ticket == "8009"
      and .value.reason == "submission-still-visible"))
  | length == 1
' "$blockers" >/dev/null || fail "pasted short-prefix blocker not recorded: $(cat "$blockers" 2>/dev/null || true)"
! grep -q 'DISPATCH ASSIGNMENT_PROMOTED agent=terminal-worker ticket=#8009' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "pasted short-prefix pane must not audit assignment promotion"

# Issue #639, regression after closed #612: #638/#468 showed the dispatch
# text still staged, then agents began working after a single manual Enter.
# The recovery must send that one extra Enter and re-check proof, not clear
# the input and paste a duplicate prompt.
reset_assignment_state
run_dispatch pasted-then-active 8011 "$prompt" >/dev/null
paste_count=$(grep -cE '^paste-buffer -b orch_send_[0-9_]+ -t terminal-pane:0.0 -d$' "$TEST_TMP/logs/tmux.log")
[[ "$paste_count" -eq 1 ]] || fail "#638/#468 staged prompt recovery should not repaste, got $paste_count"
enter_count=$(grep -c '^send-keys -t terminal-pane:0.0 Enter$' "$TEST_TMP/logs/tmux.log")
[[ "$enter_count" -eq 2 ]] || fail "#638/#468 staged prompt recovery should send exactly one extra Enter, got $enter_count"
! grep -q '^send-keys -t terminal-pane:0.0 Escape$' "$TEST_TMP/logs/tmux.log" \
  || fail "#638/#468 staged prompt recovery must not clear input before Enter recovery"
! grep -q '^send-keys -t terminal-pane:0.0 C-u$' "$TEST_TMP/logs/tmux.log" \
  || fail "#638/#468 staged prompt recovery must not clear input before Enter recovery"
grep -q 'DISPATCH PROMPT_EXECUTION_PROOF_OK agent=terminal-worker ticket=#8011' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "#638/#468 staged prompt recovery should re-check and pass after first action"

# Issue #639, regression after closed #612: #569 showed footer activity while
# a duplicate submitted prompt line was still visible. Footer text cannot be
# proof, and visible suffixes of the submitted one-liner must fail closed.
reset_assignment_state
set +e
pasted_suffix_output=$(run_dispatch pasted-suffix-footer-always 8012 "$prompt" 2>&1)
pasted_suffix_status=$?
set -e
[[ "$pasted_suffix_status" -eq 79 ]] \
  || fail "#569 visible suffix plus footer should exit 79, got $pasted_suffix_status: $pasted_suffix_output"
[[ "$pasted_suffix_output" == *"dispatch-not-consumed"* ]] \
  || fail "#569 visible suffix plus footer should report dispatch-not-consumed, got: $pasted_suffix_output"
jq -e '
  (.open // {})
  | to_entries
  | map(select(.value.code == "dispatch-not-consumed"
      and .value.agent == "terminal-worker"
      and .value.pane == "terminal-pane:0.0"
      and .value.ticket == "8012"
      and .value.reason == "submission-still-visible"))
  | length == 1
' "$blockers" >/dev/null || fail "#569 pasted suffix blocker not recorded: $(cat "$blockers" 2>/dev/null || true)"
! grep -q 'DISPATCH ASSIGNMENT_PROMOTED agent=terminal-worker ticket=#8012' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "#569 visible suffix plus footer must not audit assignment promotion"

reset_assignment_state
set +e
codex_footer_output=$(run_dispatch codex-footer-only 8013 "$prompt" 2>&1)
codex_footer_status=$?
set -e
[[ "$codex_footer_status" -eq 79 ]] \
  || fail "Codex footer-only proof should exit 79, got $codex_footer_status: $codex_footer_output"
[[ "$codex_footer_output" == *"dispatch-not-consumed"* ]] \
  || fail "Codex footer-only proof should report dispatch-not-consumed, got: $codex_footer_output"
jq -e '
  (.open // {})
  | to_entries
  | map(select(.value.code == "dispatch-not-consumed"
      and .value.agent == "terminal-worker"
      and .value.pane == "terminal-pane:0.0"
      and .value.ticket == "8013"
      and .value.reason == "no-positive-execution-proof"))
  | length == 1
' "$blockers" >/dev/null || fail "Codex footer-only blocker not recorded: $(cat "$blockers" 2>/dev/null || true)"
! grep -q 'DISPATCH ASSIGNMENT_PROMOTED agent=terminal-worker ticket=#8013' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "Codex footer-only proof must not audit assignment promotion"

reset_assignment_state
set +e
no_proof_output=$(run_dispatch no-proof-always 8010 "$prompt" 2>&1)
no_proof_status=$?
set -e
[[ "$no_proof_status" -eq 79 ]] \
  || fail "no-proof pane should exit 79, got $no_proof_status: $no_proof_output"
[[ "$no_proof_output" == *"dispatch-not-consumed"* ]] \
  || fail "no-proof pane should report dispatch-not-consumed, got: $no_proof_output"
jq -e '
  (.open // {})
  | to_entries
  | map(select(.value.code == "dispatch-not-consumed"
      and .value.agent == "terminal-worker"
      and .value.pane == "terminal-pane:0.0"
      and .value.ticket == "8010"
      and .value.reason == "no-positive-execution-proof"))
  | length == 1
' "$blockers" >/dev/null || fail "no-proof blocker not recorded: $(cat "$blockers" 2>/dev/null || true)"
! grep -q 'DISPATCH ASSIGNMENT_PROMOTED agent=terminal-worker ticket=#8010' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "no-proof pane must not audit assignment promotion"

reset_assignment_state
set +e
verify_bypass_output=$(ORCH_DISPATCH_VERIFY_CONSUMED=0 run_dispatch pasted-idle-always 8007 "$prompt" 2>&1)
verify_bypass_status=$?
set -e
[[ "$verify_bypass_status" -eq 79 ]] \
  || fail "dispatch must still require prompt execution proof when verification env is disabled, got $verify_bypass_status: $verify_bypass_output"
[[ "$verify_bypass_output" == *"dispatch-not-consumed"* ]] \
  || fail "verify-bypass dispatch should report dispatch-not-consumed, got: $verify_bypass_output"
if [[ -s "$TEST_TMP/state/terminal-dispatch/assignments.json" ]]; then
  ! jq -e '."terminal-worker".ticket == "8007"' \
    "$TEST_TMP/state/terminal-dispatch/assignments.json" >/dev/null \
    || fail "verify-bypass dispatch must not promote assignment without prompt execution proof"
fi
! grep -q 'DISPATCH ASSIGNMENT_PROMOTED agent=terminal-worker ticket=#8007' \
  "$TEST_TMP/logs/terminal-dispatch.log" \
  || fail "verify-bypass dispatch must not audit assignment promotion"

printf 'ok - terminal dispatch submission verifies paste, retry, and not-consumed blockers\n'
