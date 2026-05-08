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
  scripts/opportunity_registry.sh

config="$TEST_TMP/project.config.sh"
cat > "$config" <<EOF
PROJECT="registry-test"
DEFAULT_BRANCH="main"
EOF

export ORCH_OPPORTUNITY_REGISTRY_DIR="$TEST_TMP/registry-root"

registry=$(
  bash "$SANITIZED_ROOT/scripts/opportunity_registry.sh" "$config" path
)
[[ "$registry" == "$TEST_TMP/registry-root/registry-test/opportunities.jsonl" ]] \
  || fail "unexpected registry path: $registry"

schema=$(
  bash "$SANITIZED_ROOT/scripts/opportunity_registry.sh" "$config" schema
)
[[ "$(jq -r '.record_schema' <<< "$schema")" == "ordo.opportunity.v1" ]] \
  || fail "schema should expose record schema: $schema"
jq -e '.required_fields | index("finding") and index("linked_evidence")' \
  <<< "$schema" >/dev/null \
  || fail "schema should list required opportunity fields: $schema"

dry_output=$(
  bash "$SANITIZED_ROOT/scripts/opportunity_registry.sh" "$config" add \
    --code OP-001 \
    --finding "Clone preflight did not detect an authentication mismatch" \
    --impact "safe remediation could report partial success" \
    --detection-signal "synthetic clone report with failed rows" \
    --remediation "check repository protocol before clone attempts" \
    --validation-plan "add a negative preflight fixture and a safe remediation fixture" \
    --priority P1 \
    --severity high \
    --source "synthetic portfolio run" \
    --evidence "artifact:synthetic-clone-report" \
    --created-at "2026-05-08T00:00:00Z"
)
[[ "$dry_output" == *"DRY-RUN: append opportunity OP-001"* ]] \
  || fail "add should be dry-run by default: $dry_output"
[[ ! -e "$registry" ]] || fail "dry-run add must not create registry file"
record_json=$(printf '%s\n' "$dry_output" | tail -n 1)
[[ "$(jq -r '.id' <<< "$record_json")" == "OP-001" ]] \
  || fail "dry-run should print opportunity JSON record: $dry_output"
[[ "$(jq -r '.linked_evidence[0]' <<< "$record_json")" == "artifact:synthetic-clone-report" ]] \
  || fail "dry-run should include linked evidence: $record_json"

apply_output=$(
  bash "$SANITIZED_ROOT/scripts/opportunity_registry.sh" "$config" add \
    --code OP-001 \
    --finding "Clone preflight did not detect an authentication mismatch" \
    --impact "safe remediation could report partial success" \
    --detection-signal "synthetic clone report with failed rows" \
    --remediation "check repository protocol before clone attempts" \
    --validation-plan "add a negative preflight fixture and a safe remediation fixture" \
    --priority P1 \
    --severity high \
    --source "synthetic portfolio run" \
    --evidence "artifact:synthetic-clone-report" \
    --related "issue:synthetic-follow-up" \
    --created-at "2026-05-08T00:00:00Z" \
    --apply \
    --json
)
[[ "$(jq -r '.decision' <<< "$apply_output")" == "recorded" ]] \
  || fail "apply should record opportunity: $apply_output"
[[ -f "$registry" ]] || fail "apply should create registry file"
[[ "$(wc -l < "$registry" | tr -d ' ')" == "1" ]] \
  || fail "registry should contain exactly one record"
[[ "$(jq -r '.related_refs[0]' "$registry")" == "issue:synthetic-follow-up" ]] \
  || fail "registry should include related references"

listed=$(
  bash "$SANITIZED_ROOT/scripts/opportunity_registry.sh" "$config" list --json
)
[[ "$(jq 'length' <<< "$listed")" == "1" ]] \
  || fail "list --json should return one record: $listed"
[[ "$(jq -r '.[0].finding' <<< "$listed")" == "Clone preflight did not detect an authentication mismatch" ]] \
  || fail "list should preserve finding text: $listed"

set +e
duplicate_output=$(
  bash "$SANITIZED_ROOT/scripts/opportunity_registry.sh" "$config" add \
    --code OP-001 \
    --finding "Duplicate opportunity" \
    --impact "would obscure the registry" \
    --detection-signal "synthetic duplicate command" \
    --remediation "reject duplicate identifiers" \
    --validation-plan "assert nonzero duplicate exit" \
    --priority P2 \
    --evidence "artifact:duplicate" \
    --apply 2>&1
)
duplicate_status=$?
set -e
[[ "$duplicate_status" -eq 3 ]] \
  || fail "duplicate apply should exit 3, got $duplicate_status: $duplicate_output"
[[ "$duplicate_output" == *"duplicate opportunity id: OP-001"* ]] \
  || fail "duplicate output should explain refusal: $duplicate_output"

set +e
missing_output=$(
  bash "$SANITIZED_ROOT/scripts/opportunity_registry.sh" "$config" add \
    --code OP-002 \
    --finding "Missing evidence should fail" \
    --impact "registry would lose traceability" \
    --detection-signal "synthetic command" \
    --remediation "require linked evidence" \
    --validation-plan "assert missing evidence refusal" \
    --priority P2 2>&1
)
missing_status=$?
set -e
[[ "$missing_status" -eq 2 ]] \
  || fail "missing evidence should exit 2, got $missing_status: $missing_output"
[[ "$missing_output" == *"missing --evidence"* ]] \
  || fail "missing evidence output should explain refusal: $missing_output"

dry_apply_output=$(
  ORCH_DRY_RUN=1 \
    bash "$SANITIZED_ROOT/scripts/opportunity_registry.sh" "$config" add \
      --code OP-003 \
      --finding "Explicit dry run overrides apply" \
      --impact "protects operator preview behavior" \
      --detection-signal "synthetic command" \
      --remediation "honor ORCH_DRY_RUN" \
      --validation-plan "assert no second record is written" \
      --priority P3 \
      --evidence "artifact:dry-run-override" \
      --apply \
      --json
)
[[ "$(jq -r '.decision' <<< "$dry_apply_output")" == "dry-run" ]] \
  || fail "ORCH_DRY_RUN should override --apply: $dry_apply_output"
[[ "$(wc -l < "$registry" | tr -d ' ')" == "1" ]] \
  || fail "ORCH_DRY_RUN apply must not append a second record"

printf 'ok - opportunity_registry records durable opportunities only with explicit apply\n'
