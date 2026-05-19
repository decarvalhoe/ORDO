#!/usr/bin/env bash
# tests/test_continuation_guard_overlapping_scan.sh - issue #668
#
# Verifies continuation_guard treats an overlapping portfolio_status scan
# as an indeterminate/blocking state. The guard MUST:
#   - emit decision=scan_in_progress (never stop_ok) when portfolio_status
#     logs the "overlapping scan" degraded marker on stderr
#   - surface the scan owner PID in its JSON/TSV output
#   - include explicit retry guidance in the reason detail
#   - also fall back to the JSON-shape fingerprint (partial summary:
#     rebalance_signal=process_budget_degraded + fork_risk health signal)
#     when stderr is unavailable to the caller
#   - preserve stop_ok for a clean, non-overlapped snapshot (regression
#     guard for the canonical "no work" path)
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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/configs"

for rel in \
  scripts/continuation_guard.sh \
  lib/config_resolver.sh \
  lib/portfolio_config.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/continuation_guard.sh"

# Fake portfolio_status.sh that simulates either:
#   - SCENARIO=overlap: the degraded path (stderr marker + partial JSON)
#   - SCENARIO=overlap_json_only: partial JSON shape WITHOUT stderr,
#     to exercise the JSON-fallback detection
#   - SCENARIO=clean_idle: a non-overlapped clean snapshot (must stop_ok)
cat > "$SANITIZED_ROOT/scripts/portfolio_status.sh" <<'EOF'
#!/usr/bin/env bash
case "${SCENARIO:-overlap}" in
  overlap)
    # Mirrors lib/process_safety.sh single-flight contention: stderr
    # warning carries owner_pid + age; stdout is a partial snapshot.
    echo "portfolio_status degraded: overlapping scan owner_pid=24681 age=37s" >&2
    cat <<JSON
[
  {
    "alias":"alpha","priority":100,"config":"$TEST_ALPHA_CFG",
    "gate_state":"unknown",
    "rebalance_signal":"process_budget_degraded",
    "backlog_signal":"",
    "health_signals":["process_budget_degraded","fork_risk"],
    "counts":{"free":0,"parkable":0,"open_prs":0,"merge_ready":0,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0},
    "agents":{"free":[],"parkable":[]}
  }
]
JSON
    ;;
  overlap_json_only)
    # Caller swallowed stderr; detection must still fire via the JSON
    # fingerprint alone.
    cat <<JSON
[
  {
    "alias":"alpha","priority":100,"config":"$TEST_ALPHA_CFG",
    "gate_state":"unknown",
    "rebalance_signal":"process_budget_degraded",
    "backlog_signal":"",
    "health_signals":["process_budget_degraded","fork_risk"],
    "counts":{"free":0,"parkable":0,"open_prs":0,"merge_ready":0,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0},
    "agents":{"free":[],"parkable":[]}
  },
  {
    "alias":"beta","priority":50,"config":"$TEST_BETA_CFG",
    "gate_state":"unknown",
    "rebalance_signal":"process_budget_degraded",
    "backlog_signal":"",
    "health_signals":["process_budget_degraded","fork_risk"],
    "counts":{"free":0,"parkable":0,"open_prs":0,"merge_ready":0,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0},
    "agents":{"free":[],"parkable":[]}
  }
]
JSON
    ;;
  clean_idle)
    # Non-overlapped clean snapshot: zero capacity, zero work, no
    # degraded markers. Must stay stop_ok — the negative control that
    # ensures the new code does not over-trigger.
    cat <<JSON
[
  {
    "alias":"alpha","priority":100,"config":"$TEST_ALPHA_CFG",
    "gate_state":"dispatchable",
    "counts":{"free":0,"parkable":0,"open_prs":0,"merge_ready":0,"ci_failed":0,"needs_rebase":0,"conflicts":0,"review_required":0},
    "agents":{"free":[],"parkable":[]}
  }
]
JSON
    ;;
esac
EOF
chmod +x "$SANITIZED_ROOT/scripts/portfolio_status.sh"

# dispatch_plan stub: not consulted in any of the overlapping scenarios
# (capacity is 0 in partial summaries), but continuation_guard sources
# it unconditionally. Return an empty plan so the script never fails.
cat > "$SANITIZED_ROOT/scripts/dispatch_plan.sh" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
chmod +x "$SANITIZED_ROOT/scripts/dispatch_plan.sh"

cat > "$TEST_TMP/configs/alpha.config.sh" <<'EOF'
PROJECT="alpha"
GH_REPO="example/alpha"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
EOF

cat > "$TEST_TMP/configs/beta.config.sh" <<'EOF'
PROJECT="beta"
GH_REPO="example/beta"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="/tmp/gh"
EOF

cat > "$TEST_TMP/configs/portfolio.config.sh" <<EOF
PORTFOLIO_PROJECTS=(
  "alpha|$TEST_TMP/configs/alpha.config.sh"
  "beta|$TEST_TMP/configs/beta.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "alpha=100"
  "beta=50"
)
EOF

