#!/usr/bin/env bash
# test_brief_agents_shell_safe.sh — proves brief_agents.sh inserts kv
# values literally even when they contain shell-active syntax. Source:
# issue #89 comment 19:14Z (unquoted heredoc + Markdown backticks
# corrupted prompt files for RBOK #3068-#3073).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$SANITIZED_ROOT/templates"
mkdir -p "$TEST_TMP/logs" "$TEST_TMP/repos"

for rel in \
  scripts/brief_agents.sh \
  lib/audit_log.sh \
  lib/agent_inventory.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/portfolio_config.sh \
  lib/worktree_helpers.sh \
  templates/dispatch-canonical.md.tpl
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/brief_agents.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="brief-shellsafe"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="origin"
EOF

# Sentinel file the canary command would touch if shell substitution ran.
canary="$TEST_TMP/canary-must-not-exist"

# Backticks + command substitution + single/double quotes + multilines —
# all the active fragments that historically corrupted heredoc-built briefs.
backtick_value="git status \`touch $canary\` end"
dollar_value="result \$(touch $canary) end"
quoted_value="he said 'hi' and \"bye\""
multiline_value=$'first line\nsecond \`touch '"$canary"$'\` line\nthird $(touch '"$canary"$') line'

generated="$TEST_TMP/generated.md"

ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
  "$TEST_TMP/test.config.sh" \
  claude 7001 \
  summary="$backtick_value" \
  validation="$dollar_value" \
  scope_files="$quoted_value" \
  forbidden_files="$multiline_value" \
  > "$generated"

[[ -e "$canary" ]] && fail "shell substitution executed during render — canary was touched"

grep -Fq "git status \`touch $canary\` end" "$generated" \
  || fail "backtick value not preserved literally"
grep -Fq "result \$(touch $canary) end" "$generated" \
  || fail "command-substitution value not preserved literally"
grep -Fq "he said 'hi' and \"bye\"" "$generated" \
  || fail "mixed quote value not preserved literally"
grep -Fq "second \`touch $canary\` line" "$generated" \
  || fail "multiline backtick value not preserved literally"
grep -Fq "third \$(touch $canary) line" "$generated" \
  || fail "multiline command-substitution not preserved literally"

# Defensive contract: render must refuse to emit a half-resolved brief.
# Inject a partial template and confirm brief_agents fails fast.
broken_tpl="$TEST_TMP/broken.tpl"
printf '## Objectif\n\nticket {{ticket}} unresolved {{never_set_key}} marker\n' > "$broken_tpl"

set +e
broken_output=$(
  DISPATCH_TEMPLATE="$broken_tpl" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
    "$TEST_TMP/test.config.sh" \
    claude 7002 2>&1
)
broken_status=$?
set -e

[[ "$broken_status" -ne 0 ]] || fail "expected brief_agents to fail on unresolved placeholder"
[[ "$broken_output" == *"unresolved template placeholder"* ]] \
  || fail "expected unresolved-placeholder error, got: $broken_output"
[[ "$broken_output" == *"{{never_set_key}}"* ]] \
  || fail "error should name the unresolved placeholder, got: $broken_output"

printf 'ok - brief_agents preserves shell-active values literally\n'
