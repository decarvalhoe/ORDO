#!/usr/bin/env bash
# test_ticket_scope_validator.sh — regression coverage for the
# ticket-scope dispatch gate (#369).
#
# The 2026-05-08 incident generated `/tmp/dispatch-rbok-gemini-367.md`
# whose header said `Ticket: ORDO #367` but whose acceptance / branch
# slug actually came from #368. This suite pins the validator's
# behaviour against that exact failure mode (adjacent issue IDs with
# different scopes), the structural mismatch path, the manual-rebind
# escape hatch, and the per-call audit shape.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

mkdir -p "$TEST_TMP/logs" "$TEST_TMP/state" "$TEST_TMP/repos" "$TEST_TMP/gh"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/brief_agents.sh \
  templates/dispatch-canonical.md.tpl

chmod +x "$SANITIZED_ROOT/scripts/brief_agents.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="ticket-scope-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="origin"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

export ORCH_LOG_DIR="$TEST_TMP/logs"
export ORCH_STATE_BASE="$TEST_TMP/state"

# --- Library-level unit cases ---------------------------------------------

cat > "$TEST_TMP/lib_loader.sh" <<EOF
set -euo pipefail
export PROJECT='ticket-scope-test'
export ORCH_LOG_DIR='$TEST_TMP/logs'
export ORCH_STATE_BASE='$TEST_TMP/state'
export AGENT_WORKDIR_TEMPLATE='$TEST_TMP/repos/%s'
source '$SANITIZED_ROOT/lib/audit_log.sh'
source '$SANITIZED_ROOT/lib/ticket_scope_validator.sh'
EOF

LIB_LOADER="source '$TEST_TMP/lib_loader.sh'"

# extract_branch_issue_number: modern numbered slugs return the number;
# legacy default `feat/<project>-ticket-<N>` deliberately returns empty.
out=$(bash -c "$LIB_LOADER; ticket_scope_extract_branch_issue_number 'fix/367-validate-portability-shell-tests'")
[[ "$out" == "367" ]] || fail "expected leading-number extract = 367 (got: $out)"

out=$(bash -c "$LIB_LOADER; ticket_scope_extract_branch_issue_number 'feat/350-portfolio-auto-merge'")
[[ "$out" == "350" ]] || fail "expected leading-number extract = 350 (got: $out)"

out=$(bash -c "$LIB_LOADER; ticket_scope_extract_branch_issue_number 'feat/ticket-scope-test-ticket-7001'")
[[ -z "$out" ]] || fail "expected empty extract for legacy slug (got: $out)"

out=$(bash -c "$LIB_LOADER; ticket_scope_extract_branch_issue_number 'codex/externalize-ordo-topology'")
[[ -z "$out" ]] || fail "expected empty extract for non-conventional prefix (got: $out)"

# extract_slug_tail
out=$(bash -c "$LIB_LOADER; ticket_scope_extract_slug_tail 'fix/367-validate-portability-shell-tests'")
[[ "$out" == "validate-portability-shell-tests" ]] \
  || fail "expected slug_tail = validate-portability-shell-tests (got: $out)"

# acceptance_scope_hash is deterministic over the inputs.
hash_a=$(bash -c "$LIB_LOADER; ticket_scope_compute_acceptance_hash 367 fix/367-foo 'workdir not ready' 'lib/foo.sh'")
hash_b=$(bash -c "$LIB_LOADER; ticket_scope_compute_acceptance_hash 367 fix/367-foo 'workdir not ready' 'lib/foo.sh'")
hash_c=$(bash -c "$LIB_LOADER; ticket_scope_compute_acceptance_hash 367 fix/367-foo 'something else' 'lib/foo.sh'")
[[ -n "$hash_a" && "$hash_a" == "$hash_b" ]] || fail "scope hash should be deterministic over identical inputs"
[[ "$hash_a" != "$hash_c" ]] || fail "scope hash should change when summary changes"

# validate ok path: aligned ticket + slug + summary
ok_row=$(bash -c "$LIB_LOADER; ticket_scope_validate 367 'fix/367-workdir-not-ready-diagnostics' 'workdir not ready diagnostics' 'lib/foo.sh' 'workdir not ready diagnostics' brief_agents")
[[ "$(printf '%s' "$ok_row" | cut -f1)" == "ok" ]] \
  || fail "aligned dispatch should classify as ok (got: $ok_row)"
