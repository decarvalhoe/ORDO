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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/repo/.github/workflows" "$TEST_TMP/logs"

for rel in \
  scripts/gh_actions_optimize.sh \
  lib/audit_log.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/gh_actions_optimize.sh"

cat > "$TEST_TMP/repo/.github/workflows/ci.yml" <<'EOF'
name: CI
on:
  pull_request:
    branches: [develop]
  push:
    branches:
      - 'feat/**'
      - 'fix/**'
jobs:
  backend:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-python@v5
      - run: |
          if [ "${{ github.event_name }}" = "push" ]; then
            pytest --cov=app
          fi
      - run: gh api repos/example/repo/actions/workflows/deploy.yml/runs
EOF

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="gha-test"
DEFAULT_BRANCH="develop"
PROJECT_REPO_ROOT="$TEST_TMP/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
GH_REPO="example/repo"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/work/%s"
EOF

audit_output=$(
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  bash "$SANITIZED_ROOT/scripts/gh_actions_optimize.sh" "$TEST_TMP/config.sh" --audit
)

[[ "$audit_output" == *$'WARN\tgha-missing-permissions\t.github/workflows/ci.yml'* ]] || fail "missing permissions finding: $audit_output"
[[ "$audit_output" == *$'WARN\tgha-missing-concurrency\t.github/workflows/ci.yml'* ]] || fail "missing concurrency finding: $audit_output"
[[ "$audit_output" == *$'WARN\tgha-pr-push-duplicate-risk\t.github/workflows/ci.yml'* ]] || fail "missing duplicate risk finding: $audit_output"
[[ "$audit_output" == *$'WARN\tgha-full-tests-on-any-push\t.github/workflows/ci.yml'* ]] || fail "missing full-push finding: $audit_output"
[[ "$audit_output" == *$'ERROR\tgha-actions-read-missing\t.github/workflows/ci.yml'* ]] || fail "missing actions-read finding: $audit_output"

mkdir -p "$TEST_TMP/newrepo/backend" "$TEST_TMP/newrepo/frontend"
printf 'pytest\n' > "$TEST_TMP/newrepo/backend/requirements.txt"
printf '{"scripts":{"test":"echo ok"}}\n' > "$TEST_TMP/newrepo/frontend/package.json"
cat > "$TEST_TMP/scaffold.config.sh" <<EOF
PROJECT="gha-scaffold-test"
DEFAULT_BRANCH="main"
PROJECT_REPO_ROOT="$TEST_TMP/newrepo"
GH_CONFIG_DIR="$TEST_TMP/gh"
GH_REPO="example/newrepo"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/work/%s"
EOF

ORCH_LOG_DIR="$TEST_TMP/logs" \
  bash "$SANITIZED_ROOT/scripts/gh_actions_optimize.sh" "$TEST_TMP/scaffold.config.sh" --scaffold >/tmp/gha-scaffold.out

workflow="$TEST_TMP/newrepo/.github/workflows/ci.yml"
[[ -f "$workflow" ]] || fail "scaffold should create ci.yml"
content=$(tr -d '\r' < "$workflow")
[[ "$content" == *"dorny/paths-filter@v3"* ]] || fail "scaffold should include paths-filter"
[[ "$content" == *"concurrency:"* ]] || fail "scaffold should include concurrency"
[[ "$content" == *"cache: pip"* ]] || fail "scaffold should include pip cache"
[[ "$content" == *"cache: npm"* ]] || fail "scaffold should include npm cache"
[[ "$content" != *"feat/**"* ]] || fail "scaffold should avoid feature push duplicate triggers"

printf 'ok - gh_actions_optimize audits and scaffolds GitHub Actions\n'
