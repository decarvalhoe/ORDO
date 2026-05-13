#!/usr/bin/env bash
# tests/test_codex_config_preflight.sh — exercise the Codex runtime-config
# preflight that gates supervisor start (Issue #667).
#
# Covers the validator library directly (unit) and the orch_loop boot path
# (integration). The integration cases use the same sanitized-toolkit
# pattern as test_preflight.sh so the runner can mirror them into the
# shell-test sandbox without dragging in unrelated libs.
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

# --- Unit tests against the validator library directly ------------------

unit_run() {
  local label=$1
  shift
  local out
  set +e
  out=$(bash -c '
    set -u
    audit() { :; }
    die() { printf "DIE: %s\n" "$*" >&2; exit 1; }
    source "$1"
    shift
    codex_config_preflight "$@"
  ' _ "$ROOT/lib/codex_config_preflight.sh" "$@" 2>&1)
  local rc=$?
  set -e
  printf '%s\n' "$out" > "$TEST_TMP/$label.out"
  printf '%s' "$rc"
}

valid_rc=$(unit_run "valid_xhigh_unquoted" "gpt-5.5" "xhigh" "never" "danger-full-access")
[[ "$valid_rc" -eq 0 ]] || fail "valid xhigh unquoted should pass, rc=$valid_rc out=$(cat "$TEST_TMP/valid_xhigh_unquoted.out")"

for variant in none minimal low medium high xhigh; do
  rc=$(unit_run "valid_${variant}" "gpt-5.5" "$variant" "never" "danger-full-access")
  [[ "$rc" -eq 0 ]] || fail "valid reasoning variant $variant should pass, rc=$rc out=$(cat "$TEST_TMP/valid_${variant}.out")"
done

# Quoted reasoning effort — the canonical failure mode from issue #667.
rc=$(unit_run "quoted_single_xhigh" "gpt-5.5" "'xhigh'" "never" "danger-full-access")
[[ "$rc" -ne 0 ]] || fail "single-quoted xhigh must be rejected, out=$(cat "$TEST_TMP/quoted_single_xhigh.out")"
grep -q 'codex config field=model_reasoning_effort' "$TEST_TMP/quoted_single_xhigh.out" || \
  fail "rejection diagnostic should name the field, got: $(cat "$TEST_TMP/quoted_single_xhigh.out")"
grep -q 'literal quote characters' "$TEST_TMP/quoted_single_xhigh.out" || \
  fail "rejection diagnostic should mention literal quotes, got: $(cat "$TEST_TMP/quoted_single_xhigh.out")"

rc=$(unit_run "quoted_double_xhigh" "gpt-5.5" '"xhigh"' "never" "danger-full-access")
[[ "$rc" -ne 0 ]] || fail "double-quoted xhigh must be rejected, out=$(cat "$TEST_TMP/quoted_double_xhigh.out")"

# Embedded quote in middle of value — still invalid because Codex consumes
# the literal characters.
rc=$(unit_run "embedded_quote" "gpt-5.5" "xh'igh" "never" "danger-full-access")
[[ "$rc" -ne 0 ]] || fail "embedded quote must be rejected, out=$(cat "$TEST_TMP/embedded_quote.out")"

# Unsupported variant.
rc=$(unit_run "unsupported_variant" "gpt-5.5" "ultra" "never" "danger-full-access")
[[ "$rc" -ne 0 ]] || fail "unsupported reasoning variant must be rejected, out=$(cat "$TEST_TMP/unsupported_variant.out")"
grep -q 'value=ultra' "$TEST_TMP/unsupported_variant.out" || \
  fail "unsupported diagnostic should echo the bad value, got: $(cat "$TEST_TMP/unsupported_variant.out")"

# Whitespace value (e.g. trailing space from a config typo).
rc=$(unit_run "whitespace_value" "gpt-5.5" "xhigh " "never" "danger-full-access")
[[ "$rc" -ne 0 ]] || fail "whitespace in reasoning effort must be rejected"

# Empty reasoning is allowed — the field is optional.
rc=$(unit_run "empty_reasoning" "gpt-5.5" "" "never" "danger-full-access")
[[ "$rc" -eq 0 ]] || fail "empty reasoning effort should be accepted (field is optional)"

# Invalid approval and sandbox values are also caught.
rc=$(unit_run "bad_approval" "gpt-5.5" "xhigh" "yolo" "danger-full-access")
[[ "$rc" -ne 0 ]] || fail "invalid approval value must be rejected"
grep -q 'field=approval' "$TEST_TMP/bad_approval.out" || \
  fail "approval diagnostic should name the field"

rc=$(unit_run "bad_sandbox" "gpt-5.5" "xhigh" "never" "wide-open")
[[ "$rc" -ne 0 ]] || fail "invalid sandbox value must be rejected"
grep -q 'field=sandbox' "$TEST_TMP/bad_sandbox.out" || \
  fail "sandbox diagnostic should name the field"

# Empty model is rejected (model is required when codex is the supervisor).
rc=$(unit_run "empty_model" "" "xhigh" "never" "danger-full-access")
[[ "$rc" -ne 0 ]] || fail "empty model must be rejected"

# Redacted summary helper is callable and includes the resolved values.
summary=$(bash -c '
  source "$1"
  codex_config_render_redacted "gpt-5.5" "xhigh" "never" "danger-full-access"
' _ "$ROOT/lib/codex_config_preflight.sh")
[[ "$summary" == *"model=gpt-5.5"* ]] || fail "redacted summary should include model, got: $summary"
[[ "$summary" == *"model_reasoning_effort=xhigh"* ]] || fail "redacted summary should include reasoning, got: $summary"

printf 'ok - codex_config_preflight unit checks (valid xhigh, rejects quoted/unsupported/whitespace)\n'

# --- Integration: orch_loop refuses to boot on bad codex config ---------

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$SANITIZED_ROOT/templates" "$SANITIZED_ROOT/examples"

for rel in \
  scripts/orch_loop.sh \
  scripts/orch_manual_session.sh \
  lib/agent_inventory.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/process_safety.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/preflight.sh \
  lib/codex_config_preflight.sh \
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

run_orch_loop() {
  # `env -i` clears the parent shell's env so ambient TMUX/USER/etc. don't
  # divert the loop into interactive paths. </dev/null because the
  # supervisor cycle inherits stdin from the caller's TTY and can stall
  # on it; the production daemon runs detached.
  env -i \
    PATH="$stub_bin:/usr/bin:/bin" \
    HOME="$run_home" \
    ORCH_LOG_DIR="$TEST_TMP/logs" \
    ORCH_STATE_BASE="$TEST_TMP/state" \
    ORCH_DAEMON_CONFIRM="Codex Preflight Test" \
    ORCH_CLI_BIN="$stub_bin/codex" \
    ORCH_MAX_CYCLES=1 \
    ORCH_SIXSIGMA_DISABLED=1 \
    ORCH_MONITOR_HEARTBEAT_DISABLED=1 \
    TK="$SANITIZED_ROOT" \
    "$@" \
    bash "$SANITIZED_ROOT/scripts/orch_loop.sh" "$TEST_TMP/codex-loop.config.sh" </dev/null
}

bad_args_file="$TEST_TMP/bad-codex.args"
set +e
bad_output=$(
  run_orch_loop \
    "ORCH_CODEX_REASONING='xhigh'" \
    "ORCH_TEST_CODEX_ARGS=$bad_args_file" \
  2>&1
)
bad_status=$?
set -e

[[ "$bad_status" -ne 0 ]] || fail "orch_loop should refuse to boot with a quoted codex reasoning effort"
[[ "$bad_output" == *"CODEX_CONFIG_PREFLIGHT FAIL"* ]] || \
  fail "expected CODEX_CONFIG_PREFLIGHT FAIL audit line, got: $bad_output"
[[ "$bad_output" == *"model_reasoning_effort"* ]] || \
  fail "diagnostic should name the failing field, got: $bad_output"
[[ ! -e "$bad_args_file" ]] || fail "codex must not be spawned after preflight failure"

printf 'ok - orch_loop fails fast on quoted codex reasoning effort\n'

ok_args_file="$TEST_TMP/ok-codex.args"
set +e
ok_output=$(
  run_orch_loop \
    "ORCH_CODEX_REASONING=xhigh" \
    "ORCH_TEST_CODEX_ARGS=$ok_args_file" \
  2>&1
)
ok_status=$?
set -e

[[ "$ok_status" -eq 0 ]] || fail "orch_loop should accept bare xhigh, got status=$ok_status output=$ok_output"
[[ -s "$ok_args_file" ]] || fail "stubbed codex should have been invoked"
grep -qx -- '-c' "$ok_args_file" || \
  fail "expected -c flag to be passed to codex when reasoning is set, got args: $(tr '\n' ' ' < "$ok_args_file")"
grep -qx 'model_reasoning_effort=xhigh' "$ok_args_file" || \
  fail "expected bare 'model_reasoning_effort=xhigh' (no embedded quotes), got args: $(tr '\n' ' ' < "$ok_args_file")"
[[ "$ok_output" == *"CODEX_CONFIG_PREFLIGHT OK"* ]] || \
  fail "expected success audit line, got: $ok_output"
[[ "$ok_output" == *"model_reasoning_effort=xhigh"* ]] || \
  fail "boot audit should record the resolved reasoning value, got: $ok_output"

printf 'ok - orch_loop passes bare xhigh through as model_reasoning_effort\n'

bad_approval_args="$TEST_TMP/bad-approval.args"
set +e
bad_approval_output=$(
  run_orch_loop \
    "ORCH_CODEX_APPROVAL=yolo" \
    "ORCH_TEST_CODEX_ARGS=$bad_approval_args" \
  2>&1
)
bad_approval_status=$?
set -e

[[ "$bad_approval_status" -ne 0 ]] || fail "orch_loop should refuse an unsupported codex approval mode"
[[ "$bad_approval_output" == *"field=approval"* ]] || \
  fail "diagnostic should name approval field, got: $bad_approval_output"
[[ ! -e "$bad_approval_args" ]] || fail "codex must not be spawned after approval preflight failure"

printf 'ok - orch_loop refuses unsupported codex approval mode\n'
