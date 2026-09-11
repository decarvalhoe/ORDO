#!/usr/bin/env bash
# lib/ordo_cli.sh — command registry and router for the unified `ordo` CLI.
#
# Epic #806 (agentic control plane), child #809. `scripts/ordo.sh` is the
# entry point; this library owns the registry, argument routing, the two
# output modes, structured errors, help and bash completion.
#
# Design (see docs/architecture/cli.md):
#   - Every command routes to the EXISTING script that implements it today.
#     Arguments are passed through verbatim; the underlying scripts are not
#     modified and their direct invocation keeps working unchanged.
#   - A command can have "variants" selected by a flag (`status --loop`,
#     `dispatch --wave`, `merge --portfolio`, ...). Each variant is one
#     registry row with its own routing target.
#   - `--json` is a global flag accepted anywhere in argv. When the target
#     script already understands `--json`, the flag is passed through
#     (`passthrough`); otherwise the child's stdout is wrapped into
#     `{"command":..,"target":..,"exit_code":N,"stdout":".."}` (`wrap`).
#   - Commands whose native implementation is owned by another child of the
#     epic (`resume`, `cancel` -> #810 scheduler; `approve` -> #812 approvals)
#     are registered as `planned:#NNN` so `ordo <cmd> --help` works and the
#     command fails closed with a structured `not_implemented` error.
#   - Errors are ONE JSON line on stderr (brief shape) and the exit code comes
#     from the shared table (0 ok, 1 generic, 2 usage, 3 refused, 4 not found,
#     5 invalid state, 6 missing dependency, 7 budget, 8 lease lost). The CLI
#     owns its code -> exit mapping (`ordo_cli_exit_code_for`).
#
# Environment:
#   TK                    Toolkit root (default: parent of this lib dir).
#   ORDO_CLI_SCRIPT_DIR   Directory holding the routed scripts (default:
#                         $TK/scripts). Tests point it at stub scripts.
#   ORDO_PROJECT_PROFILE  Fallback project profile when a command that needs a
#                         project is invoked without a positional project.
#   ORDO_CLI_NO_CONTRACTS Set to 1 to skip sourcing lib/ordo_contracts.sh.
#
# Public API (all functions are prefixed ordo_cli_):
#   ordo_cli_main <argv...>                    entry point used by scripts/ordo.sh
#   ordo_cli_commands                          command names, one per line
#   ordo_cli_registry                          TSV rows of the registry
#   ordo_cli_registry_json                     the registry as a JSON array
#   ordo_cli_known <command>                   0 when registered
#   ordo_cli_row <command> [variant]           print one registry row (pipe-separated)
#   ordo_cli_route <command> <json:0|1> [args] route one command
#   ordo_cli_help [command] [variant]          help text
#   ordo_cli_completion_bash                   bash completion script
#   ordo_cli_error <code> <message> [details]  structured error; returns exit code
#   ordo_cli_exit_code_for <code>              map an error code to an exit code
#   ordo_cli_script_dir                        resolved routed-script directory
#
# Exit-code policy: this library uses the agentic-control-plane table
# documented in docs/exit-codes.md (section "Agentic control plane"). It
# deliberately does not declare ORCH_*_EXIT_CODE variables so the legacy
# manifest table is untouched.

if [[ -n "${ORDO_CLI_LIB_LOADED:-}" ]]; then
  return 0
fi
ORDO_CLI_LIB_LOADED=1

_ORDO_CLI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORDO_CLI_TOOLKIT_ROOT="${TK:-$(cd "$_ORDO_CLI_LIB_DIR/.." && pwd)}"
ORDO_CLI_MODULE="cli"
: "${ORDO_CLI_VERSION:=0.1.0}"

# Prefer the shared error helper when Child 1 (#807) has landed it; keep the
# local emitter as the fallback so the CLI works standalone.
if [[ "${ORDO_CLI_NO_CONTRACTS:-0}" != "1" && -f "$ORDO_CLI_TOOLKIT_ROOT/lib/ordo_contracts.sh" ]]; then
  # shellcheck disable=SC1091
  source "$ORDO_CLI_TOOLKIT_ROOT/lib/ordo_contracts.sh" || true
