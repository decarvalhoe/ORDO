#!/usr/bin/env bash
# tests/test_dispatch_refuse_closed_issue.sh — coverage for ORDO #598.
#
# `scripts/dispatch_ticket.sh` MUST refuse to paste a brief into an
# agent pane when the target GitHub issue is already closed. Skipping
# early prevents wasting an agent slot on a superseded ticket and
# preserves the audit trail.
#
# Stubs `gh` to return controlled state payloads and verifies, across
# three reference cases, that:
#   1. CLOSED issue → dispatch refuses, exit 0, no /tmp/dispatch-*.md
#      file created, audit line records the refusal with closedAt.
#   2. OPEN issue   → existing behavior preserved (dispatch proceeds).
#   3. REFUSE_CLOSED_ISSUE=0 + CLOSED issue → opt-out path bypasses the
#      guard so legacy fixtures still dispatch (default-on for new
#      callers, off-switch for backward compatibility).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
  rm -f /tmp/dispatch-claude-7001.md \
        /tmp/dispatch-claude-7002.md \
        /tmp/dispatch-claude-7003.md
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" \
  "$TEST_TMP/bin" "$TEST_TMP/logs"

# Sanitize a copy of the toolkit (CRLF→LF) so dispatch_ticket.sh runs
# cleanly under Windows-checkout repos.
for rel in \
  scripts/dispatch_ticket.sh \
  lib/api_rate_limiter.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dispatch_router.sh \
  lib/dispatch_workdir_preflight.sh \
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
  if [ -f "$ROOT/$rel" ]; then
    tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
  fi
done
chmod +x "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dispatch-refuse-closed-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
EOF

# gh stub : returns CLOSED for issue 7001, OPEN for issue 7002,
# CLOSED for issue 7003 (used to verify the opt-out path).
# Falls through to no-op for any other invocation.
cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh.log"
case "\$*" in
  *"issue view 7001"*)
    printf '%s\n' '{"state":"CLOSED","closedAt":"2026-05-09T12:00:00Z"}'
    ;;
  *"issue view 7002"*)
    printf '%s\n' '{"state":"OPEN","closedAt":""}'
    ;;
  *"issue view 7003"*)
    printf '%s\n' '{"state":"CLOSED","closedAt":"2026-05-09T11:00:00Z"}'
    ;;
  *"pr view"*)
    # Not a PR for any of these synthetic numbers.
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

# tmux stub : record paste-buffer + send-keys but otherwise no-op.
cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_TMP/logs/tmux.log"
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

# Minimal canonical brief that passes prompt validation.
make_brief() {
  local agent=$1 ticket=$2 path=$3
  cat > "$path" <<EOF
# Dispatch — agent=${agent} ticket=#${ticket}

## Workdir
${TEST_TMP}/worktrees/${agent}

## Summary
Synthetic fixture brief for ORDO #598 coverage.

## Validation
bash tests/_noop.sh
EOF
}

# Common dispatch invocation — minimal flags, validation off so the
# fixture brief is accepted.
run_dispatch() {
  local prompt=$1
  local ticket=$2
  shift 2
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_DRY_RUN=1 \
  ORCH_LOAD_GATE_MODE=off \
  VALIDATE_PROMPT=0 \
  "$@" \
    bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
      "$TEST_TMP/test.config.sh" claude "$ticket" "$prompt"
}

# Case 1: CLOSED issue (#7001) — dispatch must REFUSE, exit 0, no /tmp file.
brief1="$TEST_TMP/dispatch-claude-7001.md"
make_brief claude 7001 "$brief1"
set +e
out1=$(run_dispatch "$brief1" 7001 2>&1)
rc1=$?
set -e

[ "$rc1" -eq 0 ] \
  || fail "case 1 (closed) — expected exit 0, got $rc1: $out1"

[[ "$out1" == *"REFUSED #7001"*"issue closed"* ]] \
  || fail "case 1 — expected REFUSED #7001 in stderr, got: $out1"

if grep -q 'DISPATCH REFUSED reason=issue_closed' "$TEST_TMP/logs/dispatch-refuse-closed-test.log" 2>/dev/null; then
  : # ok
else
  audit_lines=$(cat "$TEST_TMP/logs/dispatch-refuse-closed-test.log" 2>/dev/null || true)
  fail "case 1 — expected audit line 'DISPATCH REFUSED reason=issue_closed', got: $audit_lines"
fi

if [ -f /tmp/dispatch-claude-7001.md ]; then
  fail "case 1 — /tmp/dispatch-claude-7001.md must NOT exist after refusal"
fi

# Case 2: OPEN issue (#7002) — dispatch must NOT refuse on issue-state
# grounds. We bypass downstream gates with ORCH_DRY_RUN=1, so the only
# refusal paths still active are the issue-state guards. Any non-issue
# refusal (or a successful exit) means the issue-state guard let it
# through.
brief2="$TEST_TMP/dispatch-claude-7002.md"
make_brief claude 7002 "$brief2"
set +e
out2=$(run_dispatch "$brief2" 7002 2>&1)
# Note: we do not assert on the exit code here — downstream gates
# (host-load, tmux preflight, etc.) may legitimately refuse for
# reasons unrelated to the issue-state guard. The contract is that
# the OPEN issue must NOT trigger the issue-state refusal path.
set -e

[[ "$out2" != *"REFUSED #7002"*"issue closed"* ]] \
  || fail "case 2 (open) — expected NO 'REFUSED issue_closed' for open issue, got: $out2"

if grep -q 'ticket=#7002' "$TEST_TMP/logs/dispatch-refuse-closed-test.log" 2>/dev/null \
   && grep -q 'DISPATCH REFUSED reason=issue_closed.*ticket=#7002' "$TEST_TMP/logs/dispatch-refuse-closed-test.log" 2>/dev/null; then
  fail "case 2 — open issue must NOT trigger 'DISPATCH REFUSED reason=issue_closed', audit: $(cat "$TEST_TMP/logs/dispatch-refuse-closed-test.log")"
fi

# Case 3: CLOSED issue (#7003) with REFUSE_CLOSED_ISSUE=0 — the opt-out
# bypass must allow dispatch to proceed past the issue-state guard.
brief3="$TEST_TMP/dispatch-claude-7003.md"
make_brief claude 7003 "$brief3"
set +e
out3=$(run_dispatch "$brief3" 7003 REFUSE_CLOSED_ISSUE=0 2>&1)
# Same as case 2: opt-out path may still trip downstream gates;
# we only assert that the issue-state guard does not fire.
set -e

[[ "$out3" != *"REFUSED #7003"*"issue closed"* ]] \
  || fail "case 3 (opt-out) — REFUSE_CLOSED_ISSUE=0 must bypass guard, got: $out3"

if grep -q 'DISPATCH REFUSED reason=issue_closed.*ticket=#7003' "$TEST_TMP/logs/dispatch-refuse-closed-test.log" 2>/dev/null; then
  fail "case 3 — REFUSE_CLOSED_ISSUE=0 path must NOT emit issue_closed refusal: $(cat "$TEST_TMP/logs/dispatch-refuse-closed-test.log")"
fi

printf 'ok - dispatch_ticket refuses closed issues (default on) and respects REFUSE_CLOSED_ISSUE=0 opt-out\n'
