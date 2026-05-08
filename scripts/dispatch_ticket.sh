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
#   2. Optionally: gh issue assign — controlled by --assign flag.
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
PORTFOLIO_ARG="${ORCH_PORTFOLIO_CONFIG:-${PORTFOLIO_CONFIG:-}}"
PORTFOLIO_PROJECT_ARG="${ORCH_PORTFOLIO_PROJECT:-}"
REQUIRE_DISPATCH_MATRIX_GATE="${ORCH_REQUIRE_DISPATCH_MATRIX_GATE:-0}"
DISPATCH_MATRIX_PATH_ARG="${ORCH_DISPATCH_MATRIX_FILE:-}"
AUTO_REFRESH_PREFLIGHT="${ORCH_AUTO_REFRESH_PREFLIGHT:-0}"
# External PR mutation authority gate (Required Rule 12). Default audit-only;
# operators authorize per-scope via --external-pr-mutations or env var. The
# flag wins over the env var so a one-off dispatch can narrow or broaden the
# inherited orchestrator authorization.
EXTERNAL_PR_MUTATIONS_ARG="${ORCH_EXTERNAL_PR_MUTATIONS:-}"
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
    --portfolio)
      PORTFOLIO_ARG=${2:?missing value for --portfolio}
      shift
      ;;
    --portfolio-project|--project)
      PORTFOLIO_PROJECT_ARG=${2:?missing value for $1}
      shift
      ;;
    --external-pr-mutations)
      EXTERNAL_PR_MUTATIONS_ARG=${2:?missing value for --external-pr-mutations}
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

TICKET_NUM=${TICKET#\#}

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

assign_ticket_if_requested() {
  [ "$ASSIGN" -eq 1 ] || return 0
  if [[ ! "$TICKET_NUM" =~ ^[0-9]+$ ]]; then
    audit "DISPATCH assignee skipped ticket=${TICKET_NUM} reason=non_numeric"
    return 0
  fi

  local gh_login
  gh_login=$(resolve_agent_github_login "$AGENT")
  if dry_run_enabled; then
    dry_run_note "gh issue edit $TICKET_NUM --repo $GH_REPO --add-assignee $gh_login"
    audit "DISPATCH assignee=${gh_login} ticket=#${TICKET_NUM}"
    return 0
  fi

  # Required Rule 11: every external mutation runs through the gate. The
  # assignee path is `issue_assignees` because it edits a GitHub issue's
  # assignee list on a third-party-managed repo. Refusal short-circuits the
  # mutation and exits with $ORCH_EXTERNAL_PR_MUTATION_EXIT_CODE so dashboards
  # can group it with other gate refusals.
  local gate_rc=0
  external_pr_mutation_assert issue_assignees \
    "dispatch_ticket:assign:#${TICKET_NUM}" || gate_rc=$?
  if [ "$gate_rc" -ne 0 ]; then
    return "$gate_rc"
  fi

  orch_github_identity_guard "$gh_login" "dispatch_ticket:assign:#${TICKET_NUM}"
  orch_run_timeout "$ORCH_GH_TIMEOUT_SEC" env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh issue edit "$TICKET_NUM" \
    --repo "$GH_REPO" \
    --add-assignee "$gh_login" 2>&1 | tail -3 || true
  audit "DISPATCH assignee=${gh_login} ticket=#${TICKET_NUM}"
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
        echo "portfolio_target_not_ready: agent=$AGENT project=$project_for_portfolio status=$preflight_status report=$(portfolio_preflight_report_path)" >&2
        exit 4
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
  # dispatch: the clone must exist, be clean, and either match the default
  # branch synced with origin/default or be on a feature branch descending
  # from origin/default. Otherwise refuse and let preflight remediate.
  if [[ -n "$matrix_workdir" ]]; then
    if ! portfolio_assert_workdir_ready "$matrix_workdir" "$default_branch_for_matrix"; then
      audit "DISPATCH REFUSED reason=matrix_workdir_not_ready agent=${AGENT} project=${project_for_portfolio} workdir=${matrix_workdir}"
      exit 4
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

# Persist a stable copy alongside the orchestrator state for audit trail.
# Idempotent: if the caller already placed the brief at the staging path, skip
# the copy (cp would error "are the same file" and `set -e` would abort the
# script before any tmux send happens — silent dispatch failure).
STAGED="/tmp/dispatch-${AGENT}-${TICKET_NUM}.md"
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

# Post-dispatch live pane context proof (issue #112): after the prompt is
# delivered, sleep briefly then verify pwd / remote / branch / target
# workdir line up with what dispatch recorded. Skipped in dry-run because
# no pane was actually written; can be force-disabled via
# ORCH_CONTEXT_PROOF=0 (e.g. on degraded hosts where the audit signal
# would otherwise be the only consequence).
if [ "${ORCH_CONTEXT_PROOF:-1}" = "1" ] && ! dry_run_enabled; then
  if pane_context_proof "$PANE_TARGET" "$WORKDIR" "${ORCH_CONTEXT_PROOF_REMOTE:-}" "${BRANCH:-}"; then
    audit "DISPATCH CONTEXT_PROOF_OK agent=${AGENT} ticket=#${TICKET_NUM} pane=${PANE_TARGET}"
  else
    proof_reason=${PANE_CONTEXT_PROOF_REASON:-unknown}
    audit "DISPATCH CONTEXT_MISMATCH agent=${AGENT} ticket=#${TICKET_NUM} pane=${PANE_TARGET} workdir=${WORKDIR} reason=${proof_reason}"
    printf 'dispatch-context-mismatch: agent=%s ticket=#%s pane=%s workdir=%s reason=%s\n' \
      "$AGENT" "$TICKET_NUM" "$PANE_TARGET" "$WORKDIR" "$proof_reason" >&2
    assign_ticket_if_requested
    exit "${ORCH_CONTEXT_MISMATCH_EXIT_CODE:-76}"
  fi
fi

# Optional: assign on GitHub using the configured agent-label to login mapping.
assign_ticket_if_requested
