#!/usr/bin/env bash
# test_brief_agents_node22_preflight.sh — issue #479.
#
# RBOK frontend validation commands fail on the default Node 20 shell
# because the project pins Node 22. Workers rediscovered the same
# `nvm use 22` fix on every dispatch during the 2026-05-09 UX/UI wave.
# brief_agents.sh now injects `source ~/.nvm/nvm.sh && nvm use 22`
# in front of frontend validation commands automatically, and leaves
# non-frontend or already-pinned validation commands alone.
#
# This regression check exercises the generated brief snippets to
# guarantee:
#   - frontend tools (npm/npx/pnpm/yarn/vite/vitest/eslint/prettier/tsc
#     /next/nx/node) trigger preflight injection
#   - non-frontend validation (shell-only) does NOT inject the preflight
#   - operator-pinned `nvm use` is preserved without double-injection
#   - the rendered validation_command and allowed_focused_checks reflect
#     the injection consistently (single-source-of-truth)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

mkdir -p "$TEST_TMP/logs" "$TEST_TMP/repos" "$TEST_TMP/gh" "$TEST_TMP/bin"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/brief_agents.sh \
  templates/dispatch-canonical.md.tpl

chmod +x "$SANITIZED_ROOT/scripts/brief_agents.sh"

# Fast `gh` stub so the source-substance fetch returns immediately.
cat > "$TEST_TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
chmod +x "$TEST_TMP/bin/gh"
export PATH="$TEST_TMP/bin:$PATH"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="brief-node22"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="origin"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

run_brief() {
  local ticket=$1
  local validation=$2
  local out=$3
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_SOURCE_FETCH_TIMEOUT_SEC=2 \
  bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
    "$TEST_TMP/test.config.sh" \
    claude "$ticket" \
    branch_slug="fix/${ticket}-node22-preflight" \
    summary="fix #479 inject node 22 preflight ${ticket}" \
    scope_files="scripts/brief_agents.sh" \
    validation="$validation" \
    > "$out"
}

# --- Case 1: frontend validation (npm test) — preflight injected -----------

frontend_brief="$TEST_TMP/frontend.md"
run_brief 4791 'timeout 300 npm test' "$frontend_brief"

grep -Fq -- 'validation_command=source ~/.nvm/nvm.sh && nvm use 22 && timeout 300 npm test' \
  "$frontend_brief" \
  || fail "frontend validation_command should inject Node 22 preflight ahead of npm test (got: $(grep -F validation_command= "$frontend_brief"))"

grep -Fq -- '  - source ~/.nvm/nvm.sh && nvm use 22' "$frontend_brief" \
  || fail "frontend allowed_focused_checks should list the Node 22 preflight as its own line"

grep -Fq -- '  - timeout 300 npm test' "$frontend_brief" \
  || fail "frontend allowed_focused_checks should preserve the original validation line"

grep -Fq -- 'validation_policy=dispatch-provided' "$frontend_brief" \
  || fail "frontend brief should keep dispatch-provided validation policy after preflight injection"

# --- Case 2: each documented frontend tool triggers injection --------------

tools=(
  'timeout 300 npx vitest run'
  'pnpm run lint'
  'yarn build'
  'timeout 180 npx prettier --check "src/**/*.ts"'
  'timeout 180 npx eslint .'
  'timeout 180 npx tsc --noEmit'
  'timeout 120 npx vite build'
  'timeout 120 npx next build'
  'timeout 120 npx nx run web:test'
  'timeout 120 node scripts/check-bundle.mjs'
)
i=1
for tool_cmd in "${tools[@]}"; do
  ticket="47910${i}"
  brief="$TEST_TMP/tool-${i}.md"
  run_brief "$ticket" "$tool_cmd" "$brief"
  grep -Fq -- "validation_command=source ~/.nvm/nvm.sh && nvm use 22 && ${tool_cmd}" \
    "$brief" \
    || fail "frontend tool [${tool_cmd}] should inject Node 22 preflight (got: $(grep -F validation_command= "$brief"))"
  i=$((i + 1))
done

# --- Case 3: non-frontend validation must NOT inject the preflight --------

shell_brief="$TEST_TMP/shell.md"
run_brief 4792 'timeout 60 bash -n scripts/brief_agents.sh' "$shell_brief"

