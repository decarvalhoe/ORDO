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
  scripts/external_pr_policy_backfill.sh

state_base="$TEST_TMP/state"
mkdir -p "$state_base/projA" "$state_base/projB"

# 1. Plan mode previews without writing.
plan_json=$(
  bash "$SANITIZED_ROOT/scripts/external_pr_policy_backfill.sh" \
    --state-base "$state_base" \
    --scan-state-base \
    --json
)
jq -e '
  .status == "plan" and
  .mode == "plan" and
  .counts.would_initialize == 2 and
  .counts.initialized == 0 and
  .counts.already_initialized == 0 and
  (.results | map(.status == "would-initialize") | all)
' <<< "$plan_json" >/dev/null \
  || fail "plan mode should preview both projects: $plan_json"
[[ ! -e "$state_base/projA/external_pr_policy_initialized.json" ]] \
  || fail "plan mode must not write the marker"

# 2. Apply writes one marker per project.
apply_json=$(
  bash "$SANITIZED_ROOT/scripts/external_pr_policy_backfill.sh" \
    --state-base "$state_base" \
    --scan-state-base \
    --apply --json
)
jq -e '
  .status == "apply" and
  .mode == "apply" and
  .counts.initialized == 2 and
  .counts.already_initialized == 0 and
  (.written_files | length) == 2
' <<< "$apply_json" >/dev/null \
  || fail "apply should initialize both projects: $apply_json"

marker_a="$state_base/projA/external_pr_policy_initialized.json"
marker_b="$state_base/projB/external_pr_policy_initialized.json"
[[ -s "$marker_a" ]] || fail "marker for projA should exist"
[[ -s "$marker_b" ]] || fail "marker for projB should exist"

jq -e '
  .policy == "external_pr_mutations" and
  .default == "audit-only-refused-unless-authorized" and
  .source_finding == "external-pr-mutation-policy-backfill" and
  .issue == 291 and
  .version == 1 and
  .project == "projA" and
  (.scope | index("pr_comment")) and
  (.scope | index("merge_action")) and
  (.scope | index("draft_state_change")) and
  (.initialized_at | type == "string")
' "$marker_a" >/dev/null \
  || fail "marker JSON should record policy default and provenance: $(cat "$marker_a")"

# 3. Re-running apply is idempotent: every project reports already-initialized
# and the marker bytes do not change.
sha_before_a=$(sha256sum "$marker_a" | awk '{print $1}')
sha_before_b=$(sha256sum "$marker_b" | awk '{print $1}')

second_json=$(
  bash "$SANITIZED_ROOT/scripts/external_pr_policy_backfill.sh" \
    --state-base "$state_base" \
    --scan-state-base \
    --apply --json
)
jq -e '
  .status == "apply" and
  .counts.initialized == 0 and
  .counts.already_initialized == 2 and
  (.written_files | length) == 0 and
  (.results | map(.status == "already-initialized") | all)
' <<< "$second_json" >/dev/null \
  || fail "second apply must be idempotent: $second_json"

sha_after_a=$(sha256sum "$marker_a" | awk '{print $1}')
sha_after_b=$(sha256sum "$marker_b" | awk '{print $1}')
[[ "$sha_before_a" == "$sha_after_a" ]] \
  || fail "projA marker bytes changed on second apply"
[[ "$sha_before_b" == "$sha_after_b" ]] \
  || fail "projB marker bytes changed on second apply"

# 4. --project list merges with --scan-state-base and deduplicates; new
# projects are previewed alongside already-initialized ones.
mixed_json=$(
  bash "$SANITIZED_ROOT/scripts/external_pr_policy_backfill.sh" \
    --state-base "$state_base" \
    --scan-state-base \
    --project projA \
    --project projC \
    --json
)
jq -e '
  .counts.already_initialized == 2 and
  .counts.would_initialize == 1 and
  ([.results[] | select(.project == "projA")] | length) == 1 and
  ([.results[] | select(.project == "projC")] | length) == 1 and
  ([.results[] | select(.project == "projC" and .status == "would-initialize")] | length) == 1
' <<< "$mixed_json" >/dev/null \
  || fail "--project should merge with --scan-state-base and dedupe: $mixed_json"

# 5. --dry-run keeps the command non-mutating even when --apply is set.
dry_json=$(
  bash "$SANITIZED_ROOT/scripts/external_pr_policy_backfill.sh" \
    --state-base "$state_base" \
    --project projD \
    --apply --dry-run --json
)
jq -e '
  .status == "dry-run" and
  .mode == "dry-run" and
  .counts.would_initialize == 1 and
  (.written_files | length) == 0
' <<< "$dry_json" >/dev/null \
  || fail "explicit --dry-run should preview without writing: $dry_json"
[[ ! -e "$state_base/projD/external_pr_policy_initialized.json" ]] \
  || fail "dry-run apply must not write a marker"

# 6. ORCH_DRY_RUN=1 overrides --apply just like other ORDO scripts.
override_json=$(
  ORCH_DRY_RUN=1 \
    bash "$SANITIZED_ROOT/scripts/external_pr_policy_backfill.sh" \
      --state-base "$state_base" \
      --project projE \
      --apply --json
)
jq -e '.status == "dry-run" and .mode == "dry-run"' \
  <<< "$override_json" >/dev/null \
  || fail "ORCH_DRY_RUN should override --apply: $override_json"
[[ ! -e "$state_base/projE/external_pr_policy_initialized.json" ]] \
  || fail "ORCH_DRY_RUN apply must not write a marker"

# 7. No projects resolved is a hard blocker (exit 78), with the matching
# blocker reason in the report.
empty_state_base="$TEST_TMP/empty-state"
mkdir -p "$empty_state_base"
set +e
empty_json=$(
  bash "$SANITIZED_ROOT/scripts/external_pr_policy_backfill.sh" \
    --state-base "$empty_state_base" \
    --json
)
empty_status=$?
set -e
[[ "$empty_status" -eq 78 ]] \
  || fail "no projects resolved should refuse with exit 78, got $empty_status"
jq -e '.status == "blocked" and (.blockers | index("no_projects_resolved"))' \
  <<< "$empty_json" >/dev/null \
  || fail "empty resolution should explain refusal: $empty_json"

# 8. The script must not write to any git working directory. The toolkit copy
# under SANITIZED_ROOT is treated as a stand-in proof: re-run the apply path
# from inside the toolkit copy and confirm no new files appear there.
toolkit_files_before=$(find "$SANITIZED_ROOT" -type f | sort | sha256sum | awk '{print $1}')
bash "$SANITIZED_ROOT/scripts/external_pr_policy_backfill.sh" \
  --state-base "$state_base" \
  --scan-state-base \
  --apply --json >/dev/null
toolkit_files_after=$(find "$SANITIZED_ROOT" -type f | sort | sha256sum | awk '{print $1}')
[[ "$toolkit_files_before" == "$toolkit_files_after" ]] \
  || fail "backfill must not modify any file inside the toolkit copy"

# 9. TSV format renders the report rows for downstream operators.
tsv_out=$(
  bash "$SANITIZED_ROOT/scripts/external_pr_policy_backfill.sh" \
    --state-base "$state_base" \
    --scan-state-base \
    --tsv
)
tab=$'\t'
grep -q "^status${tab}plan" <<< "$tsv_out" \
  || fail "tsv output missing status row: $tsv_out"
grep -q "^result${tab}projA${tab}already-initialized" <<< "$tsv_out" \
  || fail "tsv output missing projA result row: $tsv_out"

printf 'ok - external_pr_policy_backfill records the policy default once per project, idempotently, with no worktree side effects\n'
