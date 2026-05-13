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
source "$TK/lib/scope_check.sh"
source "$TK/lib/prompt_integrity.sh"
# shellcheck source=../lib/ticket_scope_validator.sh
source "$TK/lib/ticket_scope_validator.sh"
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
  printf '%s\n' "none"
}

ci_delegated_allowed_focused_checks() {
  cat <<'EOF'
  - timeout 30 bash -n <edited-shell-script>
  - timeout 120 bash <targeted-shell-test>
  - timeout 30 git diff --check
EOF
}

local_validators_validation() {
  cat <<'EOF'
timeout 300 bash scripts/run_shellcheck.sh
timeout 300 bash scripts/run_shell_tests.sh
timeout 300 bash scripts/run_bats.sh
EOF
}

validation_as_command_line() {
  local validation=${1:-}
  local line out=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ [^[:space:]] ]] || continue
    if [[ -z "$out" ]]; then
      out="$line"
    else
      out="$out && $line"
    fi
  done <<< "$validation"

  printf '%s\n' "${out:-none}"
}

validation_as_focused_check_list() {
  local validation=${1:-}
  local line emitted=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ [^[:space:]] ]] || continue
    printf '  - %s\n' "$line"
    emitted=1
  done <<< "$validation"

  if [[ "$emitted" -eq 0 ]]; then
    printf '  - none\n'
  fi
}

validation_mentions_heavy_runner() {
  local validation=${1:-}
  grep -Eq '(^|[^A-Za-z0-9_./-])(timeout[[:space:]]+[0-9]+[[:space:]]+)?bash[[:space:]]+scripts/(run_shellcheck|run_shell_tests|run_bats)\.sh([^A-Za-z0-9_./-]|$)' <<< "$validation"
}

brief_agent_workdir() {
  local agent=${1:?usage: brief_agent_workdir <agent> <ticket>}
  local ticket=${2:?usage: brief_agent_workdir <agent> <ticket>}

  if declare -F worktree_enabled >/dev/null 2>&1 \
    && declare -F worktree_path >/dev/null 2>&1 \
    && worktree_enabled; then
    worktree_path "$agent" "$ticket"
    return 0
  fi

  if declare -F agent_effective_workdir >/dev/null 2>&1; then
    agent_effective_workdir "$agent"
  elif declare -F agent_repo_root >/dev/null 2>&1; then
    agent_repo_root "$agent"
  else
    printf '%s%s' "${AGENT_REPO_PREFIX:-}" "$agent"
  fi
}

brief_agent_repo_root() {
  local agent=${1:?usage: brief_agent_repo_root <agent>}

  if declare -F agent_repo_root >/dev/null 2>&1; then
    agent_repo_root "$agent"
  else
    printf '%s%s' "${AGENT_REPO_PREFIX:-}" "$agent"
  fi
}

brief_default_base_sha() {
  local agent=${1:?usage: brief_default_base_sha <agent> <base-ref> <default-branch>}
  local base_ref=${2:?usage: brief_default_base_sha <agent> <base-ref> <default-branch>}
  local default_branch=${3:?usage: brief_default_base_sha <agent> <base-ref> <default-branch>}
  local repo ref

  repo=$(brief_agent_repo_root "$agent")
  if [[ -n "$repo" ]] \
    && git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    for ref in "$base_ref" "origin/$default_branch" "$default_branch" "HEAD"; do
      git -C "$repo" rev-parse --verify "${ref}^{commit}" 2>/dev/null && return 0
    done
  fi

  printf '%s\n' "HEAD"
}

# Default values (overridable via kv args).
DEFAULT_BRANCH_VALUE="${DEFAULT_BRANCH:-main}"
BASE_REMOTE="${SUPERVISOR_REPO:-origin}"
BASE_REF="${BASE_REMOTE}/${DEFAULT_BRANCH_VALUE}"
declare -A K=(
  [agent]="$AGENT"
  [ticket]="$TICKET_NUM"
  [project]="$PROJECT"
  [repo]="$(brief_agent_workdir "$AGENT" "$TICKET_NUM")"
  [base_remote]="$BASE_REMOTE"
  [base_ref]="$BASE_REF"
  [orch_remote]="$BASE_REMOTE"
  [default_branch]="$DEFAULT_BRANCH_VALUE"
  [branch_slug]="feat/${PROJECT}-ticket-${TICKET_NUM}"
  [base_sha]="$(brief_default_base_sha "$AGENT" "$BASE_REF" "$DEFAULT_BRANCH_VALUE")"
  [scope_files]=""
  [forbidden_files]="cli/internal/app/app.go"
  [validation]="$(ci_delegated_validation)"
  [validation_policy]="ci-delegated"
  [validation_command]="none"
  [allowed_focused_checks]="$(ci_delegated_allowed_focused_checks)"
  [require_local_validators]="no"
  [summary]=""
  [gh_repo]="$GH_REPO"
  [project_meta_context]="$(state_dir)/project_meta_context.md"
  [scope_active_project]="${ORCH_SCOPE_ACTIVE_KEY:-$PROJECT}"
  [scope_classification]="$(ordo_scope_classify "${ORCH_SCOPE_ACTIVE_KEY:-$PROJECT}")"
  [scope_posture_block]="$(ordo_scope_render_block "${ORCH_SCOPE_ACTIVE_KEY:-$PROJECT}" "$GH_REPO" "$DEFAULT_BRANCH_VALUE")"
  [ticket_title]=""
  [source_url]="https://github.com/${GH_REPO}/issues/${TICKET_NUM}"
  [source_title]=""
  [source_body]=""
  [source_substance_appendix]=""
)

