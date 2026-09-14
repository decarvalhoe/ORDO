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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/repos" "$TEST_TMP/logs"

for rel in \
  scripts/sixsigma_autoupgrade.sh \
  scripts/gh_actions_optimize.sh \
  lib/agent_inventory.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/external_mutation_gate.sh \
  lib/ordo_contracts.sh \
  lib/ordo_provider_adapter.sh \
  lib/ordo_provider_adapter_github.sh \
  lib/ordo_provider_adapter_fake.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/sixsigma_autoupgrade.sh"

cat > "$SANITIZED_ROOT/scripts/ci_autofix.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'push=%s args=%s\n' "\${CI_AUTOFIX_AGENT_CAN_PUSH:-}" "\$*" >> "$TEST_TMP/logs/ci_autofix.log"
EOF
chmod +x "$SANITIZED_ROOT/scripts/ci_autofix.sh"

repo="$TEST_TMP/repos/agent-one"
git init -q "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name "Test Agent"
printf 'ok\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -q -m 'init'
git -C "$repo" branch -M main
git -C "$repo" remote add origin "$repo"
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" checkout -q -b feat/one
printf 'base drift\n' > "$repo/base.txt"
git -C "$repo" checkout -q main
git -C "$repo" add base.txt
git -C "$repo" commit -q -m 'base drift'
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" checkout -q feat/one

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="sixsigma-test"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=(
  "agent-one|agent-one:0.0|$repo"
)
EOF

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"pr list"* )
    printf '%s\n' '[
      {"number":101,"headRefName":"feat/one","isDraft":false,"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"Frontend CI"}]},
      {"number":102,"headRefName":"feat/no-owner","isDraft":false,"mergeStateStatus":"UNKNOWN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"Backend CI"}]},
      {"number":103,"headRefName":"feat/draft","isDraft":true,"mergeStateStatus":"UNKNOWN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"CI"}]},
      {"number":104,"headRefName":"feat/pass","isDraft":false,"mergeStateStatus":"CLEAN","statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"CI"}]}
    ]'
    ;;
  # The provider adapter (#816) reads the rollup per PR (checks_get ->
  # `gh pr view N --json number,headRefOid,statusCheckRollup`).
  *"pr view 101"* )
    printf '%s\n' '{"number":101,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"Frontend CI"}]}'
    ;;
  *"pr view 102"* )
    printf '%s\n' '{"number":102,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"Backend CI"}]}'
    ;;
  *"pr view 103"* )
    printf '%s\n' '{"number":103,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE","name":"CI"}]}'
    ;;
  *"pr view 104"* )
    printf '%s\n' '{"number":104,"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"CI"}]}'
    ;;
  * )
    printf '%s\n' '{}'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  SIXSIGMA_BASE_FETCH=0 \
  SIXSIGMA_RUN_POOL_SNAPSHOT=0 \
  bash "$SANITIZED_ROOT/scripts/sixsigma_autoupgrade.sh" "$TEST_TMP/config.sh" --dry-run 2>&1
)

[[ "$output" == *"SIXSIGMA autofix pr=101 branch=feat/one agent=agent-one"* ]] || fail "expected autofix audit: $output"
[[ "$output" == *"SIXSIGMA rebase-needed pr=101 branch=feat/one agent=agent-one state=BLOCKED reason=base-drift"* ]] || fail "expected rebase-needed audit: $output"
[[ "$output" == *"SIXSIGMA skip pr=102 branch=feat/no-owner reason=no-agent-owner"* ]] || fail "expected no-owner skip: $output"
[[ "$output" == *"SIXSIGMA skip pr=103 branch=feat/draft reason=draft"* ]] || fail "expected draft skip: $output"
[[ "$output" == *"SIXSIGMA observe pr=104 branch=feat/pass failed=0"* ]] || fail "expected pass observe: $output"
grep -q 'push=1 args=.* 101 agent-one --dry-run' "$TEST_TMP/logs/ci_autofix.log" || \
  fail "expected ci_autofix dry-run dispatch with push enabled"

printf 'ok - sixsigma_autoupgrade dispatches failed PRs to owning agents\n'

# -----------------------------------------------------------------------
# #245 — cycle.sh wiring assertions
#
# The cycle wrapper must invoke sixsigma_autoupgrade.sh AFTER the default
# branch CI gate, propagate --dry-run, warn + audit on non-zero exit
# instead of silently skipping, and honor the opt-out env var.
# -----------------------------------------------------------------------

CYCLE_TMP="$TEST_TMP/cycle"
CYCLE_TK="$CYCLE_TMP/toolkit"
mkdir -p "$CYCLE_TK/scripts" "$CYCLE_TK/lib" "$CYCLE_TMP/logs" "$CYCLE_TMP/state" "$CYCLE_TMP/bin"

# Mirror the libs cycle.sh sources, plus the script under test.
for rel in \
  scripts/cycle.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/host_load_gate.sh \
  lib/process_safety.sh \
  lib/host_forensics.sh \
  lib/state_persist.sh \
  lib/external_mutation_gate.sh \
  lib/ordo_contracts.sh \
  lib/ordo_provider_adapter.sh \
  lib/ordo_provider_adapter_github.sh \
  lib/ordo_provider_adapter_fake.sh
do
  mkdir -p "$CYCLE_TK/$(dirname "$rel")"
  tr -d '\r' < "$ROOT/$rel" > "$CYCLE_TK/$rel"
done
chmod +x "$CYCLE_TK/scripts/cycle.sh"