fi

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------
# Row format (pipe-separated, 8 fields):
#   name|variant|status|script|json_mode|needs_project|post_args|description
#   variant       "-" for the default route, or the selecting flag (--loop)
#   status        routed | native | planned:#NNN
#   script        basename under ORDO_CLI_SCRIPT_DIR, or "-" for native
#   json_mode     passthrough (target accepts --json) | wrap | native
#   needs_project 1 when the first positional argument is a project profile
#   post_args     space-separated arguments appended after the user's args
ORDO_CLI_REGISTRY=(
  "status|-|routed|agent_pool_status.sh|passthrough|1||Fleet status for one project (agent panes, branches, open pull requests)"
  "status|--loop|routed|orch_ctl.sh|wrap|1|status|Supervisor loop status (cycles, paused, assignments) for one project"
  "status|--portfolio|routed|portfolio_status.sh|passthrough|0||Portfolio capacity summary across products"
  "plan|-|routed|dispatch_plan.sh|passthrough|1||Ranked dispatch plan from the issue queue (ready/blocked, atomize, hotspots)"
  "dispatch|-|routed|dispatch_ticket.sh|wrap|1||Send one prepared brief to one agent pane"
  "dispatch|--wave|routed|dispatch_wave.sh|wrap|0||Dispatch a whole wave from a matrix file with a durable ledger"
  "watch|-|routed|smart_poll_agents.sh|wrap|1||Wait for agents to commit a wave's worth of work"
  "watch|--prs|routed|pr_block_signals.sh|passthrough|1||Surface pull-request states that silently block the merge flow"
  "resume|-|planned:#810|-|native|0||Resume a paused or blocked run (native scheduler, child #810)"
  "approve|-|planned:#812|-|native|0||Grant or deny a pending approval (native approvals, child #812)"
  "cancel|-|planned:#810|-|native|0||Cancel a queued or running run (native scheduler, child #810)"
  "recover|-|routed|recover.sh|wrap|1||Re-dispatch an agent whose pane died or got stuck"
  "merge|-|routed|pr_merge_wave.sh|wrap|1||Merge the pull requests of a wave in CI-gated order"
  "merge|--portfolio|routed|portfolio_auto_merge.sh|passthrough|0||Portfolio-level merge preview/apply in priority order"
  "help|-|native|-|native|0||Show commands, routing targets, or one command's usage"
  "version|-|native|-|native|0||Print the CLI version"
  "completion|-|native|-|native|0||Print a bash completion script (ordo completion bash)"
)

ordo_cli_script_dir() {
  printf '%s\n' "${ORDO_CLI_SCRIPT_DIR:-$ORDO_CLI_TOOLKIT_ROOT/scripts}"
}

# Print the registry as TSV (same field order as the rows).
ordo_cli_registry() {
  local row
  for row in "${ORDO_CLI_REGISTRY[@]}"; do
    printf '%s\n' "${row//|/$'\t'}"
  done
}

# Command names in registry order, without duplicates.
ordo_cli_commands() {
  local row name last=""
  for row in "${ORDO_CLI_REGISTRY[@]}"; do
    name=${row%%|*}
    if [[ "$name" != "$last" ]]; then
      printf '%s\n' "$name"
      last=$name
    fi
  done
}

ordo_cli_known() {
  local wanted=${1:?usage: ordo_cli_known <command>}
  local name
  while IFS= read -r name; do
    [[ "$name" == "$wanted" ]] && return 0
  done < <(ordo_cli_commands)
  return 1
}

# Print the registry row for <command> [variant] (variant defaults to "-").
ordo_cli_row() {
  local wanted=${1:?usage: ordo_cli_row <command> [variant]}
  local variant=${2:--}
  local row name var
  for row in "${ORDO_CLI_REGISTRY[@]}"; do
    IFS='|' read -r name var _ <<<"$row"
    if [[ "$name" == "$wanted" && "$var" == "$variant" ]]; then
      printf '%s\n' "$row"
      return 0
    fi
  done
  return 1
}

