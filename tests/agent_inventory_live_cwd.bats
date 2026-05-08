#!/usr/bin/env bats

load './helpers.bash'

setup() {
  setup_orch_test

  toolkit_file lib/agent_inventory.sh >/dev/null
  toolkit_file lib/process_safety.sh >/dev/null
  toolkit_file lib/tmux_helpers.sh >/dev/null

  unset AGENTS AGENT_PANES AGENT_REPO_PREFIX AGENT_SESSION_PREFIX
  unset AGENT_WORKDIR_TEMPLATE AGENT_WINDOW_INDEX

  AGENT_PANES=(
    "planner|term-a:0.0|$BATS_TEST_TMPDIR/work/planner"
    "builder|term-b:0.0|$BATS_TEST_TMPDIR/work/builder"
    "reviewer|term-c:0.0|$BATS_TEST_TMPDIR/work/reviewer"
  )
  export AGENT_PANES
  mkdir -p "$BATS_TEST_TMPDIR/work/planner" \
           "$BATS_TEST_TMPDIR/work/builder" \
           "$BATS_TEST_TMPDIR/work/reviewer"

  # shellcheck disable=SC1090
  source "$SANITIZED_TK/lib/tmux_helpers.sh"
}

teardown() {
  unset -f tmux 2>/dev/null || true
  unset TMUX_CWD_MAP TMUX_FAIL_PANES
  rm -rf "$BATS_TEST_TMPDIR"
}

# Drive the helper deterministically by overriding `tmux` as a shell
# function. `tmux_run_timeout` already prefers a declared `tmux` function
# over the binary, so the override flows through `tmux_pane_current_path`.
install_tmux_mock() {
  TMUX_CWD_MAP=$(mktemp)
  TMUX_FAIL_PANES=$(mktemp)
  : > "$TMUX_CWD_MAP"
  : > "$TMUX_FAIL_PANES"
  export TMUX_CWD_MAP TMUX_FAIL_PANES

  tmux() {
    if [[ "$1" == "display-message" ]]; then
      local pane="" fmt=""
      shift
      while (( $# )); do
        case "$1" in
          -t) pane=$2; shift 2 ;;
          -p) shift ;;
          '#{pane_current_path}') fmt='current_path'; shift ;;
          *) shift ;;
        esac
      done
      while IFS=$'\t' read -r fail_pane; do
        [[ "$fail_pane" == "$pane" ]] && return 1
      done < "$TMUX_FAIL_PANES"
      if [[ "$fmt" == "current_path" ]]; then
        local found="" key val
        while IFS=$'\t' read -r key val; do
          if [[ "$key" == "$pane" ]]; then
            found=$val
            break
          fi
        done < "$TMUX_CWD_MAP"
        if [[ -n "$found" ]]; then
          printf '%s\n' "$found"
          return 0
        fi
        return 0
      fi
    fi
    return 0
  }
  export -f tmux
}

set_pane_cwd() {
  local pane=$1 cwd=$2
  printf '%s\t%s\n' "$pane" "$cwd" >> "$TMUX_CWD_MAP"
}

mark_pane_unreachable() {
  local pane=$1
  printf '%s\n' "$pane" >> "$TMUX_FAIL_PANES"
}

@test "agent_inventory_entries_with_live_cwd reports match=true when live cwd equals assigned workdir" {
  install_tmux_mock
  set_pane_cwd "term-a:0.0" "$BATS_TEST_TMPDIR/work/planner"
  set_pane_cwd "term-b:0.0" "$BATS_TEST_TMPDIR/work/builder"
  set_pane_cwd "term-c:0.0" "$BATS_TEST_TMPDIR/work/reviewer"

  run agent_inventory_entries_with_live_cwd
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == "planner|term-a:0.0|$BATS_TEST_TMPDIR/work/planner|$BATS_TEST_TMPDIR/work/planner|true" ]]
  [[ "${lines[1]}" == "builder|term-b:0.0|$BATS_TEST_TMPDIR/work/builder|$BATS_TEST_TMPDIR/work/builder|true" ]]
  [[ "${lines[2]}" == "reviewer|term-c:0.0|$BATS_TEST_TMPDIR/work/reviewer|$BATS_TEST_TMPDIR/work/reviewer|true" ]]
}

