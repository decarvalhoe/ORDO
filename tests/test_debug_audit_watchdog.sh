#!/usr/bin/env bash
# tests/test_debug_audit_watchdog.sh — coverage for the live debug-audit
# loop watchdog (#541).
#
# Covers the four acceptance criteria from #541:
#   1. A stale debug-audit log mtime is detected and logged as an actionable
#      health signal (`decision=stale_log…`).
#   2. The relaunch command records config path, project key, previous PID,
#      and new PID (`action=relaunched config_path=… project=… previous_pid=…
#      new_pid=…`).
#   3. The loop fails fast if it would use sample `project-a` config for live
#      RBOK (`decision=refused_sample_config`, exit 3).
#   4. A no-process detection path (`decision=no_process` /
#      `stale_log_no_process`) exists and is exercised here.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$*"
}

mkdir -p "$TEST_TMP/log" "$TEST_TMP/state"

write_config() {
  local target=$1 project=$2 gh_repo=$3
  cat > "$target" <<EOF
#!/usr/bin/env bash
PROJECT="$project"
GH_REPO="$gh_repo"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/work/%s"
EOF
}

live_config="$TEST_TMP/live.config.sh"
sample_config="$TEST_TMP/sample.config.sh"
write_config "$live_config" "rbok-ordo" "RBOKproject/ORDO"
write_config "$sample_config" "project-a" "example-org/project-a"

run_watchdog() {
  local config=$1
  shift
  ORCH_LOG_DIR="$TEST_TMP/log" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_DEBUG_AUDIT_PGREP_OVERRIDE="${ORCH_DEBUG_AUDIT_PGREP_OVERRIDE-}" \
  TK="$ROOT" \
    bash "$ROOT/scripts/debug_audit_watchdog.sh" "$config" "$@"
}

# ---------------------------------------------------------------------------
# Pure-bash lib coverage — primitives must be sourceable in isolation
# without dragging in PROJECT/GH_REPO config requirements.
# ---------------------------------------------------------------------------

lib_age_missing=$(bash -c "source '$ROOT/lib/debug_audit_watchdog.sh'; debug_audit_log_age_sec '$TEST_TMP/log/never-written.log'")
[[ "$lib_age_missing" == "-1" ]] || fail "absent log should report age -1; got '$lib_age_missing'"
pass "lib: absent log reports age=-1"

touch -d '2026-01-01T00:00:00Z' "$TEST_TMP/log/old.log"
lib_age_old=$(bash -c "source '$ROOT/lib/debug_audit_watchdog.sh'; debug_audit_log_age_sec '$TEST_TMP/log/old.log'")
[[ "$lib_age_old" =~ ^[0-9]+$ ]] || fail "old log should report non-negative age; got '$lib_age_old'"
[[ "$lib_age_old" -gt 100000 ]] || fail "old log age should be large; got '$lib_age_old'"
pass "lib: old log reports positive age in seconds"

bash -c "source '$ROOT/lib/debug_audit_watchdog.sh'; debug_audit_log_is_stale '$TEST_TMP/log/old.log' 60" \
  || fail "old log should be classified stale at threshold=60s"
pass "lib: old log is_stale returns 0 at threshold=60"

touch "$TEST_TMP/log/fresh.log"
if bash -c "source '$ROOT/lib/debug_audit_watchdog.sh'; debug_audit_log_is_stale '$TEST_TMP/log/fresh.log' 600"; then
  fail "freshly-touched log must not be classified stale at threshold=600s"
fi
pass "lib: freshly-touched log is_stale returns 1 at threshold=600"

if bash -c "source '$ROOT/lib/debug_audit_watchdog.sh'; debug_audit_loop_is_sample_config 'project-a' 'whatever/repo'"; then
  pass "lib: sample project 'project-a' matches"
else
  fail "sample project 'project-a' must match the sample guard"
fi

if bash -c "source '$ROOT/lib/debug_audit_watchdog.sh'; debug_audit_loop_is_sample_config 'rbok-ordo' 'example-org/sample'"; then
  pass "lib: example-org/* repo matches sample guard"
else
  fail "example-org/* repo must match the sample guard regardless of PROJECT name"
fi

if bash -c "source '$ROOT/lib/debug_audit_watchdog.sh'; debug_audit_loop_is_sample_config 'rbok-ordo' 'RBOKproject/ORDO'"; then
  fail "live RBOK config must NOT match the sample guard"
fi
pass "lib: live RBOK config does NOT match sample guard"