# Variant flags registered for <command>, one per line (may be empty).
ordo_cli_variants() {
  local wanted=${1:?usage: ordo_cli_variants <command>}
  local row name var
  for row in "${ORDO_CLI_REGISTRY[@]}"; do
    IFS='|' read -r name var _ <<<"$row"
    if [[ "$name" == "$wanted" && "$var" != "-" ]]; then
      printf '%s\n' "$var"
    fi
  done
}

# Human-readable routing target for a row.
ordo_cli_target_label() {
  local row=${1:?usage: ordo_cli_target_label <row>}
  local name var status script json_mode needs_project post_args desc
  IFS='|' read -r name var status script json_mode needs_project post_args desc <<<"$row"
  case "$status" in
    routed)
      if [[ -n "$post_args" ]]; then
        printf 'scripts/%s <args> %s\n' "$script" "$post_args"
      else
        printf 'scripts/%s <args>\n' "$script"
      fi
      ;;
    native) printf 'native (lib/ordo_cli.sh)\n' ;;
    planned:*) printf 'not implemented yet (%s)\n' "${status#planned:}" ;;
    *) printf '%s\n' "$status" ;;
  esac
}

ordo_cli_registry_json() {
  local row name var status script json_mode needs_project post_args desc
  for row in "${ORDO_CLI_REGISTRY[@]}"; do
    IFS='|' read -r name var status script json_mode needs_project post_args desc <<<"$row"
    jq -nc \
      --arg command "$name" \
      --arg variant "$var" \
      --arg status "$status" \
      --arg script "$script" \
      --arg json_mode "$json_mode" \
      --argjson needs_project "$([[ "$needs_project" == 1 ]] && echo true || echo false)" \
      --arg post_args "$post_args" \
      --arg description "$desc" \
      --arg target "$(ordo_cli_target_label "$row")" \
      '{command:$command, variant:(if $variant == "-" then null else $variant end),
        status:$status, script:(if $script == "-" then null else $script end),
        json_mode:$json_mode, needs_project:$needs_project,
        post_args:($post_args | if . == "" then [] else split(" ") end),
        target:$target, description:$description}'
  done | jq -s '.'
}

# ---------------------------------------------------------------------------
# Structured errors
# ---------------------------------------------------------------------------
ordo_cli_exit_code_for() {
  local code=${1:-generic}
  case "$code" in
    ok) printf '0\n' ;;
    usage|unknown_command|missing_project|bad_argument|missing_argument) printf '2\n' ;;
    refused|policy_refused|fail_closed) printf '3\n' ;;
    not_found|unknown_variant) printf '4\n' ;;
    invalid_state|invalid_transition|conflict) printf '5\n' ;;
    missing_dependency|not_implemented|target_missing) printf '6\n' ;;
    budget_exhausted) printf '7\n' ;;
    lease_lost|lease_stale|stale_lease) printf '8\n' ;;
    *) printf '1\n' ;;
  esac
}

