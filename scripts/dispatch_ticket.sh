#!/usr/bin/env bash
# scripts/dispatch_ticket.sh — send a prepared dispatch markdown to an agent.
# Usage: dispatch_ticket.sh <project_short|config_path> <agent> <ticket_number> <prompt_file>
#        [--portfolio <portfolio-config> [--portfolio-project <project>]]
#
# Surviving log signature:
#   DISPATCH agent=<name> ticket=#<N> prompt=dispatch-<agent>-<N>.md
#
# Behavior:
#   1. tmux load-buffer + paste-buffer to the agent pane (handles multi-line safely).
#      Falls back to: tmux send-keys "Read /tmp/<file>... and execute" + Enter.
#   2. Optionally: gh issue assign — controlled by --assign flag (off by
#      default). When omitted, ORDO records ownership in the local
#      assignments ledger only and emits an explicit
#      `DISPATCH assignee_policy=skipped reason=disabled-by-default
#      ledger=<path>` audit line so the GitHub view of the issue is
#      knowingly out-of-sync with ORDO's local truth (issue #273).
#      When --assign is supplied, the configured GitHub identity guard
#      verifies that the active gh login matches the agent's expected
#      login before any mutation; on mismatch the assignment is refused
#      and audited as `assignee_policy=refused
#      reason=identity-mismatch`. After a successful gh issue edit the
#      audit records `assignee_policy=applied`; a gh failure records
#      `assignee_policy=failed reason=gh-error`.
#   3. Persist the prompt to /tmp/dispatch-<agent>-<N>.md so it survives restarts
#      and the audit log can reference it.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/config_resolver.sh"
source "$TK/lib/portfolio_config.sh"
source "$TK/lib/process_safety.sh"
source "$TK/lib/github_identity.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: dispatch_ticket.sh <project> <agent> <ticket#> <prompt-file> [--assign] [--no-validate] [--dry-run]}
AGENT=${2:?missing agent name}
TICKET=${3:?missing ticket number}
PROMPT_FILE=${4:?missing prompt-file path}
shift 4

ASSIGN=0
VALIDATE_PROMPT=1
REQUIRE_LOCAL_VALIDATORS="${ORCH_REQUIRE_LOCAL_VALIDATORS:-0}"
EXTERNAL_PR_MUTATIONS_ARG="${ORCH_EXTERNAL_PR_MUTATIONS:-}"
PORTFOLIO_ARG="${ORCH_PORTFOLIO_CONFIG:-${PORTFOLIO_CONFIG:-}}"
PORTFOLIO_PROJECT_ARG="${ORCH_PORTFOLIO_PROJECT:-}"
REQUIRE_DISPATCH_MATRIX_GATE="${ORCH_REQUIRE_DISPATCH_MATRIX_GATE:-0}"
DISPATCH_MATRIX_PATH_ARG="${ORCH_DISPATCH_MATRIX_FILE:-}"
AUTO_REFRESH_PREFLIGHT="${ORCH_AUTO_REFRESH_PREFLIGHT:-0}"
# Opt-in autofix-style guard (#371): refuse to dispatch when the
# numeric ticket maps to a PR that is already merged or closed
# without merge. Off by default so non-PR-targeted dispatches stay
# unaffected. ci_autofix.sh forwards this flag for autofix waves.
SKIP_IF_PR_MERGED="${ORCH_DISPATCH_SKIP_IF_PR_MERGED:-0}"
# External PR mutation authority gate (Required Rule 12). Default audit-only;
# operators authorize per-scope via --external-pr-mutations or env var. The
# flag wins over the env var so a one-off dispatch can narrow or broaden the
# inherited orchestrator authorization. (`EXTERNAL_PR_MUTATIONS_ARG` was
# already initialised above from `ORCH_EXTERNAL_PR_MUTATIONS`; the comment
# here documents the contract at the call-site level.)
SOFT_ROUTE="${ORCH_DISPATCH_SOFT_ROUTE:-0}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --assign) ASSIGN=1 ;;
    --no-validate) VALIDATE_PROMPT=0 ;;
    --require-local-validators) REQUIRE_LOCAL_VALIDATORS=1 ;;
    --require-matrix-gate) REQUIRE_DISPATCH_MATRIX_GATE=1 ;;
    --matrix)
      DISPATCH_MATRIX_PATH_ARG=${2:?missing value for --matrix}
      shift
      ;;
    --auto-refresh-preflight) AUTO_REFRESH_PREFLIGHT=1 ;;
    --skip-if-pr-merged) SKIP_IF_PR_MERGED=1 ;;
    --external-pr-mutations)
      EXTERNAL_PR_MUTATIONS_ARG=${2:?missing value for --external-pr-mutations}
      shift
      ;;
    --soft-route) SOFT_ROUTE=1 ;;
    --portfolio)
      PORTFOLIO_ARG=${2:?missing value for --portfolio}
      shift
      ;;
    --portfolio-project|--project)
      PORTFOLIO_PROJECT_ARG=${2:?missing value for $1}
      shift
      ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done
export ORCH_EXTERNAL_PR_MUTATIONS="$EXTERNAL_PR_MUTATIONS_ARG"

load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"
source "$TK/lib/state_persist.sh"
source "$TK/lib/host_load_gate.sh"
source "$TK/lib/tmux_helpers.sh"
source "$TK/lib/worktree_helpers.sh"
source "$TK/lib/prompt_integrity.sh"
# shellcheck source=lib/external_mutation_gate.sh
source "$TK/lib/external_mutation_gate.sh"
# shellcheck source=lib/dispatch_router.sh
source "$TK/lib/dispatch_router.sh"

dispatch_external_pr_mutations_banner() {
  local declared=${ORCH_EXTERNAL_PR_MUTATIONS:-}
  local mode
  if [ -z "$declared" ]; then
    mode="audit-only"
  elif [ "$declared" = "all" ]; then
    mode="all"
  else
    mode="explicit"
  fi
  audit "DISPATCH external_pr_mutations agent=${AGENT} ticket=#${TICKET#\#} mode=${mode} scopes=${declared:-none}"
}

[ -f "$PROMPT_FILE" ] || { echo "prompt file not found: $PROMPT_FILE" >&2; exit 1; }

