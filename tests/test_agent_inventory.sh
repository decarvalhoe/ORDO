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

mkdir -p "$SANITIZED_ROOT/lib" "$TEST_TMP/repos"

for rel in \
  lib/agent_inventory.sh \
  lib/config_resolver.sh \
  lib/tmux_helpers.sh \
  lib/worktree_helpers.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

mkdir -p \
  "$TEST_TMP/repos/writer-main" \
  "$TEST_TMP/repos/reviewer" \
  "$TEST_TMP/repos/implicit-label" \
  "$TEST_TMP/repos/legacy"

cat > "$TEST_TMP/universal.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="inventory-test"
AGENT_SESSION_PREFIX="legacy-"
AGENT_WINDOW_INDEX=4
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=(
  "writer|writers:3.1|$TEST_TMP/repos/writer-main"
  "reviewer|review:2.0|$TEST_TMP/repos/reviewer"
  "implicit:1.0|$TEST_TMP/repos/implicit-label"
)
AGENT_GH_LOGINS=(
  "writer=gh-writer"
  "reviewer|gh-reviewer"
  "worker=gh-worker"
  "explicit-worker=gh-explicit-worker"
)
AGENT_GH_LABEL_ALIASES=(
  "alias-worker=worker"
)
AGENT_GH_LOGIN_PREFIX="fallback-"
EOF

cat > "$TEST_TMP/legacy.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="inventory-legacy"
AGENT_SESSION_PREFIX="legacy-"
AGENT_WINDOW_INDEX=7
AGENTS=(legacy)
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

universal_output=$(
  bash -lc "
    source '$TEST_TMP/universal.config.sh'
    source '$SANITIZED_ROOT/lib/agent_inventory.sh'
    source '$SANITIZED_ROOT/lib/config_resolver.sh'
    source '$SANITIZED_ROOT/lib/tmux_helpers.sh'
    source '$SANITIZED_ROOT/lib/worktree_helpers.sh'
    printf 'target=%s\n' \"\$(agent_target writer)\"
    printf 'repo=%s\n' \"\$(agent_repo_root reviewer)\"
    printf 'implicit=%s\n' \"\$(agent_target implicit-label)\"
    printf 'login1=%s\n' \"\$(resolve_agent_github_login writer)\"
    printf 'login2=%s\n' \"\$(resolve_agent_github_login reviewer)\"
    printf 'login3=%s\n' \"\$(resolve_agent_github_login ghost)\"
    printf 'login4=%s\n' \"\$(resolve_agent_github_login product-worker)\"
    printf 'login5=%s\n' \"\$(resolve_agent_github_login alias-worker)\"
    printf 'login6=%s\n' \"\$(resolve_agent_github_login explicit-worker)\"
    printf 'login7=%s\n' \"\$(resolve_agent_github_login product-ghost)\"
  "
)

[[ "$universal_output" == *"target=writers:3.1"* ]] || fail "expected explicit label to resolve pane, got: $universal_output"
[[ "$universal_output" == *"repo=$TEST_TMP/repos/reviewer"* ]] || fail "expected explicit label to resolve repo, got: $universal_output"
[[ "$universal_output" == *"implicit=implicit:1.0"* ]] || fail "expected two-part AGENT_PANES entry to derive label from basename, got: $universal_output"
[[ "$universal_output" == *"login1=gh-writer"* ]] || fail "expected equals mapping for GitHub login, got: $universal_output"
[[ "$universal_output" == *"login2=gh-reviewer"* ]] || fail "expected pipe mapping for GitHub login, got: $universal_output"
[[ "$universal_output" == *"login3=fallback-ghost"* ]] || fail "expected prefix fallback for GitHub login, got: $universal_output"
[[ "$universal_output" == *"login4=gh-worker"* ]] || fail "expected matrix-style label suffix to use configured GitHub mapping, got: $universal_output"
[[ "$universal_output" == *"login5=gh-worker"* ]] || fail "expected configured GitHub label alias to use base mapping, got: $universal_output"
[[ "$universal_output" == *"login6=gh-explicit-worker"* ]] || fail "expected exact GitHub mapping to win over suffix mapping, got: $universal_output"
[[ "$universal_output" == *"login7=fallback-ghost"* ]] || fail "expected prefix fallback to use normalized matrix-style label, got: $universal_output"

legacy_output=$(
  bash -lc "
    source '$TEST_TMP/legacy.config.sh'
    source '$SANITIZED_ROOT/lib/agent_inventory.sh'
    source '$SANITIZED_ROOT/lib/config_resolver.sh'
    while IFS='|' read -r label pane workdir; do
      printf '%s %s %s\n' \"\$label\" \"\$pane\" \"\$workdir\"
    done < <(agent_inventory_entries)
    printf 'login=%s\n' \"\$(resolve_agent_github_login legacy-agent)\"
  "
)

[[ "$legacy_output" == *"legacy legacy-legacy:7.0 $TEST_TMP/repos/legacy"* ]] || fail "expected legacy inventory fallback, got: $legacy_output"
[[ "$legacy_output" == *"login=legacy-agent"* ]] || fail "expected generic GitHub login fallback to preserve label, got: $legacy_output"

printf 'ok - agent inventory resolves explicit labels and legacy fleets\n'
