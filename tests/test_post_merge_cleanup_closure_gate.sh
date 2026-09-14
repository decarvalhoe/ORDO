#!/usr/bin/env bash
# Issue #723: post_merge_cleanup must consult closure_acceptance_gate before
# propagating an auto-close on a non-default-branch merge. This test wires a
# minimal fixture where:
#   * PR #900 merges into `develop` with `Closes #900-source`
#   * Source issue carries UAT-style DoD bullets
#   * PR body has NO acceptance block, NO operator override, NO scaffold trailer
# The gate must refuse close, emit a CLOSURE_REFUSED audit row, and the
# `gh issue close` mutation must NOT fire.
#
# A second scenario merges PR #901 whose body carries a valid acceptance
# block; the close must proceed.
set -euo pipefail

# PR #743: closure_acceptance_gate is opt-in (default off).
# This test exercises enforce mode explicitly.
export ORCH_CLOSURE_GATE_MODE=enforce

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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" \
  "$TEST_TMP/bin" "$TEST_TMP/repos" "$TEST_TMP/logs"

for rel in \
  scripts/post_merge_cleanup.sh \
  lib/agent_inventory.sh \
  lib/audit_log.sh \
  lib/closure_acceptance.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/external_mutation_gate.sh \
  lib/log_bounds.sh \
  lib/process_safety.sh \
  lib/state_persist.sh \
  lib/tmux_helpers.sh \
  lib/ordo_contracts.sh \
  lib/ordo_provider_adapter.sh \
  lib/ordo_provider_adapter_github.sh \
  lib/ordo_provider_adapter_fake.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh"

configure_git() {
  local repo=$1
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name "Closure Gate Test"
}

remote_repo="$TEST_TMP/remote.git"
seed_repo="$TEST_TMP/seed"
git init -q --bare "$remote_repo"
git init -q "$seed_repo"
configure_git "$seed_repo"
printf 'v1\n' > "$seed_repo/file.txt"
git -C "$seed_repo" add file.txt
git -C "$seed_repo" commit -q -m 'initial'
git -C "$seed_repo" branch -M develop
git -C "$seed_repo" remote add origin "$remote_repo"
git -C "$seed_repo" push -q -u origin develop
git -C "$remote_repo" symbolic-ref HEAD refs/heads/develop

# PR mock returns bodies that the gate evaluates. Issue 900 has lazy PR;
# issue 901 has a valid acceptance block. Issue body mock supplies UAT DoD.
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view 900"*)
    printf '%s\n' '{
      "number":900,
      "title":"feat: lazy close",
      "body":"Closes #900\n\nAdds the implementation. No proof block.",
      "url":"https://example.test/pull/900",
      "state":"MERGED",
      "headRefName":"feat/issue-900",
      "headRefOid":"sha900",
      "baseRefName":"develop",
      "mergedAt":"2026-05-19T12:00:00Z",
      "mergeCommit":{"oid":"merge900"},
      "closingIssuesReferences":[]
    }'
    ;;
  *"pr view 901"*)
    printf '%s\n' '{
      "number":901,
      "title":"feat: with proof",
      "body":"Closes #901\n\n```acceptance\n- Hard-gate test passes — artifact: run-id:hg-2026-05-19-z\n- Widget renders — evidence: https://audit.test/v2/r.html\n```",
      "url":"https://example.test/pull/901",
      "state":"MERGED",
      "headRefName":"feat/issue-901",
      "headRefOid":"sha901",
      "baseRefName":"develop",
      "mergedAt":"2026-05-19T12:00:00Z",
      "mergeCommit":{"oid":"merge901"},
      "closingIssuesReferences":[]
    }'
    ;;
  *"issue view 900"*)
    printf '%s\n' '{"body":"## Acceptance Criteria\n\n- [ ] Hard-gate test re-runs clean against the merged commit.\n- [ ] Widget renders on every V2 surface listed in the audit.\n"}'
    ;;
  *"issue view 901"*)
    printf '%s\n' '{"body":"## Acceptance Criteria\n\n- [ ] Hard-gate test re-runs clean against the merged commit.\n- [ ] Widget renders on every V2 surface listed in the audit.\n"}'
    ;;
  *"repo view RBOKproject/realisons-wordpress"*defaultBranchRef*)
    printf '%s\n' '{"defaultBranchRef":{"name":"main"}}'
    ;;
  *"issue close 900"*)
    printf '%s\n' "$*" >> "$ORCH_LOG_DIR/issue-close-attempts.log"
    printf '%s\n' '{"state":"CLOSED"}'
    ;;
  *"issue close 901"*)
    printf '%s\n' "$*" >> "$ORCH_LOG_DIR/issue-close-attempts.log"
    printf '%s\n' '{"state":"CLOSED"}'
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="closure-gate-test"
GH_REPO="RBOKproject/realisons-wordpress"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
REPO_URL="$remote_repo"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=()
EOF

mkdir -p "$TEST_TMP/state/closure-gate-test"
printf '%s\n' '{}' > "$TEST_TMP/state/closure-gate-test/assignments.json"

# Scenario A: lazy PR — gate must refuse close.
lazy_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_EXTERNAL_PR_MUTATIONS=issue_close \
  bash "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh" "$TEST_TMP/config.sh" 900 --json
)

printf '%s\n' "$lazy_output" | jq -e '
  .[]
  | select(.pr == 900
      and .action == "issue_reconcile"
      and .status == "blocked"
      and .reason == "closure_refused"
      and (.detail | contains("issue=#900"))
      and (.detail | contains("outcome=refused"))
      and (.detail | contains("reason=missing-acceptance-proof")))
' >/dev/null || fail "lazy PR must produce CLOSURE_REFUSED record: $lazy_output"

if [[ -e "$TEST_TMP/logs/issue-close-attempts.log" ]] \
  && grep -q "issue close 900" "$TEST_TMP/logs/issue-close-attempts.log"; then
  fail "lazy PR must NOT call gh issue close"
fi

# Scenario B: PR with acceptance proof — gate passes, close proceeds.
proof_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_EXTERNAL_PR_MUTATIONS=issue_close \
  bash "$SANITIZED_ROOT/scripts/post_merge_cleanup.sh" "$TEST_TMP/config.sh" 901 --json
)

printf '%s\n' "$proof_output" | jq -e '
  .[]
  | select(.pr == 901
      and .action == "issue_reconcile"
      and .status == "ok"
      and .reason == "closed"
      and (.detail | contains("issue=#901")))
' >/dev/null || fail "PR with acceptance block must close referenced issue: $proof_output"

grep -q "issue close 901" "$TEST_TMP/logs/issue-close-attempts.log" \
  || fail "PR with acceptance block must invoke gh issue close"

# Audit log must record the gate's verdict for both scenarios so operators
# can reconstruct the closure decision later.
grep -q "CLOSURE_REFUSED issue=#900" "$TEST_TMP/logs/closure-gate-test.log" \
  || fail "audit log must record CLOSURE_REFUSED for issue #900"
grep -q "CLOSURE_GATE pass issue=#901" "$TEST_TMP/logs/closure-gate-test.log" \
  || fail "audit log must record CLOSURE_GATE pass for issue #901"

printf 'ok - post_merge_cleanup gates auto-close on closure_acceptance proof\n'
