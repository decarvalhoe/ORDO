#!/usr/bin/env bash
# test_dispatch_prompt_fidelity.sh — source-ticket/PR substance fidelity gate (#655).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/gh" "$TEST_TMP/logs" "$TEST_TMP/repos" "$TEST_TMP/state"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/brief_agents.sh \
  scripts/dispatch_pr_ops.sh \
  templates/dispatch-canonical.md.tpl \
  templates/pr_op_fix_ci.md.tpl \
  templates/pr_op_resolve_conflict.md.tpl \
  templates/pr_op_mark_ready_candidate.md.tpl

cat > "$TEST_TMP/source_body.md" <<'EOF'
## Problem

The frontend dispatch softened a mandatory runtime-docs gate.

## Evidence

- parent/reference context `#3589`
- evidence path `Documents/proofs/full-audit-2026-05-11/static/bundle-dead-code.md`
- exact proof command / claim: `git grep "export const dynamic = 'force-dynamic'" origin/develop` returns 0
- rendered dispatch softened the requirement as `ajouter une gate anti-drift si adaptée`

## Acceptance Criteria

- Gate CI anti-régression obligatoire
- Mandatory requirements must not be softened into optional language.
EOF

source_body=$(<"$TEST_TMP/source_body.md")
source_hash=$(printf '%s' "$source_body" | sha256sum | awk '{print $1}')

cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2 \$3" == "issue view 3605" ]]; then
  jq -nc \\
    --arg title "P0 dispatch source fidelity fixture" \\
    --arg url "https://github.com/RBOKproject/RBOK/issues/3605" \\
    --rawfile body "$TEST_TMP/source_body.md" \\
    '{title:\$title,url:\$url,body:\$body}'
  exit 0
fi
printf 'unexpected gh invocation: %s\n' "\$*" >&2
exit 2
EOF
chmod +x "$TEST_TMP/bin/gh"

cat > "$TEST_TMP/ordo.config.sh" <<EOF
PROJECT="ordo-fixture"
GH_REPO="RBOKproject/RBOK"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="origin"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
PR_OPS_MODE_ALLOWED="delegated"
EOF

PATH="$TEST_TMP/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
ORCH_STATE_BASE="$TEST_TMP/state" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/ordo.config.sh" \
  gemini 3605 \
  branch_slug=fix/3605-docs-force-dynamic-drift \
  summary="docs force dynamic drift" \
  ticket_title="docs force dynamic drift" \
  scope_files="frontend/CLAUDE.md scripts/check_frontend_runtime_docs_drift.sh" \
  validation="timeout 30 bash tests/test_dispatch_prompt_fidelity.sh" \
  > "$TEST_TMP/rendered_dispatch.md" \
  2> "$TEST_TMP/brief_stderr"

grep -q "Source URL: https://github.com/RBOKproject/RBOK/issues/3605" "$TEST_TMP/rendered_dispatch.md" \
  || fail "canonical dispatch must include source URL"
grep -q "Source body hash: sha256:$source_hash" "$TEST_TMP/rendered_dispatch.md" \
  || fail "canonical dispatch must include source body hash"
grep -q "Gate CI anti-régression obligatoire" "$TEST_TMP/rendered_dispatch.md" \
  || fail "canonical dispatch must preserve mandatory gate line"
grep -q "fidelity_status=pass" "$TEST_TMP/logs/ordo-fixture.log" \
  || fail "canonical dispatch must emit passing PROMPT_FIDELITY audit"
grep -q "source_hash=sha256:$source_hash" "$TEST_TMP/logs/ordo-fixture.log" \
  || fail "fidelity audit must record source hash"
grep -q "rendered_prompt_hash=sha256:" "$TEST_TMP/logs/ordo-fixture.log" \
  || fail "fidelity audit must record rendered prompt hash"
grep -q "dropped_mandatory=0 softened_mandatory=0" "$TEST_TMP/logs/ordo-fixture.log" \
  || fail "fidelity audit must record dropped/softened mandatory counts"

