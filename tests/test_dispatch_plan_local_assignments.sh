#!/usr/bin/env bash
# Issue #499: dispatch_plan.sh must flag issues that are already held by
# another agent in the local ORDO ledger (assignments.json). The ready-only
# queue must subtract them so operators cannot duplicate-dispatch active work,
# and the non-ready-only output must still surface a `local-assigned` signal
# plus a `local_assigned: true` boolean in the JSON envelope.

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
  lib/dispatch_capacity.sh \
  lib/dispatch_plan_headers.sh \
  lib/dry_run.sh \
  lib/github_identity.sh \
  lib/label_helpers.sh \
  lib/process_safety.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/dispatch_plan.sh"

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="local-assign-test"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

# Seed the per-project assignments ledger that dispatch_plan inspects via
# state_dir() — agent-001 holds #3363, agent-002 holds #3181, agent-003 is
# parked on #4242 (parked rows must NOT count as local_assigned).
mkdir -p "$TEST_TMP/state/local-assign-test"
cat > "$TEST_TMP/state/local-assign-test/assignments.json" <<'JSON'
{
  "agent-001": {"issue": 3363, "workdir": "/tmp/agent-001", "parked": false},
  "agent-002": {"ticket": 3181, "workdir": "/tmp/agent-002"},
  "agent-003": {"issue": 4242, "workdir": "/tmp/agent-003", "parked": true}
}
JSON

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"

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
  {"name":"priority:P4"}
]
JSON
    ;;
  *"pr list"* )
    printf '%s\n' '[]'
    ;;
  *"issue list"* )
    cat <<'JSON'
[
  {"number":3363,"title":"Locally held: agent-001","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Ready work but already held in local ledger","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/3363"},
  {"number":3181,"title":"Locally held: agent-002","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Ready work but already held in local ledger","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/3181"},
  {"number":4242,"title":"Parked assignment — should still appear","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Parked ledger row must not trigger local-assigned","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/4242"},
  {"number":5000,"title":"Genuinely ready","labels":[{"name":"priority:P1"}],"assignees":[],"body":"No local ledger entry","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/5000"}
]
JSON
    ;;
  *"issue view"* )
    printf '%s\n' '{"state":"OPEN","assignees":[]}'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

# 1) --ready-only: locally-assigned issues must NOT appear; the unblocked
#    issue (#5000) and the parked-only row (#4242) must remain ready.
ready_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --ready-only --json
)

jq -e '
  (map(select(.issue == 3363)) | length == 0)
  and (map(select(.issue == 3181)) | length == 0)
  and (map(select(.issue == 5000 and .status == "ready" and .local_assigned == false)) | length == 1)
  and (map(select(.issue == 4242 and .local_assigned == false)) | length == 1)
' <<< "$ready_output" >/dev/null \
  || fail "ready-only JSON should subtract locally-assigned issues and keep unassigned/parked rows: $ready_output"

# 2) Full (non-ready-only) output: locally-assigned issues are still surfaced
#    so operators can see what is held, but they carry both the
#    `local-assigned` signal and `local_assigned: true`.
full_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --json
)

jq -e '
  (map(select(.issue == 3363 and .local_assigned == true and (.signals | index("local-assigned")))) | length == 1)
  and (map(select(.issue == 3181 and .local_assigned == true and (.signals | index("local-assigned")))) | length == 1)
  and (map(select(.issue == 4242 and .local_assigned == false and ((.signals | index("local-assigned")) | not))) | length == 1)
  and (map(select(.issue == 5000 and .local_assigned == false and ((.signals | index("local-assigned")) | not))) | length == 1)
' <<< "$full_output" >/dev/null \
  || fail "full JSON should annotate locally-assigned issues and leave parked/unassigned rows clean: $full_output"

# 3) TSV mirror of (2): the `local-assigned` signal must show up in the
#    signals column for held rows and must NOT show up for unrelated rows.
ready_tsv=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --tsv
)

grep -Fq $'\nlocal-assigned' <<< ",$ready_tsv" 2>/dev/null || true
awk -F"\t" -v held1=3363 -v held2=3181 -v parked=4242 -v ready=5000 '
  NR == 1 { next }
  $1 == held1 { if ($11 !~ /local-assigned/) { exit 11 } }
  $1 == held2 { if ($11 !~ /local-assigned/) { exit 12 } }
  $1 == parked { if ($11 ~ /local-assigned/) { exit 13 } }
  $1 == ready { if ($11 ~ /local-assigned/) { exit 14 } }
' <<< "$ready_tsv" \
  || fail "TSV signal column for local-assigned rows is wrong: $ready_tsv"

# 4) Missing ledger: when assignments.json is absent the script must behave
#    exactly like before — no rows are subtracted, no rows are annotated.
rm -f "$TEST_TMP/state/local-assign-test/assignments.json"

no_ledger_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" --ready-only --json
)

jq -e '
  (map(select(.issue == 3363 and .status == "ready" and .local_assigned == false)) | length == 1)
  and (map(select(.issue == 3181 and .status == "ready" and .local_assigned == false)) | length == 1)
  and (map(select(.issue == 5000 and .status == "ready" and .local_assigned == false)) | length == 1)
  and (all(.[]; (.signals | index("local-assigned")) | not))
' <<< "$no_ledger_output" >/dev/null \
  || fail "missing ledger should not trigger local-assigned: $no_ledger_output"

printf 'ok - dispatch_plan flags locally-assigned issues in the ready queue\n'