_ordo_cli_json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# ordo_cli_error <code> <message> [details-json]
#   Print one JSON error line on stderr and return the mapped exit code.
#   Delegates the printing to ordo_contracts_error when it is available; the
#   exit-code mapping stays CLI-owned so callers get stable codes either way.
ordo_cli_error() {
  local code=${1:?usage: ordo_cli_error <code> <message> [details-json]}
  local message=${2:?usage: ordo_cli_error <code> <message> [details-json]}
  local details=${3:-\{\}}
  local rc
  rc=$(ordo_cli_exit_code_for "$code")

  if declare -F ordo_contracts_error >/dev/null 2>&1; then
    ordo_contracts_error "$ORDO_CLI_MODULE" "$code" "$message" "$details" || true
    return "$rc"
  fi

  if command -v jq >/dev/null 2>&1 && printf '%s' "$details" | jq -e . >/dev/null 2>&1; then
    jq -nc \
      --arg code "$code" \
      --arg message "$message" \
      --arg module "$ORDO_CLI_MODULE" \
      --argjson details "$details" \
      '{error:{code:$code, message:$message, module:$module, details:$details}}' >&2
  else
    printf '{"error":{"code":"%s","message":"%s","module":"%s","details":{}}}\n' \
      "$(_ordo_cli_json_escape "$code")" \
      "$(_ordo_cli_json_escape "$message")" \
      "$ORDO_CLI_MODULE" >&2
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Help / version / completion
# ---------------------------------------------------------------------------
# Print the leading comment banner of a script (its usage contract), without
# the shebang and the `# ` prefixes. Stops at the first non-comment line.
ordo_cli_script_usage() {
  local path=${1:?usage: ordo_cli_script_usage <path>}
  [[ -f "$path" ]] || return 1
  awk '
    NR == 1 && /^#!/ { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$path"
}

_ordo_cli_help_overview() {
  local row name var status script json_mode needs_project post_args desc label
  cat <<'EOF'
ordo — unified ORDO CLI

Usage:
  ordo <command> [--json] [args...]
  ordo help [<command> [<variant-flag>]]
  ordo completion bash

Global flags (accepted anywhere in argv):
  --json        machine-readable output (passed through, or wrapped as
                {"command","target","exit_code","stdout"})
  --help, -h    show this help or the help of <command>

Commands (routing target in the middle column):
EOF
  for row in "${ORDO_CLI_REGISTRY[@]}"; do
    IFS='|' read -r name var status script json_mode needs_project post_args desc <<<"$row"
    if [[ "$var" == "-" ]]; then
      label=$name
    else
      label="$name $var"
    fi
    printf '  %-20s %-40s %s\n' "$label" "$(ordo_cli_target_label "$row")" "$desc"
  done
  cat <<'EOF'

Project context:
  Commands marked with a <project> first argument accept a short profile
  name or a config path (same resolution as the underlying scripts). When
  it is omitted, ORDO_PROJECT_PROFILE is used; otherwise the CLI exits 2.

Errors are one JSON line on stderr:
  {"error":{"code":"<snake_case>","message":"...","module":"cli","details":{}}}
Exit codes: 0 ok, 1 failure, 2 usage, 3 refused, 4 not found, 5 invalid
state, 6 missing dependency / not implemented, 7 budget, 8 lease lost.
Routed commands return the underlying script's exit code unchanged.
EOF
}

# ordo_cli_help [command] [variant]
ordo_cli_help() {
  local command=${1:-}
  local variant=${2:--}
  local row name var status script json_mode needs_project post_args desc
  local script_path

  if [[ -z "$command" ]]; then
    if [[ "${ORDO_CLI_JSON:-0}" == "1" ]]; then
      ordo_cli_registry_json
    else
      _ordo_cli_help_overview
    fi
    return 0
  fi

  if ! ordo_cli_known "$command"; then
    ordo_cli_error unknown_command "unknown command: $command (try: ordo help)" \
      "$(jq -nc --arg command "$command" '{command:$command}')"
    return $?
  fi

  if ! row=$(ordo_cli_row "$command" "$variant"); then
    ordo_cli_error unknown_variant "unknown variant $variant for command $command" \
      "$(jq -nc --arg command "$command" --arg variant "$variant" '{command:$command, variant:$variant}')"
    return $?
  fi
  IFS='|' read -r name var status script json_mode needs_project post_args desc <<<"$row"

  printf 'ordo %s' "$name"
  [[ "$var" != "-" ]] && printf ' %s' "$var"
  printf ' — %s\n' "$desc"
  printf 'routes to: %s\n' "$(ordo_cli_target_label "$row")"
  if [[ "$needs_project" == 1 ]]; then
    printf 'first argument: <project> (short name or config path; falls back to ORDO_PROJECT_PROFILE)\n'
  fi
  local other
  while IFS= read -r other; do
    [[ -n "$other" ]] || continue
    [[ "$other" == "$var" ]] && continue
    printf 'variant: ordo %s %s  (ordo help %s %s)\n' "$name" "$other" "$name" "$other"
  done < <(ordo_cli_variants "$name")
  if [[ "$var" != "-" ]]; then
    printf 'variant: ordo %s  (ordo help %s)\n' "$name" "$name"
  fi

  case "$status" in
    routed)
      script_path="$(ordo_cli_script_dir)/$script"
      printf '\n--- usage of scripts/%s ---\n' "$script"
      if ! ordo_cli_script_usage "$script_path"; then
        printf '(script not found at %s)\n' "$script_path"
      fi
      ;;
    planned:*)
      printf '\nThis command has no implementation yet. It will be provided natively by\n'
      printf 'child %s of epic #806. Calling it now exits 6 with a structured\n' "${status#planned:}"
      printf '{"error":{"code":"not_implemented",...}} object on stderr.\n'
      ;;
    native)
      case "$name" in
        help) printf '\nusage: ordo help [<command> [<variant-flag>]] [--json]\n' ;;
        version) printf '\nusage: ordo version [--json]\n' ;;
        completion) printf '\nusage: ordo completion bash\n       source <(ordo completion bash)\n' ;;
      esac
      ;;
  esac
  return 0
}