export TEST_ALPHA_CFG="$TEST_TMP/configs/alpha.config.sh"
export TEST_BETA_CFG="$TEST_TMP/configs/beta.config.sh"

# --- Case 1: stderr marker present ----------------------------------------
# continuation_guard MUST emit decision=scan_in_progress with owner_pid
# and retry guidance — never stop_ok — when portfolio_status logs the
# overlapping-scan warning. stderr is dropped so the captured `output`
# is parseable JSON.
set +e
output=$(SCENARIO=overlap bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json 2>/dev/null)
status=$?
set -e
[[ "$status" -eq 10 ]] \
  || fail "overlap should exit 10 (not stop_ok=0), got $status: $output"
jq -e '.decision == "scan_in_progress"' <<< "$output" >/dev/null \
  || fail "decision must be scan_in_progress (never stop_ok) on overlap: $output"
jq -e '.scan_overlap == true' <<< "$output" >/dev/null \
  || fail "scan_overlap flag must be true on overlap: $output"
jq -e '.scan_owner_pid == "24681"' <<< "$output" >/dev/null \
  || fail "scan_owner_pid must surface the owner from stderr: $output"
jq -e '.scan_owner_age == "37s"' <<< "$output" >/dev/null \
  || fail "scan_owner_age must surface the lock age from stderr: $output"
jq -e '
  .reasons[]
  | select(.reason == "portfolio-scan-overlap"
           and (.detail | contains("owner_pid=24681"))
           and (.detail | contains("age=37s"))
           and (.detail | contains("retry"))
           and (.detail | contains("partial snapshot is not proof")))
' <<< "$output" >/dev/null \
  || fail "reasons[] must carry portfolio-scan-overlap with owner_pid + retry guidance: $output"

# --- Case 2: JSON-fallback detection (stderr swallowed) -------------------
# Some callers wrap continuation_guard and redirect 2>/dev/null. The
# JSON-shape fingerprint alone must still trip the guard.
set +e
output_json=$(SCENARIO=overlap_json_only bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json 2>/dev/null)
status_json=$?
set -e
[[ "$status_json" -eq 10 ]] \
  || fail "JSON-fallback overlap should exit 10, got $status_json: $output_json"
jq -e '.decision == "scan_in_progress" and .scan_overlap == true' <<< "$output_json" >/dev/null \
  || fail "JSON-fallback path must still produce scan_in_progress: $output_json"
# owner_pid is unknown when only the JSON fingerprint trips (stderr line
# was the carrier). That is the documented degraded-evidence case; the
# decision is still scan_in_progress and retry guidance still shows.
jq -e '
  .scan_owner_pid == "unknown"
  and (.reasons[] | select(.reason == "portfolio-scan-overlap"
                           and (.detail | contains("owner_pid=unknown"))
                           and (.detail | contains("retry"))))
' <<< "$output_json" >/dev/null \
  || fail "JSON-fallback path must still emit retry guidance with owner_pid=unknown: $output_json"

# --- Case 3: TSV format also surfaces overlap fields ----------------------
# Operators reading continuation_guard's TSV output (the default) must see
# the scan_overlap/owner_pid/owner_age lines and the portfolio-scan-overlap
# reason row.
set +e
tsv_output=$(SCENARIO=overlap bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --tsv 2>/dev/null)
tsv_status=$?
set -e
[[ "$tsv_status" -eq 10 ]] \
  || fail "TSV overlap should exit 10, got $tsv_status: $tsv_output"
grep -q $'^decision\tscan_in_progress$' <<< "$tsv_output" \
  || fail "TSV must include decision\\tscan_in_progress: $tsv_output"
grep -q $'^scan_overlap\ttrue$' <<< "$tsv_output" \
  || fail "TSV must include scan_overlap\\ttrue: $tsv_output"
grep -q $'^scan_owner_pid\t24681$' <<< "$tsv_output" \
  || fail "TSV must include scan_owner_pid\\t24681: $tsv_output"
grep -q $'^scan_owner_age\t37s$' <<< "$tsv_output" \
  || fail "TSV must include scan_owner_age\\t37s: $tsv_output"
grep -qF 'portfolio-scan-overlap' <<< "$tsv_output" \
  || fail "TSV must include the portfolio-scan-overlap reason row: $tsv_output"

# --- Case 4: clean non-overlapped snapshot stays stop_ok ------------------
# Negative control: no degraded marker, no fork_risk health signal, no
# work to do. continuation_guard must still emit stop_ok here so the new
# detection does not over-trigger on legitimate idle states.
clean_output=$(SCENARIO=clean_idle bash "$SANITIZED_ROOT/scripts/continuation_guard.sh" "$TEST_TMP/configs/portfolio.config.sh" --json 2>/dev/null)
jq -e '
  .decision == "stop_ok"
  and (.scan_overlap == false)
  and (.scan_owner_pid == "unknown")
  and ([.reasons[]?.reason] | index("portfolio-scan-overlap") == null)
' <<< "$clean_output" >/dev/null \
  || fail "clean non-overlapped snapshot must remain stop_ok: $clean_output"

printf 'ok - continuation_guard treats overlapping portfolio scans as scan_in_progress (issue #668)\n'
