#!/usr/bin/env bash
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

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/dispatch_ticket.sh
chmod +x "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/gh" "$TEST_TMP/logs" "$TEST_TMP/state"

cat > "$TEST_TMP/project.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dispatch-matrix-overlap-test"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_GH_LOGINS=(
  "gemini|gemini"
  "claude|claude"
)
EOF

gh_log="$TEST_TMP/logs/gh.log"
cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$gh_log"
case "\${1:-}-\${2:-}" in
  api-user)
    printf '%s\n' "gemini"
    ;;
  issue-edit)
    printf 'unexpected GitHub mutation: %s\n' "\$*" >&2
    exit 97
    ;;
  *)
    printf '[]\n'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

prompt="$TEST_TMP/dispatch-gemini-6100.md"
cat > "$prompt" <<'EOF'
# Dispatch canonique - overlap fixture

## Objectif
Exercise the dispatch matrix gate overlap refusal before assignment.

## Format de sortie attendu
Report the refusal code and audit record.

## Tools / sources autorises
Use only hermetic fixtures under TEST_TMP.

## Boundaries / interdictions
Do not perform live GitHub, tmux, or repository mutations.

## Definition of Done verifiable
The matrix gate refuses before GitHub assignment can run.

## Preuves attendues
Audit log includes the matrix refusal reason and the gh stub sees no mutation.

This fixture intentionally contains enough neutral text for prompt integrity
validation. It is not a live dispatch and does not authorize any external
mutation. The matrix below carries two rows for the same ticket and the same
owned path, modelling a second agent attempting to own work already present in
another agent's row. The expected behavior is a dispatch-matrix conflict
refusal before any tmux send or GitHub assignee mutation is attempted.
EOF

matrix_path="$TEST_TMP/state/dispatch-matrix-overlap-test/dispatch_matrix.tsv"
mkdir -p "$(dirname "$matrix_path")"
{
  printf 'repo\tissue\tpriority\tvalidation_mode\ttarget_agent\ttmux_target\tbase_branch\towned_paths\tforbidden_paths\treadiness\tblockers\tnotes\n'
  printf 'RBOKproject/ORDO\t6100\tP1\tci-delegated\tgemini\trbok-gemini:0.0\tmain\tscripts/dispatch_ticket.sh\t\tready\t\tprimary row for gemini\n'
  printf 'RBOKproject/ORDO\t6100\tP1\tci-delegated\tclaude\trbok-claude:0.0\tmain\tscripts/dispatch_ticket.sh\t\tready\t\tconflicting duplicate row for claude\n'
} > "$matrix_path"

set +e
dispatch_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/project.config.sh" gemini 6100 "$prompt" \
    --require-matrix-gate --matrix "$matrix_path" --assign 2>&1
)
dispatch_status=$?
set -e

[[ "$dispatch_status" -eq 82 ]] \
  || fail "overlap should refuse with documented matrix conflict exit 82, got $dispatch_status: $dispatch_output"
[[ "$dispatch_output" == *"dispatch-matrix-gate refused: agent=gemini ticket=#6100"* ]] \
  || fail "dispatch output should surface matrix gate refusal, got: $dispatch_output"
[[ "$dispatch_output" == *"reason=conflict:hot-spot-shared-with=claude"* ]] \
  || fail "dispatch output should name the conflicting agent, got: $dispatch_output"

audit_log="$TEST_TMP/logs/dispatch-matrix-overlap-test.log"
grep -q 'DISPATCH MATRIX GATE refused agent=gemini ticket=#6100' "$audit_log" \
  || fail "matrix gate refusal should be audit logged, log: $(cat "$audit_log" 2>/dev/null)"
grep -q 'reason=conflict:hot-spot-shared-with=claude' "$audit_log" \
  || fail "matrix gate audit should include conflict reason, log: $(cat "$audit_log" 2>/dev/null)"

! grep -q '^issue edit ' "$gh_log" 2>/dev/null \
  || fail "matrix refusal must stop before gh issue edit, gh log: $(cat "$gh_log")"
! grep -q 'assignee_policy=applied' "$audit_log" \
  || fail "matrix refusal must not apply assignment, log: $(cat "$audit_log")"

printf 'ok - dispatch_ticket matrix gate refuses duplicate overlap before GitHub assignment\n'
