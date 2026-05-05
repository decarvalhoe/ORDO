#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
  rm -f /tmp/dispatch-claude-5001.md /tmp/dispatch-claude-5002.md
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$SANITIZED_ROOT/templates"
mkdir -p "$TEST_TMP/bin" "$TEST_TMP/logs"

for rel in \
  scripts/brief_agents.sh \
  scripts/dispatch_ticket.sh \
  lib/audit_log.sh \
  lib/config_check.sh \
  lib/dry_run.sh \
  templates/dispatch-canonical.md.tpl
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

chmod +x "$SANITIZED_ROOT/scripts/brief_agents.sh" "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dispatch-test"
GH_REPO="RBOKproject/orchestrator-toolkit"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="orchestrator"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
EOF

cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/tmux.log"
if [[ "\${1:-}" == "has-session" ]]; then
  exit 0
fi
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

generated_prompt="$TEST_TMP/generated.md"
invalid_prompt="$TEST_TMP/invalid.md"

PATH="$TEST_TMP/bin:$PATH" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash "$SANITIZED_ROOT/scripts/brief_agents.sh" "$TEST_TMP/test.config.sh" claude 5001 summary="Prompt canon test" validation="bash tests.sh" > "$generated_prompt"

for heading in \
  "## Objectif" \
  "## Format de sortie attendu" \
  "## Tools / sources autorises" \
  "## Boundaries / interdictions" \
  "## Definition of Done verifiable" \
  "## Preuves attendues"
do
  grep -q "$heading" "$generated_prompt" || fail "generated prompt missing heading: $heading"
done

cat > "$invalid_prompt" <<'EOF'
# Prompt cassé

Pas de structure canonique ici.
EOF

set +e
invalid_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" claude 5002 "$invalid_prompt" 2>&1
)
invalid_status=$?
set -e

[[ "$invalid_status" -ne 0 ]] || fail "invalid prompt should be refused"
[[ "$invalid_output" == *"missing canonical sections"* ]] || fail "expected canonical validation error, got: $invalid_output"

set +e
bypass_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" claude 5002 "$invalid_prompt" --no-validate --dry-run 2>&1
)
bypass_status=$?
set -e

[[ "$bypass_status" -eq 0 ]] || fail "bypass dispatch should succeed, got: $bypass_output"
[[ "$bypass_output" == *"VALIDATION BYPASSED"* ]] || fail "expected audit of bypass, got: $bypass_output"
[[ "$bypass_output" == *"DRY-RUN:"* ]] || fail "expected dry-run logs on bypass path"

printf 'ok - dispatch prompt canonical validation and bypass\n'
