#!/usr/bin/env bash
# tests/test_dispatch_pr_ops_ordo_mode.sh — covers ORDO PR-ops policy enablement
# and the follow-up-on-existing-branch dispatch path (#680).
#
# Exercises:
#   - examples/ordo.config.sh sets a safe PR_OPS_MODE_ALLOWED default so any
#     ORDO live profile loaded through this template can flow centralized
#     PR-ops dispatch without per-profile edits, AND does not clobber an
#     explicit value set by the live profile.
#   - scripts/dispatch_pr_ops.sh accepts a profile that opts into
#     PR_OPS_MODE_ALLOWED=centralized and emits assignments without firing
#     the missing-policy refusal (AC#1 of #680).
#   - --follow-up-on-existing-branch prefers an agent whose pool entry is
#     already pinned to the PR's branch with a workdir on disk, even when
#     that agent's capacity_class is `dispatched`. The rendered prompt is
#     staged at the agent's existing workdir under
#     `dispatch-followup-pr<N>.md` so dispatch_ticket.sh is not invoked
#     (AC#2 of #680).
#
# Note on test footprint: this test runs a small number of dispatch_pr_ops
# invocations so it can complete inside the 120s budget declared by the
# dispatch validation_command even on a contended agent host. Broader matrix
# coverage (CONFLICTING mergeability, hotspot, duplicate, observe-mode, etc.)
# lives in tests/test_dispatch_pr_ops.sh which exercises the universal code
# path on two project fixtures.
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
  "$SANITIZED_ROOT/examples" "$TEST_TMP/bin" "$TEST_TMP/state"

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
  templates/pr_op_mark_ready_candidate.md.tpl \
  examples/ordo.config.sh
do
  mkdir -p "$SANITIZED_ROOT/$(dirname "$rel")"
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/dispatch_pr_ops.sh"

# ----------------------------------------------------------------------------
# Section 1 — examples/ordo.config.sh provides a safe PR_OPS_MODE_ALLOWED
# default after sourcing the operator profile, and does not clobber an
# explicit override. No subprocess forks — runs as a pure source-and-assert.
# ----------------------------------------------------------------------------

cat > "$TEST_TMP/ordo-live.config.sh" <<EOF
PROJECT="ordo"
GH_REPO="example/ordo"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_REPO_PREFIX="$TEST_TMP/repos/ordo-"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/ordo-%s"
AGENT_PANES=("agent-010|ordo:0.0")
EOF

ORDO_PROJECT_PROFILE="$TEST_TMP/ordo-live.config.sh" \
  source "$SANITIZED_ROOT/examples/ordo.config.sh"

[ "${PR_OPS_MODE_ALLOWED:-}" = "centralized" ] \
  || fail "ordo loader must default PR_OPS_MODE_ALLOWED to centralized (got: ${PR_OPS_MODE_ALLOWED:-})"

unset PR_OPS_MODE_ALLOWED
cat > "$TEST_TMP/ordo-live-explicit.config.sh" <<EOF
PROJECT="ordo"
GH_REPO="example/ordo"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_REPO_PREFIX="$TEST_TMP/repos/ordo-"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/ordo-%s"
AGENT_PANES=("agent-010|ordo:0.0")
PR_OPS_MODE_ALLOWED="centralized,delegated"
EOF

ORDO_PROJECT_PROFILE="$TEST_TMP/ordo-live-explicit.config.sh" \
  source "$SANITIZED_ROOT/examples/ordo.config.sh"

[ "${PR_OPS_MODE_ALLOWED:-}" = "centralized,delegated" ] \
  || fail "ordo loader must not clobber explicit PR_OPS_MODE_ALLOWED (got: ${PR_OPS_MODE_ALLOWED:-})"

unset PR_OPS_MODE_ALLOWED

# ----------------------------------------------------------------------------
# Section 2 — dispatch_pr_ops.sh accepts an opted-in profile (AC#1).
# Pinned agent fixture so this single invocation also seeds the follow-up
# case in Section 3 without an extra dispatch_pr_ops fork.
# ----------------------------------------------------------------------------

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_TMP/bin/gh"

PINNED_WORKDIR="$TEST_TMP/pinned-workdir/agent-010"
mkdir -p "$PINNED_WORKDIR"

cat > "$SANITIZED_ROOT/scripts/pr_block_signals.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
[
  {"pr":"662","branch":"fix/656-keep-active","head":"c3","agent":"agent-010","merge_state":"BLOCKED","mergeable":"MERGEABLE","review":"REVIEW_REQUIRED","ci_fail":1,"ci_pending":0,"deploy_gate_pending":0,"base_current":"1","files":["src/662-only.ts"],"signals":["ci-failed"]}
]
JSON
EOF
chmod +x "$SANITIZED_ROOT/scripts/pr_block_signals.sh"

cat > "$SANITIZED_ROOT/scripts/agent_pool_status.sh" <<EOF
#!/usr/bin/env bash
cat <<JSON
[
  {"label":"agent-004","pane":"a:0.0","workdir":"/work/agent-004","capacity_class":"available","branch":"main","dirty":"0","pr":"","signals":[]},
  {"label":"agent-010","pane":"b:0.0","workdir":"$PINNED_WORKDIR","capacity_class":"dispatched","branch":"fix/656-keep-active","dirty":"0","pr":"662","signals":[]}
]
JSON
EOF
chmod +x "$SANITIZED_ROOT/scripts/agent_pool_status.sh"

