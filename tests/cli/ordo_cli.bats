#!/usr/bin/env bats

# tests/cli/ordo_cli.bats — coverage for the unified `ordo` CLI
# (scripts/ordo.sh + lib/ordo_cli.sh; epic #806, child #809).
#
# Routed commands are exercised against stub scripts placed in a temporary
# directory selected through ORDO_CLI_SCRIPT_DIR, so the suite never needs
# tmux, a provider CLI, or a real project profile. Each stub prints its own
# name and every argument it received, writes one line to stderr, and exits
# with $STUB_EXIT (default 0) so routing, argument passthrough, the --json
# wrapper, and exit-code propagation can all be asserted.

bats_require_minimum_version 1.5.0

load '../helpers.bash'

ROUTED_STUBS=(
  agent_pool_status.sh
  orch_ctl.sh
  portfolio_status.sh
  dispatch_plan.sh
  dispatch_ticket.sh
  dispatch_wave.sh
  smart_poll_agents.sh
  pr_block_signals.sh
  recover.sh
  pr_merge_wave.sh
  portfolio_auto_merge.sh
)

setup() {
  setup_orch_test
  TK="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export TK
  ORDO="$TK/scripts/ordo.sh"
  export ORDO
  STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUB_DIR"
  local name
  for name in "${ROUTED_STUBS[@]}"; do
    write_stub "$name"
  done
  export ORDO_CLI_SCRIPT_DIR="$STUB_DIR"
  unset ORDO_PROJECT_PROFILE
  export ORDO_CLI_NO_CONTRACTS=1
}

write_stub() {
  local name=$1
  cat > "$STUB_DIR/$name" <<EOF
#!/usr/bin/env bash
# $name — stub routing target for tests/cli/ordo_cli.bats
#
# Usage:
#   $name <stub-args>
set -euo pipefail
printf 'stub=%s\n' "$name"
for arg in "\$@"; do
  printf 'arg=%s\n' "\$arg"
done
printf 'stub-stderr %s\n' "$name" >&2
exit "\${STUB_EXIT:-0}"
EOF
  chmod +x "$STUB_DIR/$name"
}

# --- registry -------------------------------------------------------------

@test "registry lists the nine stable commands plus help, version, completion" {
  run bash -c "source '$TK/lib/ordo_cli.sh' && ordo_cli_commands"
  [ "$status" -eq 0 ]
  local cmd
  for cmd in status plan dispatch watch resume approve cancel recover merge help version completion; do
    grep -qx "$cmd" <<<"$output" || { echo "missing command: $cmd"; false; }
  done
}

@test "registry rows map every routed command to an existing script in scripts/" {
  run bash -c "source '$TK/lib/ordo_cli.sh' && ordo_cli_registry"
  [ "$status" -eq 0 ]
  local line name variant state script
  while IFS=$'\t' read -r name variant state script _; do
    [ "$state" = "routed" ] || continue
    [ -f "$TK/scripts/$script" ] || { echo "routed target missing: $name $variant -> $script"; false; }
  done <<<"$output"
}

@test "registry JSON exposes command, target, json_mode and planned children" {
  run bash "$ORDO" help --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e 'type == "array"' >/dev/null
  echo "$output" | jq -e '.[] | select(.command == "resume") | .status == "planned:#810"' >/dev/null
  echo "$output" | jq -e '.[] | select(.command == "approve") | .status == "planned:#812"' >/dev/null
  echo "$output" | jq -e '.[] | select(.command == "status" and .variant == null) | .json_mode == "passthrough"' >/dev/null
  echo "$output" | jq -e '.[] | select(.command == "status" and .variant == "--loop") | .post_args == ["status"]' >/dev/null
}

# --- help / version / completion -------------------------------------------

@test "help lists every command with a one-line description and routing target" {
  run bash "$ORDO" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"ordo <command> [--json] [args...]"* ]]
  [[ "$output" == *"scripts/agent_pool_status.sh"* ]]
  [[ "$output" == *"status --loop"*"scripts/orch_ctl.sh <args> status"* ]]
  [[ "$output" == *"dispatch --wave"*"scripts/dispatch_wave.sh"* ]]
  [[ "$output" == *"merge --portfolio"*"scripts/portfolio_auto_merge.sh"* ]]
  [[ "$output" == *"resume"*"not implemented yet (#810)"* ]]
  [[ "$output" == *"approve"*"not implemented yet (#812)"* ]]
  [[ "$output" == *"completion"*"native"* ]]
}

