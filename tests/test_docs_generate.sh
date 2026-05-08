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
  scripts/docs_generate.sh

# Templates live alongside the toolkit; copy them so the sanitized run is
# self-contained.
mkdir -p "$SANITIZED_ROOT/templates"
cp -R "$ROOT/templates/docs" "$SANITIZED_ROOT/templates/"

config="$TEST_TMP/project.config.sh"
cat > "$config" <<'EOF'
PROJECT="docs-fixture"
DEFAULT_BRANCH="main"
EOF

target="$TEST_TMP/downstream"
mkdir -p "$target"
git init -q "$target"
git -C "$target" symbolic-ref HEAD refs/heads/main
cat > "$target/README.md" <<'EOF'
# downstream readme
EOF
cat > "$target/package.json" <<'EOF'
{ "name": "downstream-fixture" }
EOF
ctx="$TEST_TMP/context.md"
cat > "$ctx" <<'EOF'
The downstream project exposes a CLI for reconciling daily reports.
Operators run the CLI on a scheduled basis from the reporting host.
EOF

# 1. Plan should preview without writing.
plan_json=$(
  bash "$SANITIZED_ROOT/scripts/docs_generate.sh" "$config" \
    --target-dir "$target" \
    --intent "Reconcile daily reports for operators" \
    --operator-context-file "$ctx" \
    --json
)
jq -e '
  .status == "plan" and
  .mode == "plan" and
  .defaults_safe == true and
  .layers.gxp_grade == false and
  .layers.sixsigma == false and
  (.layers.selected | index("index")) and
  (.layers.selected | index("maintenance")) and
  ((.layers.selected | index("gxp")) | not) and
  ((.layers.selected | index("sixsigma")) | not) and
  (.files | map(.layer) | unique | sort) == ["developer","index","integration","maintenance","operator","user","validation"] and
  (.files | length) >= 9 and
  .safe_to_apply == true and
  .repo_metadata_signature != null
' <<< "$plan_json" >/dev/null \
  || fail "plan should preview default normal-dev pack: $plan_json"
[[ ! -e "$target/docs/generated" ]] || fail "plan must not write to disk"

# 2. Apply normal-dev should write the default pack and the manifest.
apply_json=$(
  bash "$SANITIZED_ROOT/scripts/docs_generate.sh" "$config" \
    --target-dir "$target" \
    --intent "Reconcile daily reports for operators" \
    --operator-context-file "$ctx" \
    --apply --json
)
jq -e '
  .status == "ready" and
  .mode == "apply" and
  .defaults_safe == true and
  (.written_files | index("index.md")) and
  (.written_files | index("maintenance.md")) and
  (.written_files | index("developer/overview.md")) and
  (.written_files | index("user/user-guide.md")) and
  (.written_files | index("operator/operator-runbook.md")) and
  (.written_files | index("integration/integration-notes.md")) and
  (.written_files | index("validation/evidence-index.md")) and
  (.written_files | index("generated.manifest.json"))
' <<< "$apply_json" >/dev/null \
  || fail "default apply should write base pack: $apply_json"

[[ -s "$target/docs/generated/index.md" ]] || fail "index.md should exist"
grep -q "Documentation Pack — docs-fixture" "$target/docs/generated/index.md" \
  || fail "index.md should be branded with project name"
grep -q "Reconcile daily reports for operators" "$target/docs/generated/index.md" \
  || fail "index.md should reflect the supplied intent"
grep -q "Reconcile daily reports for operators" "$target/docs/generated/user/user-guide.md" \
  || fail "user-guide.md should reflect the supplied intent"
grep -q "Operators run the CLI on a scheduled basis" "$target/docs/generated/developer/overview.md" \
  || fail "developer overview should embed operator-supplied context"

[[ ! -d "$target/docs/generated/gxp" ]] \
  || fail "default apply must not emit gxp layer"
[[ ! -d "$target/docs/generated/sixsigma" ]] \
  || fail "default apply must not emit sixsigma layer"

manifest="$target/docs/generated/generated.manifest.json"
[[ -s "$manifest" ]] || fail "generated.manifest.json should exist"
jq -e '
  .defaults_safe == true and
  .layers.gxp_grade == false and
  .layers.sixsigma == false and
  ((.layers.selected | index("gxp")) | not) and
  ((.layers.selected | index("sixsigma")) | not) and
  .inputs.product_intent == "Reconcile daily reports for operators" and
  .inputs.project_name == "docs-fixture" and
  .inputs.repo_metadata_signature != null and
  (.files | map(.path) | index("index.md")) and
  (.files | map(.path) | index("maintenance.md")) and
  (.follow_up_gaps | type) == "array"