[[ "$(printf '%s' "$ok_row" | cut -f3)" == "367" ]] \
  || fail "branch_issue_number column should expose 367 (got: $ok_row)"

# validate structural mismatch: branch leading-number != ticket
struct_row=$(bash -c "$LIB_LOADER; ticket_scope_validate 367 'fix/368-validate-portability-shell-tests' 'workdir not ready diagnostics' '' '' brief_agents")
[[ "$(printf '%s' "$struct_row" | cut -f1)" == "mismatch" ]] \
  || fail "structural mismatch should classify as mismatch (got: $struct_row)"
[[ "$(printf '%s' "$struct_row" | cut -f2)" == "branch-issue-mismatch" ]] \
  || fail "structural mismatch reason should be branch-issue-mismatch (got: $struct_row)"

# validate semantic mismatch: same ticket# in branch, but slug_tail
# describes a different issue from the summary (the actual #367/#368 case).
semantic_row=$(bash -c "$LIB_LOADER; ticket_scope_validate 367 'fix/367-validate-portability-shell-tests' 'workdir not ready diagnostics' '' '' brief_agents")
[[ "$(printf '%s' "$semantic_row" | cut -f1)" == "mismatch" ]] \
  || fail "semantic mismatch should classify as mismatch (got: $semantic_row)"
[[ "$(printf '%s' "$semantic_row" | cut -f2)" == "slug-summary-divergence" ]] \
  || fail "semantic reason should be slug-summary-divergence (got: $semantic_row)"

# legacy default slug (no leading number) skips the semantic check, since
# the slug_tail extractor returns empty. This keeps existing brief_agents
# callers that use the legacy format from being refused.
legacy_row=$(bash -c "$LIB_LOADER; ticket_scope_validate 7001 'feat/ticket-scope-test-ticket-7001' 'an unrelated summary' '' '' brief_agents")
[[ "$(printf '%s' "$legacy_row" | cut -f1)" == "ok" ]] \
  || fail "legacy slug should pass without semantic check (got: $legacy_row)"

# acceptance surface mismatch: the ticket requests the UC-MGR manager
# lifecycle surface, but the allowlist only exposes sibling agenda and
# knowledge UAT paths. This is the #3198 false-busy failure mode.
manager_scope_row=$(bash -c "$LIB_LOADER; ticket_scope_validate 3198 'fix/3198-uc-mgr-lifecycle-gates' 'UC-MGR manager lifecycle gates' 'frontend/e2e/uat/tests/agenda/** frontend/e2e/uat/tests/knowledge/**' 'UC-MGR manager lifecycle gates' brief_agents")
[[ "$(printf '%s' "$manager_scope_row" | cut -f1)" == "mismatch" ]] \
  || fail "manager lifecycle surface should be refused when allowlist has only sibling paths (got: $manager_scope_row)"
[[ "$(printf '%s' "$manager_scope_row" | cut -f2)" == "acceptance-scope-uncovered" ]] \
  || fail "manager lifecycle refusal reason should be acceptance-scope-uncovered (got: $manager_scope_row)"

# Broad ancestors can satisfy the surface even when the literal manager
# segment is not present in the allowlist.
manager_broad_row=$(bash -c "$LIB_LOADER; ticket_scope_validate 3198 'fix/3198-uc-mgr-lifecycle-gates' 'UC-MGR manager lifecycle gates' 'frontend/e2e/uat/tests/**' 'UC-MGR manager lifecycle gates' brief_agents")
[[ "$(printf '%s' "$manager_broad_row" | cut -f1)" == "ok" ]] \
  || fail "broad UAT tests allowlist should satisfy manager lifecycle surface (got: $manager_broad_row)"

