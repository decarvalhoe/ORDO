#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
STAGED_FILE="/tmp/dispatch-claude-4242.md"
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
  rm -f "$STAGED_FILE"
  rm -f "/tmp/dispatch-claude-9001.md"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/logs"
mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib"

for rel in \
  scripts/dispatch_ticket.sh \
  scripts/cycle.sh \
  scripts/integrate_wave.sh \
  scripts/recover.sh \
  lib/audit_log.sh \
  lib/dry_run.sh \
  lib/config_check.sh \
  lib/governance_check.sh \
  lib/pr_merge.sh \
  lib/state_persist.sh \
  lib/tmux_helpers.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"
chmod +x "$SANITIZED_ROOT/scripts/cycle.sh"
chmod +x "$SANITIZED_ROOT/scripts/integrate_wave.sh"
chmod +x "$SANITIZED_ROOT/scripts/recover.sh"
chmod +x "$SANITIZED_ROOT/lib/pr_merge.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dry-run-test"
GH_REPO="RBOKproject/orchestrator-toolkit"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="develop"
AGENT_SESSION_PREFIX=""
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s"
AGENTS=(claude)
SUPERVISOR_REPO="$TEST_TMP/repos/supervisor"
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
EOF

cat > "$TEST_TMP/prompt.md" <<'EOF'
# Dispatch canonique

## Objectif

Valider le dry-run.

## Format de sortie attendu

- Rapport final standard

## Tools / sources autorises

- bash

## Boundaries / interdictions

- pas de mutation

## Definition of Done verifiable

- [ ] dry-run observe

## Preuves attendues

- logs dry-run
EOF

mkdir -p "$TEST_TMP/repos/supervisor/.git" "$TEST_TMP/repos/claude/.git"

cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/tmux.log"
if [[ "\${1:-}" == "has-session" ]]; then
  exit "\${TMUX_HAS_SESSION_EXIT:-0}"
fi
exit 0
EOF
chmod +x "$TEST_TMP/bin/tmux"

cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh.log"
if [[ "\${1:-}" == "pr" && "\${2:-}" == "view" ]]; then
  case "\$*" in
    *statusCheckRollup*)
      printf '%s\n' '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci"}]}'
      ;;
    *mergeStateStatus*)
      printf '%s\n' '{"mergeStateStatus":"CLEAN"}'
      ;;
  esac
  exit 0
fi
exit 0
EOF
chmod +x "$TEST_TMP/bin/gh"

cat > "$TEST_TMP/bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/git.log"
case "\$*" in
  *"branch --show-current"*)
    printf '%s\n' 'feature/test'
    exit 0
    ;;
  *"remote get-url"*)
    exit 1
    ;;
  *"rev-parse --short"*)
    printf '%s\n' 'abc123'
    exit 0
    ;;
esac
exit 0
EOF
chmod +x "$TEST_TMP/bin/git"

rm -f "$STAGED_FILE"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/test.config.sh" claude 4242 "$TEST_TMP/prompt.md" --dry-run 2>&1
)
status=$?
set -e

[[ "$status" -eq 0 ]] || fail "dispatch dry-run exited $status: $output"
[[ "$output" == *"DRY-RUN:"* ]] || fail "expected DRY-RUN output, got: $output"
[[ ! -f "$STAGED_FILE" ]] || fail "dry-run must not create staged dispatch file"

if [[ -f "$TEST_TMP/logs/tmux.log" ]] && grep -q 'send-keys' "$TEST_TMP/logs/tmux.log"; then
  fail "dry-run must not invoke tmux send-keys"
fi

printf 'ok - dispatch_ticket dry-run avoided send-keys and staging\n'

: > "$TEST_TMP/logs/tmux.log"

set +e
recover_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  TMUX_HAS_SESSION_EXIT=1 \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  PROJECT="dry-run-test" \
  AGENT_SESSION_PREFIX="" \
  AGENT_WORKDIR_TEMPLATE="$TEST_TMP/worktrees/%s" \
  bash "$SANITIZED_ROOT/scripts/recover.sh" claude --dry-run 2>&1
)
recover_status=$?
set -e

[[ "$recover_status" -eq 0 ]] || fail "recover dry-run exited $recover_status: $recover_output"
[[ "$recover_output" == *"DRY-RUN:"* ]] || fail "expected DRY-RUN output from recover, got: $recover_output"

if grep -q 'new-session' "$TEST_TMP/logs/tmux.log"; then
  fail "recover dry-run must not invoke tmux new-session"
fi

printf 'ok - recover dry-run avoided tmux new-session\n'

: > "$TEST_TMP/logs/gh.log"

set +e
pr_merge_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.sh" 77 --dry-run 2>&1
)
pr_merge_status=$?
set -e