@test "agent_inventory_entries_with_live_cwd reports match=false when live cwd diverges from assigned" {
  install_tmux_mock
  set_pane_cwd "term-a:0.0" "$BATS_TEST_TMPDIR/work/planner"
  set_pane_cwd "term-b:0.0" "/wrong/path"
  set_pane_cwd "term-c:0.0" "$BATS_TEST_TMPDIR/work/reviewer"

  run agent_inventory_entries_with_live_cwd
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"|true" ]]
  [[ "${lines[1]}" == "builder|term-b:0.0|$BATS_TEST_TMPDIR/work/builder|/wrong/path|false" ]]
  [[ "${lines[2]}" == *"|true" ]]
}

@test "agent_inventory_entries_with_live_cwd reports match=unknown when tmux cannot introspect the pane" {
  install_tmux_mock
  set_pane_cwd "term-a:0.0" "$BATS_TEST_TMPDIR/work/planner"
  mark_pane_unreachable "term-b:0.0"
  set_pane_cwd "term-c:0.0" "$BATS_TEST_TMPDIR/work/reviewer"

  run agent_inventory_entries_with_live_cwd
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"|true" ]]
  [[ "${lines[1]}" == "builder|term-b:0.0|$BATS_TEST_TMPDIR/work/builder||unknown" ]]
  [[ "${lines[2]}" == *"|true" ]]
}

@test "agent_inventory_entries_with_live_cwd treats empty pane_current_path as unknown" {
  install_tmux_mock
  set_pane_cwd "term-a:0.0" "$BATS_TEST_TMPDIR/work/planner"
  # term-b:0.0 is intentionally not added; the mock returns empty for it.
  set_pane_cwd "term-c:0.0" "$BATS_TEST_TMPDIR/work/reviewer"

  run agent_inventory_entries_with_live_cwd
  [ "$status" -eq 0 ]
  [[ "${lines[1]}" == "builder|term-b:0.0|$BATS_TEST_TMPDIR/work/builder||unknown" ]]
}

@test "agent_inventory_entries_with_live_cwd preserves the existing entries API output" {
  install_tmux_mock
  set_pane_cwd "term-a:0.0" "$BATS_TEST_TMPDIR/work/planner"
  set_pane_cwd "term-b:0.0" "$BATS_TEST_TMPDIR/work/builder"
  set_pane_cwd "term-c:0.0" "$BATS_TEST_TMPDIR/work/reviewer"

  run agent_inventory_entries
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == "planner|term-a:0.0|$BATS_TEST_TMPDIR/work/planner" ]]

  local entries_line live_line
  entries_line=$(agent_inventory_entries | head -n1)
  live_line=$(agent_inventory_entries_with_live_cwd | head -n1)

  local entries_fields live_fields
  entries_fields=$(awk -F '|' '{print NF}' <<< "$entries_line")
  live_fields=$(awk -F '|' '{print NF}' <<< "$live_line")
  [[ "$entries_fields" -eq 3 ]]
  [[ "$live_fields" -eq 5 ]]
}

@test "agent_inventory_entries_with_live_cwd works with legacy AGENTS configuration" {
  install_tmux_mock
  unset AGENT_PANES
  AGENTS=(planner builder)
  AGENT_REPO_PREFIX="$BATS_TEST_TMPDIR/work/legacy-"
  AGENT_SESSION_PREFIX="leg-"
  AGENT_WINDOW_INDEX="2"
  export AGENTS AGENT_REPO_PREFIX AGENT_SESSION_PREFIX AGENT_WINDOW_INDEX

  mkdir -p "$BATS_TEST_TMPDIR/work/legacy-planner" \
           "$BATS_TEST_TMPDIR/work/legacy-builder"
  set_pane_cwd "leg-planner:2.0" "$BATS_TEST_TMPDIR/work/legacy-planner"
  set_pane_cwd "leg-builder:2.0" "/elsewhere"

  run agent_inventory_entries_with_live_cwd
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "planner|leg-planner:2.0|$BATS_TEST_TMPDIR/work/legacy-planner|$BATS_TEST_TMPDIR/work/legacy-planner|true" ]]
  [[ "${lines[1]}" == "builder|leg-builder:2.0|$BATS_TEST_TMPDIR/work/legacy-builder|/elsewhere|false" ]]
}

@test "tmux_pane_current_path returns 1 and prints nothing when the pane is unreachable" {
  install_tmux_mock
  mark_pane_unreachable "term-x:0.0"

  run tmux_pane_current_path "term-x:0.0"
  [ "$status" -eq 1 ]
  [ -z "${output:-}" ]
}

@test "tmux_pane_current_path echoes the live current_path when introspection succeeds" {
  install_tmux_mock
  set_pane_cwd "term-y:0.0" "/some/live/path"

  run tmux_pane_current_path "term-y:0.0"
  [ "$status" -eq 0 ]
  [[ "$output" == "/some/live/path" ]]
}