record=$(bash -c "source '$ROOT/lib/debug_audit_watchdog.sh'; debug_audit_loop_relaunch_record '/path/c.sh' 'rbok-ordo' '12345' '67890'")
[[ "$record" == "config_path=/path/c.sh project=rbok-ordo previous_pid=12345 new_pid=67890" ]] \
  || fail "relaunch record format drift: '$record'"
pass "lib: relaunch_record formats all four fields"

record_blank=$(bash -c "source '$ROOT/lib/debug_audit_watchdog.sh'; debug_audit_loop_relaunch_record '' '' '' ''")
[[ "$record_blank" == "config_path=unknown project=unknown previous_pid=none new_pid=none" ]] \
  || fail "relaunch record blank coercion drift: '$record_blank'"
pass "lib: relaunch_record coerces empties to canonical sentinels"

# ---------------------------------------------------------------------------
# CLI: fail-fast on sample placeholder config (#541 AC3).
# ---------------------------------------------------------------------------

set +e
sample_out=$(run_watchdog "$sample_config" --log-path "$TEST_TMP/log/sample.log" --max-age-sec 60 2>&1)
sample_rc=$?
set -e
[[ "$sample_rc" -eq 3 ]] || fail "sample config should exit 3; got rc=$sample_rc out=$sample_out"
grep -F "refused_sample_config" <<<"$sample_out" >/dev/null \
  || fail "sample-config refusal must echo 'refused_sample_config' on stdout; got: $sample_out"
grep -F "DEBUG_AUDIT_WATCHDOG decision=refused_sample_config" "$TEST_TMP/log/project-a.log" >/dev/null \
  || fail "sample-config refusal must emit audit line with decision=refused_sample_config; log: $(cat "$TEST_TMP/log/project-a.log" 2>/dev/null)"
pass "cli: refuses sample placeholder config with exit 3 and audit signal"

# ---------------------------------------------------------------------------
# CLI: stale-log + no-process detection (#541 AC1 + AC4).
# ---------------------------------------------------------------------------

stale_log="$TEST_TMP/log/stale.log"
touch -d '2026-01-01T00:00:00Z' "$stale_log"

set +e
ORCH_DEBUG_AUDIT_PGREP_OVERRIDE="" stale_out=$(
  ORCH_DEBUG_AUDIT_PGREP_OVERRIDE="" run_watchdog "$live_config" \
    --log-path "$stale_log" --max-age-sec 60 --process-pattern 'sentinel-pattern-no-match' 2>&1
)
stale_rc=$?
set -e
[[ "$stale_rc" -eq 0 ]] || fail "stale+no-process detection should exit 0; got rc=$stale_rc out=$stale_out"
grep -F "stale_log_no_process" <<<"$stale_out" >/dev/null \
  || fail "decision keyword 'stale_log_no_process' missing on stdout; got: $stale_out"
grep -F "DEBUG_AUDIT_WATCHDOG decision=stale_log_no_process" "$TEST_TMP/log/rbok-ordo.log" >/dev/null \
  || fail "audit line missing decision=stale_log_no_process; log: $(cat "$TEST_TMP/log/rbok-ordo.log" 2>/dev/null)"
pass "cli: detects stale_log + no_process (the #541 outage signature)"

# ---------------------------------------------------------------------------
# CLI: no-process detection with a fresh log (process crashed mid-tick).
# ---------------------------------------------------------------------------

fresh_log="$TEST_TMP/log/fresh-but-dead.log"
touch "$fresh_log"
: > "$TEST_TMP/log/rbok-ordo.log"   # reset audit log so we read only this run

set +e
fresh_out=$(
  ORCH_DEBUG_AUDIT_PGREP_OVERRIDE="" run_watchdog "$live_config" \
    --log-path "$fresh_log" --max-age-sec 600 --process-pattern 'sentinel-pattern-no-match' 2>&1
)
fresh_rc=$?
set -e
[[ "$fresh_rc" -eq 0 ]] || fail "no-process-only detection should exit 0; got rc=$fresh_rc"
grep -E '^no_process$' <<<"$fresh_out" >/dev/null \
  || fail "decision keyword 'no_process' missing on stdout; got: $fresh_out"
grep -F "DEBUG_AUDIT_WATCHDOG decision=no_process" "$TEST_TMP/log/rbok-ordo.log" >/dev/null \
  || fail "audit line missing decision=no_process; log: $(cat "$TEST_TMP/log/rbok-ordo.log")"
pass "cli: detects no_process when log is fresh but loop has died"

# ---------------------------------------------------------------------------
# CLI: fresh log + live process => fresh, no relaunch.
# ---------------------------------------------------------------------------

