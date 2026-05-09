#!/usr/bin/env bash
# tests/test_classifier_outage.sh — fleet-wide classifier-outage detector (#410).
#
# Covers:
#   - lib/classifier_outage.sh: empty / missing-dir / multi-session / custom
#     pattern catalog / multi-dir aggregation.
#   - scripts/portfolio_status.sh: per-project `counts.classifier_fallback_count`
#     attribution from AGENT_PANES session names + simulated 60-second outage.
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

# -----------------------------------------------------------------------------
# Unit: lib/classifier_outage.sh
# -----------------------------------------------------------------------------

# Case 1: log dir absent -> total=0, scanned_files=0.
empty_dir="$TEST_TMP/no-such-dir"
empty_summary=$(
  ORCH_CLASSIFIER_OUTAGE_LOG_DIRS="$empty_dir" \
  bash -c "source '$ROOT/lib/classifier_outage.sh'; classifier_outage_summary_json"
)
[[ "$(printf '%s' "$empty_summary" | jq -r '.total')" == "0" ]] \
  || fail "absent log dir should report total=0; got: $empty_summary"
[[ "$(printf '%s' "$empty_summary" | jq -r '.scanned_files')" == "0" ]] \
  || fail "absent log dir should report scanned_files=0; got: $empty_summary"
[[ "$(printf '%s' "$empty_summary" | jq -r '.patterns_source')" == "default" ]] \
  || fail "missing-dir summary should still report patterns_source=default; got: $empty_summary"

# Case 2: log dir present but empty -> total=0, scanned_files=0.
mkdir -p "$TEST_TMP/empty/.claude/debug"
empty2_summary=$(
  ORCH_CLASSIFIER_OUTAGE_LOG_DIRS="$TEST_TMP/empty/.claude/debug" \
  bash -c "source '$ROOT/lib/classifier_outage.sh'; classifier_outage_summary_json"
)
[[ "$(printf '%s' "$empty2_summary" | jq -r '.total')" == "0" ]] \
  || fail "empty dir should report total=0; got: $empty2_summary"

# Case 3: simulated 60-second 429-storm log per the issue evidence.
log_dir="$TEST_TMP/storm/.claude/debug"
mkdir -p "$log_dir"
cat > "$log_dir/rbok-claude.log" <<'LOG'
[20:11:02Z] classifier POST -> 429 (retry-after: 6s)
[20:11:08Z] classifier POST -> 429 (retry-after: 12s)
[20:11:20Z] classifier POST -> 429 (retry-after: 24s)
[20:11:44Z] classifier POST -> 503
[20:11:44Z] classifier: giving up; defaulting to "ask user"
[20:11:44Z] tool_use[Bash] suspended awaiting confirmation
LOG
cat > "$log_dir/rbok-codex.log" <<'LOG'
[20:11:02Z] classifier POST -> 429
[20:11:08Z] classifier POST -> 429
[20:12:00Z] classifier: giving up
[20:13:00Z] auto-mode classifier: gave up
LOG
cat > "$log_dir/rbok-orchestrator.log" <<'LOG'
[20:00:00Z] classifier POST -> 200
[20:01:00Z] classifier POST -> 200
LOG
storm_summary=$(
  ORCH_CLASSIFIER_OUTAGE_LOG_DIRS="$log_dir" \
  bash -c "source '$ROOT/lib/classifier_outage.sh'; classifier_outage_summary_json"
)
[[ "$(printf '%s' "$storm_summary" | jq -r '.total')" == "3" ]] \
  || fail "storm summary should report total=3 (1 claude + 2 codex); got: $storm_summary"
[[ "$(printf '%s' "$storm_summary" | jq -r '.scanned_files')" == "3" ]] \
  || fail "storm summary should report scanned_files=3; got: $storm_summary"
[[ "$(printf '%s' "$storm_summary" | jq -r '.by_session["rbok-claude"]')" == "1" ]] \
  || fail "rbok-claude per-session count should be 1; got: $storm_summary"
[[ "$(printf '%s' "$storm_summary" | jq -r '.by_session["rbok-codex"]')" == "2" ]] \
  || fail "rbok-codex per-session count should be 2; got: $storm_summary"
[[ "$(printf '%s' "$storm_summary" | jq -r '.by_session["rbok-orchestrator"]')" == "0" ]] \
  || fail "rbok-orchestrator (no fail-closed lines) should be 0; got: $storm_summary"