# forbidden acceptance cluster: the ticket requests ADM access-lifecycle
# coverage, but the natural path is explicitly forbidden. This pins the
# #3199 failure mode.
admin_forbidden_row=$(bash -c "$LIB_LOADER; ticket_scope_validate 3199 'fix/3199-adm-access-lifecycle-coverage' 'ADM-001/002 access lifecycle coverage' 'frontend/tests/e2e/uat-admin/roles/**' 'ADM-001/002 access lifecycle coverage' brief_agents 'frontend/tests/e2e/uat-admin/access-lifecycle/**'")
[[ "$(printf '%s' "$admin_forbidden_row" | cut -f1)" == "mismatch" ]] \
  || fail "admin access-lifecycle surface should be refused when natural path is forbidden (got: $admin_forbidden_row)"
[[ "$(printf '%s' "$admin_forbidden_row" | cut -f2)" == "forbidden-acceptance-surface" ]] \
  || fail "admin access-lifecycle refusal reason should be forbidden-acceptance-surface (got: $admin_forbidden_row)"

# assert refuses with code 86 on mismatch and emits a structured audit.
log_file="$TEST_TMP/logs/ticket-scope-test.log"
: > "$log_file"
set +e
bash -c "$LIB_LOADER; ticket_scope_assert 367 'fix/368-portability' 'workdir not ready' '' '' brief_agents" \
  >/dev/null 2>"$TEST_TMP/assert_err"
status=$?
set -e
[[ "$status" -eq 86 ]] || fail "assert should exit 86 on mismatch (got: $status)"
grep -q "TICKET_SCOPE_VALIDATION action=validate" "$log_file" \
  || fail "audit line missing on mismatch refusal"
grep -q "ticket_number=367" "$log_file" \
  || fail "audit line should expose ticket_number=367"
grep -q "branch_issue_number=368" "$log_file" \
  || fail "audit line should expose branch_issue_number=368 (the divergence)"
grep -q "status=mismatch" "$log_file" \
  || fail "audit line should expose status=mismatch"
grep -q "mismatch=branch-issue-mismatch" "$log_file" \
  || fail "audit line should expose mismatch reason"
grep -q "acceptance_scope_hash=" "$log_file" \
  || fail "audit line should expose acceptance_scope_hash"

# assert returns 0 on aligned dispatch, audit shows status=ok.
: > "$log_file"
bash -c "$LIB_LOADER; ticket_scope_assert 367 'fix/367-workdir-not-ready' 'workdir not ready diagnostics' '' '' brief_agents" \
  >/dev/null
grep -q "status=ok" "$log_file" \
  || fail "audit line should expose status=ok on aligned dispatch"

# assert_or_rebind never refuses but emits action=rebind so the override
# is durable in the audit ledger.
: > "$log_file"
bash -c "$LIB_LOADER; ticket_scope_assert_or_rebind 367 'fix/368-portability' 'workdir not ready' '' '' brief_agents_rebind" \
  >/dev/null
grep -q "TICKET_SCOPE_VALIDATION action=rebind" "$log_file" \
  || fail "rebind path should emit action=rebind audit line"
grep -q "branch_issue_number=368" "$log_file" \
  || fail "rebind audit should still expose the divergent branch_issue_number"

# --- brief_agents end-to-end fixture --------------------------------------
# This is the #367/#368 acceptance case from the issue body. The
# orchestrator passes `ticket=367` plus a slug + summary that actually
# describe #368's scope. brief_agents must refuse with code 86.
log_file_be="$TEST_TMP/logs/brief-agents-test.log"
brief_config="$TEST_TMP/brief.config.sh"
cat > "$brief_config" <<EOF
#!/usr/bin/env bash
PROJECT="brief-agents-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="origin"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

set +e
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$brief_config" \
  claude 367 \
  branch_slug=fix/367-validate-portability-shell-tests \
  summary="workdir_not_ready diagnostics too coarse" \
  scope_files="lib/host_health.sh" \
  > "$TEST_TMP/brief_out" 2>"$TEST_TMP/brief_err"
status=$?
set -e

[[ "$status" -eq 86 ]] \
  || fail "brief_agents should refuse with 86 on #367/#368 swap (got: $status, stderr: $(cat "$TEST_TMP/brief_err"))"
grep -q "ticket_scope_mismatch" "$TEST_TMP/brief_err" \
  || fail "brief_agents stderr should include ticket_scope_mismatch line"
grep -q "TICKET_SCOPE_VALIDATION" "$log_file_be" \
  || fail "brief_agents must emit TICKET_SCOPE_VALIDATION audit line"
