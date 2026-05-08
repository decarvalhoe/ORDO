#!/usr/bin/env bash
# tests/test_dispatch_pr_ops.sh — covers lib/pr_ops_tasks.sh and
# scripts/dispatch_pr_ops.sh (#359).
#
# Exercises:
#   - classifier (signals → fix_ci | resolve_conflict | mark_ready_candidate | none)
#   - mutation-scope helper
#   - validator (negative cases: missing mergeability, dirty clone,
#     duplicate assignment, hotspot conflict, missing policy, observe mode)
#   - end-to-end dry-run dispatch on TWO project fixtures (alpha/beta),
#     proving universal behaviour
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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$SANITIZED_ROOT/templates" \
  "$TEST_TMP/bin" "$TEST_TMP/state"

for rel in \
  scripts/dispatch_pr_ops.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/pr_ops_tasks.sh \
  lib/process_safety.sh \
  templates/pr_op_fix_ci.md.tpl \
  templates/pr_op_resolve_conflict.md.tpl \
  templates/pr_op_mark_ready_candidate.md.tpl
do
  mkdir -p "$SANITIZED_ROOT/$(dirname "$rel")"
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/dispatch_pr_ops.sh"

# ----------------------------------------------------------------------------
# Unit coverage for lib/pr_ops_tasks.sh
# ----------------------------------------------------------------------------
# shellcheck disable=SC1091 # sourcing sanitized copy
source "$SANITIZED_ROOT/lib/pr_ops_tasks.sh"

# Classifier matrix.
[ "$(pr_ops_classify_signals "merge-conflict,review-required")" = "resolve_conflict" ] \
  || fail "merge-conflict must classify as resolve_conflict"
[ "$(pr_ops_classify_signals "needs-rebase")" = "resolve_conflict" ] \
  || fail "needs-rebase must classify as resolve_conflict"
[ "$(pr_ops_classify_signals "ci-failed")" = "fix_ci" ] \
  || fail "ci-failed must classify as fix_ci"
[ "$(pr_ops_classify_signals "draft,ci-pass")" = "mark_ready_candidate" ] \
  || fail "draft+ci-pass must classify as mark_ready_candidate"
[ "$(pr_ops_classify_signals "draft,ci-pending")" = "none" ] \
  || fail "draft+ci-pending must NOT classify as ready_candidate (CI not green)"
[ "$(pr_ops_classify_signals "merge-conflict,ci-failed,draft")" = "resolve_conflict" ] \
  || fail "conflict beats fix_ci and ready_candidate"
[ "$(pr_ops_classify_signals "merge-ready")" = "none" ] \
  || fail "merge-ready is not a remediation task"
[ "$(pr_ops_classify_signals "")" = "none" ] \
  || fail "empty signals classify as none"

# Mutation-scope helper.
[ "$(pr_ops_mutation_scope_for fix_ci)" = "audit_evidence" ] \
  || fail "fix_ci scope must be audit_evidence only"
[ "$(pr_ops_mutation_scope_for resolve_conflict)" = "audit_evidence" ] \
  || fail "resolve_conflict scope must be audit_evidence only"
[ "$(pr_ops_mutation_scope_for mark_ready_candidate)" = "audit_evidence,pr_state" ] \
  || fail "mark_ready_candidate scope must include pr_state"

# Validator negative paths (each must exit non-zero) — `if cmd; then fail`
# inverts the success/failure test cleanly; bash's set -e is suspended inside
# the `if` predicate so we can capture the validator's non-zero rc.
if pr_ops_validate_candidate fix_ci UNKNOWN 0 available delegated 0 0 2>/dev/null; then
  fail "UNKNOWN mergeability must refuse"
fi
if pr_ops_validate_candidate fix_ci MERGEABLE 4 available delegated 0 0 2>/dev/null; then
  fail "dirty clone must refuse"
