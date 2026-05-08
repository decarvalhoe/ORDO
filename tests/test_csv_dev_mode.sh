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
  scripts/csv_dev_mode.sh

config="$TEST_TMP/project.config.sh"
target="$TEST_TMP/target"
mkdir -p "$target/scripts" "$target/tests" "$target/config" "$target/docs"
printf '%s\n' '{"scripts":{"test":"printf ok"}}' > "$target/package.json"
printf '%s\n' '[project]' 'name = "target-system"' > "$target/pyproject.toml"
printf '%s\n' 'test:' '	@printf ok' > "$target/Makefile"

cat > "$config" <<'EOF'
PROJECT="target-system"
CSV_DEV_PROJECT_ID="target-system"
CSV_DEV_DOSSIER_DIR=".ordo/validation"
CSV_DEV_REQUIREMENTS=(
  "URS-101|Controlled workflow requires reviewable evidence before release.|RR-101"
  "URS-102|Evidence integrity status must be visible before final review.|RR-102"
)
CSV_DEV_RISKS=(
  "RR-101|Generated structure is mistaken for approval.|FVR, OPS"
  "RR-102|Critical evidence lacks attribution or integrity.|EL, DEV"
)
EOF

dry_json=$(
  bash "$SANITIZED_ROOT/scripts/csv_dev_mode.sh" "$config" \
    --target-dir "$target" \
    --json
)
jq -e '
  .status == "dry-run" and
  .mode == "dry-run" and
  .safe_to_apply == true and
  .dossier_dir == ".ordo/validation" and
  .generator_limits.validates_system == false and
  .generator_limits.releases_system == false and
  .generator_limits.approves_human_decisions == false and
  (.tooling_classes | index("javascript-package")) and
  (.tooling_classes | index("python-project")) and
  (.tooling_classes | index("make-targets")) and
  (.files | map(select(.id == "FVR" and .path == ".ordo/validation/final-validation-report.md")) | length == 1) and
  (.written_files | length == 0)
' <<< "$dry_json" >/dev/null \
  || fail "dry-run should preview a safe non-mutating dossier: $dry_json"
[[ ! -e "$target/.ordo" ]] || fail "dry-run must not create dossier directory"
if grep -F "$TEST_TMP" <<< "$dry_json" >/dev/null; then
  fail "dry-run JSON should not expose local filesystem paths: $dry_json"
fi

dry_override_json=$(
  ORCH_DRY_RUN=1 \
    bash "$SANITIZED_ROOT/scripts/csv_dev_mode.sh" "$config" \
      --target-dir "$target" \
      --apply \
      --json
)
jq -e '.status == "dry-run" and .mode == "dry-run" and (.written_files | length == 0)' \
  <<< "$dry_override_json" >/dev/null \
  || fail "ORCH_DRY_RUN should override apply: $dry_override_json"
[[ ! -e "$target/.ordo" ]] || fail "dry-run override must not create dossier directory"

apply_json=$(
  bash "$SANITIZED_ROOT/scripts/csv_dev_mode.sh" "$config" \
    --target-dir "$target" \
    --apply \
    --json
)
jq -e '
  .status == "ready" and
  .mode == "apply" and
  .safe_to_apply == true and
  (.written_files | index(".ordo/validation/final-validation-report.md")) and
  (.written_files | index(".ordo/validation/evidence-ledger.md")) and
  (.written_files | index(".ordo/validation/iq-oq-pq-dependency-graph.md"))
' <<< "$apply_json" >/dev/null \
  || fail "apply should write generated dossier files: $apply_json"

dossier="$target/.ordo/validation"
[[ -s "$dossier/document-index.md" ]] || fail "document index should be generated"
[[ -s "$dossier/final-validation-report.md" ]] || fail "final report template should be generated"
[[ -s "$dossier/evidence-ledger.md" ]] || fail "evidence ledger should be generated"
grep -q "\`VMP\`" "$dossier/document-index.md" \
  || fail "document index should include VMP stable ID"