grep -q "ticket_number=367" "$log_file_be" \
  || fail "audit line should record ticket_number=367"
grep -q "mismatch=slug-summary-divergence" "$log_file_be" \
  || fail "audit line should classify as slug-summary-divergence"
[[ ! -s "$TEST_TMP/brief_out" ]] \
  || fail "no brief should be rendered when validator refuses (stdout: $(cat "$TEST_TMP/brief_out"))"

# The brief path must also pass forbidden_files into the acceptance-surface
# gate so an impossible ADM access-lifecycle assignment is blocked before
# the prompt is rendered or sent.
: > "$log_file_be"
set +e
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$brief_config" \
  claude 3199 \
  branch_slug=fix/3199-adm-access-lifecycle-coverage \
  summary="ADM-001/002 access lifecycle coverage" \
  ticket_title="ADM-001/002 access lifecycle coverage" \
  scope_files="frontend/tests/e2e/uat-admin/roles/**" \
  forbidden_files="frontend/tests/e2e/uat-admin/access-lifecycle/**" \
  > "$TEST_TMP/brief_out_forbidden_surface" 2>"$TEST_TMP/brief_err_forbidden_surface"
forbidden_surface_status=$?
set -e
[[ "$forbidden_surface_status" -eq 86 ]] \
  || fail "brief_agents should refuse when acceptance surface is forbidden (got: $forbidden_surface_status, stderr: $(cat "$TEST_TMP/brief_err_forbidden_surface"))"
grep -q "reason=forbidden-acceptance-surface" "$TEST_TMP/brief_err_forbidden_surface" \
  || fail "brief_agents stderr should include forbidden acceptance surface reason"
grep -q "mismatch=forbidden-acceptance-surface" "$log_file_be" \
  || fail "brief_agents audit should classify forbidden acceptance surface"
[[ ! -s "$TEST_TMP/brief_out_forbidden_surface" ]] \
  || fail "no brief should render when acceptance surface is forbidden"

# Aligned dispatch must still render the brief.
: > "$log_file_be"
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$brief_config" \
  claude 369 \
  branch_slug=fix/369-reject-mismatched-ticket-scope \
  summary="reject mismatched ticket scope" \
  scope_files="lib/ticket_scope_validator.sh" \
  > "$TEST_TMP/brief_out_ok" 2>"$TEST_TMP/brief_err_ok"
[[ -s "$TEST_TMP/brief_out_ok" ]] \
  || fail "aligned dispatch should render a brief (stderr: $(cat "$TEST_TMP/brief_err_ok"))"
grep -q "Ticket: #369" "$TEST_TMP/brief_out_ok" \
  || fail "rendered brief should carry the ticket header"
grep -q "TICKET_SCOPE_VALIDATION action=validate" "$log_file_be" \
  || fail "aligned dispatch should still emit a validate audit line (status=ok)"
grep -q "status=ok" "$log_file_be" \
  || fail "aligned dispatch audit should be status=ok"

# --allow-rebind path: same #367/#368 swap but operator opts to keep
# the brief. The brief renders, exit is 0, and audit carries action=rebind.
: > "$log_file_be"
set +e
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$brief_config" \
  claude 367 \
  --allow-rebind \
  branch_slug=fix/367-validate-portability-shell-tests \
  summary="workdir_not_ready diagnostics too coarse" \
  > "$TEST_TMP/brief_out_rebind" 2>"$TEST_TMP/brief_err_rebind"
rebind_status=$?
set -e
[[ "$rebind_status" -eq 0 ]] \
  || fail "--allow-rebind should let the brief render (got: $rebind_status, stderr: $(cat "$TEST_TMP/brief_err_rebind"))"
[[ -s "$TEST_TMP/brief_out_rebind" ]] \
  || fail "rebind path should render the brief"
grep -q "TICKET_SCOPE_VALIDATION action=rebind" "$log_file_be" \
  || fail "rebind path should emit action=rebind audit line"
grep -q "status=mismatch" "$log_file_be" \
  || fail "rebind audit must still record the underlying mismatch"

printf 'ok - ticket_scope_validator refuses #367/#368-style swaps and exposes audit evidence\n'
