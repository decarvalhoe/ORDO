#!/usr/bin/env bash
# Issue #763: dispatch_plan --atomize --apply --max-children-per-cycle cap.
#
# Phase B of the queue resolver needs a hard upper bound on how many child
# issues can be created per supervisor cycle so a runaway invocation cannot
# carpet-bomb the repo. This test pins the contract:
#
#   * --max-children-per-cycle N stops creation after N children are made,
#     even when more atomizable parents are still in the queue.
#   * Each parent that produced children emits exactly one
#     `AUTO_ATOMIZE_SUMMARY parent=N children=a,b project=X max_per_cycle=K`
#     stderr line so orch_loop can record the parent->children mapping in
#     the rate-limit ledger without re-reading the repo.
#   * The fixture parent yields >= 1 child after one cycle even with the
#     cap at 1, satisfying the acceptance criterion in the ticket body.
#   * --apply is accepted as an alias for the default mutating behavior so
#     the orch_loop wiring can pass it explicitly.
#   * The env fallback DISPATCH_PLAN_ATOMIZE_MAX_CHILDREN_PER_CYCLE applies
#     when no CLI flag is supplied.
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
  "$TEST_TMP/bin" "$TEST_TMP/logs"

for rel in \
  scripts/dispatch_plan.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dispatch_plan_headers.sh \
  lib/dry_run.sh \
  lib/github_identity.sh \
  lib/label_helpers.sh \
  lib/process_safety.sh \
  lib/external_mutation_gate.sh \
  lib/ordo_contracts.sh \
  lib/ordo_provider_adapter.sh \
  lib/ordo_provider_adapter_github.sh \
  lib/ordo_provider_adapter_fake.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/dispatch_plan.sh"

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="atomize-cap-test"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

# gh mock: two atomizable parents with three subtasks each, plus one ready
# row for sanity. issue create returns a fresh URL with a unique tail
# integer so the script's child_num parsing surfaces deterministic ids.
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >> "${GH_MOCK_LOG:-/dev/null}"

if [[ "$args" == *"issue list"* && "$args" == *"ORDO-ATOMIZE"* ]]; then
  printf '%s\n' '[]'
  exit 0
fi

case "$args" in
  *"label list"* )
    cat <<'JSON'
[
  {"name":"priority:P0"},
  {"name":"priority:P1"},
  {"name":"priority:P2"},
  {"name":"priority:P3"},
  {"name":"ordo:atomized"},
  {"name":"ordo:child"}
]
JSON
    ;;
  *"pr list"* )
    printf '%s\n' '[]'
    ;;
  *"issue list"* )
    cat <<'JSON'
[
  {"number":501,"title":"EPIC: Big parent A","labels":[{"name":"priority:P1"},{"name":"epic"}],"assignees":[],"body":"Parent scope A\n\n- [ ] subtask A1\n- [ ] subtask A2\n- [ ] subtask A3","updatedAt":"2026-05-20T00:00:00Z","url":"https://example.test/501"},
  {"number":502,"title":"EPIC: Big parent B","labels":[{"name":"priority:P2"},{"name":"epic"}],"assignees":[],"body":"Parent scope B\n\n- [ ] subtask B1\n- [ ] subtask B2\n- [ ] subtask B3","updatedAt":"2026-05-20T00:00:00Z","url":"https://example.test/502"},
  {"number":503,"title":"Ready unrelated work","labels":[{"name":"priority:P3"}],"assignees":[],"body":"No checklist","updatedAt":"2026-05-20T00:00:00Z","url":"https://example.test/503"}
]
JSON
    ;;
  *"issue create"* )
    : "${ISSUE_CREATE_COUNTER_FILE:?ISSUE_CREATE_COUNTER_FILE must be set}"
    next=$(( $(cat "$ISSUE_CREATE_COUNTER_FILE" 2>/dev/null || echo 600) + 1 ))
    printf '%s\n' "$next" > "$ISSUE_CREATE_COUNTER_FILE"
    body_file=""
    while [[ $# -gt 0 ]]; do
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
    if [[ -n "$body_file" && -f "$body_file" ]]; then
      cat "$body_file" >> "${GH_MOCK_BODY:-/dev/null}"
    fi
    printf '%s\n' "https://example.test/issues/${next}"
    ;;
  *"issue comment"*|*"issue edit"* )
    printf '%s\n' '{}'
    ;;
  *"issue view"* )
    printf '%s\n' '{"state":"OPEN"}'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