fi
if pr_ops_validate_candidate fix_ci MERGEABLE 0 dispatched delegated 0 0 2>/dev/null; then
  fail "agent not available must refuse"
fi
if pr_ops_validate_candidate fix_ci MERGEABLE 0 available delegated 0 1 2>/dev/null; then
  fail "duplicate assignment must refuse"
fi
if pr_ops_validate_candidate fix_ci MERGEABLE 0 available delegated 1 0 2>/dev/null; then
  fail "hotspot conflict must refuse"
fi
if pr_ops_validate_candidate fix_ci MERGEABLE 0 available observe 0 0 2>/dev/null; then
  fail "observe mode must refuse to emit a task"
fi
if pr_ops_validate_candidate mark_ready_candidate MERGEABLE 0 available centralized 0 0 2>/dev/null; then
  fail "centralized mode must refuse mark_ready_candidate (operator-owned)"
fi
if ! pr_ops_validate_candidate resolve_conflict CONFLICTING 0 available delegated 0 0 2>/dev/null; then
  fail "resolve_conflict + CONFLICTING must succeed"
fi
if pr_ops_validate_candidate fix_ci CONFLICTING 0 available delegated 0 0 2>/dev/null; then
  fail "CONFLICTING mergeability must refuse fix_ci task (must rebase first)"
fi

# Template rendering: every required placeholder must be substituted, and
# universal sections must be present. Inline `VAR=val func` assignments are
# consumed by `pr_ops_render_template` after it auto-exports them; shellcheck
# cannot see that lifecycle, hence the per-line disables below.
# shellcheck disable=SC2034
PR_OPS_TPL_PR_URL="https://example.test/owner/repo/pull/42" \
PR_OPS_TPL_PR_NUMBER="42" \
PR_OPS_TPL_REPO="owner/repo" \
PR_OPS_TPL_BRANCH="feat/x" \
PR_OPS_TPL_BASE_BRANCH="main" \
PR_OPS_TPL_PROJECT="alpha" \
PR_OPS_TPL_AGENT_LABEL="planner" \
PR_OPS_TPL_AGENT_WORKDIR="/work/alpha-planner" \
PR_OPS_TPL_MUTATION_SCOPE="audit_evidence" \
PR_OPS_TPL_FILE_OWNERSHIP="src/foo.ts,src/bar.ts" \
PR_OPS_TPL_HOTSPOT_FILES="none" \
PR_OPS_TPL_CI_FAILING="2" \
PR_OPS_TPL_CI_PENDING="0" \
PR_OPS_TPL_CI_ROLLUP="fail" \
PR_OPS_TPL_MERGEABLE="MERGEABLE" \
PR_OPS_TPL_CONFLICT_SIGNALS="ci-failed" \
PR_OPS_TPL_VERIFICATION_COMMANDS="bash ci/check.sh" \
PR_OPS_TPL_MERGE_POLICY="no-merge-from-this-task" \
PR_OPS_TPL_EXPECTED_EVIDENCE="state_dir/gate-evidence/pr-42-fix-ci.json" \
PR_OPS_TPL_MODE="delegated" \
PR_OPS_TPL_WAVE_ID="wave-test-1" \
  rendered=$(pr_ops_render_template "$SANITIZED_ROOT/templates/pr_op_fix_ci.md.tpl")
case "$rendered" in
  *"https://example.test/owner/repo/pull/42"*) ;;
  *) fail "fix_ci template did not substitute PR_URL" ;;
esac
case "$rendered" in
  *"feat/x"*) ;;
  *) fail "fix_ci template did not substitute BRANCH" ;;
esac
case "$rendered" in
  *"audit_evidence"*) ;;
  *) fail "fix_ci template did not substitute MUTATION_SCOPE" ;;
esac
case "$rendered" in
  *"src/foo.ts,src/bar.ts"*) ;;
  *) fail "fix_ci template did not substitute FILE_OWNERSHIP" ;;
