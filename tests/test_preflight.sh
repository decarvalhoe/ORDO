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

stub_bin="$TEST_TMP/bin"
mkdir -p "$stub_bin" "$TEST_TMP/gh" "$TEST_TMP/supervisor"

cat > "$stub_bin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ORCH_TEST_CODEX_ARGS"
exit 0
SH

cat > "$stub_bin/gh" <<'SH'
#!/usr/bin/env bash
printf '0\n'
SH

cat > "$stub_bin/jq" <<'SH'
#!/usr/bin/env bash
printf '0\n'
SH

cat > "$stub_bin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH

chmod +x "$stub_bin/codex" "$stub_bin/gh" "$stub_bin/jq" "$stub_bin/tmux"

cat > "$TEST_TMP/codex-loop.config.sh" <<EOF
PROJECT="codex-loop"
GH_REPO="example-org/codex-loop"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_PANES=("planner|terminal-a:0.0|$TEST_TMP/planner")
PROJECT_REPO_ROOT="$TEST_TMP/supervisor"
SUPERVISOR_REPO="$TEST_TMP/supervisor"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/%s"
EOF

codex_args_file="$TEST_TMP/codex.args"
set +e
codex_output=$(
  PATH="$stub_bin:/usr/bin:/bin" \
  HOME="$run_home" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_DAEMON_CONFIRM="Codex Exec Test" \
  ORCH_CLI_BIN="$stub_bin/codex" \
  ORCH_TEST_CODEX_ARGS="$codex_args_file" \
  ORCH_MAX_CYCLES=1 \
  ORCH_SIXSIGMA_DISABLED=1 \
  ORCH_MONITOR_HEARTBEAT_DISABLED=1 \
  TK="$SANITIZED_ROOT" \
  bash "$SANITIZED_ROOT/scripts/orch_loop.sh" "$TEST_TMP/codex-loop.config.sh" 2>&1
)
codex_status=$?
set -e

[[ "$codex_status" -eq 0 ]] || fail "codex loop should complete one stubbed cycle, got status=$codex_status output=$codex_output"
[[ -s "$codex_args_file" ]] || fail "stubbed codex was not invoked"

mapfile -t codex_args < "$codex_args_file"
expected_prefix=(
  exec
  --ephemeral
  -C "$TEST_TMP/supervisor"
  -m "gpt-5.5"
  -s "danger-full-access"
  -a "never"
)

for i in "${!expected_prefix[@]}"; do
  [[ "${codex_args[$i]:-}" == "${expected_prefix[$i]}" ]] || \
    fail "expected codex arg $i to be ${expected_prefix[$i]}, got ${codex_args[$i]:-<missing>}; all args: $(tr '\n' ' ' < "$codex_args_file")"
done
grep -q 'ORCH CYCLE 1' "$codex_args_file" || \
  fail "expected codex invocation to contain the task prompt, got: $(tr '\n' ' ' < "$codex_args_file")"

printf 'ok - orch_loop uses non-interactive codex exec for live supervisor cycles\n'