run_dispatch_plan() {
  # Child creation/labels/comment go through the provider adapter (#816),
  # which gates them; the apply scenarios authorise those scopes. Every run
  # models a fresh cycle against a forge that forgot the previous one, so
  # the adapter's idempotency ledger (keyed by the atomize trace id) is
  # cleared first — otherwise the second scenario would replay the receipts
  # of the first instead of creating children.
  rm -f "$TEST_TMP"/state/*/ordo-provider-idempotency.jsonl
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_EXTERNAL_PR_MUTATIONS="issue_create,issue_labels,issue_comment" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  GH_MOCK_BODY="$TEST_TMP/logs/child-body.md" \
  ISSUE_CREATE_COUNTER_FILE="$TEST_TMP/logs/issue-create.counter" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" "$@"
}

count_issue_creates() {
  if [[ ! -f "$TEST_TMP/logs/gh.log" ]]; then
    printf '0\n'
    return
  fi
  grep -c '^issue create ' "$TEST_TMP/logs/gh.log" || true
}

reset_logs() {
  rm -f "$TEST_TMP/logs/gh.log" "$TEST_TMP/logs/child-body.md" \
    "$TEST_TMP/logs/issue-create.counter" \
    "$TEST_TMP/logs/atomize-cap-test.log"
  printf '600\n' > "$TEST_TMP/logs/issue-create.counter"
}

# --------------------------------------------------------------------
# Scenario 1: --max-children-per-cycle 2 caps creations at 2 even though
# the queue carries 6 atomizable subtasks across two parents.
# --------------------------------------------------------------------
reset_logs
run_dispatch_plan --atomize --apply --max-children-per-cycle 2 --tsv \
  2> "$TEST_TMP/logs/capped.stderr" >/dev/null

created=$(count_issue_creates)
[[ "$created" == "2" ]] \
  || fail "expected exactly 2 issue create calls under cap=2; got $created. log=$(cat "$TEST_TMP/logs/gh.log" 2>/dev/null)"

summary_lines=$(grep -c '^AUTO_ATOMIZE_SUMMARY' "$TEST_TMP/logs/capped.stderr" || true)
[[ "$summary_lines" -ge 1 ]] \
  || fail "expected at least one AUTO_ATOMIZE_SUMMARY stderr line under cap=2; stderr=$(cat "$TEST_TMP/logs/capped.stderr")"

# The first parent (501, priority P1, processed first) must produce
# children. The summary line carries project + max_per_cycle metadata so
# orch_loop can round-trip the ledger entry.
grep -E '^AUTO_ATOMIZE_SUMMARY parent=501 children=[0-9,]+ project=atomize-cap-test max_per_cycle=2' \
  "$TEST_TMP/logs/capped.stderr" >/dev/null \
  || fail "expected AUTO_ATOMIZE_SUMMARY for parent=501 with project+max_per_cycle metadata; stderr=$(cat "$TEST_TMP/logs/capped.stderr")"

# Audit ledger must record the cap-reached condition so an operator can
# tell capped runs apart from a queue that simply ran out of work.
grep -q 'DISPATCH_PLAN atomize cap-reached project=atomize-cap-test max_per_cycle=2 created=2' \
  "$TEST_TMP/logs/atomize-cap-test.log" \
  || fail "audit log must record cap-reached event; log=$(cat "$TEST_TMP/logs/atomize-cap-test.log" 2>/dev/null)"

# --------------------------------------------------------------------
# Scenario 2: cap=1 still produces at least one child (acceptance criterion
# from the ticket body: "one needs-atomization parent yields at least 1
# child after one cycle").
# --------------------------------------------------------------------
reset_logs
run_dispatch_plan --atomize --apply --max-children-per-cycle 1 --tsv \
  2> "$TEST_TMP/logs/cap1.stderr" >/dev/null

created=$(count_issue_creates)
[[ "$created" == "1" ]] \
  || fail "expected exactly 1 issue create call under cap=1; got $created"

grep -E '^AUTO_ATOMIZE_SUMMARY parent=501 children=[0-9]+ project=atomize-cap-test max_per_cycle=1' \
  "$TEST_TMP/logs/cap1.stderr" >/dev/null \
  || fail "expected single-child AUTO_ATOMIZE_SUMMARY under cap=1; stderr=$(cat "$TEST_TMP/logs/cap1.stderr")"

# --------------------------------------------------------------------
# Scenario 3: no cap (omitted flag) processes every atomizable subtask in
# both parents, confirming the cap defaults to 0=unlimited and does not
# break the legacy behaviour.
# --------------------------------------------------------------------
reset_logs
run_dispatch_plan --atomize --apply --tsv \
  2> "$TEST_TMP/logs/uncapped.stderr" >/dev/null

created=$(count_issue_creates)
[[ "$created" == "6" ]] \
  || fail "expected 6 issue create calls without a cap; got $created"

uncapped_summaries=$(grep -c '^AUTO_ATOMIZE_SUMMARY' "$TEST_TMP/logs/uncapped.stderr" || true)
[[ "$uncapped_summaries" == "2" ]] \
  || fail "expected one AUTO_ATOMIZE_SUMMARY per parent (2 total) without a cap; got $uncapped_summaries"

# max_per_cycle=0 surfaces the uncapped mode explicitly in the summary,
# so a downstream parser can tell the run was uncapped without re-reading
# the CLI invocation.
grep -E '^AUTO_ATOMIZE_SUMMARY parent=501 children=[0-9,]+ project=atomize-cap-test max_per_cycle=0' \
  "$TEST_TMP/logs/uncapped.stderr" >/dev/null \
  || fail "expected uncapped summary to carry max_per_cycle=0; stderr=$(cat "$TEST_TMP/logs/uncapped.stderr")"

# --------------------------------------------------------------------
# Scenario 4: env fallback DISPATCH_PLAN_ATOMIZE_MAX_CHILDREN_PER_CYCLE.
# --------------------------------------------------------------------
reset_logs
DISPATCH_PLAN_ATOMIZE_MAX_CHILDREN_PER_CYCLE=2 \
  run_dispatch_plan --atomize --apply --tsv \
  2> "$TEST_TMP/logs/envcap.stderr" >/dev/null

created=$(count_issue_creates)
[[ "$created" == "2" ]] \
  || fail "expected env-fallback cap=2 to limit creations to 2; got $created"

# --------------------------------------------------------------------
# Scenario 5: --max-children-per-cycle rejects non-numeric input.
# --------------------------------------------------------------------
set +e
bad_err=$(run_dispatch_plan --atomize --max-children-per-cycle abc --tsv 2>&1)
bad_rc=$?
set -e
[[ "$bad_rc" -ne 0 ]] \
  || fail "non-numeric --max-children-per-cycle must exit non-zero"
[[ "$bad_err" == *"non-negative integer"* ]] \
  || fail "non-numeric --max-children-per-cycle must explain the error; got: $bad_err"

printf 'ok - dispatch_plan --atomize --apply --max-children-per-cycle caps child creation and emits AUTO_ATOMIZE_SUMMARY per parent (#763)\n'