: "${AGENT_SESSION_PREFIX:=}" "${GH_REPO:?}" "${GH_CONFIG_DIR:?}"
: "${ORCH_TMUX_TIMEOUT_SEC:=10}"
: "${ORCH_GH_TIMEOUT_SEC:=5}"
: "${ORCH_TMUX_DEGRADED_EXIT_CODE:=75}"
: "${DISPATCH_VERIFY_READY:=1}"
: "${DISPATCH_READY_RETRIES:=5}"
: "${DISPATCH_READY_DELAY_SEC:=1}"
# 77 is reserved for the pre-dispatch readiness handshake (#123) and
# is intentionally distinct from ORCH_CONTEXT_MISMATCH_EXIT_CODE=76 used
# by the post-dispatch pane_context_proof gate (#112), so callers can
# tell whether the brief was never sent (77) vs sent into the wrong
# context (76).
: "${ORCH_DISPATCH_NOT_READY_EXIT_CODE:=77}"
: "${ORCH_DISPATCH_NOT_CONSUMED_EXIT_CODE:=79}"

validate_canonical_prompt() {
  local prompt_file=${1:?usage: validate_canonical_prompt <prompt-file>}
  local -a missing=()
  local label pattern
  local -a checks=(
    "Objectif|^##[[:space:]]+Objectif[[:space:]]*$"
    "Format de sortie attendu|^##[[:space:]]+Format de sortie attendu[[:space:]]*$"
    "Tools / sources autorises|^##[[:space:]]+Tools / sources autorises[[:space:]]*$"
    "Boundaries / interdictions|^##[[:space:]]+Boundaries / interdictions[[:space:]]*$"
    "Definition of Done verifiable|^##[[:space:]]+Definition of Done verifiable[[:space:]]*$"
    "Preuves attendues|^##[[:space:]]+Preuves attendues[[:space:]]*$"
  )

  for check in "${checks[@]}"; do
    label=${check%%|*}
    pattern=${check#*|}
    if ! grep -Eq "$pattern" "$prompt_file"; then
      missing+=("$label")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    printf 'missing canonical sections: %s\n' "$(IFS=', '; echo "${missing[*]}")" >&2
    return 1
  fi
}

prompt_mentions_heavy_local_validators() {
  local prompt_file=${1:?usage: prompt_mentions_heavy_local_validators <prompt-file>}
  grep -Eq '(^|[^A-Za-z0-9_./-])(timeout[[:space:]]+[0-9]+[[:space:]]+)?bash[[:space:]]+scripts/(run_shellcheck|run_shell_tests|run_bats)\.sh([^A-Za-z0-9_./-]|$)' "$prompt_file"
}

prompt_requires_local_validators() {
  local prompt_file=${1:?usage: prompt_requires_local_validators <prompt-file>}
  grep -Eq '^[[:space:]]*-[[:space:]]*require-local-validators:[[:space:]]*yes[[:space:]]*$' "$prompt_file"
}

# #268: external-pr-mutations declaration on the prompt body, in the same
# style as require-local-validators. Prints the comma-separated declared
# scopes on stdout (empty when the prompt makes no claim, which means the
# default audit-only policy applies).
prompt_external_pr_mutations() {
  local prompt_file=${1:?usage: prompt_external_pr_mutations <prompt-file>}
  awk '
    BEGIN { found = "" }
    /^[[:space:]]*-[[:space:]]*external-pr-mutations:[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*external-pr-mutations:[[:space:]]*/, "")
      gsub(/[[:space:]]/, "")
      found = $0
      exit
    }
    END { print found }
  ' "$prompt_file"
}

TICKET_NUM=${TICKET#\#}

# Opt-in PR-merged pre-check (#371). When SKIP_IF_PR_MERGED=1 and the
# ticket is a numeric PR, query GitHub once for state + mergedAt and
# refuse to paste a brief into the agent pane if the PR is already
# merged (or closed without merge). The default is off, so existing
# dispatch_ticket callers see no behavior change. ci_autofix.sh sets
# the env var when it forwards autofix dispatches.
case "$SKIP_IF_PR_MERGED" in
  1|yes|true|on) SKIP_IF_PR_MERGED=1 ;;
  *) SKIP_IF_PR_MERGED=0 ;;
esac
if [ "$SKIP_IF_PR_MERGED" -eq 1 ] && [[ "$TICKET_NUM" =~ ^[0-9]+$ ]]; then
  pr_state_json=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$TICKET_NUM" \
    --repo "$GH_REPO" \
    --json state,mergedAt,closedAt,mergeCommit 2>/dev/null || printf '{}')
  pr_state_value=$(printf '%s' "$pr_state_json" | jq -r '.state // ""')
  pr_state_merged_at=$(printf '%s' "$pr_state_json" | jq -r '.mergedAt // ""')
  pr_state_closed_at=$(printf '%s' "$pr_state_json" | jq -r '.closedAt // ""')
  pr_state_merge_commit=$(printf '%s' "$pr_state_json" | jq -r '.mergeCommit.oid // .mergeCommit // ""')
  if [ "$pr_state_value" = "MERGED" ] || [ -n "$pr_state_merged_at" ]; then
    audit "DISPATCH skip reason=already_merged agent=${AGENT} ticket=#${TICKET_NUM} mergedAt=${pr_state_merged_at:-unknown} mergeCommit=${pr_state_merge_commit:-unknown}"
    printf 'dispatch_ticket: skipping #%s — PR already merged at %s (commit %s)\n' \
      "$TICKET_NUM" "${pr_state_merged_at:-unknown}" "${pr_state_merge_commit:-unknown}" >&2
    exit 0
  fi
  if [ "$pr_state_value" = "CLOSED" ]; then
    audit "DISPATCH skip reason=closed_without_merge agent=${AGENT} ticket=#${TICKET_NUM} closedAt=${pr_state_closed_at:-unknown}"
    printf 'dispatch_ticket: skipping #%s — PR closed without merge at %s; reopen or open a new PR before retry\n' \
      "$TICKET_NUM" "${pr_state_closed_at:-unknown}" >&2
    exit 0
  fi
fi

if [ "$VALIDATE_PROMPT" -eq 1 ]; then
  validate_canonical_prompt "$PROMPT_FILE"
  validate_prompt_integrity "$PROMPT_FILE"
else
  audit "DISPATCH VALIDATION BYPASSED agent=${AGENT} ticket=#${TICKET#\#} prompt=$(basename "$PROMPT_FILE")"
fi

