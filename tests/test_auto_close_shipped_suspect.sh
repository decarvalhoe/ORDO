#!/usr/bin/env bash
# Issue #762: queue resolver phase A — auto_close_shipped_suspect.sh.
#
# Verifies the script wires the closure_acceptance_gate (#723) to the
# shipped_suspect rows surfaced by dispatch_plan and that:
#
#   * --dry-run never invokes gh issue close and emits one
#     AUTO_CLOSE_CANDIDATE audit row per shipped_suspect row;
#   * --apply closes the issue only when closure_acceptance_should_close
#     returns true AND the PR body carries an artifact-bearing
#     acceptance block;
#   * --apply refuses a row whose PR body lacks acceptance proof, even
#     when the planner classified it as shipped_suspect;
#   * mode=off short-circuits without contacting gh at all.
#
# The test feeds the script a synthetic plan via --plan-file so it
# does not need to run dispatch_plan.sh against a real repo.
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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" \
  "$TEST_TMP/bin" "$TEST_TMP/logs" "$TEST_TMP/state/auto-close-test"

for rel in \
  scripts/auto_close_shipped_suspect.sh \
  lib/audit_log.sh \
  lib/closure_acceptance.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/external_mutation_gate.sh \
  lib/log_bounds.sh \
  lib/ordo_contracts.sh \
  lib/ordo_provider_adapter.sh \
  lib/ordo_provider_adapter_github.sh \
  lib/ordo_provider_adapter_fake.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/auto_close_shipped_suspect.sh"

# gh mock: PR #900 = lazy (no acceptance), PR #901 = acceptance proof.
# Issue #800 and #801 both carry the same DoD bullets so the only thing
# differentiating them is the PR body.
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view 900"*body*)
    printf '%s\n' '{"body":"Closes #800\n\nAdds the implementation. No proof block."}'
    ;;
  *"pr view 901"*body*)
    printf '%s\n' '{"body":"Closes #801\n\n```acceptance\n- Hard-gate test passes — artifact: run-id:hg-2026-05-19-z\n- Widget renders — evidence: https://audit.test/v2/r.html\n```"}'
    ;;
  *"issue view 800"*body*|*"issue view 801"*body*)
    printf '%s\n' '{"body":"## Acceptance Criteria\n\n- [ ] Hard-gate test re-runs clean against the merged commit.\n- [ ] Widget renders on every V2 surface listed in the audit.\n"}'
    ;;
  *"issue close 800"*)
    printf '%s\n' "$*" >> "$ORCH_LOG_DIR/issue-close-attempts.log"
    printf '%s\n' '{"state":"CLOSED"}'
    ;;
  *"issue close 801"*)
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
PROJECT="auto-close-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=()
EOF

# Synthetic plan with two shipped_suspect rows, one lazy and one with proof,
# plus a non-shipped_suspect row to confirm the filter.
cat > "$TEST_TMP/plan.json" <<'EOF'
[
  {
    "issue": 800,
    "priority": "P2",
    "score": -300,
    "status": "shipped_suspect",
    "signals": ["shipped-suspect","merged-pr:#900","stale-suspect"],
    "title": "lazy close candidate"
  },
  {
    "issue": 801,
    "priority": "P2",
    "score": -300,
    "status": "shipped_suspect",
    "signals": ["shipped-suspect","merged-pr:#901","stale-suspect"],
    "title": "acceptance-proof candidate"
  },
  {
    "issue": 802,
    "priority": "P3",
    "score": 0,
    "status": "ready",
    "signals": ["ready","unassigned"],
    "title": "unrelated ready row"
  }
]
EOF

run_script() {
  local mode=$1
  shift
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_EXTERNAL_PR_MUTATIONS="${ORCH_EXTERNAL_PR_MUTATIONS:-}" \
  bash "$SANITIZED_ROOT/scripts/auto_close_shipped_suspect.sh" \
    "$TEST_TMP/config.sh" "--$mode" --json --plan-file "$TEST_TMP/plan.json" "$@"
}

# ------------------------------------------------------------------
# Scenario 1: --dry-run never closes anything, emits both candidates.
# ------------------------------------------------------------------
rm -f "$TEST_TMP/logs/issue-close-attempts.log"
dry_output=$(run_script dry-run)

printf '%s\n' "$dry_output" | jq -e '
  .[]
  | select(.issue == 800
      and .pr == 900
      and .outcome == "refused"
      and .action == "audit_only"
      and .reason == "missing-acceptance-proof"
      and .mode == "dry-run")
' >/dev/null || fail "dry-run must emit audit_only row for lazy PR: $dry_output"

printf '%s\n' "$dry_output" | jq -e '
  .[]
  | select(.issue == 801
      and .pr == 901
      and .outcome == "pass"
      and .action == "would_close"
      and .mode == "dry-run")
