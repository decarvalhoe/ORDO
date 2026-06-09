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
  scripts/dispatch_ticket.sh \
  templates/dispatch-canonical.md.tpl
chmod +x "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"

git init --bare "$TEST_TMP/origin.git" >/dev/null
git init "$TEST_TMP/seed" >/dev/null
git -C "$TEST_TMP/seed" config user.name "Assignee Test"
git -C "$TEST_TMP/seed" config user.email "assignee@test.local"
git -C "$TEST_TMP/seed" checkout -b main >/dev/null
printf 'seed\n' > "$TEST_TMP/seed/README.md"
git -C "$TEST_TMP/seed" add README.md
git -C "$TEST_TMP/seed" commit -m "seed" >/dev/null
git -C "$TEST_TMP/seed" remote add origin "$TEST_TMP/origin.git"
git -C "$TEST_TMP/seed" push -u origin main >/dev/null
mkdir -p "$TEST_TMP/repos"
git clone "$TEST_TMP/origin.git" "$TEST_TMP/repos/group-worker" >/dev/null 2>&1
git -C "$TEST_TMP/repos/group-worker" checkout main >/dev/null
git -C "$TEST_TMP/repos/group-worker" config user.name "gh-worker"
git -C "$TEST_TMP/repos/group-worker" config user.email "gh-worker@example.test"

cat > "$TEST_TMP/project.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="assignee-test"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
REPO_URL="$TEST_TMP/origin.git"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_GH_LOGINS=("worker=gh-worker")
AGENT_GIT_IDENTITIES=("group-worker|gh-worker|gh-worker@example.test")
EOF

cat > "$TEST_TMP/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="assignee-portfolio"
PORTFOLIO_PROJECTS=(
  "assignee-test|$TEST_TMP/project.config.sh"
)
PORTFOLIO_ENSURE_AGENT_MATRIX=1
PORTFOLIO_FLEET_AGENTS=(
  "group-worker|group-worker:0.0"
)
EOF

state_dir="$TEST_TMP/state/_portfolio"
mkdir -p "$state_dir"
cat > "$state_dir/session_start.json" <<JSON
[
  {"alias":"assignee-test","label":"group-worker","ready":1,"status":"ready","priority":100,"source":"portfolio_matrix"}
]
JSON

prompt="$TEST_TMP/prompt.md"
cat > "$prompt" <<'EOF'
## Objectif
Verify matrix label assignee normalization.

## Format de sortie attendu
Report dry-run output.

## Tools / sources autorises
Use mocked local repository only.

## Boundaries / interdictions
No live GitHub writes.

## Definition of Done verifiable
Dry-run assignee target is normalized.

## Preuves attendues
Dry-run command includes the configured assignee.

This prompt includes enough filler for prompt integrity validation. It is a
generic local fixture and does not represent a live project, host, account, or
provider. The remaining text exists only to exceed the minimum byte threshold
used by dispatch prompt integrity checks in tests.
EOF

output=$(
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
    "$TEST_TMP/project.config.sh" group-worker 7001 "$prompt" \
    --portfolio "$TEST_TMP/portfolio.config.sh" --assign --dry-run 2>&1
)

[[ "$output" == *"gh issue edit 7001 --repo example/repo --add-assignee gh-worker"* ]] \
  || fail "matrix-style label should assign configured base login, got: $output"

printf 'ok - matrix labels resolve to configured GitHub assignees\n'
