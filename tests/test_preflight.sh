#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  if [[ -n "${TEST_TMP:-}" && "$TEST_TMP" == /tmp/tmp.* ]]; then
    perl -e '
      my ($root, $self) = @ARGV;
      my @targets;
      for my $f (glob("/proc/[0-9]*/cmdline")) {
        my ($pid) = $f =~ m{/proc/([0-9]+)/cmdline};
        next if !$pid || $pid == $self;
        open my $fh, "<", $f or next;
        local $/;
        my $cmd = <$fh> // "";
        $cmd =~ s/\0/ /g;
        next unless $cmd =~ /\Q$root\E/;
        next unless $cmd =~ m{\bbash\s+\Q$root\E/}
          || $cmd =~ m{\Q$root\E/toolkit/scripts/orch_loop\.sh\b};
        push @targets, $pid;
      }
      if (@targets) {
        kill "TERM", @targets;
        select undef, undef, undef, 0.2;
        kill "KILL", @targets;
      }
    ' "$TEST_TMP" "$$" 2>/dev/null || true
  fi
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$SANITIZED_ROOT/templates" "$SANITIZED_ROOT/examples"

for rel in \
  scripts/orch_manual_session.sh \
  scripts/orch_loop.sh \
  lib/agent_inventory.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/preflight.sh \
  lib/state_persist.sh \
  lib/worktree_helpers.sh \
  lib/monitor_heartbeat.sh \
  templates/orch_briefing.md \
  examples/nomos.config.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

chmod +x "$SANITIZED_ROOT/scripts/orch_loop.sh"
chmod +x "$SANITIZED_ROOT/scripts/orch_manual_session.sh"

run_home="$TEST_TMP/home"
mkdir -p "$run_home"

set +e
guard_output=$(
  PATH="/usr/bin:/bin" \
  HOME="$run_home" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/orch_loop.sh" nomos 2>&1
)
guard_status=$?
set -e

[[ "$guard_status" -ne 0 ]] || fail "orch_loop should refuse daemon startup without explicit confirmation"
[[ "$guard_output" == *"refused to start without an explicit daemon confirmation"* ]] || \
  fail "expected daemon confirmation refusal, got: $guard_output"
[[ "$guard_output" == *"orch_manual_session.sh"* ]] || \
  fail "expected manual session fallback guidance, got: $guard_output"

set +e
preflight_output=$(
  PATH="/usr/bin:/bin" \
  HOME="$run_home" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_DAEMON_CONFIRM="Preflight Test" \
  ORCH_CLI_BIN="__orch_missing_supervisor_cli__" \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/orch_loop.sh" nomos 2>&1
)
status=$?
set -e

[[ "$status" -ne 0 ]] || fail "orch_loop should fail fast when required CLIs are missing"
[[ "$preflight_output" == *"PREFLIGHT FAIL"* ]] || fail "expected PREFLIGHT FAIL audit line, got: $preflight_output"
[[ "$preflight_output" == *"__orch_missing_supervisor_cli__"* ]] || fail "expected missing supervisor CLI in output, got: $preflight_output"

printf 'ok - orch_loop preflight fails fast on missing CLIs\n'