esac
case "$rendered" in
  *"## Objectif"*"## Tools / sources autorises"*"## Boundaries / interdictions"*"## Definition of Done verifiable"*"## Preuves attendues"*) ;;
  *) fail "fix_ci template missing canonical dispatch sections" ;;
esac
case "$rendered" in
  *"{{PR_URL}}"*) fail "fix_ci template still has unsubstituted {{PR_URL}}" ;;
esac

# Universality checks: no agent-CLI-specific or project-name-specific
# branding should appear in any template.
for t in pr_op_fix_ci.md.tpl pr_op_resolve_conflict.md.tpl pr_op_mark_ready_candidate.md.tpl; do
  if grep -qE -i 'claude|codex|copilot|cursor|gemini|rbok|ordo|nomos|praxis|lumen|wordpress' "$ROOT/templates/$t"; then
    fail "$t contains a non-universal token (CLI or project name)"
  fi
done

# ----------------------------------------------------------------------------
# Integration coverage: end-to-end dry-run on TWO project fixtures.
# Universal proof: the same script with the same templates produces correct
# behaviour for both `alpha` and `beta` profiles.
# ----------------------------------------------------------------------------
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_TMP/bin/gh"

# Stub out the upstream collectors so the test does not need a real `gh`.
cat > "$SANITIZED_ROOT/scripts/pr_block_signals.sh" <<'EOF'
#!/usr/bin/env bash
cfg=$1
case "$cfg" in
  *alpha* )
    cat <<'JSON'
[
  {"pr":"101","branch":"feat/alpha-fix","head":"a1","agent":"planner","merge_state":"BLOCKED","mergeable":"MERGEABLE","review":"REVIEW_REQUIRED","ci_fail":2,"ci_pending":0,"deploy_gate_pending":0,"base_current":"1","files":["frontend/src/foo.ts","frontend/src/bar.ts"],"signals":["ci-failed","review-required"]},
  {"pr":"102","branch":"feat/alpha-rebase","head":"b2","agent":"builder","merge_state":"DIRTY","mergeable":"CONFLICTING","review":"REVIEW_REQUIRED","ci_fail":0,"ci_pending":0,"deploy_gate_pending":0,"base_current":"0","files":["docs/install.md"],"signals":["merge-conflict","review-required"]},
  {"pr":"103","branch":"feat/alpha-readiness","head":"c3","agent":"reviewer","merge_state":"CLEAN","mergeable":"MERGEABLE","review":"REVIEW_REQUIRED","ci_fail":0,"ci_pending":0,"deploy_gate_pending":0,"base_current":"1","files":["src/widget.ts"],"signals":["draft","ci-pass"]}
]
JSON
    ;;
  *beta* )
    cat <<'JSON'
[
  {"pr":"201","branch":"fix/beta-ci","head":"d4","agent":"planner","merge_state":"BLOCKED","mergeable":"MERGEABLE","review":"REVIEW_REQUIRED","ci_fail":1,"ci_pending":0,"deploy_gate_pending":0,"base_current":"1","files":["service/handler.go"],"signals":["ci-failed","review-required"]},
  {"pr":"202","branch":"fix/beta-unknown","head":"e5","agent":"builder","merge_state":"UNKNOWN","mergeable":"UNKNOWN","review":"REVIEW_REQUIRED","ci_fail":0,"ci_pending":0,"deploy_gate_pending":0,"base_current":"1","files":["service/util.go"],"signals":["merge-state-unknown","mergeable-unknown"]}
]
JSON
    ;;
esac
EOF
chmod +x "$SANITIZED_ROOT/scripts/pr_block_signals.sh"

cat > "$SANITIZED_ROOT/scripts/agent_pool_status.sh" <<'EOF'
#!/usr/bin/env bash
cfg=$1
case "$cfg" in
  *alpha* )
    cat <<'JSON'
