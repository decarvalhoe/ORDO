#!/usr/bin/env bash
# tests/test_ci_autofix_skip_merged.sh — coverage for ORDO #371.
#
# `scripts/ci_autofix.sh` and `scripts/dispatch_ticket.sh` MUST refuse
# to dispatch an autofix wave when the target PR is already merged or
# closed without merge. Skipping early saves agent capacity and
# prevents resurrecting branches that GitHub deleted on merge.
#
# This fixture stubs `gh` to return controlled state payloads and
# verifies, across three reference cases, that:
#   1. MERGED PR → ci_autofix exits 0, no prompt file, no
#      dispatch_ticket invocation, audit line records the skip with
#      mergedAt + mergeCommit.
#   2. CLOSED-without-merge PR → ci_autofix exits 0, audit line
#      records `closed_without_merge` with closedAt.
#   3. OPEN PR → existing behavior preserved (prompt + dispatch
#      both happen).
#   4. dispatch_ticket --skip-if-pr-merged → opt-in defense-in-depth
#      flag refuses an autofix-style dispatch on a MERGED PR even
#      when ci_autofix has already validated. Default-off behavior
#      preserves every existing dispatch_ticket caller.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
  rm -f /tmp/dispatch-claude-autofix-pr-42.md \
        /tmp/dispatch-claude-autofix-pr-43.md \
        /tmp/dispatch-claude-autofix-pr-44.md \
        /tmp/dispatch-claude-skip-flag-99.md
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" \
  "$TEST_TMP/bin" "$TEST_TMP/logs"

for rel in \
  scripts/ci_autofix.sh \
  scripts/dispatch_ticket.sh \
  lib/api_rate_limiter.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/ci_external_blockers.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dispatch_router.sh \
  lib/dry_run.sh \
  lib/external_mutation_gate.sh \
  lib/github_identity.sh \
  lib/host_load_gate.sh \
  lib/portfolio_config.sh \
  lib/process_safety.sh \
  lib/prompt_integrity.sh \
  lib/mcp_permission_preflight.sh \
  lib/recovery_context.sh \
  lib/state_persist.sh \
  lib/tmux_helpers.sh \
  lib/worktree_helpers.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

chmod +x "$SANITIZED_ROOT/scripts/ci_autofix.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="ci-autofix-skip-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
EOF

cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh.log"
case "\$*" in
  *"pr view 42"*"--json"*"state"*)
    # Merged PR — every state-aware caller must skip.
    printf '%s\n' '{"title":"Merged PR","headRefName":"feat/merged-branch","baseRefName":"main","changedFiles":1,"files":[{"path":"README.md"}],"url":"https://github.com/RBOKproject/ORDO/pull/42","state":"MERGED","mergedAt":"2026-05-08T14:49:46Z","closedAt":"2026-05-08T14:49:46Z","mergeCommit":{"oid":"abc123def456"}}'
    ;;
  *"pr view 43"*"--json"*"state"*)
    # Closed without merge.
    printf '%s\n' '{"title":"Abandoned PR","headRefName":"feat/abandoned","baseRefName":"main","changedFiles":1,"files":[{"path":"foo.md"}],"url":"https://github.com/RBOKproject/ORDO/pull/43","state":"CLOSED","mergedAt":"","closedAt":"2026-05-08T13:00:00Z","mergeCommit":null}'
    ;;
  *"pr view 44"*"--json"*"state"*)
    # Open — proceeds normally.
    printf '%s\n' '{"title":"Live PR","headRefName":"feat/live","baseRefName":"main","changedFiles":1,"files":[{"path":"bar.md"}],"url":"https://github.com/RBOKproject/ORDO/pull/44","state":"OPEN","mergedAt":"","closedAt":"","mergeCommit":null}'
    ;;
  *"pr view 99"*"--json"*"state"*)
    # Used by the dispatch_ticket --skip-if-pr-merged direct test.
    printf '%s\n' '{"state":"MERGED","mergedAt":"2026-05-08T16:00:00Z","closedAt":"2026-05-08T16:00:00Z","mergeCommit":{"oid":"deadbeef"}}'
    ;;
  *"pr checks 44"*)
    printf '%s\n' '[{"name":"unit","state":"FAILURE","bucket":"fail","link":"https://github.com/RBOKproject/ORDO/actions/runs/1/job/2","workflow":"CI"}]'
    ;;
  *"run view"*"--log-failed"*)
    printf 'FAILED STEP: tests/test_demo.sh\n'
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