# Case 4: classifier_outage_total wraps the JSON helper.
storm_total=$(
  ORCH_CLASSIFIER_OUTAGE_LOG_DIRS="$log_dir" \
  bash -c "source '$ROOT/lib/classifier_outage.sh'; classifier_outage_total"
)
[[ "$storm_total" == "3" ]] || fail "classifier_outage_total should be 3; got: $storm_total"

# Case 5: classifier_outage_count_for_sessions filters to named sessions only.
filtered=$(
  ORCH_CLASSIFIER_OUTAGE_LOG_DIRS="$log_dir" \
  bash -c "source '$ROOT/lib/classifier_outage.sh'; classifier_outage_count_for_sessions rbok-claude"
)
[[ "$filtered" == "1" ]] \
  || fail "count_for_sessions(rbok-claude) should be 1; got: $filtered"
filtered_pair=$(
  ORCH_CLASSIFIER_OUTAGE_LOG_DIRS="$log_dir" \
  bash -c "source '$ROOT/lib/classifier_outage.sh'; classifier_outage_count_for_sessions rbok-claude rbok-codex"
)
[[ "$filtered_pair" == "3" ]] \
  || fail "count_for_sessions(rbok-claude rbok-codex) should be 3; got: $filtered_pair"
filtered_missing=$(
  ORCH_CLASSIFIER_OUTAGE_LOG_DIRS="$log_dir" \
  bash -c "source '$ROOT/lib/classifier_outage.sh'; classifier_outage_count_for_sessions rbok-nonexistent"
)
[[ "$filtered_missing" == "0" ]] \
  || fail "count_for_sessions for unknown session should be 0; got: $filtered_missing"
filtered_none=$(
  ORCH_CLASSIFIER_OUTAGE_LOG_DIRS="$log_dir" \
  bash -c "source '$ROOT/lib/classifier_outage.sh'; classifier_outage_count_for_sessions"
)
[[ "$filtered_none" == "0" ]] \
  || fail "count_for_sessions with no args should be 0; got: $filtered_none"

# Case 6: operator-supplied pattern catalog REPLACES the defaults.
patterns_file="$TEST_TMP/custom-patterns.txt"
cat > "$patterns_file" <<'EOF'
operator-pinned-fail-closed-marker
EOF
mkdir -p "$TEST_TMP/custom/.claude/debug"
cat > "$TEST_TMP/custom/.claude/debug/rbok-claude.log" <<'LOG'
[20:00:00Z] classifier: giving up
[20:01:00Z] operator-pinned-fail-closed-marker fired
LOG
custom_summary=$(
  ORCH_CLASSIFIER_OUTAGE_LOG_DIRS="$TEST_TMP/custom/.claude/debug" \
  ORCH_CLASSIFIER_OUTAGE_PATTERNS_FILE="$patterns_file" \
  bash -c "source '$ROOT/lib/classifier_outage.sh'; classifier_outage_summary_json"
)
[[ "$(printf '%s' "$custom_summary" | jq -r '.total')" == "1" ]] \
  || fail "custom patterns should match only operator marker; got: $custom_summary"
[[ "$(printf '%s' "$custom_summary" | jq -r '.patterns_source')" == "$patterns_file" ]] \
  || fail "patterns_source should reflect override; got: $custom_summary"

# Case 7: multiple log dirs aggregate cleanly.
mkdir -p "$TEST_TMP/dir1/.claude/debug" "$TEST_TMP/dir2/.claude/debug"
printf '[20:00:00Z] classifier: giving up\n' > "$TEST_TMP/dir1/.claude/debug/rbok-a.log"
printf '[20:00:00Z] classifier: giving up\n[20:00:01Z] classifier: giving up\n' \
  > "$TEST_TMP/dir2/.claude/debug/rbok-b.log"
multi_summary=$(
  ORCH_CLASSIFIER_OUTAGE_LOG_DIRS="$TEST_TMP/dir1/.claude/debug:$TEST_TMP/dir2/.claude/debug" \
  bash -c "source '$ROOT/lib/classifier_outage.sh'; classifier_outage_summary_json"
)
[[ "$(printf '%s' "$multi_summary" | jq -r '.total')" == "3" ]] \
  || fail "multi-dir summary should aggregate (1+2=3); got: $multi_summary"
[[ "$(printf '%s' "$multi_summary" | jq -r '.log_dirs | length')" == "2" ]] \
  || fail "multi-dir summary should list 2 dirs; got: $multi_summary"