[
  {"label":"planner","pane":"a:0.0","workdir":"/work/alpha-planner","capacity_class":"available","branch":"feat/alpha-fix","dirty":"0","pr":"101","signals":[]},
  {"label":"builder","pane":"b:0.0","workdir":"/work/alpha-builder","capacity_class":"available","branch":"feat/alpha-rebase","dirty":"0","pr":"102","signals":[]},
  {"label":"reviewer","pane":"c:0.0","workdir":"/work/alpha-reviewer","capacity_class":"available","branch":"feat/alpha-readiness","dirty":"0","pr":"103","signals":[]}
]
JSON
    ;;
  *beta* )
    cat <<'JSON'
[
  {"label":"planner","pane":"p:0.0","workdir":"/work/beta-planner","capacity_class":"available","branch":"fix/beta-ci","dirty":"0","pr":"201","signals":[]},
  {"label":"builder","pane":"q:0.0","workdir":"/work/beta-builder","capacity_class":"available","branch":"fix/beta-unknown","dirty":"3","pr":"202","signals":["dirty"]}
]
JSON
    ;;
esac
EOF
chmod +x "$SANITIZED_ROOT/scripts/agent_pool_status.sh"

cat > "$TEST_TMP/alpha.config.sh" <<EOF
PROJECT="alpha"
GH_REPO="example/alpha"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_REPO_PREFIX="$TEST_TMP/repos/alpha-"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/alpha-%s"
PR_OPS_MODE_ALLOWED="centralized,delegated"
EOF

cat > "$TEST_TMP/beta.config.sh" <<EOF
PROJECT="beta"
GH_REPO="example/beta"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_REPO_PREFIX="$TEST_TMP/repos/beta-"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/beta-%s"
PR_OPS_MODE_ALLOWED="centralized,delegated"
EOF

cat > "$TEST_TMP/no_policy.config.sh" <<EOF
PROJECT="gamma"
GH_REPO="example/gamma"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_REPO_PREFIX="$TEST_TMP/repos/gamma-"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/gamma-%s"
EOF

run_pr_ops() {
  PATH="$TEST_TMP/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  ORCH_LOG_DIR="$TEST_TMP/log" \
  ORCH_STATE_BASE="$TEST_TMP/state/orch-state" \
  XDG_DATA_HOME="$TEST_TMP/state" \
  ORCH_GITHUB_IDENTITY_GUARD=0 \
  ORCH_VALIDATOR_FORK_PREFLIGHT=0 \
    bash "$SANITIZED_ROOT/scripts/dispatch_pr_ops.sh" "$@"
}

# Project alpha — delegated mode, dry-run JSON.
alpha_out_dir="$TEST_TMP/alpha-out"
alpha_json=$(run_pr_ops "$TEST_TMP/alpha.config.sh" --mode delegated --output-dir "$alpha_out_dir" --json)

alpha_count=$(printf '%s' "$alpha_json" | jq 'length')
[ "$alpha_count" = "3" ] || fail "alpha: expected 3 PR rows, got $alpha_count: $alpha_json"

alpha_assigned=$(printf '%s' "$alpha_json" | jq -r '[.[] | select(.outcome == "assigned")] | length')
[ "$alpha_assigned" = "3" ] || fail "alpha: expected 3 assigned, got $alpha_assigned: $alpha_json"

# Verify the three task kinds are all represented.
alpha_kinds=$(printf '%s' "$alpha_json" | jq -r '[.[] | select(.outcome == "assigned") | .kind] | sort | join(",")')
[ "$alpha_kinds" = "fix_ci,mark_ready_candidate,resolve_conflict" ] \
  || fail "alpha: expected the three canonical task kinds, got $alpha_kinds"