# Emit the external-PR-mutation gate banner before any potentially mutating
# step so operator-declared scope is on record even if dispatch refuses
# downstream (host-load gate, tmux degraded, context proof, etc.).
dispatch_external_pr_mutations_banner

case "$REQUIRE_LOCAL_VALIDATORS" in
  1|yes|true|on) REQUIRE_LOCAL_VALIDATORS=1 ;;
  0|no|false|off|'') REQUIRE_LOCAL_VALIDATORS=0 ;;
  *)
    printf 'invalid ORCH_REQUIRE_LOCAL_VALIDATORS value: %s\n' "$REQUIRE_LOCAL_VALIDATORS" >&2
    exit 2
    ;;
esac
if [ "$REQUIRE_LOCAL_VALIDATORS" -eq 1 ] \
  || prompt_requires_local_validators "$PROMPT_FILE"; then
  orch_host_load_gate \
    "local_validators:${PROJECT}:${AGENT}:#${TICKET_NUM}" \
    "${ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE:-${ORCH_HOST_GATE_MODE:-off}}"
fi
if prompt_mentions_heavy_local_validators "$PROMPT_FILE" \
  && [ "$REQUIRE_LOCAL_VALIDATORS" -ne 1 ] \
  && ! prompt_requires_local_validators "$PROMPT_FILE"; then
  printf '%s\n' \
    "dispatch_ticket: full local validators require --require-local-validators; default is CI-delegated validation" >&2
  exit "${ORCH_HEAVY_VALIDATION_EXIT_CODE:-78}"
fi

# Direct dispatch matrix gate (#253). Opt-in only: the normal local
# issue-pack handoff stays the default path. When the operator passes
# --require-matrix-gate (or sets ORCH_REQUIRE_DISPATCH_MATRIX_GATE=1),
# refuse to dispatch unless the matrix has a row for $TICKET_NUM and
# that row evaluates as ready (not blocked, dirty, conflicting, or
# already owned by another agent).
case "$REQUIRE_DISPATCH_MATRIX_GATE" in
  1|yes|true|on) REQUIRE_DISPATCH_MATRIX_GATE=1 ;;
  0|no|false|off|'') REQUIRE_DISPATCH_MATRIX_GATE=0 ;;
  *)
    printf 'invalid ORCH_REQUIRE_DISPATCH_MATRIX_GATE value: %s\n' \
      "$REQUIRE_DISPATCH_MATRIX_GATE" >&2
    exit 2
    ;;
esac
if [ "$REQUIRE_DISPATCH_MATRIX_GATE" -eq 1 ]; then
  # shellcheck source=../lib/dispatch_matrix.sh
  source "$TK/lib/dispatch_matrix.sh"
  matrix_path="$DISPATCH_MATRIX_PATH_ARG"
  [ -n "$matrix_path" ] || matrix_path=$(dispatch_matrix_default_path)
  matrix_reason=""
  matrix_rc=0
  if matrix_reason=$(dispatch_matrix_evaluate_row "$matrix_path" "$TICKET_NUM" 2>&1 1>/dev/null); then
    matrix_rc=0
  else
    matrix_rc=$?
  fi
  if [ "$matrix_rc" -ne 0 ]; then
    audit "DISPATCH MATRIX GATE refused agent=${AGENT} ticket=#${TICKET_NUM} matrix=${matrix_path} reason=${matrix_reason}"
    printf 'dispatch-matrix-gate refused: agent=%s ticket=#%s matrix=%s reason=%s\n' \
      "$AGENT" "$TICKET_NUM" "$matrix_path" "$matrix_reason" >&2
    exit "$matrix_rc"
  fi
  audit "DISPATCH MATRIX GATE ready agent=${AGENT} ticket=#${TICKET_NUM} matrix=${matrix_path}"
fi

