#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

config="$TEST_TMP/project.config.sh"
cat > "$config" <<EOF
PROJECT="ledger-test"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
EOF

ledger=$(
  ORCH_FINDINGS_LEDGER_DIR="$TEST_TMP/state-ledgers" \
  bash "$ROOT/scripts/findings_ledger.sh" "$config" path --run-id run-1
)
[[ "$ledger" == "$TEST_TMP/state-ledgers/ledger-test/ordo-run-findings-run-1.md" ]] \
  || fail "unexpected default ledger path: $ledger"
case "$ledger" in
  "$ROOT"/*)
    fail "default ledger path must not live inside active worktree: $ledger"
    ;;
esac

append_output=$(
  ORCH_FINDINGS_LEDGER_DIR="$TEST_TMP/state-ledgers" \
  bash "$ROOT/scripts/findings_ledger.sh" "$config" append \
    --run-id run-1 \
    --code F-016 \
    --summary "Ledger outside worktree" \
    --source "manual run" \
    --severity high \
    --impact "agent worktree stays clean" \
    --remediation "curate into issue or PR" \
    --validation "git status remains clean" \
    --priority P1
)
[[ "$append_output" == "$ledger" ]] || fail "append should print ledger path"
[[ -f "$ledger" ]] || fail "ledger was not created"
grep -q 'Storage policy: live ledger outside active worktrees by default' "$ledger" \
  || fail "ledger header should document storage policy"
grep -q '## F-016 - Ledger outside worktree' "$ledger" \
  || fail "ledger entry missing code heading"

dry_issue=$(
  bash "$ROOT/scripts/findings_ledger.sh" "$config" curate-issue \
    --ledger "$ledger" \
    --code F-016 \
    --title "fix(findings): ledger outside worktree" \
    --label type:bug \
    --dry-run
)
[[ "$dry_issue" == *"DRY-RUN: gh issue create --repo example/repo --title fix(findings): ledger outside worktree"* ]] \
  || fail "dry-run issue command missing expected preview: $dry_issue"
[[ "$dry_issue" == *"Finding code: F-016"* && "$dry_issue" == *"Ledger outside worktree"* ]] \
  || fail "dry-run issue body missing curated finding: $dry_issue"

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/gh-out"
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$GH_OUT/argv.txt"
body_file=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --body-file)
      body_file=$2
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$body_file" ]] || { echo "missing --body-file" >&2; exit 99; }
cp "$body_file" "$GH_OUT/body.md"
printf 'https://example.invalid/created\n'
EOF
chmod +x "$TEST_TMP/bin/gh"

GH_OUT="$TEST_TMP/gh-out" \
PATH="$TEST_TMP/bin:$PATH" \
  bash "$ROOT/scripts/findings_ledger.sh" "$config" curate-issue \
    --ledger "$ledger" \
    --code F-016 \
    --title "fix(findings): ledger outside worktree" \
    --label type:bug >/dev/null
grep -qxF 'issue' "$TEST_TMP/gh-out/argv.txt" || fail "gh issue create argv missing issue"
grep -qxF 'create' "$TEST_TMP/gh-out/argv.txt" || fail "gh issue create argv missing create"
grep -qxF -- '--body-file' "$TEST_TMP/gh-out/argv.txt" || fail "gh issue create must use --body-file"
grep -q 'Source ledger:' "$TEST_TMP/gh-out/body.md" || fail "issue body missing source ledger"
grep -q '## F-016 - Ledger outside worktree' "$TEST_TMP/gh-out/body.md" \
  || fail "issue body missing finding section"

set +e
missing_docs_pr=$(
  bash "$ROOT/scripts/findings_ledger.sh" "$config" curate-pr \
    --ledger "$ledger" \
    --code F-016 \
    --head fix/findings-ledger \
    --dry-run 2>&1
)
missing_docs_status=$?
set -e
[[ "$missing_docs_status" -eq 2 ]] \
  || fail "curate-pr without docs impact should fail with exit 2, got $missing_docs_status: $missing_docs_pr"
[[ "$missing_docs_pr" == *"missing --docs-impact"* ]] \
  || fail "curate-pr without docs impact should explain missing --docs-impact: $missing_docs_pr"

dry_pr=$(
  bash "$ROOT/scripts/findings_ledger.sh" "$config" curate-pr \
    --ledger "$ledger" \
    --code F-016 \
    --head fix/findings-ledger \
    --docs-impact no-docs-needed \
    --docs-impact-note "curated finding affects operator triage only" \
    --dry-run
)
[[ "$dry_pr" == *"DRY-RUN: gh pr create --repo example/repo --base main --head fix/findings-ledger"* ]] \
  || fail "dry-run PR command missing expected preview: $dry_pr"
grep -qxF 'Docs-Impact: no-docs-needed' <<<"$dry_pr" \
  || fail "dry-run PR body missing no-docs-needed declaration: $dry_pr"
grep -qxF 'Docs-Impact-Note: curated finding affects operator triage only' <<<"$dry_pr" \
  || fail "dry-run PR body missing docs impact note: $dry_pr"

printf '%s\n' 'scripts/findings_ledger.sh' > "$TEST_TMP/changed-paths.txt"
printf '%s\n' "$dry_pr" > "$TEST_TMP/pr-body.md"
bash "$ROOT/scripts/docs_impact_gate.sh" check \
  --paths-from "$TEST_TMP/changed-paths.txt" \
  --declaration-from "$TEST_TMP/pr-body.md" \
  --quiet \
  || fail "dry-run PR no-docs-needed declaration should satisfy docs-impact gate"

followup_pr=$(
  bash "$ROOT/scripts/findings_ledger.sh" "$config" curate-pr \
    --ledger "$ledger" \
    --code F-016 \
    --head fix/findings-ledger \
    --docs-impact follow-up \
    --docs-impact-followup RBOKproject/ORDO#568 \
    --dry-run
)
grep -qxF 'Docs-Impact: follow-up' <<<"$followup_pr" \
  || fail "dry-run PR body missing follow-up declaration: $followup_pr"
grep -qxF 'Docs-Impact-Followup: RBOKproject/ORDO#568' <<<"$followup_pr" \
  || fail "dry-run PR body missing docs impact follow-up ref: $followup_pr"
printf '%s\n' "$followup_pr" > "$TEST_TMP/pr-followup-body.md"
bash "$ROOT/scripts/docs_impact_gate.sh" check \
  --paths-from "$TEST_TMP/changed-paths.txt" \
  --declaration-from "$TEST_TMP/pr-followup-body.md" \
  --quiet \
  || fail "dry-run PR follow-up declaration should satisfy docs-impact gate"

printf 'ok - findings_ledger keeps live ledgers outside worktrees and curates issues/PRs\n'