@test "help <cmd> shows the underlying script usage banner" {
  run bash "$ORDO" help plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"routes to: scripts/dispatch_plan.sh"* ]]
  [[ "$output" == *"first argument: <project>"* ]]
  [[ "$output" == *"--- usage of scripts/dispatch_plan.sh ---"* ]]
  [[ "$output" == *"dispatch_plan.sh <stub-args>"* ]]
}

@test "help <cmd> against the real scripts prints the real usage banner" {
  unset ORDO_CLI_SCRIPT_DIR
  run bash "$ORDO" help plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatch_plan.sh <project_short|config_path>"* ]]
  run bash "$ORDO" dispatch --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatch_ticket.sh <project_short|config_path> <agent> <ticket_number> <prompt_file>"* ]]
}

@test "help <cmd> <variant> shows the variant's target and lists sibling variants" {
  run bash "$ORDO" help status --loop
  [ "$status" -eq 0 ]
  [[ "$output" == *"ordo status --loop"* ]]
  [[ "$output" == *"routes to: scripts/orch_ctl.sh <args> status"* ]]
  [[ "$output" == *"variant: ordo status --portfolio"* ]]
  [[ "$output" == *"variant: ordo status  (ordo help status)"* ]]
  [[ "$output" == *"orch_ctl.sh <stub-args>"* ]]
}

@test "<cmd> --help is equivalent to help <cmd>" {
  run bash "$ORDO" merge --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"routes to: scripts/pr_merge_wave.sh"* ]]
  run bash "$ORDO" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Commands (routing target"* ]]
}

@test "help for a planned command explains which child implements it" {
  run bash "$ORDO" resume --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"not implemented yet (#810)"* ]]
  [[ "$output" == *"child #810 of epic #806"* ]]
  run bash "$ORDO" help approve
  [ "$status" -eq 0 ]
  [[ "$output" == *"child #812 of epic #806"* ]]
}

@test "help for an unknown command exits 2 with a structured error" {
  run --separate-stderr bash "$ORDO" help bogus
  [ "$status" -eq 2 ]
  echo "$stderr" | jq -e '.error.code == "unknown_command" and .error.module == "cli"' >/dev/null
}

@test "version prints a version line and JSON in --json mode" {
  run bash "$ORDO" version
  [ "$status" -eq 0 ]
  [[ "$output" == ordo\ * ]]
  run bash "$ORDO" version --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.version | length > 0' >/dev/null
}

@test "completion bash prints a script that completes command names" {
  run bash "$ORDO" completion bash
  [ "$status" -eq 0 ]
  [[ "$output" == *"_ordo_complete()"* ]]
  [[ "$output" == *"complete -o default -F _ordo_complete ordo ordo.sh"* ]]
  local script="$BATS_TEST_TMPDIR/completion.bash"
  printf '%s\n' "$output" > "$script"
  run bash -c "source '$script'; COMP_WORDS=(ordo st); COMP_CWORD=1; _ordo_complete; printf '%s\n' \"\${COMPREPLY[@]}\""
  [ "$status" -eq 0 ]
  [ "$output" = "status" ]
  run bash -c "source '$script'; COMP_WORDS=(ordo status --); COMP_CWORD=2; _ordo_complete; printf '%s\n' \"\${COMPREPLY[@]}\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"--loop"* ]]
  [[ "$output" == *"--portfolio"* ]]
  [[ "$output" == *"--json"* ]]
}

@test "completion for an unsupported shell exits 2 with a structured error" {
  run --separate-stderr bash "$ORDO" completion fish
  [ "$status" -eq 2 ]
  echo "$stderr" | jq -e '.error.code == "usage"' >/dev/null
}

# --- errors ---------------------------------------------------------------

