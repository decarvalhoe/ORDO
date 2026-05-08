#!/usr/bin/env bats

# Coverage for #351: scripts/portfolio_auto_merge.sh — preview-by-default,
# defense-in-depth live mode (flag AND profile opt-in), portfolio priority
# ordering, --limit, and clean no-candidate behaviour.

load './helpers.bash'

setup() {
  setup_orch_test

  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TK_ROOT="$BATS_TEST_TMPDIR/toolkit"
  mkdir -p "$TK_ROOT/scripts" "$TK_ROOT/lib"

  for rel in \
    scripts/portfolio_auto_merge.sh \
    lib/dry_run.sh \
    lib/portfolio_config.sh \
    lib/process_safety.sh \
    lib/config_resolver.sh \
    lib/audit_log.sh \
    lib/config_check.sh \
    lib/log_bounds.sh; do
    tr -d '\r' < "$ROOT/$rel" > "$TK_ROOT/$rel"
  done
  chmod +x "$TK_ROOT/scripts/portfolio_auto_merge.sh"

  # Stub pr_block_signals.sh — the script the auto-merge command shells out
  # to. The fixture pretends every project-config that has "ready" in its
  # name returns three PRs (two merge-ready, one drafty), and configs with
  # "empty" in the name return no PRs.
  cat > "$TK_ROOT/scripts/pr_block_signals.sh" <<'PRBS'
#!/usr/bin/env bash
cfg=$1
case "$cfg" in
  *empty* )
    printf '[]\n' ;;
  *ready* )
    project_token=$(basename "$cfg" .config.sh)
    cat <<JSON
[
  {"pr":"101","branch":"feat/${project_token}-101","agent":"a-1","signals":["merge-ready","ci-pass"]},
  {"pr":"102","branch":"feat/${project_token}-102","agent":"a-2","signals":["draft","ci-pass"]},
  {"pr":"103","branch":"feat/${project_token}-103","agent":"a-3","signals":["merge-ready","ci-pass"]}
]
JSON
    ;;
  * )
    printf '[]\n' ;;
esac
PRBS
  chmod +x "$TK_ROOT/scripts/pr_block_signals.sh"

  # Stub lib/pr_merge.sh so the test can observe what would have been merged
  # and choose to fail on demand. The stub records every invocation in
  # PR_MERGE_LOG and exits 0 unless PR_MERGE_FAIL_FOR_PR matches the PR.
  cat > "$TK_ROOT/lib/pr_merge.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
log=${PR_MERGE_LOG:-/tmp/pr_merge.log}
fail_for=${PR_MERGE_FAIL_FOR_PR:-}
cfg=$1
pr=$2
shift 2
extra="$*"
printf '%s\n' "INVOKED cfg=${cfg} pr=${pr} extra=${extra}" >> "$log"
if [ -n "$fail_for" ] && [ "$pr" = "$fail_for" ]; then
  exit 7
fi
exit 0
STUB
  chmod +x "$TK_ROOT/lib/pr_merge.sh"

  PORTFOLIO_CFG="$BATS_TEST_TMPDIR/portfolio.config.sh"
  cat > "$PORTFOLIO_CFG" <<EOF
PORTFOLIO_NAME="auto-merge-test"
PORTFOLIO_PROJECTS=(
  "alpha|$BATS_TEST_TMPDIR/alpha-ready.config.sh"
  "beta|$BATS_TEST_TMPDIR/beta-ready.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "alpha=20"
  "beta=10"
)
EOF

  cat > "$BATS_TEST_TMPDIR/alpha-ready.config.sh" <<'EOF'
PROJECT="alpha"
GH_REPO="example/alpha"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
EOF
  cat > "$BATS_TEST_TMPDIR/beta-ready.config.sh" <<'EOF'
PROJECT="beta"
GH_REPO="example/beta"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
EOF

  # Empty-portfolio variant: both project configs return no PRs.
  PORTFOLIO_EMPTY_CFG="$BATS_TEST_TMPDIR/portfolio-empty.config.sh"
  cat > "$PORTFOLIO_EMPTY_CFG" <<EOF
PORTFOLIO_NAME="auto-merge-empty"
PORTFOLIO_PROJECTS=(
  "alpha|$BATS_TEST_TMPDIR/alpha-empty.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "alpha=10"
)
EOF
  cat > "$BATS_TEST_TMPDIR/alpha-empty.config.sh" <<'EOF'
PROJECT="alpha"
GH_REPO="example/alpha-empty"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
EOF

  PR_MERGE_LOG="$BATS_TEST_TMPDIR/pr_merge.log"
  : > "$PR_MERGE_LOG"
  export TK_ROOT PORTFOLIO_CFG PORTFOLIO_EMPTY_CFG PR_MERGE_LOG
}

