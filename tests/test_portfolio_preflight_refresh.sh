#!/usr/bin/env bash
# tests/test_portfolio_preflight_refresh.sh — wave-startup freshness gate (#267).
#
# Covers:
#   - lib/portfolio_config.sh:portfolio_preflight_report_freshness_status — fresh,
#     missing, stale.
#   - scripts/portfolio_session_start.sh --ensure-fresh — fresh exits 0; stale
#     refuses with the canonical `portfolio_preflight_required: ... status=stale`
#     pattern.
#   - scripts/portfolio_session_start.sh --ensure-fresh --auto-refresh-if-stale —
#     fresh exits 0 (no work); stale refreshes the report through the regular
#     session-start flow and the new mtime is current.
#   - scripts/dispatch_ticket.sh --auto-refresh-preflight — stale report is
#     refreshed before the per-agent guard fires.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TEST_TMP/state" "$TEST_TMP/state/_portfolio" "$TEST_TMP/logs" "$TEST_TMP/bin" "$TEST_TMP/repos"

# --- lib unit tests --------------------------------------------------------

unit_log="$TEST_TMP/lib_unit.log"
ORCH_STATE_BASE="$TEST_TMP/state" \
PROJECT="preflight-refresh-unit" \
ORCH_LOG_DIR="$TEST_TMP/logs" \
bash -c '
  set -euo pipefail
  source "'"$ROOT"'/lib/portfolio_config.sh"
  report=$(portfolio_preflight_report_path)
  rm -f "$report"

  status=$(portfolio_preflight_report_freshness_status 2>/dev/null || true)
  [[ "$status" == "missing" ]] || { echo "expected missing got=$status"; exit 1; }

  printf "[]\n" > "$report"
  status=$(portfolio_preflight_report_freshness_status 2>/dev/null || true)
  [[ "$status" == "ok" ]] || { echo "expected ok got=$status"; exit 1; }

  age=$(portfolio_preflight_report_age_sec 2>/dev/null || true)
  [[ "$age" =~ ^[0-9]+$ ]] || { echo "expected numeric age got=$age"; exit 1; }

  touch -d "@$(($(date +%s) - 7200))" "$report"
  PORTFOLIO_PREFLIGHT_MAX_AGE_SEC=3600
  status=$(portfolio_preflight_report_freshness_status 2>/dev/null || true)
  [[ "$status" == "stale" ]] || { echo "expected stale got=$status"; exit 1; }
' > "$unit_log" 2>&1 || fail "lib unit checks failed: $(cat "$unit_log")"

# --- portfolio_session_start.sh --ensure-fresh ------------------------------

remote_repo="$TEST_TMP/remote.git"
seed_repo="$TEST_TMP/seed"
git init -q --bare "$remote_repo"
git init -q "$seed_repo"
git -C "$seed_repo" config user.email test@example.invalid
git -C "$seed_repo" config user.name "Preflight Refresh Test"
printf 'v1\n' > "$seed_repo/file.txt"
git -C "$seed_repo" add file.txt
git -C "$seed_repo" commit -q -m 'initial'
git -C "$seed_repo" branch -M main
git -C "$seed_repo" remote add origin "$remote_repo"
git -C "$seed_repo" push -q -u origin main
git -C "$remote_repo" symbolic-ref HEAD refs/heads/main

ready_clone="$TEST_TMP/repos/ready"
git clone -q "$remote_repo" "$ready_clone"
git -C "$ready_clone" config user.email test@example.invalid
git -C "$ready_clone" config user.name "Preflight Refresh Test"

mkdir -p "$TEST_TMP/gh"
cat > "$TEST_TMP/product.config.sh" <<EOF
PROJECT="product"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
REPO_URL="$remote_repo"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=(
  "ready|product-ready:0.0|$ready_clone"
)
EOF

cat > "$TEST_TMP/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="preflight-refresh"
PORTFOLIO_PROJECTS=(
  "product|$TEST_TMP/product.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "product=100"
)
EOF

state_dir="$TEST_TMP/state/_portfolio"
report="$state_dir/session_start.json"

# fresh case: --ensure-fresh exits 0 without running the audit and prints the
# canonical fresh marker.
cat > "$report" <<JSON
[
  {"alias":"product","label":"ready","ready":1,"status":"ready","priority":100,"source":"portfolio_matrix"}
]
JSON
touch "$report"

set +e
fresh_output=$(
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  bash "$ROOT/scripts/portfolio_session_start.sh" "$TEST_TMP/portfolio.config.sh" \
    --ensure-fresh --json 2>&1
)
fresh_status=$?
set -e
[[ "$fresh_status" -eq 0 ]] \
  || fail "ensure-fresh on a fresh report should exit 0; status=$fresh_status output=$fresh_output"
[[ "$fresh_output" == *"portfolio_preflight_fresh: status=ok"* ]] \
  || fail "expected fresh marker, got: $fresh_output"

# stale case: --ensure-fresh refuses with canonical pattern, exit 4, no
# mutation of the report.
touch -d "@$(($(date +%s) - 7200))" "$report"
mtime_before=$(stat -c %Y "$report")
set +e
stale_output=$(
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  PORTFOLIO_PREFLIGHT_MAX_AGE_SEC=3600 \
  bash "$ROOT/scripts/portfolio_session_start.sh" "$TEST_TMP/portfolio.config.sh" \
    --ensure-fresh --json 2>&1
)
stale_status=$?
set -e
[[ "$stale_status" -eq 4 ]] \
  || fail "ensure-fresh on stale should exit 4; status=$stale_status output=$stale_output"