# Stub dispatch_ticket so case 1, 2, 3 do not trigger the real one.
# Case 3 (open PR) MUST end up invoking this stub, so we record every
# call in dispatch.log to verify behavior.
cat > "$SANITIZED_ROOT/scripts/dispatch_ticket.sh.stub" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/dispatch.log"
exit 0
EOF


# ------------------------------------------------------------------
# Case 1 — MERGED PR: ci_autofix must skip without dispatching
# ------------------------------------------------------------------
cp "$SANITIZED_ROOT/scripts/dispatch_ticket.sh.stub" "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"
chmod +x "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"
: > "$TEST_TMP/logs/gh.log"
: > "$TEST_TMP/logs/dispatch.log"

set +e
merged_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/ci_autofix.sh" "$TEST_TMP/test.config.sh" 42 claude 2>&1
)
merged_status=$?
set -e

[[ "$merged_status" -eq 0 ]] || fail "ci_autofix should exit 0 on MERGED PR (got $merged_status): $merged_output"
[[ "$merged_output" == *"already merged"* ]] || fail "missing 'already merged' message: $merged_output"
[[ "$merged_output" == *"abc123def456"* ]] || fail "skip message must include mergeCommit: $merged_output"
[[ "$merged_output" == *"AUDIT LOG"*"CI_AUTOFIX skip reason=already_merged"* ]] || fail "missing audit line for merged PR: $merged_output"
[[ ! -f "/tmp/dispatch-claude-autofix-pr-42.md" ]] || fail "MERGED PR must not produce a prompt file"
[[ ! -s "$TEST_TMP/logs/dispatch.log" ]] || fail "MERGED PR must not invoke dispatch_ticket: $(cat "$TEST_TMP/logs/dispatch.log")"

# ------------------------------------------------------------------
# Case 2 — CLOSED without merge: ci_autofix must skip with
# closed_without_merge reason
# ------------------------------------------------------------------
: > "$TEST_TMP/logs/gh.log"
: > "$TEST_TMP/logs/dispatch.log"

set +e
closed_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/ci_autofix.sh" "$TEST_TMP/test.config.sh" 43 claude 2>&1
)
closed_status=$?
set -e

[[ "$closed_status" -eq 0 ]] || fail "ci_autofix should exit 0 on CLOSED PR (got $closed_status): $closed_output"
[[ "$closed_output" == *"closed without merge"* ]] || fail "missing 'closed without merge' message: $closed_output"
[[ "$closed_output" == *"AUDIT LOG"*"CI_AUTOFIX skip reason=closed_without_merge"* ]] || fail "missing audit line for closed PR: $closed_output"
[[ ! -f "/tmp/dispatch-claude-autofix-pr-43.md" ]] || fail "CLOSED PR must not produce a prompt file"
[[ ! -s "$TEST_TMP/logs/dispatch.log" ]] || fail "CLOSED PR must not invoke dispatch_ticket"

# ------------------------------------------------------------------
# Case 3 — OPEN PR: existing autofix path is preserved
# ------------------------------------------------------------------
: > "$TEST_TMP/logs/gh.log"
: > "$TEST_TMP/logs/dispatch.log"

set +e
open_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/ci_autofix.sh" "$TEST_TMP/test.config.sh" 44 claude 2>&1
)
open_status=$?
set -e

[[ "$open_status" -eq 0 ]] || fail "ci_autofix should exit 0 on OPEN PR (got $open_status): $open_output"
[[ -f "/tmp/dispatch-claude-autofix-pr-44.md" ]] || fail "OPEN PR must produce a prompt file"
grep -q "Live PR" "/tmp/dispatch-claude-autofix-pr-44.md" || fail "OPEN PR prompt must contain title"
[[ -s "$TEST_TMP/logs/dispatch.log" ]] || fail "OPEN PR must invoke dispatch_ticket: $(cat "$TEST_TMP/logs/dispatch.log")"
# ci_autofix forwards --skip-if-pr-merged to dispatch_ticket as a
# defense-in-depth handoff. The stub records every call for inspection.
grep -q -- "--skip-if-pr-merged" "$TEST_TMP/logs/dispatch.log" \
  || fail "ci_autofix must forward --skip-if-pr-merged to dispatch_ticket: $(cat "$TEST_TMP/logs/dispatch.log")"