@test "preview default: emits plan, calls pr_merge --dry-run for every merge-ready PR, reports counts" {
  run env PR_MERGE_LOG="$PR_MERGE_LOG" \
    bash -c "bash '$TK_ROOT/scripts/portfolio_auto_merge.sh' '$PORTFOLIO_CFG' --json 2>$BATS_TEST_TMPDIR/stderr"

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .mode == "preview"
    and .candidates == 4
    and .merged == 4
    and .failed == 0
    and .skipped == 0
    and ([.plan[] | select(.action == "merge-ok")] | length == 4)
    and .plan[0].alias == "alpha"
    and .plan[0].priority == 20
  ' >/dev/null

  invocations=$(grep -c '^INVOKED ' "$PR_MERGE_LOG" 2>/dev/null) || invocations=0
  [ "$invocations" -eq 4 ]
  grep -q -- '--dry-run' "$PR_MERGE_LOG"
}

@test "refusal: --apply without profile opt-in refuses with exit 70 and audits the refusal" {
  stderr_file="$BATS_TEST_TMPDIR/refusal.stderr"
  run env PR_MERGE_LOG="$PR_MERGE_LOG" \
    bash -c "bash '$TK_ROOT/scripts/portfolio_auto_merge.sh' '$PORTFOLIO_CFG' --apply --json 2>$stderr_file"

  [ "$status" -eq 70 ]
  stderr_text=$(cat "$stderr_file")
  [[ "$stderr_text" == *"refused"* ]]
  # The refusal must short-circuit before invoking pr_merge.
  [ "$(grep -c '^INVOKED ' "$PR_MERGE_LOG" || true)" -eq 0 ]
  grep -Eq 'AUTO_MERGE refused reason=not_authorized' "$ORCH_STATE_BASE/_portfolio/auto_merge.log"
}

@test "apply: --apply WITH PORTFOLIO_AUTO_MERGE_LIVE_OPT_IN=1 invokes pr_merge live for every candidate" {
  run env \
    PR_MERGE_LOG="$PR_MERGE_LOG" \
    PORTFOLIO_AUTO_MERGE_LIVE_OPT_IN=1 \
    PORTFOLIO_AUTO_MERGE_INTER_PR_SLEEP_SEC=0 \
    bash -c "bash '$TK_ROOT/scripts/portfolio_auto_merge.sh' '$PORTFOLIO_CFG' --apply --json 2>$BATS_TEST_TMPDIR/apply.stderr"

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .mode == "live"
    and .candidates == 4
    and .merged == 4
    and .failed == 0
  ' >/dev/null

  invocations=$(grep -c '^INVOKED ' "$PR_MERGE_LOG" 2>/dev/null) || invocations=0
  [ "$invocations" -eq 4 ]
  # Live mode must NOT pass --dry-run to the child.
  ! grep -q -- '--dry-run' "$PR_MERGE_LOG"
}

@test "limit: --limit caps merged count and remaining candidates are skip-limit" {
  run env \
    PR_MERGE_LOG="$PR_MERGE_LOG" \
    PORTFOLIO_AUTO_MERGE_LIVE_OPT_IN=1 \
    PORTFOLIO_AUTO_MERGE_INTER_PR_SLEEP_SEC=0 \
    bash -c "bash '$TK_ROOT/scripts/portfolio_auto_merge.sh' '$PORTFOLIO_CFG' --apply --limit 2 --json 2>$BATS_TEST_TMPDIR/limit.stderr"

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .mode == "live"
    and .limit == "2"
    and .candidates == 4
    and .merged == 2
    and .skipped == 2
    and ([.plan[] | select(.action == "skip-limit")] | length == 2)
    and ([.plan[] | select(.action == "merge-ok")] | length == 2)
  ' >/dev/null

  invocations=$(grep -c '^INVOKED ' "$PR_MERGE_LOG" 2>/dev/null) || invocations=0
  [ "$invocations" -eq 2 ]
}

@test "no-candidate: empty merge-ready set produces a clean exit 0 and no merge attempts" {
  run env PR_MERGE_LOG="$PR_MERGE_LOG" \
    bash -c "bash '$TK_ROOT/scripts/portfolio_auto_merge.sh' '$PORTFOLIO_EMPTY_CFG' --json 2>$BATS_TEST_TMPDIR/empty.stderr"

  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .mode == "preview"
    and .candidates == 0
    and .merged == 0
    and .skipped == 0
    and .failed == 0
    and (.plan | length) == 0
  ' >/dev/null

  invocations=$(grep -c '^INVOKED ' "$PR_MERGE_LOG" 2>/dev/null) || invocations=0
  [ "$invocations" -eq 0 ]
}