[[ "$stale_output" == *"portfolio_preflight_required: status=stale"* ]] \
  || fail "expected stale refusal pattern, got: $stale_output"
[[ "$stale_output" == *"rerun scripts/portfolio_session_start.sh"* ]] \
  || fail "expected explicit remediation command, got: $stale_output"
mtime_after=$(stat -c %Y "$report")
[[ "$mtime_before" -eq "$mtime_after" ]] \
  || fail "ensure-fresh refusal must not mutate the report"

# stale + auto-refresh: refresh runs and the report mtime moves forward.
touch -d "@$(($(date +%s) - 7200))" "$report"
mtime_before=$(stat -c %Y "$report")
set +e
refresh_output=$(
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  PORTFOLIO_PREFLIGHT_MAX_AGE_SEC=3600 \
  bash "$ROOT/scripts/portfolio_session_start.sh" "$TEST_TMP/portfolio.config.sh" \
    --ensure-fresh --auto-refresh-if-stale --json 2>&1
)
refresh_status=$?
set -e
[[ "$refresh_status" -eq 0 ]] \
  || fail "ensure-fresh --auto-refresh-if-stale on stale should refresh successfully; status=$refresh_status output=$refresh_output"
mtime_after=$(stat -c %Y "$report")
[[ "$mtime_after" -gt "$mtime_before" ]] \
  || fail "refresh must rewrite the report (mtime_before=$mtime_before mtime_after=$mtime_after)"
[[ "$refresh_output" == *"previous_status=stale"* ]] \
  || fail "expected refresh trace mentioning previous_status=stale, got: $refresh_output"

# missing report + auto-refresh: refresh creates the report.
rm -f "$report"
set +e
missing_refresh_output=$(
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  bash "$ROOT/scripts/portfolio_session_start.sh" "$TEST_TMP/portfolio.config.sh" \
    --ensure-fresh --auto-refresh-if-stale --json 2>&1
)
missing_refresh_status=$?
set -e
[[ "$missing_refresh_status" -eq 0 ]] \
  || fail "ensure-fresh --auto-refresh-if-stale on missing should refresh; status=$missing_refresh_status output=$missing_refresh_output"
[[ -s "$report" ]] \
  || fail "auto-refresh on missing must create the report"

# --- dispatch_ticket.sh --auto-refresh-preflight ---------------------------

# Stub tmux so dispatch_ticket can probe a pane in dry-run.
cat > "$TEST_TMP/bin/tmux" <<'TMUX'
#!/bin/sh
exit 0
TMUX
chmod +x "$TEST_TMP/bin/tmux"

# Make the report stale on disk before invoking dispatch.
touch -d "@$(($(date +%s) - 7200))" "$report"

# Build a minimal canonical brief with the required headers.
brief="$TEST_TMP/dispatch-brief.md"
cat > "$brief" <<'BRIEF'
# Dispatch test

## Objectif
Trigger the wave-startup preflight gate.

## Format de sortie attendu
- short

## Tools / sources autorises
- shell

## Boundaries / interdictions
- no mutation

## Definition of Done verifiable
- [x] gate evaluated

## Preuves attendues
- audit log line
BRIEF

set +e
auto_refresh_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  PORTFOLIO_PREFLIGHT_MAX_AGE_SEC=3600 \
  bash "$ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/product.config.sh" \
    ready 5267 "$brief" \
    --portfolio "$TEST_TMP/portfolio.config.sh" \
    --auto-refresh-preflight --dry-run 2>&1
)
auto_refresh_status=$?
set -e
[[ "$auto_refresh_status" -eq 0 ]] \
  || fail "dispatch with --auto-refresh-preflight should refresh and continue; status=$auto_refresh_status output=$auto_refresh_output"

audit_log="$TEST_TMP/logs/product.log"
[[ -s "$audit_log" ]] || fail "audit log not written"
grep -Fq 'PREFLIGHT REFRESH START' "$audit_log" \
  || fail "expected PREFLIGHT REFRESH START in audit log, got: $(cat "$audit_log")"
grep -Fq 'PREFLIGHT REFRESHED' "$audit_log" \
  || fail "expected PREFLIGHT REFRESHED in audit log, got: $(cat "$audit_log")"

# Without --auto-refresh-preflight: stale state is recorded as PREFLIGHT REFUSED
# and the existing per-agent fail-closed guard still surfaces the canonical
# refusal line.
touch -d "@$(($(date +%s) - 7200))" "$report"
: > "$audit_log"

set +e
no_refresh_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  PORTFOLIO_PREFLIGHT_MAX_AGE_SEC=3600 \
  bash "$ROOT/scripts/dispatch_ticket.sh" "$TEST_TMP/product.config.sh" \
    ready 5268 "$brief" \
    --portfolio "$TEST_TMP/portfolio.config.sh" \
    --dry-run 2>&1
)
no_refresh_status=$?
set -e
[[ "$no_refresh_status" -ne 0 ]] \
  || fail "dispatch without --auto-refresh-preflight on stale must fail closed; output=$no_refresh_output"
[[ "$no_refresh_output" == *"portfolio_preflight_required"* ]] \
  || fail "expected per-agent fail-closed guard to fire; output=$no_refresh_output"
grep -Fq 'PREFLIGHT REFUSED' "$audit_log" \
  || fail "expected PREFLIGHT REFUSED in audit log, got: $(cat "$audit_log")"

printf 'ok - test_portfolio_preflight_refresh\n'