[[ "$pr_merge_status" -eq 0 ]] || fail "pr_merge dry-run exited $pr_merge_status: $pr_merge_output"
[[ "$pr_merge_output" == *"DRY-RUN:"* ]] || fail "expected DRY-RUN output from pr_merge, got: $pr_merge_output"

if grep -q 'pr merge' "$TEST_TMP/logs/gh.log"; then
  fail "pr_merge dry-run must not invoke gh pr merge"
fi
if grep -q 'pr review' "$TEST_TMP/logs/gh.log"; then
  fail "pr_merge dry-run must not invoke gh pr review"
fi

printf 'ok - pr_merge dry-run avoided merge/review calls\n'

rm -f "$TEST_TMP/state/dry-run-test/wave-DRYWAVE.yaml"
: > "$TEST_TMP/logs/git.log"

set +e
integrate_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/integrate_wave.sh" "$TEST_TMP/test.config.sh" DRYWAVE --dry-run 2>&1
)
integrate_status=$?
set -e

[[ "$integrate_status" -eq 0 ]] || fail "integrate dry-run exited $integrate_status: $integrate_output"
[[ "$integrate_output" == *"DRY-RUN:"* ]] || fail "expected DRY-RUN output from integrate, got: $integrate_output"

if grep -Eq 'fetch|remote add|branch -f|checkout|rebase' "$TEST_TMP/logs/git.log"; then
  fail "integrate dry-run must not invoke mutating git commands"
fi
[[ ! -f "$TEST_TMP/state/dry-run-test/wave-DRYWAVE.yaml" ]] || fail "integrate dry-run must not persist wave state"

printf 'ok - integrate dry-run avoided mutating git/state operations\n'

cat > "$SANITIZED_ROOT/scripts/check_ci_health.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'check_ci_health %s\n' "\$*" >> "$TEST_TMP/logs/cycle.log"
exit 0
EOF
cat > "$SANITIZED_ROOT/scripts/audit_state.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'audit_state %s\n' "\$*" >> "$TEST_TMP/logs/cycle.log"
exit 0
EOF
cat > "$SANITIZED_ROOT/scripts/smart_poll_agents.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'smart_poll_agents %s\n' "\$*" >> "$TEST_TMP/logs/cycle.log"
exit 0
EOF
cat > "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'dispatch_ticket %s\n' "\$*" >> "$TEST_TMP/logs/cycle.log"
if [[ " \$* " != *" --dry-run "* ]]; then
  touch "$TEST_TMP/logs/cycle-dispatch-mutated"
fi
exit 0
EOF
cat > "$SANITIZED_ROOT/scripts/integrate_wave.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'integrate_wave %s\n' "\$*" >> "$TEST_TMP/logs/cycle.log"
if [[ " \$* " != *" --dry-run "* ]]; then
  touch "$TEST_TMP/logs/cycle-integrate-mutated"
fi
exit 0
EOF
chmod +x "$SANITIZED_ROOT/scripts/check_ci_health.sh" \
  "$SANITIZED_ROOT/scripts/audit_state.sh" \
  "$SANITIZED_ROOT/scripts/smart_poll_agents.sh" \
  "$SANITIZED_ROOT/scripts/dispatch_ticket.sh" \
  "$SANITIZED_ROOT/scripts/integrate_wave.sh"

: > "$TEST_TMP/logs/cycle.log"
rm -f "$TEST_TMP/logs/cycle-dispatch-mutated" "$TEST_TMP/logs/cycle-integrate-mutated"
rm -f "$TEST_TMP/state/dry-run-test/ORCHESTRATION_STATE.md"

cp "$TEST_TMP/prompt.md" "/tmp/dispatch-claude-9001.md"

set +e
cycle_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/cycle.sh" "$TEST_TMP/test.config.sh" DRYRUN 9001:claude --dry-run 2>&1
)
cycle_status=$?
set -e

[[ "$cycle_status" -eq 0 ]] || fail "cycle dry-run exited $cycle_status: $cycle_output"
[[ "$cycle_output" == *"DRY-RUN:"* ]] || fail "expected DRY-RUN output from cycle, got: $cycle_output"

[[ ! -f "$TEST_TMP/logs/cycle-dispatch-mutated" ]] || fail "cycle dry-run must pass --dry-run to dispatch_ticket"
[[ ! -f "$TEST_TMP/logs/cycle-integrate-mutated" ]] || fail "cycle dry-run must pass --dry-run to integrate_wave"
[[ ! -f "$TEST_TMP/state/dry-run-test/ORCHESTRATION_STATE.md" ]] || fail "cycle dry-run must not persist orchestration state"

printf 'ok - cycle dry-run propagated dry-run and skipped state persist\n'