grep -Fq -- 'validation_command=timeout 60 bash -n scripts/brief_agents.sh' "$shell_brief" \
  || fail "shell-only validation should be rendered as-is (got: $(grep -F validation_command= "$shell_brief"))"

! grep -Fq -- 'source ~/.nvm/nvm.sh && nvm use 22' "$shell_brief" \
  || fail "shell-only validation must NOT inject Node 22 preflight"

# --- Case 4: validation already pinning a Node runtime must NOT re-inject --

pinned_brief="$TEST_TMP/pinned.md"
run_brief 4793 $'source ~/.nvm/nvm.sh && nvm use 22\nnpm test' "$pinned_brief"

grep -Fq -- 'validation_command=source ~/.nvm/nvm.sh && nvm use 22 && npm test' "$pinned_brief" \
  || fail "operator-pinned validation should be rendered as-is"
! grep -Fq -- 'nvm use 22 && source ~/.nvm/nvm.sh' "$pinned_brief" \
  || fail "operator-pinned nvm use must not be double-injected (preflight prepended ahead of an existing pin)"
! grep -Fq -- 'nvm use 22 && nvm use 22' "$pinned_brief" \
  || fail "operator-pinned nvm use must not produce a doubled nvm use chain"

# --- Case 5: `nvm exec ...` and explicit `source ~/.nvm/nvm.sh` are pins ---

exec_brief="$TEST_TMP/exec.md"
run_brief 4794 'nvm exec 22 npm test' "$exec_brief"
grep -Fq -- 'validation_command=nvm exec 22 npm test' "$exec_brief" \
  || fail "nvm exec must count as a Node runtime pin, got: $(grep -F validation_command= "$exec_brief" | head -1)"
! grep -Fq -- 'source ~/.nvm/nvm.sh && nvm use 22 && nvm exec' "$exec_brief" \
  || fail "nvm exec validation must not have preflight prepended"

src_brief="$TEST_TMP/src.md"
run_brief 4795 $'. ~/.nvm/nvm.sh && nvm use 22\nnpm run lint' "$src_brief"
grep -Fq -- 'validation_command=. ~/.nvm/nvm.sh && nvm use 22 && npm run lint' "$src_brief" \
  || fail "explicit . ~/.nvm/nvm.sh must count as a Node runtime pin"
! grep -Fq -- 'source ~/.nvm/nvm.sh && nvm use 22 && . ~/.nvm/nvm.sh' "$src_brief" \
  || fail "explicit . ~/.nvm/nvm.sh must not produce a double-inject"

# --- Case 6: false-positive guard — "npmjs.com" in a path must NOT match ---
# The detector keys on the tool name as a token (word boundary). A
# validation command that merely mentions "npmjs" as part of a longer
# token should not trigger injection.

word_brief="$TEST_TMP/word.md"
run_brief 4796 'curl https://registry.npmjs.com/some-pkg' "$word_brief"
grep -Fq -- 'validation_command=curl https://registry.npmjs.com/some-pkg' "$word_brief" \
  || fail "non-token mention of npmjs should be rendered as-is"
! grep -Fq -- 'source ~/.nvm/nvm.sh && nvm use 22' "$word_brief" \
  || fail "non-token mention of npmjs must NOT inject preflight"

# --- Case 7: CI-delegated default (no validation kv arg) stays untouched ---

ci_brief="$TEST_TMP/ci.md"
ORCH_LOG_DIR="$TEST_TMP/logs" \
ORCH_SOURCE_FETCH_TIMEOUT_SEC=2 \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 4797 \
  branch_slug="fix/4797-ci-default" \
  summary="fix #479 ci default stays none" \
  scope_files="scripts/brief_agents.sh" \
  > "$ci_brief"

grep -Fq -- 'validation_policy=ci-delegated' "$ci_brief" \
  || fail "no-validation default must remain ci-delegated"
grep -Fq -- 'validation_command=none' "$ci_brief" \
  || fail "no-validation default must remain validation_command=none"
! grep -Fq -- 'source ~/.nvm/nvm.sh && nvm use 22' "$ci_brief" \
  || fail "ci-delegated default must not inject Node 22 preflight"

printf 'ok - brief_agents injects Node 22 preflight into frontend validation commands\n'