# -----------------------------------------------------------------------------
# Integration: scripts/portfolio_status.sh exposes classifier_fallback_count
# -----------------------------------------------------------------------------

# shellcheck source=lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
SANITIZED_ROOT="$TEST_TMP/toolkit"
mkdir -p "$SANITIZED_ROOT/scripts" "$TEST_TMP/configs"

sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/portfolio_status.sh

cat > "$SANITIZED_ROOT/scripts/agent_pool_status.sh" <<'EOF'
#!/usr/bin/env bash
cfg=$1
case "$cfg" in
  *alpha*) printf '[]\n' ;;
  *beta* ) printf '[]\n' ;;
esac
EOF
chmod +x "$SANITIZED_ROOT/scripts/agent_pool_status.sh"

cat > "$SANITIZED_ROOT/scripts/pr_block_signals.sh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
chmod +x "$SANITIZED_ROOT/scripts/pr_block_signals.sh"

# alpha owns the rbok-alpha session; beta owns rbok-beta. The simulated outage
# log only fires on rbok-alpha; alpha's row should carry count=1 and beta's 0.
cat > "$TEST_TMP/configs/alpha.config.sh" <<EOF
PROJECT="alpha"
GH_REPO="example/alpha"
DEFAULT_BRANCH="main"
AGENT_PANES=(
  "claude|rbok-alpha:0.0|/tmp/alpha"
)
EOF
cat > "$TEST_TMP/configs/beta.config.sh" <<EOF
PROJECT="beta"
GH_REPO="example/beta"
DEFAULT_BRANCH="main"
AGENT_PANES=(
  "claude|rbok-beta:0.0|/tmp/beta"
)
EOF
cat > "$TEST_TMP/configs/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="classifier-outage-smoke"
PORTFOLIO_PROJECTS=(
  "alpha|$TEST_TMP/configs/alpha.config.sh"
  "beta|$TEST_TMP/configs/beta.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "alpha=100"
  "beta=80"
)
EOF

mkdir -p "$TEST_TMP/storm-int/.claude/debug"
cat > "$TEST_TMP/storm-int/.claude/debug/rbok-alpha.log" <<'LOG'
[20:11:44Z] classifier: giving up
LOG

output=$(
  ORCH_CLASSIFIER_OUTAGE_LOG_DIRS="$TEST_TMP/storm-int/.claude/debug" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/portfolio_status.sh" \
    "$TEST_TMP/configs/portfolio.config.sh" --json
)

[[ "$(printf '%s' "$output" | jq -r '.[] | select(.alias=="alpha") | .counts.classifier_fallback_count')" == "1" ]] \
  || fail "alpha row should carry classifier_fallback_count=1; output=$output"
[[ "$(printf '%s' "$output" | jq -r '.[] | select(.alias=="beta") | .counts.classifier_fallback_count')" == "0" ]] \
  || fail "beta row (no log activity) should carry classifier_fallback_count=0; output=$output"

# A clean fleet (no log dir) keeps every project at 0 — fleets without Claude
# debug logging enabled MUST NOT be a hard error here.
clean_output=$(
  ORCH_CLASSIFIER_OUTAGE_LOG_DIRS="$TEST_TMP/no-such-dir" \
  ORCH_STATE_BASE="$TEST_TMP/state-clean" \
  bash "$SANITIZED_ROOT/scripts/portfolio_status.sh" \
    "$TEST_TMP/configs/portfolio.config.sh" --json
)
[[ "$(printf '%s' "$clean_output" | jq -r '[.[].counts.classifier_fallback_count] | add')" == "0" ]] \
  || fail "clean fleet should sum classifier_fallback_count=0 across projects; output=$clean_output"

# TSV variant must also carry the new column at the row tail.
tsv=$(
  ORCH_CLASSIFIER_OUTAGE_LOG_DIRS="$TEST_TMP/storm-int/.claude/debug" \
  ORCH_STATE_BASE="$TEST_TMP/state-tsv" \
  bash "$SANITIZED_ROOT/scripts/portfolio_status.sh" \
    "$TEST_TMP/configs/portfolio.config.sh" --tsv
)
[[ "$tsv" == *$'\tclassifier_fallback_count'* ]] \
  || fail "TSV header should advertise classifier_fallback_count column; tsv=$tsv"

printf 'ok - test_classifier_outage\n'
