#!/usr/bin/env bash
# tests/test_ci_autofix_pr_head_branch.sh — coverage for ORDO #628.
#
# When `ci_autofix.sh <project> <pr> <agent>` targets an open PR, the
# downstream `dispatch_ticket.sh` MUST route to the PR's actual head
# branch (e.g. `fix/issue-603-...`) — not a synthetic `feat/issue-<PR>`
# that would diverge from the PR head and hide remediation commits.
#
# Live evidence (#628) showed PR #620 / #621 stuck red because their
# autofix waves committed on `feat/issue-620` / `feat/issue-621` while
# the PR heads were `fix/issue-618-run-shellcheck-timeout` and
# `fix/issue-603-ordo-live-worktree-status`.
#
# Approach: stub `gh` + `tmux` + `dispatch_ticket.sh` to capture the
# environment ci_autofix forwards. Verify ORCH_DISPATCH_BRANCH_OVERRIDE
# is set to the PR's headRefName when ci_autofix dispatches.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_TMP"
  rm -f /tmp/dispatch-claude-autofix-pr-820.md
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/logs" "$TEST_TMP/state"

# gh stub: returns OPEN PR 820 with a non-default head branch
# (`fix/issue-617-host-assessment-text-mode-isolation` — i.e. NOT
# `feat/issue-820`). Returns failed checks list so ci_autofix proceeds
# past its no-failures early-exit.
cat > "$TEST_TMP/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view 820"*"--json"*"state"*)
    printf '%s\n' '{"title":"Live autofix PR","headRefName":"fix/issue-617-host-assessment-text-mode-isolation","baseRefName":"main","changedFiles":1,"files":[{"path":"tests/test_host_assessment.sh"}],"url":"https://github.com/RBOKproject/ORDO/pull/820","state":"OPEN","mergedAt":"","closedAt":"","mergeCommit":null}'
    ;;
  *"pr checks 820"*"--json"*)
    printf '%s\n' '[{"name":"validate","state":"failure","bucket":"fail","link":"https://example.com/run/1","workflow":"CI"}]'
    ;;
  *"run view"*)
    printf '%s\n' "stub run log content"
    ;;
  *)
    exit 0
    ;;
esac
GHEOF
chmod +x "$TEST_TMP/bin/gh"

# dispatch_ticket stub: record argv + ORCH_DISPATCH_BRANCH_OVERRIDE
# value into a deterministic log so the test can assert the env var
# was forwarded.
cat > "$TEST_TMP/bin/dispatch_ticket.sh" <<EOF
#!/usr/bin/env bash
{
  printf 'argv=%s\n' "\$*"
  printf 'ORCH_DISPATCH_BRANCH_OVERRIDE=%s\n' "\${ORCH_DISPATCH_BRANCH_OVERRIDE:-(unset)}"
} >> "$TEST_TMP/logs/dispatch_ticket.log"
exit 0
EOF
chmod +x "$TEST_TMP/bin/dispatch_ticket.sh"

# tmux stub (no-op).
cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

# Minimal config consumable by ci_autofix.
cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="ci-autofix-628-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
EOF

# Override ci_autofix's dispatch_ticket invocation by intercepting
# `bash "$TK/scripts/dispatch_ticket.sh"`. We stub the path by
# replacing the toolkit dispatch_ticket with our log-recorder via a
# bin shim.

# Sanitize a copy of ci_autofix.sh and required libs so the script can
# run with the stubbed dispatch_ticket on $PATH.
SANITIZED_ROOT="$TEST_TMP/toolkit"
mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib"
for rel in scripts/ci_autofix.sh \
           lib/api_rate_limiter.sh \
           lib/audit_log.sh \
           lib/log_bounds.sh \
           lib/ci_external_blockers.sh \
           lib/config_check.sh \
           lib/config_resolver.sh \
           lib/dry_run.sh \
           lib/portfolio_config.sh \
           lib/state_persist.sh; do
  if [ -f "$ROOT/$rel" ]; then
    tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
  fi
done

# Hot-patch sanitized ci_autofix.sh: replace `bash "$TK/scripts/dispatch_ticket.sh"`
# with `bash dispatch_ticket.sh` (PATH-resolved → our stub recorder).
# shellcheck disable=SC2016 # the sed pattern must match the literal $TK token.
sed -i 's|bash "\$TK/scripts/dispatch_ticket.sh"|bash dispatch_ticket.sh|' "$SANITIZED_ROOT/scripts/ci_autofix.sh"

chmod +x "$SANITIZED_ROOT/scripts/ci_autofix.sh"

# Run ci_autofix against PR #820 with the stubbed environment.
PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
ORCH_STATE_BASE="$TEST_TMP/state" \
ORCH_DRY_RUN=1 \
  bash "$SANITIZED_ROOT/scripts/ci_autofix.sh" \
    "$TEST_TMP/test.config.sh" 820 claude 2>&1 \
  | tee "$TEST_TMP/logs/ci_autofix.stdout" >/dev/null

# Assert dispatch_ticket was invoked with ORCH_DISPATCH_BRANCH_OVERRIDE
# set to the PR's headRefName (NOT `feat/issue-820`).
if ! grep -q '^ORCH_DISPATCH_BRANCH_OVERRIDE=fix/issue-617-host-assessment-text-mode-isolation$' "$TEST_TMP/logs/dispatch_ticket.log"; then
  fail "expected ORCH_DISPATCH_BRANCH_OVERRIDE=fix/issue-617-... ; got: $(cat "$TEST_TMP/logs/dispatch_ticket.log")"
fi

# Negative assertion: ORCH_DISPATCH_BRANCH_OVERRIDE must not be unset
# or set to feat/issue-820 in the dispatch invocation. The unique
# headRefName in the gh stub guards against accidental matches.
if grep -q '^ORCH_DISPATCH_BRANCH_OVERRIDE=feat/issue-820$' "$TEST_TMP/logs/dispatch_ticket.log"; then
  fail "ORCH_DISPATCH_BRANCH_OVERRIDE must NOT be feat/issue-820: $(cat "$TEST_TMP/logs/dispatch_ticket.log")"
fi
if grep -q '^ORCH_DISPATCH_BRANCH_OVERRIDE=(unset)$' "$TEST_TMP/logs/dispatch_ticket.log"; then
  fail "ORCH_DISPATCH_BRANCH_OVERRIDE must be set: $(cat "$TEST_TMP/logs/dispatch_ticket.log")"
fi

printf 'ok - ci_autofix routes PR autofix to the PR head branch (no synthetic feat/issue-<pr>)\n'