# Each rendered prompt file must exist and contain the canonical sections.
for prompt in $(printf '%s' "$alpha_json" | jq -r '.[] | select(.outcome == "assigned") | .prompt'); do
  [ -f "$prompt" ] || fail "alpha: rendered prompt missing: $prompt"
  grep -q '^## Objectif' "$prompt" || fail "alpha: prompt missing Objectif: $prompt"
  grep -q '^## Definition of Done verifiable' "$prompt" || fail "alpha: prompt missing DoD: $prompt"
  grep -q '^## Preuves attendues' "$prompt" || fail "alpha: prompt missing Preuves: $prompt"
  if grep -qE -i 'claude|codex|copilot|cursor|gemini|rbok|ordo|nomos|praxis|lumen' "$prompt"; then
    fail "alpha: prompt contains a non-universal token: $prompt"
  fi
done

# Project beta — delegated mode. PR #202 has UNKNOWN mergeability AND its
# candidate agent is dirty (capacity_class is "available" in the fixture
# but dirty=3 — the validator must refuse on UNKNOWN before it even reaches
# the dirty check; that single-blocker reporting is the contract).
beta_out_dir="$TEST_TMP/beta-out"
beta_json=$(run_pr_ops "$TEST_TMP/beta.config.sh" --mode delegated --output-dir "$beta_out_dir" --json)

beta_count=$(printf '%s' "$beta_json" | jq 'length')
[ "$beta_count" = "2" ] || fail "beta: expected 2 PR rows, got $beta_count: $beta_json"

# PR #201 has MERGEABLE + planner is available + dirty=0 → assigned fix_ci.
beta_201_outcome=$(printf '%s' "$beta_json" | jq -r '.[] | select(.pr == "201") | .outcome')
[ "$beta_201_outcome" = "assigned" ] || fail "beta: PR #201 must be assigned, got $beta_201_outcome"
beta_201_kind=$(printf '%s' "$beta_json" | jq -r '.[] | select(.pr == "201") | .kind')
[ "$beta_201_kind" = "fix_ci" ] || fail "beta: PR #201 kind must be fix_ci, got $beta_201_kind"

# PR #202 has UNKNOWN mergeability → blocker (validator refuses before
# considering anything else).
beta_202_outcome=$(printf '%s' "$beta_json" | jq -r '.[] | select(.pr == "202") | .outcome')
[ "$beta_202_outcome" = "blocker" ] || fail "beta: PR #202 must be blocker, got $beta_202_outcome"

# Negative case: missing policy.
set +e
run_pr_ops "$TEST_TMP/no_policy.config.sh" --mode delegated --json >/dev/null 2>"$TEST_TMP/no_policy.err"
no_policy_rc=$?
set -e
[ "$no_policy_rc" -ne 0 ] || fail "missing-policy must refuse; got rc=$no_policy_rc"
grep -q 'missing-policy\|PR_OPS_MODE_ALLOWED' "$TEST_TMP/no_policy.err" \
  || fail "missing-policy refusal must mention the policy variable; got: $(cat "$TEST_TMP/no_policy.err")"

# Negative case: observe mode emits no tasks (only classifications).
observe_json=$(run_pr_ops "$TEST_TMP/alpha.config.sh" --mode observe --json)
observe_assigned=$(printf '%s' "$observe_json" | jq -r '[.[] | select(.outcome == "assigned")] | length')
[ "$observe_assigned" = "0" ] || fail "observe mode must not assign; got $observe_assigned"
observe_only=$(printf '%s' "$observe_json" | jq -r '[.[] | select(.outcome == "observe-only")] | length')
[ "$observe_only" = "3" ] || fail "observe mode must report 3 observe-only rows; got $observe_only"

# Negative case: autonomous mode is reserved.
set +e
run_pr_ops "$TEST_TMP/alpha.config.sh" --mode autonomous --json >/dev/null 2>"$TEST_TMP/auto.err"
auto_rc=$?
set -e
[ "$auto_rc" -ne 0 ] || fail "autonomous mode must refuse in this iteration"
grep -q 'reserved\|autonomous' "$TEST_TMP/auto.err" \
  || fail "autonomous refusal must explain reservation; got: $(cat "$TEST_TMP/auto.err")"

