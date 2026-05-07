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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/logs"

for rel in \
  scripts/project_meta_context.sh \
  lib/agent_inventory.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/state_persist.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/project_meta_context.sh"

repo="$TEST_TMP/repo"
mkdir -p "$repo/docs"
git init -q "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Test Agent"
cat > "$repo/AGENTS.md" <<'EOF'
# Agent Rules

- PR target: develop only.
- Never push direct to main.
EOF
cat > "$repo/README.md" <<'EOF'
# Demo Project

## Quick Start

Run tests before merge.
EOF
cat > "$repo/docs/architecture.md" <<'EOF'
# Architecture

## Backend

Must keep API stable.
EOF
git -C "$repo" add AGENTS.md README.md docs/architecture.md
git -C "$repo" commit -q -m 'docs'

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="meta-test"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
DOC_META_REPO="$repo"
DOC_META_PATHS=(AGENTS.md README.md docs)
EOF

first_output=$(
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/project_meta_context.sh" "$TEST_TMP/config.sh" --print 2>&1
)

[[ "$first_output" == *"# Project Meta Context - meta-test"* ]] || fail "missing meta context header: $first_output"
[[ "$first_output" == *"Project Map"* ]] || fail "missing project map: $first_output"
[[ "$first_output" == *"PR target: develop only"* ]] || fail "missing high-signal rule: $first_output"

sig_before=$(cat "$TEST_TMP/state/meta-test/project_meta_context.sig")

second_output=$(
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/project_meta_context.sh" "$TEST_TMP/config.sh" 2>&1
)

[[ "$second_output" == *"DOC_META unchanged"* ]] || fail "unchanged run should use cache: $second_output"

printf '\n## Frontend\n\nNew doc requirement.\n' >> "$repo/docs/architecture.md"

third_output=$(
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/project_meta_context.sh" "$TEST_TMP/config.sh" --print 2>&1
)

sig_after=$(cat "$TEST_TMP/state/meta-test/project_meta_context.sig")
[[ "$sig_before" != "$sig_after" ]] || fail "signature should change after doc edit"
[[ "$third_output" == *$'changed\tdocs/architecture.md'* || "$third_output" == *"- changed	docs/architecture.md"* ]] || \
  fail "doc diff should mention changed file: $third_output"

printf 'ok - project_meta_context persists and refreshes only on doc diffs\n'