@test "unknown command exits 2 with a JSON error object on stderr" {
  run --separate-stderr bash "$ORDO" frobnicate proj
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  echo "$stderr" | jq -e '.error.code == "unknown_command"' >/dev/null
  echo "$stderr" | jq -e '.error.module == "cli"' >/dev/null
  echo "$stderr" | jq -e '.error.details.command == "frobnicate"' >/dev/null
  echo "$stderr" | jq -e '.error.message | test("frobnicate")' >/dev/null
}

@test "no command exits 2 with usage on stderr and a JSON error object" {
  run --separate-stderr bash "$ORDO"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"Commands (routing target"* ]]
  echo "$stderr" | tail -n1 | jq -e '.error.code == "usage"' >/dev/null
}

@test "planned commands (resume, cancel, approve) exit 6 with not_implemented errors" {
  local cmd child
  for cmd in resume cancel approve; do
    case "$cmd" in
      approve) child="#812" ;;
      *) child="#810" ;;
    esac
    run --separate-stderr bash "$ORDO" "$cmd" run_0123456789abcdef01234567
    [ "$status" -eq 6 ]
    [ -z "$output" ]
    echo "$stderr" | jq -e '.error.code == "not_implemented"' >/dev/null
    echo "$stderr" | jq -e --arg c "$child" '.error.details.implemented_by == $c' >/dev/null
    echo "$stderr" | jq -e --arg c "$child" '.error.message | test($c)' >/dev/null
  done
}

@test "missing project context exits 2 with a helpful missing_project error" {
  run --separate-stderr bash "$ORDO" status
  [ "$status" -eq 2 ]
  echo "$stderr" | jq -e '.error.code == "missing_project"' >/dev/null
  echo "$stderr" | jq -e '.error.message | test("ORDO_PROJECT_PROFILE")' >/dev/null
  echo "$stderr" | jq -e '.error.details.hint == "ordo help status"' >/dev/null
  run --separate-stderr bash "$ORDO" plan --ready-only --json
  [ "$status" -eq 2 ]
  echo "$stderr" | jq -e '.error.code == "missing_project"' >/dev/null
}

@test "ORDO_PROJECT_PROFILE supplies the project when it is omitted" {
  export ORDO_PROJECT_PROFILE="examples/ordo.config.sh"
  run bash "$ORDO" plan --ready-only
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "stub=dispatch_plan.sh" ]
  [ "${lines[1]}" = "arg=examples/ordo.config.sh" ]
  [ "${lines[2]}" = "arg=--ready-only" ]
}

@test "missing routing target exits 6 with target_missing" {
  rm -f "$STUB_DIR/recover.sh"
  run --separate-stderr bash "$ORDO" recover proj fleet-001
  [ "$status" -eq 6 ]
  echo "$stderr" | jq -e '.error.code == "target_missing"' >/dev/null
}

@test "ordo_cli_error emits the brief error shape and maps codes to the exit table" {
  run --separate-stderr bash -c "source '$TK/lib/ordo_cli.sh'; ordo_cli_error refused 'nope' '{\"why\":\"policy\"}'"
  [ "$status" -eq 3 ]
  echo "$stderr" | jq -e '.error == {code:"refused", message:"nope", module:"cli", details:{why:"policy"}}' >/dev/null
  run bash -c "source '$TK/lib/ordo_cli.sh'; for c in ok usage refused not_found invalid_state missing_dependency budget_exhausted lease_lost something_else; do ordo_cli_exit_code_for \$c; done | paste -sd,"
  [ "$output" = "0,2,3,4,5,6,7,8,1" ]
}

# --- routing --------------------------------------------------------------

@test "status routes to agent_pool_status.sh and passes --json through" {
  run bash "$ORDO" status proj --json
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "stub=agent_pool_status.sh" ]
  [ "${lines[1]}" = "arg=proj" ]
  [ "${lines[2]}" = "arg=--json" ]
  run bash "$ORDO" status proj --tsv
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "arg=proj" ]
  [ "${lines[2]}" = "arg=--tsv" ]
}

