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
  scripts/controlled_operation.sh

mkdir -p "$TEST_TMP/gh" "$TEST_TMP/logs" "$TEST_TMP/worktrees"

config="$TEST_TMP/project.config.sh"
cat > "$config" <<EOF
PROJECT="controlled-op-test"
GH_REPO="example-org/example-repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
EOF

export ORCH_LOG_DIR="$TEST_TMP/logs"
export ORCH_STATE_BASE="$TEST_TMP/state"

plan_output=$(
  bash "$SANITIZED_ROOT/scripts/controlled_operation.sh" "$config" plan \
    --type emergency-admin \
    --id emergency-001 \
    --reason "temporary maintenance" \
    --json
)

[[ "$(jq -r '.operation.type' <<< "$plan_output")" == "emergency-admin" ]] \
  || fail "plan should preserve controlled operation type"
for section in approval temporary_branch workflow secrets run cache cleanup; do
  jq -e --arg section "$section" '.evidence_sections | index($section)' \
    <<< "$plan_output" >/dev/null \
    || fail "plan missing evidence section: $section"
done
[[ "$(jq -r '.note' <<< "$plan_output")" == *"do not store secret material"* ]] \
  || fail "plan must warn against secret material"

valid_evidence="$TEST_TMP/valid-evidence.json"
cat > "$valid_evidence" <<'JSON'
{
  "operation": {
    "id": "emergency-001",
    "type": "emergency-admin",
    "reason": "temporary maintenance"
  },
  "approval": {
    "approved_by": "operator-a"
  },
  "temporary_branch": {
    "name": "ops/emergency-001",
    "base": "main",
    "created": true,
    "removed": true
  },
  "workflow": {
    "path": "workflows/controlled-operation.yml",
    "created": true,
    "removed": true
  },
  "secrets": {
    "names": ["TEMP_CONTROLLED_SECRET"],
    "created": true,
    "removed": true
  },
  "run": {
    "id": "123",
    "url": "https://example.invalid/runs/123",
    "conclusion": "success"
  },
  "cache": {
    "key": "controlled-cache-001",
    "purged": true
  },
  "cleanup": {
    "completed": true,
    "branch_deleted": true,
    "workflow_removed": true,
    "secrets_removed": true,
    "cache_purged": true
  }
}
JSON

verify_output=$(
  bash "$SANITIZED_ROOT/scripts/controlled_operation.sh" "$config" verify \
    --evidence-file "$valid_evidence" \
    --json
)
[[ "$(jq -r '.decision' <<< "$verify_output")" == "pass" ]] \
  || fail "valid evidence should pass verification: $verify_output"

invalid_evidence="$TEST_TMP/invalid-evidence.json"
cat > "$invalid_evidence" <<'JSON'
{
  "operation": {
    "id": "provider-001",
    "type": "provider-workflow",
    "reason": "temporary external gate"
  },
  "approval": {
    "approved_by": "operator-a"
  },
  "temporary_branch": {
    "name": "ops/provider-001",
    "base": "main",
    "created": true,
    "removed": true
  },
  "workflow": {
    "path": "workflows/controlled-operation.yml",
    "created": true,
    "removed": true
  },
  "secrets": {
    "names": ["TEMP_CONTROLLED_SECRET"],
    "created": true,
    "removed": true,
    "value": "must-not-be-recorded"
  },
  "run": {
    "id": "456",
    "url": "https://example.invalid/runs/456",
    "conclusion": "success"
  }
}
JSON

set +e
invalid_output=$(
  bash "$SANITIZED_ROOT/scripts/controlled_operation.sh" "$config" verify \
    --evidence-file "$invalid_evidence" \
    --json
)
invalid_status=$?
set -e
[[ "$invalid_status" -eq 10 ]] \
  || fail "invalid evidence should exit 10, got $invalid_status: $invalid_output"
jq -e '.missing | index("cache.key") and index("cleanup.completed")' \
  <<< "$invalid_output" >/dev/null \
  || fail "invalid evidence should report missing cache and cleanup evidence: $invalid_output"
jq -e '.missing[] | select(. == "prohibited-secret-material:secrets.value")' \
  <<< "$invalid_output" >/dev/null \
  || fail "invalid evidence should reject secret material: $invalid_output"

dry_output=$(
  bash "$SANITIZED_ROOT/scripts/controlled_operation.sh" "$config" record \
    --evidence-file "$valid_evidence" \
    --dry-run \
    --json 2>&1
)
[[ "$dry_output" == *"DRY-RUN:"* ]] || fail "dry-run record should print dry-run note"
[[ "$dry_output" == *'"decision": "dry-run"'* ]] || fail "dry-run record should return JSON decision"
[[ ! -e "$ORCH_STATE_BASE/controlled-op-test/controlled_operations.jsonl" ]] \
  || fail "dry-run record must not create state file"

record_output=$(
  bash "$SANITIZED_ROOT/scripts/controlled_operation.sh" "$config" record \
    --evidence-file "$valid_evidence" \
    --json
)
[[ "$(jq -r '.decision' <<< "$record_output")" == "recorded" ]] \
  || fail "record should return recorded decision: $record_output"
state_file="$ORCH_STATE_BASE/controlled-op-test/controlled_operations.jsonl"
[[ -f "$state_file" ]] || fail "record should create controlled operation state file"
[[ "$(wc -l < "$state_file" | tr -d ' ')" == "1" ]] \
  || fail "record should append exactly one JSONL line"
[[ "$(jq -r '.operation.id' "$state_file")" == "emergency-001" ]] \
  || fail "state record should contain operation id"
grep -q 'CONTROLLED_OPERATION recorded id=emergency-001 type=emergency-admin' \
  "$ORCH_LOG_DIR/controlled-op-test.log" \
  || fail "record should write audit evidence"

printf 'ok - controlled_operation plans, verifies, and records controlled workflow evidence\n'