cat > "$TEST_TMP/ordo-centralized.config.sh" <<EOF
PROJECT="ordo"
GH_REPO="example/ordo"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_REPO_PREFIX="$TEST_TMP/repos/ordo-"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/ordo-%s"
PR_OPS_MODE_ALLOWED="centralized,delegated"
EOF

cat > "$TEST_TMP/ordo-no-policy.config.sh" <<EOF
PROJECT="ordo"
GH_REPO="example/ordo"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_REPO_PREFIX="$TEST_TMP/repos/ordo-"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/ordo-%s"
EOF

run_pr_ops() {
  PATH="$TEST_TMP/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  ORCH_LOG_DIR="$TEST_TMP/log" \
  ORCH_STATE_BASE="$TEST_TMP/state/orch-state" \
  XDG_DATA_HOME="$TEST_TMP/state" \
  ORCH_GITHUB_IDENTITY_GUARD=0 \
  ORCH_VALIDATOR_FORK_PREFLIGHT=0 \
  ORCH_OTEL_ENDPOINT="" \
    bash "$SANITIZED_ROOT/scripts/dispatch_pr_ops.sh" "$@"
}

# AC#1: centralized mode runs without refusal when the profile opts in.
set +e
centralized_json=$(run_pr_ops "$TEST_TMP/ordo-centralized.config.sh" --mode centralized --output-dir "$TEST_TMP/c-out" --json 2>"$TEST_TMP/c.err")
centralized_rc=$?
set -e
[ "$centralized_rc" -eq 0 ] \
  || fail "centralized mode with opted-in profile must not refuse; rc=$centralized_rc err=$(cat "$TEST_TMP/c.err" 2>/dev/null) out=$centralized_json"
if grep -q 'missing-policy\|PR_OPS_MODE_ALLOWED' "$TEST_TMP/c.err" 2>/dev/null; then
  fail "centralized mode with opted-in profile must not emit missing-policy refusal; err=$(cat "$TEST_TMP/c.err")"
fi

# AC#1 negative control: a profile without PR_OPS_MODE_ALLOWED still refuses.
set +e
run_pr_ops "$TEST_TMP/ordo-no-policy.config.sh" --mode centralized --json >/dev/null 2>"$TEST_TMP/np.err"
np_rc=$?
set -e
[ "$np_rc" -ne 0 ] \
  || fail "missing PR_OPS_MODE_ALLOWED must still refuse centralized mode (got rc=$np_rc)"
grep -q 'missing-policy\|PR_OPS_MODE_ALLOWED' "$TEST_TMP/np.err" \
  || fail "missing-policy refusal must mention the policy variable; got: $(cat "$TEST_TMP/np.err")"

# ----------------------------------------------------------------------------
# Section 3 — --follow-up-on-existing-branch routes the dispatch to the
# pinned agent and stages the prompt at its workdir (AC#2).
# ----------------------------------------------------------------------------

followup_json=$(run_pr_ops "$TEST_TMP/ordo-centralized.config.sh" --mode delegated --output-dir "$TEST_TMP/f-out" --follow-up-on-existing-branch --apply --json)

followup_agent=$(printf '%s' "$followup_json" | jq -r '.[] | select(.pr == "662") | .agent')
[ "$followup_agent" = "agent-010" ] \
  || fail "follow-up route must pick the pinned agent (agent-010); got '$followup_agent': $followup_json"
followup_route=$(printf '%s' "$followup_json" | jq -r '.[] | select(.pr == "662") | .route')
[ "$followup_route" = "followup_existing_branch" ] \
  || fail "follow-up route value must be 'followup_existing_branch'; got '$followup_route'"
followup_workdir=$(printf '%s' "$followup_json" | jq -r '.[] | select(.pr == "662") | .follow_up_target_workdir')
[ "$followup_workdir" = "$PINNED_WORKDIR" ] \
  || fail "follow-up route must surface the pinned workdir; got '$followup_workdir'"
followup_outcome=$(printf '%s' "$followup_json" | jq -r '.[] | select(.pr == "662") | .outcome')
[ "$followup_outcome" = "assigned" ] \
  || fail "follow-up outcome must be 'assigned' (capacity gate relaxed for this route); got '$followup_outcome'"

# --apply staged the prompt at the pinned workdir so the agent can pick it up
# on its existing branch without dispatch_ticket.sh creating a new per-PR
# worktree that would refuse with DISPATCH_ROUTE_MISMATCH.
[ -f "$PINNED_WORKDIR/dispatch-followup-pr662.md" ] \
  || fail "follow-up --apply must stage dispatch-followup-pr662.md at the pinned workdir"

# The audit ledger must record the follow-up route so the orchestrator can
# observe (and replay) which dispatch path each PR took.
grep -q 'PR_OPS DISPATCH apply route=followup_existing_branch.*pr=#662.*agent=agent-010' \
  "$TEST_TMP/log/ordo.log" \
  || fail "audit log must record route=followup_existing_branch for PR #662; tail=$(tail -5 "$TEST_TMP/log/ordo.log" 2>/dev/null)"

printf 'ok - test_dispatch_pr_ops_ordo_mode\n'