# Negative case: hotspot conflict (synthetic — two PRs claiming the same path
# in the same wave). Construct a fixture where two PRs share a file.
cat > "$SANITIZED_ROOT/scripts/pr_block_signals.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"pr":"301","branch":"feat/p1","head":"f1","agent":"planner","merge_state":"BLOCKED","mergeable":"MERGEABLE","review":"REVIEW_REQUIRED","ci_fail":1,"ci_pending":0,"deploy_gate_pending":0,"base_current":"1","files":["README.md"],"signals":["ci-failed"]},
  {"pr":"302","branch":"feat/p2","head":"f2","agent":"builder","merge_state":"BLOCKED","mergeable":"MERGEABLE","review":"REVIEW_REQUIRED","ci_fail":1,"ci_pending":0,"deploy_gate_pending":0,"base_current":"1","files":["README.md"],"signals":["ci-failed"]}
]
JSON
EOF

cat > "$SANITIZED_ROOT/scripts/agent_pool_status.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"label":"planner","pane":"a:0.0","workdir":"/work/h-planner","capacity_class":"available","branch":"feat/p1","dirty":"0","pr":"301","signals":[]},
  {"label":"builder","pane":"b:0.0","workdir":"/work/h-builder","capacity_class":"available","branch":"feat/p2","dirty":"0","pr":"302","signals":[]}
]
JSON
EOF

hotspot_json=$(run_pr_ops "$TEST_TMP/alpha.config.sh" --mode delegated --output-dir "$TEST_TMP/h-out" --json)
hotspot_blocker=$(printf '%s' "$hotspot_json" | jq -r '.[] | select(.pr == "302") | .blocker // ""')
case "$hotspot_blocker" in
  *hotspot-conflict*) ;;
  *) fail "hotspot fixture: PR #302 must report hotspot-conflict blocker, got: $hotspot_blocker" ;;
esac

# Negative case: duplicate assignment. Same agent owns two PRs in the same
# wave → second one must be refused with duplicate-assignment.
cat > "$SANITIZED_ROOT/scripts/pr_block_signals.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"pr":"401","branch":"feat/d1","head":"g1","agent":"planner","merge_state":"BLOCKED","mergeable":"MERGEABLE","review":"REVIEW_REQUIRED","ci_fail":1,"ci_pending":0,"deploy_gate_pending":0,"base_current":"1","files":["src/a.ts"],"signals":["ci-failed"]},
  {"pr":"402","branch":"feat/d2","head":"g2","agent":"planner","merge_state":"BLOCKED","mergeable":"MERGEABLE","review":"REVIEW_REQUIRED","ci_fail":1,"ci_pending":0,"deploy_gate_pending":0,"base_current":"1","files":["src/b.ts"],"signals":["ci-failed"]}
]
JSON
EOF

cat > "$SANITIZED_ROOT/scripts/agent_pool_status.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"label":"planner","pane":"a:0.0","workdir":"/work/d-planner","capacity_class":"available","branch":"feat/d1","dirty":"0","pr":"401","signals":[]}
]
JSON
EOF

dup_json=$(run_pr_ops "$TEST_TMP/alpha.config.sh" --mode delegated --output-dir "$TEST_TMP/d-out" --json)
dup_402_outcome=$(printf '%s' "$dup_json" | jq -r '.[] | select(.pr == "402") | .outcome')
dup_402_blocker=$(printf '%s' "$dup_json" | jq -r '.[] | select(.pr == "402") | .blocker // ""')
[ "$dup_402_outcome" = "blocker" ] || fail "duplicate fixture: PR #402 must be blocker, got $dup_402_outcome"
case "$dup_402_blocker" in
  *duplicate-assignment*) ;;
  *) fail "duplicate fixture: PR #402 must report duplicate-assignment, got $dup_402_blocker" ;;
esac

printf 'ok - test_dispatch_pr_ops\n'