: > "$TEST_TMP/log/rbok-ordo.log"
set +e
ok_out=$(
  ORCH_DEBUG_AUDIT_PGREP_OVERRIDE="12345" run_watchdog "$live_config" \
    --log-path "$fresh_log" --max-age-sec 600 --process-pattern 'sentinel' \
    --relaunch-command "echo should-not-run" 2>&1
)
ok_rc=$?
set -e
[[ "$ok_rc" -eq 0 ]] || fail "fresh state should exit 0; got rc=$ok_rc"
grep -E '^fresh$' <<<"$ok_out" >/dev/null \
  || fail "decision keyword 'fresh' missing on stdout; got: $ok_out"
! grep -F "relaunched" <<<"$ok_out" >/dev/null \
  || fail "fresh state must NOT relaunch; got: $ok_out"
pass "cli: fresh log + alive process is a no-op even with --relaunch-command"

# ---------------------------------------------------------------------------
# CLI: relaunch records all four fields required by #541 AC2.
# ---------------------------------------------------------------------------

: > "$TEST_TMP/log/rbok-ordo.log"
relaunch_log="$TEST_TMP/log/relaunch.log"
touch -d '2026-01-01T00:00:00Z' "$relaunch_log"

set +e
relaunch_out=$(
  ORCH_DEBUG_AUDIT_PGREP_OVERRIDE="42424" run_watchdog "$live_config" \
    --log-path "$relaunch_log" --max-age-sec 60 --process-pattern 'sentinel' \
    --relaunch-command "echo relaunch-marker $(date -u +%s)" 2>&1
)
relaunch_rc=$?
set -e
[[ "$relaunch_rc" -eq 0 ]] || fail "relaunch should exit 0; got rc=$relaunch_rc out=$relaunch_out"
grep -E '^relaunched$' <<<"$relaunch_out" >/dev/null \
  || fail "decision keyword 'relaunched' missing on stdout; got: $relaunch_out"
grep -E '^config_path=.* project=rbok-ordo previous_pid=42424 new_pid=[0-9]+$' <<<"$relaunch_out" >/dev/null \
  || fail "relaunch record missing required fields; got: $relaunch_out"
grep -F "DEBUG_AUDIT_WATCHDOG action=relaunched" "$TEST_TMP/log/rbok-ordo.log" >/dev/null \
  || fail "audit line missing action=relaunched; log: $(cat "$TEST_TMP/log/rbok-ordo.log")"
grep -F "previous_pid=42424" "$TEST_TMP/log/rbok-ordo.log" >/dev/null \
  || fail "audit line missing previous_pid; log: $(cat "$TEST_TMP/log/rbok-ordo.log")"
grep -E "new_pid=[0-9]+" "$TEST_TMP/log/rbok-ordo.log" >/dev/null \
  || fail "audit line missing new_pid; log: $(cat "$TEST_TMP/log/rbok-ordo.log")"
grep -E "config_path=.*live\.config\.sh" "$TEST_TMP/log/rbok-ordo.log" >/dev/null \
  || fail "audit line missing config_path; log: $(cat "$TEST_TMP/log/rbok-ordo.log")"
pass "cli: relaunch records config_path, project, previous_pid, new_pid"

# ---------------------------------------------------------------------------
# CLI: --dry-run emits a `would_relaunch` audit line and the same record
# (with new_pid=DRY-RUN) without spawning any process.
# ---------------------------------------------------------------------------

: > "$TEST_TMP/log/rbok-ordo.log"
# The previous relaunch path appended into $relaunch_log, refreshing its
# mtime. Re-pin it stale so the dry-run reproduces the #541 outage shape.
touch -d '2026-01-01T00:00:00Z' "$relaunch_log"
set +e
dry_out=$(
  ORCH_DEBUG_AUDIT_PGREP_OVERRIDE="" run_watchdog "$live_config" \
    --log-path "$relaunch_log" --max-age-sec 60 --process-pattern 'sentinel' \
    --relaunch-command "echo should-not-actually-run" --dry-run 2>&1
)
dry_rc=$?
set -e
[[ "$dry_rc" -eq 0 ]] || fail "dry-run should exit 0; got rc=$dry_rc"
grep -E '^stale_log_no_process$' <<<"$dry_out" >/dev/null \
  || fail "dry-run should still echo the decision keyword; got: $dry_out"
grep -F "new_pid=DRY-RUN" <<<"$dry_out" >/dev/null \
  || fail "dry-run record should carry new_pid=DRY-RUN; got: $dry_out"
grep -F "DEBUG_AUDIT_WATCHDOG action=would_relaunch" "$TEST_TMP/log/rbok-ordo.log" >/dev/null \
  || fail "dry-run audit line missing action=would_relaunch"
pass "cli: dry-run records would_relaunch without spawning"

printf '\n# all debug_audit_watchdog tests passed\n'