' "$manifest" >/dev/null \
  || fail "manifest should record neutral default and inputs: $(cat "$manifest")"

# 3. Re-applying without --overwrite must refuse with exit 78.
set +e
duplicate_json=$(
  bash "$SANITIZED_ROOT/scripts/docs_generate.sh" "$config" \
    --target-dir "$target" \
    --intent "Reconcile daily reports for operators" \
    --operator-context-file "$ctx" \
    --apply --json
)
duplicate_status=$?
set -e
[[ "$duplicate_status" -eq 78 ]] \
  || fail "duplicate apply should refuse with exit 78, got $duplicate_status"
jq -e '
  .status == "blocked" and
  ((.apply_blockers | index("output_dir_not_empty")) or
   (.apply_blockers | map(startswith("generated_file_exists:")) | any))
' <<< "$duplicate_json" >/dev/null \
  || fail "duplicate apply should explain refusal: $duplicate_json"

# 4. With --overwrite the apply should succeed.
overwrite_json=$(
  bash "$SANITIZED_ROOT/scripts/docs_generate.sh" "$config" \
    --target-dir "$target" \
    --intent "Reconcile daily reports for operators" \
    --operator-context-file "$ctx" \
    --apply --overwrite --json
)
jq -e '.status == "ready" and .mode == "apply"' <<< "$overwrite_json" >/dev/null \
  || fail "overwrite apply should succeed: $overwrite_json"

# 5. GxP-grade selection emits the gxp layer and never leaks into normal-dev.
gxp_target="$TEST_TMP/gxp-target"
mkdir -p "$gxp_target"
git init -q "$gxp_target"
git -C "$gxp_target" symbolic-ref HEAD refs/heads/main
gxp_json=$(
  bash "$SANITIZED_ROOT/scripts/docs_generate.sh" "$config" \
    --target-dir "$gxp_target" \
    --intent "Operate a regulated reconciliation pipeline" \
    --operator-context-file "$ctx" \
    --gxp-grade --apply --json
)
jq -e '
  .status == "ready" and
  .layers.gxp_grade == true and
  .layers.sixsigma == false and
  .defaults_safe == false and
  (.layers.selected | index("gxp")) and
  ((.layers.selected | index("sixsigma")) | not) and
  (.written_files | index("gxp/controlled-document-policy.md")) and
  (.written_files | index("gxp/validation-evidence.md")) and
  (.written_files | index("gxp/audit-trail.md")) and
  (.written_files | index("gxp/deviation-capa.md")) and
  (.written_files | index("gxp/traceability.md")) and
  (.written_files | index("gxp/approval-handoff.md"))
' <<< "$gxp_json" >/dev/null \
  || fail "gxp-grade apply should emit gxp layer: $gxp_json"
[[ ! -d "$gxp_target/docs/generated/sixsigma" ]] \
  || fail "gxp-only apply must not emit sixsigma layer"
grep -q "gxp_grade_layer: \`1\`" "$gxp_target/docs/generated/index.md" \
  || fail "index should record gxp_grade=1"

# 6. Six Sigma selection emits the sixsigma layer and does not pull in GxP.
ss_target="$TEST_TMP/ss-target"
mkdir -p "$ss_target"
git init -q "$ss_target"
git -C "$ss_target" symbolic-ref HEAD refs/heads/main
ss_json=$(
  bash "$SANITIZED_ROOT/scripts/docs_generate.sh" "$config" \
    --target-dir "$ss_target" \
    --intent "Drive process improvement on the reconciliation pipeline" \
    --operator-context-file "$ctx" \
    --sixsigma --apply --json
)
jq -e '
  .layers.sixsigma == true and
  .layers.gxp_grade == false and
  (.layers.selected | index("sixsigma")) and
  ((.layers.selected | index("gxp")) | not) and
  (.written_files | index("sixsigma/dmaic.md")) and
  (.written_files | index("sixsigma/ctq.md")) and
  (.written_files | index("sixsigma/metric-evidence-ledger.md")) and
  (.written_files | index("sixsigma/control-plan.md")) and
  (.written_files | index("sixsigma/improvement-backlog.md"))
' <<< "$ss_json" >/dev/null \
  || fail "sixsigma apply should emit sixsigma layer: $ss_json"
[[ ! -d "$ss_target/docs/generated/gxp" ]] \
  || fail "sixsigma-only apply must not emit gxp layer"