grep -q "\`IQ-P\`" "$dossier/document-index.md" \
  || fail "document index should include IQ protocol stable ID"
grep -q "\`OQ-P\`" "$dossier/document-index.md" \
  || fail "document index should include OQ protocol stable ID"
grep -q "\`PQ-P\`" "$dossier/document-index.md" \
  || fail "document index should include PQ protocol stable ID"
grep -q "\`URS-101\`" "$dossier/user-requirements.md" \
  || fail "configured non-product-specific requirements should be rendered"
grep -q "\`RR-102\`" "$dossier/risk-register.md" \
  || fail "configured non-product-specific risks should be rendered"
grep -q 'javascript-package' "$dossier/iq-oq-pq-dependency-graph.md" \
  || fail "dependency graph should include detected tooling"
grep -q 'Human approval is separate' "$dossier/evidence-ledger.md" \
  || fail "evidence ledger should separate mechanical evidence from approval"
grep -q 'Missing or failed signature or attestation verification for critical evidence' "$dossier/evidence-ledger.md" \
  || fail "evidence ledger should route failed critical verification to deviation"

final_report="$dossier/final-validation-report.md"
grep -q 'Release status: NOT RELEASED.' "$final_report" \
  || fail "final report must state not released"
grep -q 'Production readiness: NOT APPROVED.' "$final_report" \
  || fail "final report must state production readiness is not approved"
grep -q 'Validation decision: not made by generator.' "$final_report" \
  || fail "final report must not claim a validation decision"
if grep -Eiq 'Release status:[[:space:]]*(RELEASED|APPROVED)|Production readiness:[[:space:]]*(READY|APPROVED)|Validation decision:[[:space:]]*(VALIDATED|APPROVED|RELEASED)' "$final_report"; then
  fail "final report must not contain an automatic validated/released claim"
fi

if rg -n -F "$TEST_TMP" "$dossier"; then
  fail "generated dossier should not expose local filesystem paths"
fi
if rg -n '://|[0-9]{1,3}(\.[0-9]{1,3}){3}' "$dossier"; then
  fail "generated dossier should not contain network or address references"
fi

before_hashes=$(
  find "$dossier" -type f -print0 | sort -z | xargs -0 sha256sum
)
second_apply_json=$(
  bash "$SANITIZED_ROOT/scripts/csv_dev_mode.sh" "$config" \
    --target-dir "$target" \
    --apply \
    --json
)
jq -e '.status == "ready" and (.files | map(select(.action == "update")) | length > 0)' \
  <<< "$second_apply_json" >/dev/null \
  || fail "safe re-run should update managed generated files: $second_apply_json"
after_hashes=$(
  find "$dossier" -type f -print0 | sort -z | xargs -0 sha256sum
)
[[ "$before_hashes" == "$after_hashes" ]] \
  || fail "idempotent re-run should not change generated file content"

blocked_target="$TEST_TMP/blocked-target"
mkdir -p "$blocked_target/validation"
printf '%s\n' '# Human-authored file' > "$blocked_target/validation/README.md"
set +e
blocked_json=$(
  bash "$SANITIZED_ROOT/scripts/csv_dev_mode.sh" "$config" \
    --target-dir "$blocked_target" \
    --dossier-dir validation \
    --apply \
    --json
)
blocked_status=$?
set -e
[[ "$blocked_status" -eq 78 ]] \
  || fail "unmanaged existing files should refuse apply, got $blocked_status: $blocked_json"
jq -e '.status == "blocked" and (.apply_blockers | index("generated_file_exists_unmanaged:validation/README.md"))' \
  <<< "$blocked_json" >/dev/null \
  || fail "unmanaged file refusal should name the blocking file: $blocked_json"

printf 'ok - csv_dev_mode previews, applies, re-runs safely, and never auto-validates\n'
