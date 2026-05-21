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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/logs"

for rel in \
  scripts/dispatch_plan.sh \
  lib/audit_log.sh \
  lib/label_helpers.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dispatch_plan_headers.sh \
  lib/dry_run.sh \
  lib/github_identity.sh \
  lib/process_safety.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/dispatch_plan.sh"

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="dispatch-blockers-test"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >> "${GH_MOCK_LOG:-/dev/null}"

case "$args" in
  *"pr list"* )
    printf '%s\n' '[]'
    ;;
  *"issue list"* )
    cat <<'JSON'
[
  {"number":30,"title":"Ready implementation task","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Ready to implement; design assets are attached as reference.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/30"},
  {"number":31,"title":"French design gate","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Précondition bloquante: validation design requise avant implémentation.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/31"},
  {"number":32,"title":"Design handoff gate","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Figma first: Code Connect access required before coding can start.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/32"},
  {"number":33,"title":"Arbitration needed","labels":[{"name":"priority:P2"}],"assignees":[],"body":"À arbitrer: hosting decision and agency inputs are pending.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/33"},
  {"number":34,"title":"Multilingual rollout","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Blocage externe: traductions manquantes, plugin retenu et structure d'URL à valider.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/34"},
  {"number":35,"title":"External asset dependency","labels":[{"name":"priority:P3"}],"assignees":[],"body":"Blocked until the external asset required for the layout is delivered.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/35"},
  {"number":36,"title":"Validation gate","labels":[{"name":"priority:P3"}],"assignees":[],"body":"Requires validation from design before implementation begins.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/36"},
  {"number":37,"title":"Ready implementation validation tests","labels":[{"name":"priority:P3"}],"assignees":[],"body":"Implementation requires validation tests before merge.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/37"},
  {"number":38,"title":"feat: add GUI visual verification lane to ORDO diagnostics","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Use the Figma MCP available in this environment to capture visual baselines. The Figma MCP is required for the new diagnostics lane; this issue builds the capability and unblocks future visual checks.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/38"},
  {"number":39,"title":"feat: improve figma resource integration","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Figma MCP available. Validation through visual snapshots; access path is the new helper. No designer handoff needed.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/39"},
  {"number":40,"title":"design-blocked rollout","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Figma required before implementation. Designer must produce the spec first.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/40"},
  {"number":41,"title":"waiting on figma sign-off","labels":[{"name":"priority:P1"}],"assignees":[],"body":"This change is blocked on figma sign-off from the design lead.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/41"},
  {"number":42,"title":"figma asset required","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Figma asset required: we cannot start coding without the export from the design team.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/42"},
  {"number":43,"title":"codify parked-decisions ledger","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Meta-issue documenting arbitration discipline. The quoted rule below intentionally describes the policy and is not a request for a decision: 'a pending arbitration item is not a session-stop signal'.\n\nDecision status: RESOLVED — implement directly.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/43"},
  {"number":44,"title":"arbitration prose without resolved marker","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Pending arbitration on the agency inputs. No resolved marker, so this stays blocked.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/44"}
]
JSON
    ;;
  *"issue view"* )
    if [[ "$args" == *"--json comments"* ]]; then
      printf '%s\n' '{"comments":[]}'
    else
      printf '%s\n' '{"state":"OPEN"}'
    fi
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

json_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --json
)

jq -e '
  def row($n): map(select(.issue == $n))[0];
  (row(30).status == "ready") and
  ((row(30).signals | index("text-blocked")) | not) and
  (row(31).status == "blocked" and (row(31).blockers | index("precondition:blocking-precondition")) and (row(31).blockers | index("design:figma-or-design-gate")) and (row(31).signals | index("text-blocked"))) and
  (row(32).status == "blocked" and (row(32).blockers | index("design:figma-or-design-gate"))) and
  (row(33).status == "blocked" and (row(33).blockers | index("arbitration:decision-required"))) and
  (row(34).status == "blocked" and (row(34).blockers | index("multilingual:external-content-or-routing"))) and
  (row(35).status == "blocked" and (row(35).blockers | index("precondition:blocking-precondition")) and (row(35).blockers | index("arbitration:decision-required"))) and
  (row(36).status == "blocked" and (row(36).blockers | index("design:figma-or-design-gate"))) and
  (row(37).status == "ready") and
  ((row(37).signals | index("text-blocked")) | not) and
  (row(38).status == "ready") and
  (((row(38).blockers // []) | index("design:figma-or-design-gate")) | not) and
  ((row(38).signals | index("text-blocked")) | not) and
  (row(39).status == "ready") and
  (((row(39).blockers // []) | index("design:figma-or-design-gate")) | not) and
  ((row(39).signals | index("text-blocked")) | not) and
  (row(40).status == "blocked" and (row(40).blockers | index("design:figma-or-design-gate"))) and
  (row(41).status == "blocked" and (row(41).blockers | index("design:figma-or-design-gate"))) and
  (row(42).status == "blocked" and (row(42).blockers | index("design:figma-or-design-gate"))) and
  (row(43).status == "ready") and
  (((row(43).blockers // []) | index("arbitration:decision-required")) | not) and
  ((row(43).signals | index("text-blocked")) | not) and
  (row(44).status == "blocked" and (row(44).blockers | index("arbitration:decision-required")) and (row(44).signals | index("text-blocked")))
' <<< "$json_output" >/dev/null \
  || fail "dispatch blocker JSON classifications unexpected: $json_output"

tsv_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --tsv
)

[[ "$tsv_output" == *"precondition:blocking-precondition"* ]] || fail "TSV missing precondition blocker reason: $tsv_output"
[[ "$tsv_output" == *"design:figma-or-design-gate"* ]] || fail "TSV missing design blocker reason: $tsv_output"
[[ "$tsv_output" == *"arbitration:decision-required"* ]] || fail "TSV missing arbitration blocker reason: $tsv_output"
[[ "$tsv_output" == *"multilingual:external-content-or-routing"* ]] || fail "TSV missing multilingual blocker reason: $tsv_output"

printf 'ok - dispatch_plan blocks design, precondition, arbitration, and multilingual dependency language\n'
