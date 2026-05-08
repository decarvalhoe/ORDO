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
  scripts/project_scaffold.sh \
  scripts/repository_bootstrap.sh \
  scripts/repository_platform_readiness.sh

config="$TEST_TMP/project.config.sh"
cat > "$config" <<EOF
PROJECT="scaffold-test"
DEFAULT_BRANCH="main"
EOF

target="$TEST_TMP/project"
intent="Expose request response capability for internal operators"

plan_json=$(
  bash "$SANITIZED_ROOT/scripts/project_scaffold.sh" "$config" \
    --intent "$intent" \
    --target-dir "$target" \
    --repo-mode existing \
    --json
)
jq -e '
  .status == "plan" and
  .mode == "plan" and
  .selected_archetype == "service" and
  .safe_to_apply == false and
  (.repository_contract.required_command | contains("repository_platform_readiness.sh")) and
  (.apply_blockers | index("readiness_report_required_for_apply")) and
  (.files | map(select(.path == "ci/validate.sh" and .executable == true)) | length == 1)
' <<< "$plan_json" >/dev/null \
  || fail "plan should select service archetype and require readiness evidence: $plan_json"
[[ ! -e "$target" ]] || fail "plan must not create target directory"

ready_report="$TEST_TMP/readiness-ready.json"
cat > "$ready_report" <<'JSON'
{
  "status": "ready",
  "repository": "synthetic-repository",
  "capabilities": {
    "repository_access": {"ready": true},
    "push_permission": {"ready": true}
  },
  "blockers": []
}
JSON

defaults_target="$TEST_TMP/defaults-project"
mkdir -p "$defaults_target"
git init -q "$defaults_target"
git -C "$defaults_target" symbolic-ref HEAD refs/heads/main
defaults_config="$TEST_TMP/project-defaults.config.sh"
cat > "$defaults_config" <<EOF
PROJECT="scaffold-defaults-test"
DEFAULT_BRANCH="main"
PROJECT_SCAFFOLD_INTENT="Run scheduled background work for operators"
PROJECT_SCAFFOLD_TARGET_DIR="$defaults_target"
PROJECT_SCAFFOLD_REPO_MODE="existing"
PROJECT_SCAFFOLD_READINESS_REPORT="$ready_report"
EOF

defaults_json=$(
  bash "$SANITIZED_ROOT/scripts/project_scaffold.sh" "$defaults_config" \
    --apply \
    --json
)
jq -e '
  .status == "ready" and
  .mode == "apply" and
  .selected_archetype == "worker" and
  .target_dir == "'"$defaults_target"'" and
  .repository_contract.mode == "existing" and
  .repository_contract.readiness_report == "'"$ready_report"'" and
  (.written_files | index("README.md"))
' <<< "$defaults_json" >/dev/null \
  || fail "config-provided scaffold defaults should work without repeated flags: $defaults_json"

dry_json=$(
  bash "$SANITIZED_ROOT/scripts/project_scaffold.sh" "$config" \
    --intent "$intent" \
    --target-dir "$target" \
    --repo-mode existing \
    --readiness-report "$ready_report" \
    --apply \
    --dry-run \
    --json
)
jq -e '.status == "dry-run" and .mode == "dry-run" and .safe_to_apply == true' \
  <<< "$dry_json" >/dev/null \
  || fail "explicit dry-run should preview safe apply without writing: $dry_json"
[[ ! -e "$target" ]] || fail "dry-run apply must not create target directory"

mkdir -p "$target"
git init -q "$target"
git -C "$target" symbolic-ref HEAD refs/heads/main

apply_json=$(
  bash "$SANITIZED_ROOT/scripts/project_scaffold.sh" "$config" \
    --intent "$intent" \
    --target-dir "$target" \
    --repo-mode existing \
    --readiness-report "$ready_report" \
    --apply \
    --json
)
jq -e '
  .status == "ready" and
  .mode == "apply" and
  .safe_to_apply == true and
  (.written_files | index("README.md")) and
  (.written_files | index("ci/validate.sh")) and
  (.decisions_required | length > 0)
' <<< "$apply_json" >/dev/null \
  || fail "apply should write scaffold and report decisions: $apply_json"
[[ -s "$target/README.md" ]] || fail "README should be generated"
[[ -x "$target/ci/validate.sh" ]] || fail "validation stub should be executable"
grep -q "No framework, provider, runtime" "$target/README.md" \
  || fail "README should surface neutral assumptions"
grep -q "repository_platform_readiness.sh" "$target/docs/bootstrap-summary.md" \
  || fail "bootstrap summary should consume repository readiness contract"
(cd "$target" && bash ci/validate.sh) >/dev/null \
  || fail "generated validation stub should pass baseline scaffold"

set +e
duplicate_json=$(
  bash "$SANITIZED_ROOT/scripts/project_scaffold.sh" "$config" \
    --intent "$intent" \
    --target-dir "$target" \
    --repo-mode existing \
    --readiness-report "$ready_report" \
    --apply \
    --json
)
duplicate_status=$?
set -e
[[ "$duplicate_status" -eq 78 ]] \
  || fail "existing scaffold files should refuse apply, got $duplicate_status: $duplicate_json"
jq -e '.status == "blocked" and (.apply_blockers | index("target_dir_not_empty")) and (.apply_blockers | index("scaffold_file_exists:README.md"))' \
  <<< "$duplicate_json" >/dev/null \
  || fail "duplicate apply should explain refusal: $duplicate_json"

blocked_report="$TEST_TMP/readiness-blocked.json"
cat > "$blocked_report" <<'JSON'
{
  "status": "blocked",
  "blockers": ["repository_access"]
}
JSON

blocked_target="$TEST_TMP/blocked-project"
mkdir -p "$blocked_target"
git init -q "$blocked_target"
git -C "$blocked_target" symbolic-ref HEAD refs/heads/main
set +e
blocked_json=$(
  bash "$SANITIZED_ROOT/scripts/project_scaffold.sh" "$config" \
    --intent "Run scheduled background work" \
    --target-dir "$blocked_target" \
    --repo-mode greenfield \
    --readiness-report "$blocked_report" \
    --apply \
    --json
)
blocked_status=$?
set -e
[[ "$blocked_status" -eq 78 ]] \
  || fail "blocked readiness should refuse apply, got $blocked_status: $blocked_json"
jq -e '
  .selected_archetype == "worker" and
  (.repository_contract.required_command | contains("repository_bootstrap.sh")) and
  (.apply_blockers | index("readiness_report_not_ready"))
' <<< "$blocked_json" >/dev/null \
  || fail "greenfield path should consume bootstrap contract and refusal: $blocked_json"

dry_override_target="$TEST_TMP/dry-override"
mkdir -p "$dry_override_target"
git init -q "$dry_override_target"
git -C "$dry_override_target" symbolic-ref HEAD refs/heads/main
dry_override=$(
  ORCH_DRY_RUN=1 \
    bash "$SANITIZED_ROOT/scripts/project_scaffold.sh" "$config" \
      --intent "Reusable package for shared calculations" \
      --target-dir "$dry_override_target" \
      --repo-mode existing \
      --readiness-report "$ready_report" \
      --apply \
      --json
)
jq -e '.status == "dry-run" and .selected_archetype == "library"' \
  <<< "$dry_override" >/dev/null \
  || fail "ORCH_DRY_RUN should override --apply and preserve selection: $dry_override"
[[ ! -e "$dry_override_target/README.md" ]] \
  || fail "ORCH_DRY_RUN apply must not write scaffold files"

printf 'ok - project_scaffold selects archetypes, previews by default, and applies with readiness evidence\n'