@test "status --loop routes to orch_ctl.sh <project> status" {
  run --separate-stderr bash "$ORDO" status --loop proj
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "stub=orch_ctl.sh" ]
  [ "${lines[1]}" = "arg=proj" ]
  [ "${lines[2]}" = "arg=status" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "status --portfolio routes to portfolio_status.sh with --json passthrough" {
  run bash "$ORDO" --json status --portfolio portfolio.config.sh --yolo-priority
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "stub=portfolio_status.sh" ]
  [ "${lines[1]}" = "arg=portfolio.config.sh" ]
  [ "${lines[2]}" = "arg=--yolo-priority" ]
  [ "${lines[3]}" = "arg=--json" ]
}

@test "plan routes to dispatch_plan.sh with every flag preserved in order" {
  run bash "$ORDO" plan proj --ready-only --priority-set 1,2 --json
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "stub=dispatch_plan.sh" ]
  [ "${lines[1]}" = "arg=proj" ]
  [ "${lines[2]}" = "arg=--ready-only" ]
  [ "${lines[3]}" = "arg=--priority-set" ]
  [ "${lines[4]}" = "arg=1,2" ]
  [ "${lines[5]}" = "arg=--json" ]
}

@test "dispatch routes to dispatch_ticket.sh with positional and flag arguments intact" {
  run bash "$ORDO" dispatch proj fleet-001 42 /tmp/dispatch-fleet-001-42.md --dry-run --portfolio pf.config.sh
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "stub=dispatch_ticket.sh" ]
  [ "${lines[1]}" = "arg=proj" ]
  [ "${lines[2]}" = "arg=fleet-001" ]
  [ "${lines[3]}" = "arg=42" ]
  [ "${lines[4]}" = "arg=/tmp/dispatch-fleet-001-42.md" ]
  [ "${lines[5]}" = "arg=--dry-run" ]
  [ "${lines[6]}" = "arg=--portfolio" ]
  [ "${lines[7]}" = "arg=pf.config.sh" ]
}

@test "dispatch --wave routes to dispatch_wave.sh without requiring a project" {
  run bash "$ORDO" dispatch --wave wave-7 matrix.tsv --resume --dry-run
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "stub=dispatch_wave.sh" ]
  [ "${lines[1]}" = "arg=wave-7" ]
  [ "${lines[2]}" = "arg=matrix.tsv" ]
  [ "${lines[3]}" = "arg=--resume" ]
  [ "${lines[4]}" = "arg=--dry-run" ]
}

@test "watch routes to smart_poll_agents.sh and watch --prs to pr_block_signals.sh" {
  run bash "$ORDO" watch proj wave-7
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "stub=smart_poll_agents.sh" ]
  [ "${lines[1]}" = "arg=proj" ]
  [ "${lines[2]}" = "arg=wave-7" ]
  run bash "$ORDO" watch --prs proj --json
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "stub=pr_block_signals.sh" ]
  [ "${lines[1]}" = "arg=proj" ]
  [ "${lines[2]}" = "arg=--json" ]
}

@test "recover routes to recover.sh with the agent and flags" {
  run bash "$ORDO" recover proj fleet-002 --reset-state
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "stub=recover.sh" ]
  [ "${lines[1]}" = "arg=proj" ]
  [ "${lines[2]}" = "arg=fleet-002" ]
  [ "${lines[3]}" = "arg=--reset-state" ]
}

@test "merge routes to pr_merge_wave.sh and merge --portfolio to portfolio_auto_merge.sh" {
  run bash "$ORDO" merge proj wave1 '^feat/api-ns-0[2-6]' --no-admin-fallback
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "stub=pr_merge_wave.sh" ]
  [ "${lines[1]}" = "arg=proj" ]
  [ "${lines[2]}" = "arg=wave1" ]
  [ "${lines[3]}" = "arg=^feat/api-ns-0[2-6]" ]
  [ "${lines[4]}" = "arg=--no-admin-fallback" ]
  run bash "$ORDO" merge --portfolio pf.config.sh --apply --limit 2 --json
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "stub=portfolio_auto_merge.sh" ]
  [ "${lines[1]}" = "arg=pf.config.sh" ]
  [ "${lines[2]}" = "arg=--apply" ]
  [ "${lines[3]}" = "arg=--limit" ]
  [ "${lines[4]}" = "arg=2" ]
  [ "${lines[5]}" = "arg=--json" ]
}