' >/dev/null || fail "dry-run must emit would_close row for acceptance PR: $dry_output"

printf '%s\n' "$dry_output" | jq -e '[.[] | select(.issue == 802)] | length == 0' >/dev/null \
  || fail "dry-run must not emit a row for non-shipped_suspect status"

if [[ -e "$TEST_TMP/logs/issue-close-attempts.log" ]]; then
  fail "dry-run must NOT invoke gh issue close"
fi

# ------------------------------------------------------------------
# Scenario 2: --apply closes the acceptance-proof row; lazy row stays
# in audit_only because the gate refuses it.
# ------------------------------------------------------------------
rm -f "$TEST_TMP/logs/issue-close-attempts.log"
apply_output=$(ORCH_EXTERNAL_PR_MUTATIONS=issue_close run_script apply)

printf '%s\n' "$apply_output" | jq -e '
  .[]
  | select(.issue == 801
      and .pr == 901
      and .outcome == "pass"
      and .action == "closed"
      and .mode == "apply")
' >/dev/null || fail "--apply must close the acceptance-proof issue: $apply_output"

printf '%s\n' "$apply_output" | jq -e '
  .[]
  | select(.issue == 800
      and .pr == 900
      and .outcome == "refused"
      and .action == "audit_only"
      and .reason == "missing-acceptance-proof"
      and .mode == "apply")
' >/dev/null || fail "--apply must refuse the lazy PR via audit_only: $apply_output"

grep -q "issue close 801" "$TEST_TMP/logs/issue-close-attempts.log" \
  || fail "--apply must invoke gh issue close for issue #801"

if grep -q "issue close 800" "$TEST_TMP/logs/issue-close-attempts.log"; then
  fail "--apply must NOT invoke gh issue close for refused issue #800"
fi

# Audit log must carry one AUTO_CLOSE_CANDIDATE row per processed issue
# and the start banner.
grep -q "AUTO_CLOSE_SHIPPED_SUSPECT start mode=apply" \
  "$TEST_TMP/logs/auto-close-test.log" \
  || fail "audit log must record apply-mode start banner"
grep -q "AUTO_CLOSE_CANDIDATE issue=#800 pr=#900 .* action=audit_only reason=missing-acceptance-proof" \
  "$TEST_TMP/logs/auto-close-test.log" \
  || fail "audit log must record refused candidate row"
grep -q "AUTO_CLOSE_CANDIDATE issue=#801 pr=#901 .* action=closed" \
  "$TEST_TMP/logs/auto-close-test.log" \
  || fail "audit log must record closed candidate row"

# ------------------------------------------------------------------
# Scenario 3: explicit --off short-circuits before contacting gh.
# ------------------------------------------------------------------
rm -f "$TEST_TMP/logs/issue-close-attempts.log"
off_output=$(run_script off)
printf '%s\n' "$off_output" | jq -e '. == []' >/dev/null \
  || fail "--off must emit an empty array: $off_output"
if [[ -e "$TEST_TMP/logs/issue-close-attempts.log" ]]; then
  fail "--off must NOT invoke gh issue close"
fi
grep -q "AUTO_CLOSE_SHIPPED_SUSPECT skip mode=off" \
  "$TEST_TMP/logs/auto-close-test.log" \
  || fail "audit log must record off-mode skip banner"

# ------------------------------------------------------------------
# Scenario 4: --apply without ORCH_EXTERNAL_PR_MUTATIONS authorisation
# must refuse the close mutation (the provider adapter gate returns a
# policy_refused exit code), so the row is reported as close_failed and
# the issue close is never executed.
# ------------------------------------------------------------------
rm -f "$TEST_TMP/logs/issue-close-attempts.log"
# Scenario 2 recorded the close of #801 in the provider adapter's
# idempotency ledger (#816); a replayed key returns the recorded receipt
# without asking the policy again, so start scenario 4 from a fresh ledger.
rm -f "$TEST_TMP"/state/*/ordo-provider-idempotency.jsonl
unauth_output=$(run_script apply || true)
printf '%s\n' "$unauth_output" | jq -e '
  .[]
  | select(.issue == 801
      and .action == "close_failed"
      and (.reason | startswith("issue_close_rc=")))
' >/dev/null || fail "--apply without authorised scope must report close_failed: $unauth_output"

if [[ -e "$TEST_TMP/logs/issue-close-attempts.log" ]] \
  && grep -q "issue close 801" "$TEST_TMP/logs/issue-close-attempts.log"; then
  fail "--apply without authorised scope must NOT execute gh issue close"
fi

printf 'ok - auto_close_shipped_suspect gates closure on closure_acceptance proof\n'
