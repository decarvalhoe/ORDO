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
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
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
  {"number":36,"title":"Validation gate","labels":[{"name":"priority:P3"}],"assignees":[],"body":"Requires validation from design before implementation begins.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/36"}
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
  (row(36).status == "blocked" and (row(36).blockers | index("precondition:blocking-precondition")))
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