# Stub the cycle's other dependencies so we can isolate the sixsigma hook.
for stub in check_ci_health audit_state smart_poll_agents dispatch_ticket integrate_wave; do
  cat > "$CYCLE_TK/scripts/${stub}.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$stub" "\$*" >> "$CYCLE_TMP/logs/cycle.log"
exit 0
EOF
  chmod +x "$CYCLE_TK/scripts/${stub}.sh"
done

cat > "$CYCLE_TK/scripts/pr_block_signals.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'pr_block_signals %s\n' "\$*" >> "$CYCLE_TMP/logs/cycle.log"
printf '%s\n' '[]'
exit 0
EOF
chmod +x "$CYCLE_TK/scripts/pr_block_signals.sh"

cat > "$CYCLE_TMP/cycle.config.sh" <<EOF
PROJECT="cycle-sixsigma-test"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$CYCLE_TMP/gh"
AGENT_REPO_PREFIX="$CYCLE_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$CYCLE_TMP/repos/%s"
EOF

# Place an empty prompt file so the dispatch step does not warn-skip.
mkdir -p /tmp
prompt_file="/tmp/dispatch-claude-9245.md"
printf '# stub dispatch prompt\n' > "$prompt_file"
trap 'rm -f "$prompt_file"; rm -rf "$TEST_TMP"' EXIT

run_cycle() {
  local extra_env=$1
  shift
  : > "$CYCLE_TMP/logs/cycle.log"
  : > "$CYCLE_TMP/logs/cycle-sixsigma-test.log"
  # shellcheck disable=SC2086 # extra_env intentionally splits on whitespace
  env -u ORCH_DRY_RUN \
    PATH="$CYCLE_TMP/bin:$PATH" \
    ORCH_LOG_DIR="$CYCLE_TMP/logs" \
    ORCH_STATE_BASE="$CYCLE_TMP/state" \
    ${extra_env} \
    bash "$CYCLE_TK/scripts/cycle.sh" "$CYCLE_TMP/cycle.config.sh" \
      WAVEA 9245:claude --dry-run "$@" 2>&1
}

# --- Case A: sixsigma succeeds → cycle audits SIXSIGMA OK -----------------

cat > "$CYCLE_TK/scripts/sixsigma_autoupgrade.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'sixsigma_autoupgrade %s\n' "\$*" >> "$CYCLE_TMP/logs/cycle.log"
exit 0
EOF
chmod +x "$CYCLE_TK/scripts/sixsigma_autoupgrade.sh"

cycle_log="$CYCLE_TMP/logs/cycle-sixsigma-test.log"

set +e
output=$(run_cycle "")
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "cycle should exit 0 when sixsigma succeeds (got: $status, output: $output)"
grep -q '^sixsigma_autoupgrade .*--dry-run' "$CYCLE_TMP/logs/cycle.log" \
  || fail "cycle must propagate --dry-run to sixsigma (got: $(cat "$CYCLE_TMP/logs/cycle.log"))"
awk '/^check_ci_health /{ci=NR} /^sixsigma_autoupgrade /{sixsigma=NR}
     END { if (sixsigma <= ci) exit 1 }' "$CYCLE_TMP/logs/cycle.log" \
  || fail "sixsigma must run AFTER check_ci_health"
grep -q 'CYCLE WAVEA SIXSIGMA OK' "$cycle_log" \
  || fail "audit must record SIXSIGMA OK on success"

# --- Case B: sixsigma exits non-zero → cycle warns + audits, continues ----

cat > "$CYCLE_TK/scripts/sixsigma_autoupgrade.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'sixsigma_autoupgrade %s\n' "\$*" >> "$CYCLE_TMP/logs/cycle.log"
exit 7
EOF
chmod +x "$CYCLE_TK/scripts/sixsigma_autoupgrade.sh"

set +e
output=$(run_cycle "")
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "cycle must NOT abort when sixsigma fails (got: $status, output: $output)"
grep -q 'CYCLE WAVEA SIXSIGMA WARN' "$cycle_log" \
  || fail "audit must record SIXSIGMA WARN when sixsigma exits non-zero (got: $(cat "$cycle_log"))"
grep -q 'sixsigma_autoupgrade.sh exited non-zero' "$cycle_log" \
  || fail "warn line must explain sixsigma exit"
grep -q '^sixsigma_autoupgrade ' "$CYCLE_TMP/logs/cycle.log" \
  || fail "sixsigma must still have been invoked"
grep -q '^integrate_wave ' "$CYCLE_TMP/logs/cycle.log" \
  || fail "downstream integrate_wave must still run after sixsigma WARN"

# --- Case C: opt-out via ORCH_SIXSIGMA_DISABLED=1 → no invocation ---------

set +e
output=$(run_cycle "ORCH_SIXSIGMA_DISABLED=1")
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "cycle should exit 0 when sixsigma is disabled (got: $status)"
if grep -q '^sixsigma_autoupgrade ' "$CYCLE_TMP/logs/cycle.log"; then
  fail "ORCH_SIXSIGMA_DISABLED=1 must skip the sixsigma invocation entirely"
fi
if grep -q 'SIXSIGMA OK\|SIXSIGMA WARN' "$cycle_log"; then
  fail "ORCH_SIXSIGMA_DISABLED=1 must not emit SIXSIGMA OK/WARN audit lines"
fi

printf 'ok - cycle.sh runs sixsigma_autoupgrade after CI gate, warns on failure, honors ORCH_SIXSIGMA_DISABLED\n'