# #268 external-pr-mutation gate. The prompt may declare which external-PR
# scopes it expects to mutate; the orchestrator must explicitly authorize
# each requested scope (env or --external-pr-mutations) or the dispatch is
# refused. When no declaration is present, audit-only is the default and the
# dispatch proceeds without granting anything.
PROMPT_EXTERNAL_PR_MUTATIONS=$(prompt_external_pr_mutations "$PROMPT_FILE" || true)
if [ -n "$PROMPT_EXTERNAL_PR_MUTATIONS" ]; then
  IFS=',' read -r -a __orch_dispatch_requested <<<"$PROMPT_EXTERNAL_PR_MUTATIONS"
  IFS=',' read -r -a __orch_dispatch_authorized <<<"${EXTERNAL_PR_MUTATIONS_ARG:-}"
  __orch_unmet=()
  for __orch_scope in "${__orch_dispatch_requested[@]}"; do
    __orch_scope=${__orch_scope// /}
    [ -z "$__orch_scope" ] && continue
    [ "$__orch_scope" = "audit_evidence" ] && continue
    __orch_match=0
    for __orch_authz in "${__orch_dispatch_authorized[@]}"; do
      __orch_authz=${__orch_authz// /}
      [ -z "$__orch_authz" ] && continue
      if [ "$__orch_authz" = "all" ] || [ "$__orch_authz" = "$__orch_scope" ]; then
        __orch_match=1
        break
      fi
    done
    if [ "$__orch_match" -eq 0 ]; then
      __orch_unmet+=("$__orch_scope")
    fi
  done
  if [ "${#__orch_unmet[@]}" -gt 0 ]; then
    audit "DISPATCH REFUSED reason=external_pr_mutations_unauthorized agent=${AGENT} ticket=#${TICKET_NUM} requested=${PROMPT_EXTERNAL_PR_MUTATIONS} authorized=${EXTERNAL_PR_MUTATIONS_ARG:-<empty>} unmet=$(IFS=,; echo "${__orch_unmet[*]}")"
    printf 'dispatch_ticket: prompt requests external-pr-mutations=%s; not authorized=%s; default is audit-only — pass --external-pr-mutations or set ORCH_EXTERNAL_PR_MUTATIONS\n' \
      "$PROMPT_EXTERNAL_PR_MUTATIONS" "$(IFS=,; echo "${__orch_unmet[*]}")" >&2
    exit "${ORCH_EXTERNAL_PR_MUTATION_REFUSED_EXIT_CODE:-80}"
  fi
  audit "DISPATCH external_pr_mutations agent=${AGENT} ticket=#${TICKET_NUM} requested=${PROMPT_EXTERNAL_PR_MUTATIONS} authorized=${EXTERNAL_PR_MUTATIONS_ARG:-<empty>}"
  unset __orch_dispatch_requested __orch_dispatch_authorized __orch_unmet __orch_scope __orch_authz __orch_match
else
  audit "DISPATCH external_pr_mutations agent=${AGENT} ticket=#${TICKET_NUM} requested=<none> authorized=${EXTERNAL_PR_MUTATIONS_ARG:-<empty>} mode=audit-only"
fi

assign_ticket_if_requested() {
  # Policy (issue #273): GitHub assignment is opt-in via --assign. Every
  # dispatch emits an explicit assignee_policy audit line — applied,
  # skipped, refused, or failed — and surfaces the local assignment
  # ledger so operators can correlate ORDO state with what GitHub shows.
  local ledger_path
  if declare -F state_file >/dev/null 2>&1; then
    ledger_path=$(state_file assignments.json 2>/dev/null || printf '%s' '<unset>')
  else
    ledger_path='<unset>'
  fi

  if [ "$ASSIGN" -ne 1 ]; then
    audit "DISPATCH assignee_policy=skipped ticket=#${TICKET_NUM} reason=disabled-by-default ledger=${ledger_path}"
    if [ "${ORCH_DISPATCH_QUIET_LEDGER:-0}" != "1" ]; then
      printf 'dispatch_ticket: GitHub assignment disabled by policy (default); local assignment ledger: %s\n' \
        "$ledger_path" >&2
    fi
    return 0
  fi

  if [[ ! "$TICKET_NUM" =~ ^[0-9]+$ ]]; then
    audit "DISPATCH assignee_policy=skipped ticket=${TICKET_NUM} reason=non-numeric ledger=${ledger_path}"
    return 0
  fi

  local gh_login
  gh_login=$(resolve_agent_github_login "$AGENT")

  if dry_run_enabled; then
    dry_run_note "gh issue edit $TICKET_NUM --repo $GH_REPO --add-assignee $gh_login"
    audit "DISPATCH assignee_policy=skipped ticket=#${TICKET_NUM} reason=dry-run expected_login=${gh_login} ledger=${ledger_path}"
    return 0
  fi

  # Gate ordering (#273 + #289): identity guard runs first, then the
  # external-PR-mutation gate. #273 explicitly designates the identity guard
  # as the mechanism that "prevents assigning the wrong actor" with refusal
  # exit code 78, so a wrong-actor dispatch must surface
  # `github_identity_mismatch` rather than a generic scope refusal. #289 is
  # silent on order; defense-in-depth is preserved either way because both
  # gates still run at the call site. Reading the runtime story: identity
  # ("who is acting?") is a precondition for authorization ("is this actor
  # allowed?") — refusing on identity first matches the conceptual layering.
  local guard_status=0
  orch_github_identity_guard "$gh_login" "dispatch_ticket:assign:#${TICKET_NUM}" \
    || guard_status=$?
  if [ "$guard_status" -ne 0 ]; then
    local active_login
    active_login=$(orch_github_active_login || true)
    audit "DISPATCH assignee_policy=refused ticket=#${TICKET_NUM} expected_login=${gh_login} active_login=${active_login:-unknown} reason=identity-mismatch guard_exit=${guard_status} ledger=${ledger_path}"
    return 0
  fi

  # Required Rule 12: every external mutation runs through the gate. The
  # assignee path is `issue_assignees` because it edits a GitHub issue's
  # assignee list on a third-party-managed repo. Refusal short-circuits the
  # mutation and exits with $ORCH_EXTERNAL_PR_MUTATION_EXIT_CODE (80) so
  # dashboards can group it with other gate refusals.
  local gate_rc=0
  external_pr_mutation_assert issue_assignees \
    "dispatch_ticket:assign:#${TICKET_NUM}" || gate_rc=$?
  if [ "$gate_rc" -ne 0 ]; then
    audit "DISPATCH assignee_policy=refused ticket=#${TICKET_NUM} expected_login=${gh_login} reason=external-pr-mutation-gate gate_exit=${gate_rc} ledger=${ledger_path}"
    return "$gate_rc"
  fi

  local assign_status=0 assign_output
  assign_output=$(orch_run_timeout "$ORCH_GH_TIMEOUT_SEC" env GH_CONFIG_DIR="$GH_CONFIG_DIR" \
    gh issue edit "$TICKET_NUM" \
      --repo "$GH_REPO" \
      --add-assignee "$gh_login" 2>&1) || assign_status=$?
  if [ -n "$assign_output" ]; then
    printf '%s\n' "$assign_output" | tail -3
  fi
  if [ "$assign_status" -eq 0 ]; then
    audit "DISPATCH assignee_policy=applied ticket=#${TICKET_NUM} login=${gh_login} ledger=${ledger_path}"
  else
    audit "DISPATCH assignee_policy=failed ticket=#${TICKET_NUM} expected_login=${gh_login} reason=gh-error gh_exit=${assign_status} ledger=${ledger_path}"
  fi
}

record_dispatch_not_consumed_blocker() {
  local reason=${1:-not-consumed}
  local detail=${2:-}
  local attempts=${3:-${DISPATCH_SUBMIT_ATTEMPT:-0}}
  local created_at id blocker_file tmp existing_open record task_line

  created_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  id=$(printf '%s|%s|%s|%s|dispatch-not-consumed' \
    "${PROJECT:-unknown}" "$AGENT" "$TICKET_NUM" "$PANE_TARGET" \
    | sha256sum | awk '{print substr($1,1,16)}')
  blocker_file=$(state_file dispatch_blockers.json)
  tmp="${blocker_file}.tmp.$$"
  mkdir -p "$(dirname "$blocker_file")"

  record=$(jq -nc \
    --arg id "$id" \
    --arg created_at "$created_at" \
    --arg code "dispatch-not-consumed" \
    --arg project "${PROJECT:-}" \
    --arg agent "$AGENT" \
    --arg ticket "$TICKET_NUM" \
    --arg pane "$PANE_TARGET" \
    --arg workdir "${WORKDIR:-}" \
    --arg prompt_file "${STAGED:-}" \
    --arg reason "$reason" \
    --arg detail "$detail" \
    --arg attempts "$attempts" \
    '{
      id:$id,
      created_at:$created_at,
      status:"open",
      code:$code,
      project:$project,
      agent:$agent,
      ticket:$ticket,
      pane:$pane,
      workdir:$workdir,
      prompt_file:$prompt_file,
      reason:$reason,
      detail:$detail,
      attempts:($attempts|tonumber? // 0),
      recommended_action:"Inspect the terminal pane, clear stale input or queued work, then redispatch or recover the agent."
    }')

  existing_open="{}"
  if [[ -s "$blocker_file" ]]; then
    existing_open=$(jq -c '.open // {}' "$blocker_file" 2>/dev/null || printf '{}')
  fi

  if [[ -s "$blocker_file" ]]; then
    jq \
      --arg id "$id" \
      --argjson record "$record" \
      --argjson existing_open "$existing_open" \
      '
        . as $old
        | {
            open: (($old.open // {}) + {($id): $record}),
            history: (($old.history // [])
              + (if ($existing_open[$id] // null) == null then [$record] else [] end))
          }
      ' "$blocker_file" > "$tmp"
  else
    jq -nc --arg id "$id" --argjson record "$record" \
      '{open:{($id):$record}, history:[$record]}' > "$tmp"
  fi
  mv "$tmp" "$blocker_file"

  task_line="- [ ] ${created_at} id=${id} code=dispatch-not-consumed agent=${AGENT} ticket=#${TICKET_NUM} pane=${PANE_TARGET} action=Inspect terminal pane, clear stale input or queued work, then redispatch or recover the agent."
  state_append_unique "ORCH_TASKS.md" "$task_line"
  audit "DISPATCH NOT_CONSUMED agent=${AGENT} ticket=#${TICKET_NUM} pane=${PANE_TARGET} reason=${reason} attempts=${attempts}"
}

dispatch_same_pr_workdir_matches_ticket() {
  local workdir=${1:?usage: dispatch_same_pr_workdir_matches_ticket <workdir> <ticket>}
  local ticket=${2:?usage: dispatch_same_pr_workdir_matches_ticket <workdir> <ticket>}
  local branch dirty pr_json pr_number

  [[ -d "$workdir/.git" ]] || return 1
  dirty=$(git -C "$workdir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  [[ "${dirty:-0}" == "0" ]] || return 1

  branch=$(git -C "$workdir" branch --show-current 2>/dev/null || true)
  [[ -n "$branch" && "$branch" != "${DEFAULT_BRANCH:-main}" ]] || return 1
  [[ -n "${GH_REPO:-}" ]] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  pr_json=$(orch_run_timeout "$ORCH_GH_TIMEOUT_SEC" env GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" gh pr list \
    --repo "$GH_REPO" \
    --state open \
    --head "$branch" \
    --json number,headRefName,headRefOid,mergeStateStatus \
    --limit 1 2>/dev/null || printf '[]')
  pr_number=$(printf '%s' "$pr_json" | jq -r '.[0].number // ""' 2>/dev/null || printf '')
  [[ -n "$pr_number" && "$pr_number" == "${ticket#\#}" ]]
}

dispatch_preflight_status_allows_same_pr() {
  case "${1:-}" in
    local_work_branch|branch_needs_rebase)
      return 0
      ;;
  esac
  return 1
}

if [[ -n "$PORTFOLIO_ARG" ]]; then
  project_for_portfolio="${PORTFOLIO_PROJECT_ARG:-${PROJECT:-}}"
  [[ -n "$project_for_portfolio" ]] || {
    echo "portfolio project is required for matrix dispatch resolution" >&2
    exit 4
  }
  load_portfolio_config "$PORTFOLIO_ARG"
  target_cfg=$(portfolio_find_project "$project_for_portfolio")
  current_cfg=$(readlink -f "${ORCH_CONFIG_PATH:-$(resolve_config_path "$CFG_ARG")}")
  target_cfg_real=$(readlink -f "$target_cfg")
  if [[ "$current_cfg" != "$target_cfg_real" ]]; then
    echo "portfolio context mismatch: dispatch config=$current_cfg portfolio project ${project_for_portfolio} config=$target_cfg_real" >&2
    exit 4
  fi

  # Wave-startup preflight gate (#267): evaluate report-level freshness once
  # the portfolio is loaded but before any matrix expansion or per-agent work.
  # The orchestrator is expected to have run this same gate at wave startup
  # via `scripts/portfolio_session_start.sh --ensure-fresh`; this is the
  # in-dispatch safety net so the wave fails on a stale report without first
  # walking the matrix.
  #
  # Behavior:
  #   - fresh report: continue silently.
  #   - stale/missing/jq_missing without auto-refresh: audit
  #     `PREFLIGHT REFUSED` and let the existing per-agent guard surface the
  #     canonical `portfolio_preflight_required` line and exit 4.
  #   - stale/missing with --auto-refresh-preflight (or
  #     ORCH_AUTO_REFRESH_PREFLIGHT=1): shell out to portfolio_session_start
  #     in --ensure-fresh --auto-refresh-if-stale mode, audit
  #     `PREFLIGHT REFRESHED`, and let the per-agent guard re-evaluate the
  #     refreshed state.
  if [[ "${PORTFOLIO_REQUIRE_PREFLIGHT:-1}" == "1" ]]; then
    wave_freshness=$(portfolio_preflight_report_freshness_status 2>/dev/null || true)
    wave_age=$(portfolio_preflight_report_age_sec 2>/dev/null || true)
    wave_report=$(portfolio_preflight_report_path)
    wave_max_age=$(portfolio_preflight_max_age_sec)
    case "$wave_freshness" in
      ok)
        ;;
      missing|stale|jq_missing)
        if [[ "$AUTO_REFRESH_PREFLIGHT" == "1" ]]; then
          audit "PREFLIGHT REFRESH START agent=${AGENT} project=${project_for_portfolio} previous_status=${wave_freshness} age_sec=${wave_age:-unknown} max_age_sec=${wave_max_age} report=${wave_report}"
          if bash "$TK/scripts/portfolio_session_start.sh" "$PORTFOLIO_ARG" \
              --ensure-fresh --auto-refresh-if-stale --json >/dev/null 2>&1; then
            refreshed_status=$(portfolio_preflight_report_freshness_status 2>/dev/null || true)
            refreshed_age=$(portfolio_preflight_report_age_sec 2>/dev/null || true)
            audit "PREFLIGHT REFRESHED agent=${AGENT} project=${project_for_portfolio} previous_status=${wave_freshness} status=${refreshed_status} age_sec=${refreshed_age:-unknown} max_age_sec=${wave_max_age} report=${wave_report}"
          else
            audit "PREFLIGHT REFRESH FAILED agent=${AGENT} project=${project_for_portfolio} previous_status=${wave_freshness} max_age_sec=${wave_max_age} report=${wave_report}"
            echo "portfolio_preflight_refresh_failed: agent=$AGENT status=$wave_freshness report=$wave_report; rerun scripts/portfolio_session_start.sh $PORTFOLIO_ARG --json" >&2
            exit 4
          fi
        else
          audit "PREFLIGHT REFUSED agent=${AGENT} project=${project_for_portfolio} status=${wave_freshness} age_sec=${wave_age:-unknown} max_age_sec=${wave_max_age} report=${wave_report}"
        fi
        ;;
    esac
  fi

  matrix_spec=$(portfolio_fleet_spec)
  ensure_matrix="${PORTFOLIO_ENSURE_AGENT_MATRIX:-}"
  if [[ -z "$ensure_matrix" ]]; then
    if [[ -n "$matrix_spec" ]]; then
      ensure_matrix=1
    else
      ensure_matrix=0
    fi
  fi
  if ! portfolio_expand_matrix_agent_pane "$AGENT" "$matrix_spec" "$ensure_matrix" >/dev/null; then
    echo "agent not found in project config or portfolio matrix: $AGENT" >&2
    exit 4
  fi

  # Resolve the matrix workdir from AGENT_PANES (populated by the call above;
  # doing this in a command substitution would hide the AGENT_PANES mutation
  # from agent_target later).
  matrix_workdir=""
  matrix_entry=$(agent_inventory_find "$AGENT" 2>/dev/null || true)
  if [[ -n "$matrix_entry" ]]; then
    IFS='|' read -r _ _ matrix_workdir <<< "$matrix_entry"
  fi

  same_pr_dispatch=0
  preflight_row_status=""
  if [[ -n "$matrix_workdir" ]] \
    && dispatch_same_pr_workdir_matches_ticket "$matrix_workdir" "$TICKET_NUM"; then
    same_pr_dispatch=1
  fi

  canonical_url=$(portfolio_canonical_clone_url_for_loaded_project)
  default_branch_for_matrix="${DEFAULT_BRANCH:-main}"
  if [[ -n "$canonical_url" && -n "$matrix_workdir" && -d "$matrix_workdir/.git" ]]; then
    if ! portfolio_workdir_origin_matches_canonical "$matrix_workdir" "$canonical_url"; then
      actual_origin=$(portfolio_workdir_origin_url "$matrix_workdir" 2>/dev/null || printf '<unset>')
      audit "DISPATCH REFUSED reason=duplicate_clone_remote_mismatch agent=${AGENT} project=${project_for_portfolio} workdir=${matrix_workdir}"
      echo "duplicate-clone context mismatch (context-mismatch): agent=$AGENT workdir=$matrix_workdir origin=$actual_origin canonical=$canonical_url" >&2
      exit 4
    fi
  fi

  if [[ "${PORTFOLIO_REQUIRE_PREFLIGHT:-1}" == "1" ]]; then
    # #279: pass the target project alias and expected matrix workdir into the
    # preflight check. Multi-project portfolios reuse labels (`claude`, `codex`,
    # `cursor`, ...), so a label-only readiness check can satisfy the dispatch
    # gate for the wrong project. Project + workdir scoping closes that gap.
    preflight_status=$(portfolio_preflight_target_status \
      "$AGENT" "$project_for_portfolio" "$matrix_workdir" 2>/dev/null || true)
    case "$preflight_status" in
      ok)
        ;;
      missing|stale|jq_missing)
        echo "portfolio_preflight_required: agent=$AGENT project=$project_for_portfolio status=$preflight_status report=$(portfolio_preflight_report_path); rerun scripts/portfolio_session_start.sh" >&2
        exit 4
        ;;
      not_found|not_ready)
        preflight_row_status=$(portfolio_preflight_target_row_status \
          "$AGENT" "$project_for_portfolio" "$matrix_workdir" 2>/dev/null || true)
        if [[ "$preflight_status" == "not_ready" \
          && "$same_pr_dispatch" -eq 1 ]] \
          && dispatch_preflight_status_allows_same_pr "$preflight_row_status"; then
          audit "DISPATCH PREFLIGHT SAME_PR_OK agent=${AGENT} ticket=#${TICKET_NUM} project=${project_for_portfolio} workdir=${matrix_workdir} status=${preflight_row_status}"
        else
          echo "portfolio_target_not_ready: agent=$AGENT project=$project_for_portfolio status=$preflight_status report=$(portfolio_preflight_report_path)" >&2
          exit 4
        fi
        ;;
      wrong_project|wrong_workdir)
        echo "portfolio_preflight_wrong_target: agent=$AGENT project=$project_for_portfolio workdir=$matrix_workdir status=$preflight_status report=$(portfolio_preflight_report_path); rerun scripts/portfolio_session_start.sh for the target project" >&2
        exit 4
        ;;
      *)
        echo "portfolio_preflight_required: agent=$AGENT project=$project_for_portfolio status=${preflight_status:-unknown} report=$(portfolio_preflight_report_path)" >&2
        exit 4
        ;;
    esac
  fi

  # F-023/F-024/F-030/F-031 — require matrix readiness before matrix
  # dispatch. Refusal reasons are now state-specific (#367): the audit
  # log records the porcelain-proven dirty count, the in-progress git
  # operation marker, the branch + upstream + ahead/behind, and the
  # non-destructive recovery action the orchestrator should take next
  # — only DIRTY and IN_PROGRESS_OP states are treated as destructive
  # and require RECOVERY_CONTEXT_PROOF.
  if [[ -n "$matrix_workdir" ]]; then
    if ! portfolio_assert_workdir_ready "$matrix_workdir" "$default_branch_for_matrix"; then
      # Same-PR escape hatch (#379): when this dispatch is the operator's
      # own same-PR work AND the upstream preflight already classifies
      # the row as same-PR-allowable, accept the readiness signal as a
      # warning rather than a refusal — the agent already owns the
      # workdir and is iterating on its own PR. Otherwise refuse with
      # the full structured #367 readiness diagnostics so the audit
      # log records the precise reason instead of a generic
      # "uncommitted changes" claim.
      if [[ "$same_pr_dispatch" -eq 1 ]] \
        && dispatch_preflight_status_allows_same_pr "$preflight_row_status"; then
        audit "DISPATCH MATRIX SAME_PR_OK agent=${AGENT} ticket=#${TICKET_NUM} project=${project_for_portfolio} workdir=${matrix_workdir} preflight_status=${preflight_row_status} state=${PORTFOLIO_WORKDIR_READINESS_STATE:-unknown} branch=${PORTFOLIO_WORKDIR_READINESS_BRANCH:-} dirty=${PORTFOLIO_WORKDIR_READINESS_DIRTY:-0} recovery_action=${PORTFOLIO_WORKDIR_READINESS_RECOVERY_ACTION:-none}"
      else
        audit "DISPATCH REFUSED reason=matrix_workdir_not_ready state=${PORTFOLIO_WORKDIR_READINESS_STATE:-unknown} branch=${PORTFOLIO_WORKDIR_READINESS_BRANCH:-} upstream=${PORTFOLIO_WORKDIR_READINESS_UPSTREAM:-} ahead=${PORTFOLIO_WORKDIR_READINESS_AHEAD:-0} behind=${PORTFOLIO_WORKDIR_READINESS_BEHIND:-0} dirty=${PORTFOLIO_WORKDIR_READINESS_DIRTY:-0} dirty_modified=${PORTFOLIO_WORKDIR_READINESS_DIRTY_MODIFIED:-0} dirty_untracked=${PORTFOLIO_WORKDIR_READINESS_DIRTY_UNTRACKED:-0} in_progress=${PORTFOLIO_WORKDIR_READINESS_IN_PROGRESS:-} recovery_action=${PORTFOLIO_WORKDIR_READINESS_RECOVERY_ACTION:-none} destructive=${PORTFOLIO_WORKDIR_READINESS_DESTRUCTIVE:-0} agent=${AGENT} project=${project_for_portfolio} workdir=${matrix_workdir}"
        exit 4
      fi
    fi
  fi
fi

PANE_TARGET=$(agent_target "$AGENT")
PANE="${PANE_TARGET%%:*}"  # session name only — what tmux has-session expects
if dry_run_enabled; then
  dry_run_note "tmux has-session -t $PANE"
else
  if ! orch_tmux_probe; then
    audit "DISPATCH TMUX DEGRADED agent=${AGENT} ticket=#${TICKET_NUM} signal=tmux_degraded fallback=github-only"
    printf 'tmux_degraded: %s; tmux dispatch not sent; fallback=github-only\n' \
      "${ORCH_TMUX_DEGRADED_REASON:-tmux probe failed}" >&2
    assign_ticket_if_requested
    exit "$ORCH_TMUX_DEGRADED_EXIT_CODE"
  fi
  orch_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" tmux has-session -t "$PANE" 2>/dev/null || {
    echo "tmux pane $PANE_TARGET (session $PANE) not found" >&2
    exit 1
  }
fi

# Routing-surface guard (#376). Refuse before staging or sending when
# the prompt body, the staging filename slug, the pinned cwd, the
# resolved pane and the workdir-side git identity disagree about which
# agent is being addressed. The declarative workdir (`agent_repo_root`)
# is the right reference here even when worktrees are enabled — the
# brief pins the repo root, not the per-ticket worktree path.
if ! dispatch_router_assert_consistency \
    "$AGENT" "$TICKET_NUM" "$PANE_TARGET" "$PROMPT_FILE" \
    "$(agent_repo_root "$AGENT")"; then
  exit "$ORCH_DISPATCH_ROUTE_MISMATCH_EXIT_CODE"
fi

# Persist a stable copy alongside the orchestrator state for audit trail.
# Idempotent: if the caller already placed the brief at the staging path, skip
# the copy (cp would error "are the same file" and `set -e` would abort the
# script before any tmux send happens — silent dispatch failure).
STAGED="/tmp/dispatch-${AGENT}-${TICKET_NUM}.md"
# #313 — refuse to stage the brief inside any active worktree. `/tmp` is
# outside by construction, but the call makes the contract explicit so a
# future operator who reroutes the staging path cannot silently drop the
# brief into a feature branch. The guard honours
# `ORCH_EVIDENCE_PATH_GUARD={strict,warn,off}` for migrations.
audit_assert_evidence_outside_worktree "$STAGED" "dispatch_ticket:STAGED" \
  || die "evidence path guard refused $STAGED — set ORCH_EVIDENCE_PATH_GUARD=warn|off to override"
if [ "$(readlink -f "$PROMPT_FILE")" != "$(readlink -f "$STAGED" 2>/dev/null)" ]; then
  dry_run_exec "cp $PROMPT_FILE $STAGED" cp "$PROMPT_FILE" "$STAGED"
fi

WORKDIR=$(agent_repo_root "$AGENT")
BRANCH=""
if worktree_enabled; then
  BRANCH=$(worktree_feature_branch "$TICKET_NUM")
  if dry_run_enabled; then
    WORKDIR=$(worktree_path "$AGENT" "$TICKET_NUM")
    dry_run_note "git -C $(agent_repo_root "$AGENT") worktree add -B $BRANCH $WORKDIR origin/$DEFAULT_BRANCH"
  else
    WORKDIR=$(worktree_create "$AGENT" "$TICKET_NUM")
    tmux_cmd=$(agent_launch_command "$PANE_TARGET")
    orch_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" tmux respawn-pane -k -t "$PANE_TARGET" -c "$WORKDIR" "$tmux_cmd"
    sleep 2
    # Issue #123: post-respawn readiness handshake. Refuse dispatch if the
    # pane is not in $WORKDIR with the agent CLI live, instead of writing
    # the brief into a half-booted shell.
    if [[ "$DISPATCH_VERIFY_READY" == "1" ]]; then
      if ! agent_pane_ready "$PANE_TARGET" "$WORKDIR" \
        "$DISPATCH_READY_RETRIES" "$DISPATCH_READY_DELAY_SEC"; then
        audit "DISPATCH NOT READY agent=${AGENT} ticket=#${TICKET_NUM} pane=${PANE_TARGET} reason=${AGENT_READY_REASON:-unknown} detail=${AGENT_READY_DETAIL:-}"
        printf 'dispatch ready handshake failed: pane=%s reason=%s detail=%s\n' \
          "$PANE_TARGET" "${AGENT_READY_REASON:-unknown}" "${AGENT_READY_DETAIL:-}" >&2
        exit "$ORCH_DISPATCH_NOT_READY_EXIT_CODE"
      fi
    fi
  fi
fi

if ! dry_run_enabled; then
  dispatched_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  assignment_file=$(state_file assignments.json)
  assignment_tmp="${assignment_file}.tmp.$$"
  issue_arg=()
  if [[ "$TICKET_NUM" =~ ^[0-9]+$ ]]; then
    issue_arg=(--argjson issue "$TICKET_NUM")
  else
    issue_arg=(--arg issue "$TICKET_NUM")
  fi
  state_get assignments | jq \
    --arg agent "$AGENT" \
    --arg branch "$BRANCH" \
    --arg workdir "$WORKDIR" \
    --arg repo_root "$(agent_repo_root "$AGENT")" \
    --arg prompt_file "$STAGED" \
    --arg dispatched_at "$dispatched_at" \
    "${issue_arg[@]}" \
    '.[$agent] = {
      ticket: ($issue | tostring),
      issue: $issue,
      branch: (if $branch == "" then null else $branch end),
      workdir: $workdir,
      repo_root: $repo_root,
      prompt_file: $prompt_file,
      dispatched_at: $dispatched_at
    }' > "$assignment_tmp"
  mv "$assignment_tmp" "$assignment_file"
else
  dry_run_note "record assignment agent=$AGENT ticket=$TICKET_NUM workdir=$WORKDIR branch=${BRANCH:-default}"
fi

# Build the one-liner the terminal agent reads.
ONELINER="Read $STAGED and execute it end-to-end. Stay strictly in scope. Verify your git identity matches the agent name before commit. Report final status."

# Submit via paste-buffer, then Enter as a separate terminal event. Use
# $PANE_TARGET (full session:window.pane) so universal fleets with shared
# sessions still hit the intended pane.
if dry_run_enabled; then
  dry_run_note "tmux load-buffer -b orch_send <dispatch-text>"
  dry_run_note "tmux paste-buffer -b orch_send -t $PANE_TARGET -d"
  dry_run_note "tmux send-keys -t $PANE_TARGET Enter"
else
  if ! terminal_dispatch_submit "$PANE_TARGET" "$ONELINER"; then
    record_dispatch_not_consumed_blocker \
      "${DISPATCH_SUBMIT_LAST_REASON:-not-consumed}" \
      "${DISPATCH_SUBMIT_LAST_DETAIL:-}" \
      "${DISPATCH_SUBMIT_ATTEMPT:-0}"
    printf 'dispatch-not-consumed: agent=%s ticket=#%s pane=%s reason=%s detail=%s\n' \
      "$AGENT" "$TICKET_NUM" "$PANE_TARGET" \
      "${DISPATCH_SUBMIT_LAST_REASON:-not-consumed}" \
      "${DISPATCH_SUBMIT_LAST_DETAIL:-}" >&2
    exit "$ORCH_DISPATCH_NOT_CONSUMED_EXIT_CODE"
  fi
fi

audit "DISPATCH agent=${AGENT} ticket=#${TICKET_NUM} prompt=$(basename "$STAGED")"

# Record the routing decision (#286). A hard-switched dispatch goes through
# `agent_product_switch.sh` (or worktree respawn) and the pane CWD is the
# target workdir before the brief is sent. A soft-routed dispatch sends the
# brief into a pane that may still be in another product workdir; the agent
# is expected to `cd` into the absolute target path itself.
if [[ "$SOFT_ROUTE" == "1" ]]; then
  DISPATCH_ROUTE="soft"
else
  DISPATCH_ROUTE="hard"
fi
audit "DISPATCH ROUTE agent=${AGENT} ticket=#${TICKET_NUM} pane=${PANE_TARGET} route=${DISPATCH_ROUTE}"

# Post-dispatch live pane context proof (issue #112, extended #286): after
# the prompt is delivered, sleep briefly then verify pwd / remote / branch /
# target workdir line up with what dispatch recorded. The check now also
# compares the pane's live current_path against WORKDIR. Skipped in dry-run
# because no pane was actually written; can be force-disabled via
# ORCH_CONTEXT_PROOF=0 (e.g. on degraded hosts where the audit signal would
# otherwise be the only consequence).
#
# Soft-routed dispatches pass `accept-soft-routed` so the proof records the
# live cwd in audit but does not refuse the dispatch on a cwd mismatch.
# Hard-switched dispatches keep the strict policy: a live cwd that does not
# equal WORKDIR is treated as `live-cwd-mismatch` and refused.
if [ "${ORCH_CONTEXT_PROOF:-1}" = "1" ] && ! dry_run_enabled; then
  if [[ "$SOFT_ROUTE" == "1" ]]; then
    proof_mode="accept-soft-routed"
  else
    proof_mode="strict"
  fi
  if pane_context_proof "$PANE_TARGET" "$WORKDIR" "${ORCH_CONTEXT_PROOF_REMOTE:-}" "${BRANCH:-}" "$proof_mode"; then
    audit "DISPATCH CONTEXT_PROOF_OK agent=${AGENT} ticket=#${TICKET_NUM} pane=${PANE_TARGET} workdir=${WORKDIR} live_workdir=${PANE_CONTEXT_PROOF_LIVE_PATH:-} route=${PANE_CONTEXT_PROOF_ROUTE:-${DISPATCH_ROUTE}}"
  else
    proof_reason=${PANE_CONTEXT_PROOF_REASON:-unknown}
    audit "DISPATCH CONTEXT_MISMATCH agent=${AGENT} ticket=#${TICKET_NUM} pane=${PANE_TARGET} workdir=${WORKDIR} live_workdir=${PANE_CONTEXT_PROOF_LIVE_PATH:-} reason=${proof_reason} route=${DISPATCH_ROUTE}"
    printf 'dispatch-context-mismatch: agent=%s ticket=#%s pane=%s workdir=%s live_workdir=%s reason=%s\n' \
      "$AGENT" "$TICKET_NUM" "$PANE_TARGET" "$WORKDIR" "${PANE_CONTEXT_PROOF_LIVE_PATH:-}" "$proof_reason" >&2
    assign_ticket_if_requested
    exit "${ORCH_CONTEXT_MISMATCH_EXIT_CODE:-76}"
  fi
fi

# Optional: assign on GitHub using the configured agent-label to login mapping.
assign_ticket_if_requested