@test "arguments after -- are passed verbatim, including --json" {
  run bash "$ORDO" dispatch --wave wave-1 m.tsv -- --json
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "stub=dispatch_wave.sh" ]
  [ "${lines[3]}" = "arg=--" ]
  [ "${lines[4]}" = "arg=--json" ]
}

# --- output modes ---------------------------------------------------------

@test "--json wraps the stdout of scripts that have no JSON mode" {
  run --separate-stderr bash "$ORDO" status --loop proj --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.command == "status"' >/dev/null
  echo "$output" | jq -e '.target == "scripts/orch_ctl.sh"' >/dev/null
  echo "$output" | jq -e '.exit_code == 0' >/dev/null
  echo "$output" | jq -e '.stdout == "stub=orch_ctl.sh\narg=proj\narg=status\n"' >/dev/null
  [[ "$stderr" == *"stub-stderr orch_ctl.sh"* ]]
}

@test "--json wrapper keeps the child's non-zero exit code and reports it" {
  STUB_EXIT=77 run --separate-stderr bash "$ORDO" dispatch proj fleet-001 42 prompt.md --json
  [ "$status" -eq 77 ]
  echo "$output" | jq -e '.command == "dispatch" and .exit_code == 77' >/dev/null
  echo "$output" | jq -e '.target == "scripts/dispatch_ticket.sh"' >/dev/null
  [[ "$stderr" == *"stub-stderr dispatch_ticket.sh"* ]]
}

@test "human mode passes the child's exit code and output through unchanged" {
  STUB_EXIT=124 run --separate-stderr bash "$ORDO" watch proj
  [ "$status" -eq 124 ]
  [ "${lines[0]}" = "stub=smart_poll_agents.sh" ]
  [ "${lines[1]}" = "arg=proj" ]
  [[ "$stderr" == *"stub-stderr smart_poll_agents.sh"* ]]
  STUB_EXIT=2 run bash "$ORDO" plan proj --json
  [ "$status" -eq 2 ]
  [ "${lines[0]}" = "stub=dispatch_plan.sh" ]
}

@test "global --json is accepted before the command" {
  run --separate-stderr bash "$ORDO" --json status --loop proj
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.command == "status" and .exit_code == 0' >/dev/null
}

# --- compatibility --------------------------------------------------------

@test "scripts/ordo.sh is executable, resolves TK and passes shellcheck-relevant strict mode" {
  [ -x "$ORDO" ]
  head -n 40 "$ORDO" | grep -q '^set -euo pipefail$'
  head -n 40 "$ORDO" | grep -q 'TK="${TK:-'
}

@test "direct invocation of a routed script is unaffected by the CLI (usage refusal unchanged)" {
  unset ORDO_CLI_SCRIPT_DIR
  run bash "$TK/scripts/orch_ctl.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: orch_ctl.sh <project> <command>"* ]]
  run bash "$TK/scripts/dispatch_wave.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage: dispatch_wave.sh <wave-id> <matrix-file>"* ]]
}

@test "with lib/ordo_contracts.sh present the CLI prints through ordo_contracts_error and keeps its exit codes" {
  [ -f "$TK/lib/ordo_contracts.sh" ] || skip "lib/ordo_contracts.sh (child #807) not present at this base"
  unset ORDO_CLI_NO_CONTRACTS
  run bash -c "source '$TK/lib/ordo_cli.sh'; declare -F ordo_contracts_error >/dev/null && echo delegated"
  [ "$output" = "delegated" ]
  run --separate-stderr bash "$ORDO" cancel run_0123456789abcdef01234567
  [ "$status" -eq 6 ]
  echo "$stderr" | jq -e '.error == {code:"not_implemented", message:(.error.message), module:"cli", details:{command:"cancel", implemented_by:"#810", epic:"#806"}}' >/dev/null
  run --separate-stderr bash "$ORDO" nope
  [ "$status" -eq 2 ]
  echo "$stderr" | jq -e '.error.code == "unknown_command" and .error.module == "cli"' >/dev/null
  run --separate-stderr bash "$ORDO" status
  [ "$status" -eq 2 ]
  echo "$stderr" | jq -e '.error.code == "missing_project"' >/dev/null
}