# ------------------------------------------------------------------
# Case 4 — dispatch_ticket --skip-if-pr-merged direct invocation
# ------------------------------------------------------------------
# Cases 1–3 overwrote the sanitized dispatch_ticket.sh with a stub so
# we could observe whether ci_autofix called it. Case 4 exercises the
# REAL dispatch_ticket pre-check, so restore the sanitized real
# script from $ROOT now.
tr -d '\r' < "$ROOT/scripts/dispatch_ticket.sh" \
  > "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"
chmod +x "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"

# A canonical-shaped prompt large enough to clear the prompt-integrity
# threshold. The skip pre-check fires BEFORE prompt validation so an
# unrealistic prompt is fine, but we still mirror the canonical shape
# so default behavior assertions (case 4b) are realistic.
cat > "/tmp/dispatch-claude-skip-flag-99.md" <<'EOF'
# Dispatch canonique — ordo agent: claude
# Ticket: #99 (PR-merged-skip flag direct test)

## Objectif

Cover dispatch_ticket --skip-if-pr-merged direct invocation against a
MERGED PR. The check should fire BEFORE prompt validation, audit, or
any tmux interaction so we can rely on the audit trail to prove the
guard worked.

## Format de sortie attendu

Status block.

## Tools / sources autorises

- gh issue view

## Boundaries / interdictions

- Stay strictly in scope.

## Definition of Done verifiable

- [ ] Done.

## Preuves attendues

- pwd
EOF

# The skip pre-check is the FIRST gate in dispatch_ticket after
# argument parsing. It runs before prompt validation, host gate,
# matrix gate, etc. A MERGED PR must hit the pre-check and exit 0.
mkdir -p "$TEST_TMP/work/claude" "$TEST_TMP/state"

cat > "$TEST_TMP/dispatch.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="ci-autofix-skip-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/work/"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/work/%s"
AGENT_PANES=("claude|cap-claude:0.0|$TEST_TMP/work/claude")
EOF

set +e
flag_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_VALIDATOR_FORK_PREFLIGHT=0 \
  ORCH_VALIDATOR_SEMAPHORE_HELD=1 \
  ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE=off \
  ORCH_HOST_GATE_MODE=off \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/dispatch.config.sh" claude 99 \
    "/tmp/dispatch-claude-skip-flag-99.md" \
    --skip-if-pr-merged --no-validate --dry-run 2>&1
)
flag_status=$?
set -e

[[ "$flag_status" -eq 0 ]] || fail "dispatch_ticket --skip-if-pr-merged should exit 0 on MERGED PR (got $flag_status): $flag_output"
[[ "$flag_output" == *"PR already merged"* ]] || fail "missing PR-already-merged message: $flag_output"
[[ "$flag_output" == *"AUDIT LOG"*"DISPATCH skip reason=already_merged"* ]] || fail "missing audit line for direct skip: $flag_output"
# The guard ran BEFORE the staged dispatch, so no /tmp/dispatch-claude-99.md should exist.
[[ ! -f "/tmp/dispatch-claude-99.md" ]] || fail "MERGED PR must not produce a staged prompt copy"

# Negative control: without --skip-if-pr-merged, the MERGED PR check
# does not fire (default-off contract preserves every existing
# dispatch_ticket caller). We don't need to exercise the full
# dispatch flow here; merely confirm the guard's audit line is
# absent, proving the gate is gated.
set +e
default_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_VALIDATOR_FORK_PREFLIGHT=0 \
  ORCH_VALIDATOR_SEMAPHORE_HELD=1 \
  ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE=off \
  ORCH_HOST_GATE_MODE=off \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/dispatch.config.sh" claude 99 \
    "/tmp/dispatch-claude-skip-flag-99.md" \
    --no-validate --dry-run 2>&1
)
# We deliberately ignore the dispatch_ticket exit code here (the
# default path may fail later for unrelated stub reasons) — what
# matters is that the already_merged audit line MUST NOT appear when
# --skip-if-pr-merged was not passed.
set -e
[[ "$default_output" != *"DISPATCH skip reason=already_merged"* ]] \
  || fail "default-off contract violated: skip-if-pr-merged audit line fired without the flag"

printf 'ok - ci_autofix + dispatch_ticket skip when target PR is already merged or closed\n'