# Negative fixture: a mandatory source gate softened to "si adaptée" in the
# operational prompt must fail even when the source appendix is present.
# shellcheck source=/dev/null
source "$SANITIZED_ROOT/lib/prompt_integrity.sh"
bad_rendered=$(
  printf '## Objectif\n\nAjouter une gate anti-drift si adaptée.\n'
  prompt_source_substance_appendix \
    "https://github.com/RBOKproject/RBOK/issues/3605" \
    "P0 dispatch source fidelity fixture" \
    "$source_body"
)
if prompt_validate_source_fidelity \
  "https://github.com/RBOKproject/RBOK/issues/3605" \
  "P0 dispatch source fidelity fixture" \
  "$source_body" \
  "$bad_rendered" >/dev/null 2>"$TEST_TMP/negative_err"; then
  fail "softened mandatory gate should fail prompt fidelity validation"
fi
grep -q "softened mandatory source requirement" "$TEST_TMP/negative_err" \
  || fail "negative fixture should report softened mandatory requirement"

cat > "$TEST_TMP/pr_signals.json" <<'JSON'
[
  {
    "pr": "42",
    "branch": "fix/pr-ci",
    "head": "abc1234",
    "head_full": "abc1234def",
    "body_text": "## Summary\nFix dispatch fidelity.\n\nCloses #655\nRefs #3605",
    "merge_state": "BLOCKED",
    "mergeable": "MERGEABLE",
    "review": "REVIEW_REQUIRED",
    "ci_fail": 1,
    "ci_pending": 0,
    "ci_failed_check_names": ["Frontend runtime docs drift / Check frontend runtime docs claims"],
    "ci_failed_urls": ["https://github.com/RBOKproject/ORDO/actions/runs/123456789/job/987654321"],
    "ci_pending_urls": [],
    "ci_rollup": {
      "aggregate": "failed_or_cancelled",
      "failed": [{"name": "Frontend runtime docs drift / Check frontend runtime docs claims", "url": "https://github.com/RBOKproject/ORDO/actions/runs/123456789/job/987654321"}],
      "cancelled": [],
      "pending": [],
      "passed": []
    },
    "deploy_gate_pending": 0,
    "base_current": "1",
    "files": ["scripts/check_frontend_runtime_docs_drift.sh"],
    "signals": ["ci-failed"]
  }
]
JSON

cat > "$TEST_TMP/agent_pool.json" <<'JSON'
[
  {"label":"gemini","pane":"g:0.0","workdir":"/work/gemini","capacity_class":"available","branch":"fix/pr-ci","dirty":"0","pr":"42","signals":[]}
]
JSON

pr_body_text=$'## Summary\nFix dispatch fidelity.\n\nCloses #655\nRefs #3605'
pr_body_hash=$(printf '%s' "$pr_body_text" | sha256sum | awk '{print $1}')
pr_out_dir="$TEST_TMP/pr-out"
PATH="$TEST_TMP/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
ORCH_STATE_BASE="$TEST_TMP/state" \
bash "$SANITIZED_ROOT/scripts/dispatch_pr_ops.sh" \
  "$TEST_TMP/ordo.config.sh" \
  --mode delegated \
  --pr-signals-file "$TEST_TMP/pr_signals.json" \
  --agent-pool-file "$TEST_TMP/agent_pool.json" \
  --output-dir "$pr_out_dir" \
  --json \
  > "$TEST_TMP/pr_ops.json"

prompt=$(jq -r '.[0].prompt' "$TEST_TMP/pr_ops.json")
[[ -f "$prompt" ]] || fail "PR-ops prompt should be rendered"
grep -q "PR body hash: sha256:$pr_body_hash" "$prompt" \
  || fail "PR-ops prompt must include PR body hash"
grep -Eq "Linked issue context from PR body: (#3605,#655|#655,#3605)" "$prompt" \
  || fail "PR-ops prompt must include linked issue context"
grep -q "Frontend runtime docs drift / Check frontend runtime docs claims" "$prompt" \
  || fail "PR-ops prompt must include failed check names"
grep -q "gh run view 123456789 --log --repo RBOKproject/RBOK" "$prompt" \
  || fail "PR-ops prompt must include failed-check log retrieval command"

printf 'ok - dispatch prompt fidelity preserves source ticket and PR substance\n'