brief_fetch_source_issue_json() {
  local fetch_timeout=${ORCH_SOURCE_FETCH_TIMEOUT_SEC:-15}

  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  if [[ -n "${GH_CONFIG_DIR:-}" ]]; then
    timeout "$fetch_timeout" env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh issue view "${K[ticket]}" \
      --repo "${K[gh_repo]}" \
      --json title,body,url 2>/dev/null
  else
    timeout "$fetch_timeout" gh issue view "${K[ticket]}" \
      --repo "${K[gh_repo]}" \
      --json title,body,url 2>/dev/null
  fi
}

brief_prepare_source_substance() {
  local source_json=""

  if [[ -z "${K[source_body]}" ]]; then
    source_json=$(brief_fetch_source_issue_json || true)
    # `gh issue view --json ...` returns an object; sandboxed tests and
    # offline fixtures may surface `[]` or other non-object JSON. Treat
    # those as "no source available" so jq does not error on `.body`.
    if [[ -n "$source_json" ]] && jq -e 'type == "object"' >/dev/null 2>&1 <<< "$source_json"; then
      K[source_body]=$(jq -r '.body // ""' <<< "$source_json")
      K[source_title]=$(jq -r '.title // ""' <<< "$source_json")
      K[source_url]=$(jq -r '.url // ""' <<< "$source_json")
    fi
  fi

  if [[ -z "${K[source_title]}" ]]; then
    K[source_title]="${K[ticket_title]:-}"
  fi
  if [[ -z "${K[source_url]}" ]]; then
    K[source_url]="https://github.com/${K[gh_repo]}/issues/${K[ticket]}"
  fi

  K[source_substance_appendix]="$(prompt_source_substance_appendix \
    "${K[source_url]}" \
    "${K[source_title]}" \
    "${K[source_body]}")"
}

# Override via k=v args.
ALLOW_REBIND=0
VALIDATION_OVERRIDDEN=0
for kv in "$@"; do
  case "$kv" in
    --require-local-validators)
      REQUIRE_LOCAL_VALIDATORS=1
      ;;
    --allow-rebind)
      ALLOW_REBIND=1
      ;;
    *=*)
      key=${kv%%=*}
      K[$key]="${kv#*=}"
      if [[ "$key" == "validation" ]]; then
        VALIDATION_OVERRIDDEN=1
      fi
      ;;
    *)   echo "ignoring non-kv arg: $kv" >&2 ;;
  esac
done

# #369 — refuse dispatch when the ticket number, branch slug, and
# summary do not point at the same issue. The validator emits a
# structured TICKET_SCOPE_VALIDATION audit line carrying ticket_number,
# ticket_title, branch_issue_number, slug_tail, acceptance_scope_hash,
# and the mismatch reason. `--allow-rebind` swaps the assert for an
# audit-only rebind so operators can keep the brief and re-aim it at
# the right ticket without losing evidence.
TICKET_SCOPE_CONTEXT="brief_agents:${PROJECT}:${AGENT}:#${K[ticket]}"
if [[ "$ALLOW_REBIND" -eq 1 ]]; then
  ticket_scope_assert_or_rebind \
    "${K[ticket]}" "${K[branch_slug]}" "${K[summary]}" \
    "${K[scope_files]}" "${K[ticket_title]:-}" \
    "$TICKET_SCOPE_CONTEXT" "${K[forbidden_files]}"
else
  ticket_scope_assert \
    "${K[ticket]}" "${K[branch_slug]}" "${K[summary]}" \
    "${K[scope_files]}" "${K[ticket_title]:-}" \
    "$TICKET_SCOPE_CONTEXT" "${K[forbidden_files]}"
fi

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

if [[ "${K[require_local_validators]}" == "yes" ]]; then
  K[validation_policy]="require-local-validators"
  K[validation_command]="$(validation_as_command_line "${K[validation]}")"
  K[allowed_focused_checks]="$(validation_as_focused_check_list "${K[validation]}")"
elif [[ "$VALIDATION_OVERRIDDEN" -eq 1 && "${K[validation]}" != "none" ]]; then
  K[validation_policy]="dispatch-provided"
  K[validation_command]="$(validation_as_command_line "${K[validation]}")"
  K[allowed_focused_checks]="$(validation_as_focused_check_list "${K[validation]}")"
else
  K[validation_policy]="ci-delegated"
  K[validation_command]="none"
  K[allowed_focused_checks]="$(ci_delegated_allowed_focused_checks)"
fi

brief_prepare_source_substance

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

  prompt_validate_source_fidelity \
    "${K[source_url]}" \
    "${K[source_title]}" \
    "${K[source_body]}" \
    "$content" || return 1

  printf '%s\n' "$content"
}

render
