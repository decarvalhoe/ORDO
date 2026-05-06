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
          || $cmd =~ m{\Q$root\E/(bin/tmux|toolkit/scripts/cli_swap\.sh)\b};
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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/logs"

for rel in \
  scripts/cli_swap.sh \
  lib/audit_log.sh \
  lib/config_resolver.sh \
  lib/config_check.sh \
  lib/tmux_helpers.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done

chmod +x "$SANITIZED_ROOT/scripts/cli_swap.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="cli-swap-test"
GH_REPO="RBOKproject/orchestrator-toolkit"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_SESSION_PREFIX=""
AGENT_WINDOW_INDEX=4
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

cat > "$TEST_TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_TMP/bin/sleep"

cat > "$TEST_TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:-}"
shift || true
printf '%s %s\n' "\$cmd" "\$*" >> "$TEST_TMP/logs/tmux.log"
state_file="$TEST_TMP/tmux-state"
pending_exit_file="$TEST_TMP/tmux-pending-exit"

current_state() {
  cat "\$state_file"
}

case "\$cmd" in
  has-session)
    exit 0
    ;;
  list-panes)
    if [[ -f "$TEST_TMP/tmux-dead" ]]; then
      printf '%s\n' '0: [80x24] %0 (dead)'
    else
      printf '%s\n' '0: [80x24] %0'
    fi
    ;;
  capture-pane)
    case "\$(current_state)" in
      unknown)
        printf '%s\n' 'mystery tui content'
        ;;
      claude2)
        printf '────────────────────\n❯\n────────────────────\n  ? for shortcuts\n'
        ;;
      shell)
        printf '%s\n' 'user@host:~/repo$'
        ;;
      codex)
        printf '%s\n' 'OpenAI Codex (v0.128.0)'
        ;;
    esac
    ;;
  send-keys)
    payload="\$*"
    if [[ "\$payload" == *"/exit"* ]]; then
      touch "\$pending_exit_file"
    elif [[ "\$payload" == *"Enter"* ]] && [[ -f "\$pending_exit_file" ]]; then
      printf '%s' 'shell' > "\$state_file"
      rm -f "\$pending_exit_file"
    fi
    ;;
  respawn-pane)
    printf '%s' 'codex' > "\$state_file"
    rm -f "$TEST_TMP/tmux-dead"
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/tmux"

printf '%s' 'unknown' > "$TEST_TMP/tmux-state"
: > "$TEST_TMP/logs/tmux.log"

set +e
unknown_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/cli_swap.sh" "$TEST_TMP/test.config.sh" claude codex 2>&1
)
unknown_status=$?
set -e

[[ "$unknown_status" -eq 4 ]] || fail "expected exit 4 on unknown CLI, got $unknown_status: $unknown_output"
[[ "$unknown_output" == *"refusing to send keystrokes"* ]] || fail "expected refusal message, got: $unknown_output"
if grep -Eq 'send-keys|respawn-pane' "$TEST_TMP/logs/tmux.log"; then
  fail "unknown CLI path must not send keystrokes or respawn panes"
fi

printf '%s' 'claude2' > "$TEST_TMP/tmux-state"
: > "$TEST_TMP/logs/tmux.log"

set +e
claude_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/cli_swap.sh" "$TEST_TMP/test.config.sh" claude codex --model gpt-5.5 2>&1
)
claude_status=$?
set -e

[[ "$claude_status" -eq 0 ]] || fail "expected Claude 2.x swap to succeed, got $claude_status: $claude_output"
grep -q '/exit' "$TEST_TMP/logs/tmux.log" || fail "expected graceful /exit for Claude 2.x"
grep -q 'respawn-pane' "$TEST_TMP/logs/tmux.log" || fail "expected respawn-pane launch path"
grep -q 'respawn-pane -k -t claude:4' "$TEST_TMP/logs/tmux.log" || fail "expected respawn target to honor AGENT_WINDOW_INDEX"
[[ "$claude_output" == *"status=codex"* ]] || fail "expected final codex audit line, got: $claude_output"

printf '%s' 'claude2' > "$TEST_TMP/tmux-state"
: > "$TEST_TMP/logs/tmux.log"

set +e
auto_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/cli_swap.sh" "$TEST_TMP/test.config.sh" claude auto 2>&1
)
auto_status=$?
set -e

[[ "$auto_status" -eq 0 ]] || fail "expected auto CLI swap to succeed, got $auto_status: $auto_output"
grep -q 'respawn-pane -k -t claude:4 .*exec codex -m gpt-5.5 --dangerously-bypass-approvals-and-sandbox' "$TEST_TMP/logs/tmux.log" || \
  fail "expected auto target to relaunch codex from Claude"

printf 'ok - cli_swap detects Claude 2.x and refuses unknown panes\n'