ordo_cli_version() {
  if [[ "${ORDO_CLI_JSON:-0}" == "1" ]]; then
    jq -nc --arg version "$ORDO_CLI_VERSION" --arg toolkit_root "$ORDO_CLI_TOOLKIT_ROOT" \
      '{version:$version, toolkit_root:$toolkit_root}'
  else
    printf 'ordo %s\n' "$ORDO_CLI_VERSION"
  fi
}

# Bash completion script generated from the registry so it never drifts.
ordo_cli_completion_bash() {
  local commands variants name
  commands=$(ordo_cli_commands | paste -sd' ' -)
  cat <<EOF
# bash completion for the unified ORDO CLI (generated by: ordo completion bash)
# Install: source <(ordo completion bash)
_ordo_complete() {
  local cur cmd i word
  COMPREPLY=()
  cur=\${COMP_WORDS[COMP_CWORD]}
  cmd=""
  for ((i = 1; i < COMP_CWORD; i++)); do
    word=\${COMP_WORDS[i]}
    case "\$word" in
      --json|--help|-h) continue ;;
      -*) continue ;;
      *) cmd=\$word; break ;;
    esac
  done
  local global_flags="--json --help"
  local commands="$commands"
  if [[ -z "\$cmd" ]]; then
    mapfile -t COMPREPLY < <(compgen -W "\$commands \$global_flags" -- "\$cur")
    return 0
  fi
  local variants=""
  case "\$cmd" in
EOF
  while IFS= read -r name; do
    variants=$(ordo_cli_variants "$name" | paste -sd' ' -)
    if [[ "$name" == "help" ]]; then
      printf '    %s) variants="%s" ;;\n' "$name" "$commands"
    elif [[ "$name" == "completion" ]]; then
      printf '    %s) variants="bash" ;;\n' "$name"
    else
      printf '    %s) variants="%s" ;;\n' "$name" "$variants"
    fi
  done < <(ordo_cli_commands)
  cat <<'EOF'
  esac
  if [[ "$cur" == -* || "$cmd" == help || "$cmd" == completion ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$variants $global_flags" -- "$cur")
    return 0
  fi
  # Positional arguments (project profile, prompt file, matrix): default
  # readline filename completion via `-o default`.
  return 0
}
complete -o default -F _ordo_complete ordo ordo.sh
EOF
}