# 7. Both layers can be combined.
both_target="$TEST_TMP/both-target"
mkdir -p "$both_target"
git init -q "$both_target"
git -C "$both_target" symbolic-ref HEAD refs/heads/main
both_json=$(
  bash "$SANITIZED_ROOT/scripts/docs_generate.sh" "$config" \
    --target-dir "$both_target" \
    --intent "Operate a regulated and continuously improved pipeline" \
    --operator-context-file "$ctx" \
    --gxp-grade --sixsigma --apply --json
)
jq -e '
  .layers.gxp_grade == true and
  .layers.sixsigma == true and
  (.layers.selected | index("gxp")) and
  (.layers.selected | index("sixsigma")) and
  .defaults_safe == false
' <<< "$both_json" >/dev/null \
  || fail "combined apply should emit both layers: $both_json"

# 8. Dry-run apply must not write.
dry_target="$TEST_TMP/dry-target"
mkdir -p "$dry_target"
git init -q "$dry_target"
git -C "$dry_target" symbolic-ref HEAD refs/heads/main
dry_json=$(
  bash "$SANITIZED_ROOT/scripts/docs_generate.sh" "$config" \
    --target-dir "$dry_target" \
    --intent "Reconcile daily reports for operators" \
    --apply --dry-run --json
)
jq -e '.status == "dry-run" and .mode == "dry-run" and .safe_to_apply == true' \
  <<< "$dry_json" >/dev/null \
  || fail "dry-run should preview without writing: $dry_json"
[[ ! -e "$dry_target/docs/generated" ]] \
  || fail "dry-run must not create output directory"

# 9. ORCH_DRY_RUN should override --apply.
override_target="$TEST_TMP/override-target"
mkdir -p "$override_target"
git init -q "$override_target"
git -C "$override_target" symbolic-ref HEAD refs/heads/main
override_json=$(
  ORCH_DRY_RUN=1 \
    bash "$SANITIZED_ROOT/scripts/docs_generate.sh" "$config" \
      --target-dir "$override_target" \
      --intent "Reconcile reports" \
      --gxp-grade --sixsigma --apply --json
)
jq -e '.status == "dry-run" and .layers.gxp_grade == true and .layers.sixsigma == true' \
  <<< "$override_json" >/dev/null \
  || fail "ORCH_DRY_RUN should preserve layer selection while suppressing writes"
[[ ! -e "$override_target/docs/generated" ]] \
  || fail "ORCH_DRY_RUN apply must not write"

# 10. Missing inputs must be reported as gaps and as blockers.
set +e
missing_target_json=$(
  bash "$SANITIZED_ROOT/scripts/docs_generate.sh" "$config" --intent "x" --apply --json
)
missing_target_status=$?
set -e
[[ "$missing_target_status" -eq 78 ]] \
  || fail "missing target should block, got $missing_target_status"
jq -e '
  .status == "blocked" and
  (.blockers | index("target_dir_missing")) and
  (.follow_up_gaps | index("target_directory_missing"))
' <<< "$missing_target_json" >/dev/null \
  || fail "missing target should be reported in blockers and follow_up_gaps: $missing_target_json"

# 11. Gaps surface when intent and operator context are absent.
gaps_target="$TEST_TMP/gaps-target"
mkdir -p "$gaps_target"
gaps_json=$(
  bash "$SANITIZED_ROOT/scripts/docs_generate.sh" "$config" \
    --target-dir "$gaps_target" \
    --json
)
jq -e '
  .status == "plan" and
  (.follow_up_gaps | index("product_intent_not_supplied")) and
  (.follow_up_gaps | index("operator_context_not_supplied"))
' <<< "$gaps_json" >/dev/null \
  || fail "gaps should report missing intent and missing operator context: $gaps_json"

# 12. Generated docs do not infer a business claim from the project config.
grep -q "validation_owner\|production-ready\|FDA\|regulated for" \
  "$target/docs/generated/index.md" \
  && fail "generated index leaked an unwarranted regulated claim"
grep -q "production_ready: true" "$target/docs/generated/index.md" \
  && fail "generated index leaked production-ready claim"
grep -qi "this project is validated" "$target/docs/generated/index.md" \
  && fail "generated index leaked validation claim"

# 13. TSV format works for plan output.
tsv_out=$(
  bash "$SANITIZED_ROOT/scripts/docs_generate.sh" "$config" \
    --target-dir "$gaps_target" \
    --intent "x" \
    --tsv
)
tab=$'\t'
grep -q "^status${tab}plan" <<< "$tsv_out" \
  || fail "tsv output missing status row: $tsv_out"
grep -q "^layer${tab}index" <<< "$tsv_out" \
  || fail "tsv output missing index layer row: $tsv_out"

printf 'ok - docs_generate produces neutral default pack and emits optional gxp and sixsigma layers only when requested\n'
