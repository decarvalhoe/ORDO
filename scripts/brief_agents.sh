#!/usr/bin/env bash
# scripts/brief_agents.sh — render a templated dispatch markdown for an agent
# from the canonical dispatch template and a kvargs list.
#
# Usage:
#   brief_agents.sh <project_short|config_path> <agent> <ticket#> [--require-local-validators] [k=v ...]
#   k=v keys recognized by the default template:
#     branch_slug=     (e.g. feat/sfi-01-source-segment-ledger)
#     base_sha=        (sha of main the agent must branch from)
#     scope_files=     (glob list of files agent may modify)
#     forbidden_files= (glob list agent must NOT touch)
#     validation=      (command the agent must run before commit)
#     summary=         (one-line ticket summary)
#
# Output: prints the rendered markdown to stdout. Caller pipes to a file
# under /tmp/dispatch-<agent>-<ticket>.md, then invokes dispatch_ticket.sh.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TK/lib/config_resolver.sh"

CFG_ARG=${1:?usage: brief_agents.sh <project> <agent> <ticket#> [k=v ...]}
AGENT=${2:?}
TICKET=${3:?}
shift 3
load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"
source "$TK/lib/host_load_gate.sh"
# worktree_helpers exposes agent_repo_root which is AGENT_PANES-aware.
# Source it for the [repo] default so matrix labels resolve through the
# configured inventory rather than through legacy prefix concatenation.
# Defensive — the sanitized shell-test sandbox only copies brief_agents'
# historical deps, so we fall back below to the legacy concat when
# worktree_helpers is absent.
if [ -f "$TK/lib/worktree_helpers.sh" ]; then
  # shellcheck source=/dev/null
  source "$TK/lib/worktree_helpers.sh"
fi

TICKET_NUM=${TICKET#\#}
TEMPLATE="${DISPATCH_TEMPLATE:-$TK/templates/dispatch-canonical.md.tpl}"
[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE" >&2; exit 1; }

: "${ORCH_HEAVY_VALIDATION_EXIT_CODE:=78}"
REQUIRE_LOCAL_VALIDATORS="${ORCH_REQUIRE_LOCAL_VALIDATORS:-0}"

ci_delegated_validation() {
  cat <<'EOF'
CI-delegated validation. Do not run full local repository validators on the shared agent host. Run only cheap foreground smoke checks directly tied to changed files, such as bash -n on edited shell scripts, then report validation as CI-delegated for the orchestrator/PR gate.
EOF
}

local_validators_validation() {
  cat <<'EOF'
require-local-validators: yes
timeout 300 bash scripts/run_shellcheck.sh
timeout 300 bash scripts/run_shell_tests.sh
timeout 300 bash scripts/run_bats.sh
EOF
}

validation_mentions_heavy_runner() {
  local validation=${1:-}
  grep -Eq '(^|[^A-Za-z0-9_./-])(timeout[[:space:]]+[0-9]+[[:space:]]+)?bash[[:space:]]+scripts/(run_shellcheck|run_shell_tests|run_bats)\.sh([^A-Za-z0-9_./-]|$)' <<< "$validation"
}

# Default values (overridable via kv args).
DEFAULT_BRANCH_VALUE="${DEFAULT_BRANCH:-main}"
BASE_REMOTE="${SUPERVISOR_REPO:-origin}"
BASE_REF="${BASE_REMOTE}/${DEFAULT_BRANCH_VALUE}"
declare -A K=(
  [agent]="$AGENT"
  [ticket]="$TICKET_NUM"
  [project]="$PROJECT"
  [repo]="$(if declare -F agent_repo_root >/dev/null 2>&1; then agent_repo_root "$AGENT"; else printf '%s%s' "${AGENT_REPO_PREFIX:-}" "$AGENT"; fi)"
  [base_remote]="$BASE_REMOTE"
  [base_ref]="$BASE_REF"
  [orch_remote]="$BASE_REMOTE"
  [default_branch]="$DEFAULT_BRANCH_VALUE"
  [branch_slug]="feat/${PROJECT}-ticket-${TICKET_NUM}"
  [base_sha]="HEAD"
  [scope_files]=""
  [forbidden_files]="cli/internal/app/app.go"
  [validation]="$(ci_delegated_validation)"
  [require_local_validators]="no"
  [summary]=""
  [gh_repo]="$GH_REPO"
  [project_meta_context]="$(state_dir)/project_meta_context.md"
)

# Override via k=v args.
for kv in "$@"; do
  case "$kv" in
    --require-local-validators)
      REQUIRE_LOCAL_VALIDATORS=1
      ;;
    *=*) K[${kv%%=*}]="${kv#*=}" ;;
    *)   echo "ignoring non-kv arg: $kv" >&2 ;;
  esac
done

case "$REQUIRE_LOCAL_VALIDATORS" in
  1|yes|true|on)
    orch_host_load_gate \
      "local_validators_brief:${PROJECT}:${AGENT}:#${TICKET_NUM}" \
      "${ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE:-${ORCH_HOST_GATE_MODE:-off}}"
    K[require_local_validators]="yes"
    if ! validation_mentions_heavy_runner "${K[validation]}"; then
      K[validation]="$(local_validators_validation)"
    fi
    ;;
  0|no|false|off|'')
    K[require_local_validators]="no"
    if validation_mentions_heavy_runner "${K[validation]}"; then
      printf '%s\n' \
        "brief_agents: full local validators require --require-local-validators; default is CI-delegated validation" >&2
      exit "$ORCH_HEAVY_VALIDATION_EXIT_CODE"
    fi
    ;;
  *)
    printf 'brief_agents: invalid ORCH_REQUIRE_LOCAL_VALIDATORS value: %s\n' "$REQUIRE_LOCAL_VALIDATORS" >&2
    exit 2
    ;;
esac

# Render template by substitution.
#
# Shell-safety contract (issue #121, source: issue #89 comment 19:14Z):
# the template is read as a file via "$(<...)" — never via an unquoted
# heredoc — and values are inserted with bash parameter substitution
# only, which does NOT re-evaluate the replacement string. Backticks,
# command-substitution syntax, single/double quotes and embedded
# newlines in K[$k] are inserted literally and cannot trigger shell
# execution during rendering.
render() {
  local content val
  content=$(<"$TEMPLATE")
  for k in "${!K[@]}"; do
    # bash 5.2+ interprets `&` in the replacement of ${var//pat/repl} as
    # "the matched pattern". A value containing `&&` therefore expands to
    # `{{key}}{{key}}` instead of being inserted literally. Escape `&` in
    # the value so it's treated as a literal ampersand on bash 5.2+ (and
    # is harmless on earlier versions, where `\&` was already literal).
    # `\` must be escaped first or the `&` escape itself gets mangled.
    val=${K[$k]//\\/\\\\}
    val=${val//&/\\&}
    content=${content//\{\{${k}\}\}/$val}
  done

  # Refuse to emit a half-rendered brief — an unresolved {{key}} downstream
  # is exactly the corruption pattern dispatch_ticket.sh now rejects, and
  # catching it here gives a clearer error than the staged-prompt check.
  if [[ "$content" =~ \{\{[a-zA-Z_][a-zA-Z0-9_]*\}\} ]]; then
    printf 'brief_agents: unresolved template placeholder %s\n' \
      "${BASH_REMATCH[0]}" >&2
    return 1
  fi

  printf '%s\n' "$content"
}

render