# ---------------------------------------------------------------------------
# Routing
# ---------------------------------------------------------------------------
# ordo_cli_route <command> <json:0|1> [args...]
ordo_cli_route() {
  local command=${1:?usage: ordo_cli_route <command> <json> [args...]}
  local json=${2:-0}
  shift 2
  local -a args=() final=()
  local a variant="-" row
  local name var status script json_mode needs_project post_args desc

  if ! ordo_cli_known "$command"; then
    ordo_cli_error unknown_command "unknown command: $command (try: ordo help)" \
      "$(jq -nc --arg command "$command" '{command:$command}')"
    return $?
  fi

  # Pick the variant: the first argv entry that is a registered variant flag
  # of this command selects the row; every other argument is passed through.
  for a in "$@"; do
    if [[ "$a" == --* && "$variant" == "-" ]] && ordo_cli_row "$command" "$a" >/dev/null; then
      variant=$a
      continue
    fi
    args+=("$a")
  done
  row=$(ordo_cli_row "$command" "$variant")
  IFS='|' read -r name var status script json_mode needs_project post_args desc <<<"$row"

  case "$status" in
    planned:*)
      ordo_cli_error not_implemented \
        "ordo $command is not implemented yet; it will be provided by child ${status#planned:} of epic #806" \
        "$(jq -nc --arg command "$command" --arg child "${status#planned:}" \
          '{command:$command, implemented_by:$child, epic:"#806"}')"
      return $?
      ;;
    native)
      ordo_cli_error usage "ordo $command is a native command; call it directly" \
        "$(jq -nc --arg command "$command" '{command:$command}')"
      return $?
      ;;
  esac

  # Project context: the first positional argument must be a project profile.
  if [[ "$needs_project" == 1 ]]; then
    local has_positional=0
    for a in "${args[@]}"; do
      if [[ "$a" != -* ]]; then
        has_positional=1
        break
      fi
    done
    if [[ "$has_positional" == 0 ]]; then
      if [[ -n "${ORDO_PROJECT_PROFILE:-}" ]]; then
        args=("$ORDO_PROJECT_PROFILE" "${args[@]}")
      else
        ordo_cli_error missing_project \
          "ordo $command needs a project: pass <project> (short name or config path, e.g. examples/ordo.config.sh) as the first argument or set ORDO_PROJECT_PROFILE" \
          "$(jq -nc --arg command "$command" --arg script "$script" \
            '{command:$command, script:$script, hint:"ordo help \($command)"}')"
        return $?
      fi
    fi
  fi

  local script_path
  script_path="$(ordo_cli_script_dir)/$script"
  if [[ ! -f "$script_path" ]]; then
    ordo_cli_error target_missing "routing target not found: $script_path" \
      "$(jq -nc --arg command "$command" --arg script "$script_path" '{command:$command, script:$script}')"
    return $?
  fi

  final=("${args[@]}")
  if [[ -n "$post_args" ]]; then
    # shellcheck disable=SC2206  # post_args is a registry-owned space-separated list
    final+=($post_args)
  fi
  if [[ "$json" == 1 && "$json_mode" == passthrough ]]; then
    final+=(--json)
  fi

  local rc=0
  if [[ "$json" == 1 && "$json_mode" == wrap ]]; then
    local capture
    capture=$(mktemp "${TMPDIR:-/tmp}/ordo-cli.XXXXXX")
    if bash "$script_path" "${final[@]}" >"$capture"; then
      rc=0
    else
      rc=$?
    fi
    jq -nc \
      --arg command "$command" \
      --arg target "scripts/$script" \
      --argjson exit_code "$rc" \
      --rawfile stdout "$capture" \
      '{command:$command, target:$target, exit_code:$exit_code, stdout:$stdout}'
    rm -f "$capture"
    return "$rc"
  fi

  if bash "$script_path" "${final[@]}"; then
    rc=0
  else
    rc=$?
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
ordo_cli_main() {
  local -a rest=()
  local a command="" json=0 want_help=0 literal=0

  for a in "$@"; do
    if [[ "$literal" == 1 ]]; then
      rest+=("$a")
      continue
    fi
    case "$a" in
      --) literal=1; rest+=("$a") ;;
      --json) json=1 ;;
      --help|-h) want_help=1 ;;
      *)
        if [[ -z "$command" ]]; then
          command=$a
        else
          rest+=("$a")
        fi
        ;;
    esac
  done
  export ORDO_CLI_JSON=$json

  if [[ -z "$command" ]]; then
    if [[ "$want_help" == 1 ]]; then
      ordo_cli_help
      return 0
    fi
    _ordo_cli_help_overview >&2
    ordo_cli_error usage "missing command (try: ordo help)" '{"hint":"ordo help"}'
    return $?
  fi

  if [[ "$want_help" == 1 ]]; then
    ordo_cli_help "$command" "${rest[@]}"
    return $?
  fi

  case "$command" in
    help)
      ordo_cli_help "${rest[@]}"
      return $?
      ;;
    version)
      ordo_cli_version
      return 0
      ;;
    completion)
      case "${rest[0]:-bash}" in
        bash)
          ordo_cli_completion_bash
          return 0
          ;;
        *)
          ordo_cli_error usage "unsupported completion shell: ${rest[0]} (supported: bash)" \
            "$(jq -nc --arg shell "${rest[0]}" '{shell:$shell, supported:["bash"]}')"
          return $?
          ;;
      esac
      ;;
  esac

  ordo_cli_route "$command" "$json" "${rest[@]}"
}
