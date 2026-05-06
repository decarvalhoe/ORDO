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
  scripts/pr_merge_wave.sh \
  scripts/recover.sh \
  lib/agent_inventory.sh \
  lib/audit_log.sh \
  lib/dry_run.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/governance_check.sh \
  lib/portfolio_config.sh \
  lib/pr_merge.sh \
  lib/state_persist.sh \
  lib/tmux_helpers.sh \
  lib/worktree_helpers.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/dispatch_ticket.sh"
chmod +x "$SANITIZED_ROOT/scripts/cycle.sh"
chmod +x "$SANITIZED_ROOT/scripts/integrate_wave.sh"
chmod +x "$SANITIZED_ROOT/scripts/pr_merge_wave.sh"
chmod +x "$SANITIZED_ROOT/scripts/recover.sh"
chmod +x "$SANITIZED_ROOT/lib/pr_merge.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="dry-run-test"
GH_REPO="RBOKproject/ORDO"
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

cat > "$TEST_TMP/bin/sleep" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/sleep.log"
exit 0
EOF
chmod +x "$TEST_TMP/bin/sleep"

cat > "$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "$TEST_TMP/logs/gh.log"
if [[ "\${1:-}" == "pr" && "\${2:-}" == "list" ]]; then
  if [[ "\${GH_WAVE_MODE:-}" == "wave" ]]; then
    printf '%s\n' '[{"number":101,"headRefName":"feat/test-a","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","title":"A"},{"number":102,"headRefName":"feat/test-b","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","title":"B"}]'
  else
    printf '%s\n' '[]'
  fi
  exit 0
fi
if [[ "\${1:-}" == "pr" && "\${2:-}" == "view" ]]; then
  case "\$*" in
    *"--json state,mergeStateStatus,mergeable"*)
      printf '%s\n' '{"state":"OPEN","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}'
      ;;
    *statusCheckRollup*)
      if [[ "\${PR_MERGE_DRY_RUN_MODE:-}" == "pending" ]]; then
        printf '%s\n' '{"statusCheckRollup":[]}'
      else
        printf '%s\n' '{"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS","name":"ci"}]}'
      fi
      ;;
    *"--json files"*)
      printf '%s\n' '{"files":[]}'
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
[[ "$pr_merge_output" == *"gh pr merge 77 --repo RBOKproject/ORDO --squash"* ]] || \
  fail "expected pr_merge dry-run to preview squash merge, got: $pr_merge_output"

if grep -q 'pr merge' "$TEST_TMP/logs/gh.log"; then
  fail "pr_merge dry-run must not invoke gh pr merge"
fi
if grep -q 'pr review' "$TEST_TMP/logs/gh.log"; then
  fail "pr_merge dry-run must not invoke gh pr review"
fi

printf 'ok - pr_merge dry-run avoided merge/review calls\n'

: > "$TEST_TMP/logs/gh.log"
: > "$TEST_TMP/logs/sleep.log"

set +e
pr_merge_pending_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  PR_MERGE_DRY_RUN_MODE=pending \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  PR_MERGE_CI_TIMEOUT_SEC=1 \
  PR_MERGE_CI_INTERVAL_SEC=1 \
  bash "$SANITIZED_ROOT/lib/pr_merge.sh" "$TEST_TMP/test.config.sh" 78 --dry-run 2>&1
)
pr_merge_pending_status=$?
set -e

[[ "$pr_merge_pending_status" -eq 0 ]] || fail "pending pr_merge dry-run should exit 0, got $pr_merge_pending_status: $pr_merge_pending_output"
[[ "$pr_merge_pending_output" == *"DRY-RUN:"* ]] || fail "expected DRY-RUN output from pending pr_merge dry-run, got: $pr_merge_pending_output"
[[ ! -s "$TEST_TMP/logs/sleep.log" ]] || fail "pr_merge dry-run must not sleep while CI is pending"

printf 'ok - pr_merge dry-run snapshots pending CI without sleeping\n'

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

cat > "$SANITIZED_ROOT/lib/pr_merge.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'pr_merge %s\n' "\$*" >> "$TEST_TMP/logs/pr-merge-wave.log"
if [[ " \$* " != *" --dry-run "* ]]; then
  touch "$TEST_TMP/logs/pr-merge-wave-mutated"
fi
printf 'DRY-RUN: pr_merge stub\n'
exit 0
EOF
chmod +x "$SANITIZED_ROOT/lib/pr_merge.sh"

: > "$TEST_TMP/logs/pr-merge-wave.log"
: > "$TEST_TMP/logs/sleep.log"
rm -f "$TEST_TMP/logs/pr-merge-wave-mutated"

set +e
pr_merge_wave_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  GH_WAVE_MODE=wave \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  PR_MERGE_WAVE_INTER_PR_SLEEP=30 \
  bash "$SANITIZED_ROOT/scripts/pr_merge_wave.sh" "$TEST_TMP/test.config.sh" DRYMERGE '^feat/test-' --dry-run 2>&1
)
pr_merge_wave_status=$?
set -e

[[ "$pr_merge_wave_status" -eq 0 ]] || fail "pr_merge_wave dry-run exited $pr_merge_wave_status: $pr_merge_wave_output"
[[ "$pr_merge_wave_output" == *"DRY-RUN:"* ]] || fail "expected DRY-RUN output from pr_merge_wave, got: $pr_merge_wave_output"
grep -q -- '--dry-run' "$TEST_TMP/logs/pr-merge-wave.log" || fail "pr_merge_wave must relay --dry-run to pr_merge.sh"
[[ ! -s "$TEST_TMP/logs/sleep.log" ]] || fail "pr_merge_wave dry-run must not sleep between PRs"
[[ ! -f "$TEST_TMP/logs/pr-merge-wave-mutated" ]] || fail "pr_merge_wave dry-run must not call pr_merge without --dry-run"

printf 'ok - pr_merge_wave dry-run relays preview mode and skips settle sleep\n'
