#!/usr/bin/env bats
#
# Issue #322: agent_pool_status used to issue one tmux display-message
# per pane variable (command, then path). On a slow tmux server this
# added latency that scaled with fleet size and risked tmux timeouts.
# These bats cover the batched-read regression: agent_pool_status must
# do exactly one display-message call per agent for command + path,
# and the lib helper must round-trip the same fields in one call.

load ./helpers.bash

setup() {
  setup_orch_test
  TMUX_CALL_LOG="$BATS_TEST_TMPDIR/tmux-calls.log"
  export TMUX_CALL_LOG
  : > "$TMUX_CALL_LOG"

  # Mock tmux that logs every invocation so the test can count
  # display-message calls directly. Honors the batched format
  # (#{pane_current_command}<US>#{pane_current_path}) plus the legacy
  # single-format calls so any leftover non-batched caller is visible
  # in the log.
  cat > "$TEST_BIN_DIR/tmux" <<'TMUX_EOF'
#!/bin/sh
log=${TMUX_CALL_LOG:-/dev/null}
printf '%s\n' "$*" >> "$log"
case "$1" in
  has-session) exit 0 ;;
  list-panes)  exit 0 ;;
  display-message)
    fmt=""
    batched=0
    for arg in "$@"; do
      case "$arg" in
        *'#{pane_current_command}'*'#{pane_current_path}'*)
          batched=1
          ;;
        '#{pane_current_path}'|'#{pane_current_command}')
          fmt=$arg
          ;;
      esac
    done
    if [ "$batched" = "1" ]; then
      # \037 == ASCII US (0x1f). Use octal so /bin/sh printf honors it
      # on hosts where the shell is dash and "\x1f" is interpreted as
      # the literal six bytes \, x, 1, f.
      printf 'claude\037/repos/agent-one\n'
    elif [ "$fmt" = '#{pane_current_path}' ]; then
      printf '/repos/agent-one\n'
    elif [ "$fmt" = '#{pane_current_command}' ]; then
      printf 'claude\n'
    fi
    exit 0
    ;;
esac
exit 0
TMUX_EOF
  chmod +x "$TEST_BIN_DIR/tmux"

  # Mock gh: empty PR list keeps agent_pool_status focused on the tmux
  # path being measured.
  cat > "$TEST_BIN_DIR/gh" <<'GH_EOF'
#!/bin/sh
case "$*" in
  *"pr list"*) printf '[]\n' ;;
  *)            printf '{}\n' ;;
esac
exit 0
GH_EOF
  chmod +x "$TEST_BIN_DIR/gh"

  AGENT_REPO="$BATS_TEST_TMPDIR/repos/agent-one"
  mkdir -p "$AGENT_REPO"
  git -C "$AGENT_REPO" init -q
  git -C "$AGENT_REPO" config user.email t@t.local
  git -C "$AGENT_REPO" config user.name "t"
  printf 'one\n' > "$AGENT_REPO/file.txt"
  git -C "$AGENT_REPO" add file.txt
  git -C "$AGENT_REPO" commit -q -m "seed"
  export AGENT_REPO

  CONFIG="$BATS_TEST_TMPDIR/project.config.sh"
  cat > "$CONFIG" <<EOF
#!/usr/bin/env bash
PROJECT="$PROJECT"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$GH_CONFIG_DIR"
AGENT_PANES=(
  "agent-one|agent-one:0.0|$AGENT_REPO"
)
export AGENT_WORKDIR_TEMPLATE="$BATS_TEST_TMPDIR/work/%s"
EOF
  export CONFIG

  toolkit_file scripts/agent_pool_status.sh >/dev/null
  toolkit_file lib/agent_inventory.sh        >/dev/null
  toolkit_file lib/config_resolver.sh        >/dev/null
  toolkit_file lib/dispatch_capacity.sh      >/dev/null
  toolkit_file lib/process_safety.sh         >/dev/null
  toolkit_file lib/tmux_helpers.sh           >/dev/null
  toolkit_file lib/worktree_helpers.sh       >/dev/null
  chmod +x "$SANITIZED_TK/scripts/agent_pool_status.sh"
}

@test "agent_pool_status issues exactly one display-message per agent" {
  run bash "$SANITIZED_TK/scripts/agent_pool_status.sh" "$CONFIG" --tsv
  [ "$status" -eq 0 ]

  # Exactly one display-message line per agent (one agent in this fleet).
  display_count=$(grep -c '^display-message' "$TMUX_CALL_LOG" || true)
  [ "$display_count" -eq 1 ]

  # No legacy single-field invocations should remain.
  legacy_count=$(grep -cE "display-message.*'#\{pane_current_command\}'$|display-message.*'#\{pane_current_path\}'$" \
    "$TMUX_CALL_LOG" || true)
  [ "$legacy_count" -eq 0 ]

  # The single call must request both fields together.
  combined_count=$(grep -cE "display-message.*pane_current_command.*pane_current_path" "$TMUX_CALL_LOG" || true)
  [ "$combined_count" -eq 1 ]
}

@test "tmux_pane_values_batch returns command and path from one tmux call" {
  : > "$TMUX_CALL_LOG"
  run bash -c "$(orch_env_exports)
    source '$SANITIZED_TK/lib/tmux_helpers.sh'
    cmd_var=''
    path_var=''
    tmux_pane_values_batch agent-one:0.0 cmd_var path_var 5
    printf 'cmd=%s\npath=%s\n' \"\$cmd_var\" \"\$path_var\""

  [ "$status" -eq 0 ]
  [[ "$output" == *"cmd=claude"* ]]
  [[ "$output" == *"path=/repos/agent-one"* ]]

  # Single display-message call.
  display_count=$(grep -c '^display-message' "$TMUX_CALL_LOG" || true)
  [ "$display_count" -eq 1 ]
}

@test "tmux_pane_values_batch tolerates missing separator (very old tmux)" {
  : > "$TMUX_CALL_LOG"
  # Replace the mock tmux to drop the literal US byte the way an old
  # tmux would: emit only the command portion of the format string.
  cat > "$TEST_BIN_DIR/tmux" <<'TMUX_EOF'
#!/bin/sh
log=${TMUX_CALL_LOG:-/dev/null}
printf '%s\n' "$*" >> "$log"
case "$1" in
  display-message) printf 'claude\n'; exit 0 ;;
esac
exit 0
TMUX_EOF
  chmod +x "$TEST_BIN_DIR/tmux"

  run bash -c "$(orch_env_exports)
    source '$SANITIZED_TK/lib/tmux_helpers.sh'
    cmd_var=''
    path_var=''
    tmux_pane_values_batch agent-one:0.0 cmd_var path_var 5
    printf 'cmd=%s\npath=%s\n' \"\$cmd_var\" \"\$path_var\""

  [ "$status" -eq 0 ]
  # Without a separator the command captures everything; path stays empty
  # rather than mirroring the command, which keeps callers from acting on
  # a stale or duplicated value.
  [[ "$output" == *"cmd=claude"* ]]
  [[ "$output" == *"path="* ]]
  [[ "$output" != *"path=claude"* ]]
}
