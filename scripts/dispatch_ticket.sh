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

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: dispatch_ticket.sh <project> <agent> <ticket#> <prompt-file> [--assign] [--no-validate] [--dry-run]}
AGENT=${2:?missing agent name}
TICKET=${3:?missing ticket number}
PROMPT_FILE=${4:?missing prompt-file path}
shift 4

ASSIGN=0
VALIDATE_PROMPT=1
PORTFOLIO_ARG="${ORCH_PORTFOLIO_CONFIG:-${PORTFOLIO_CONFIG:-}}"
PORTFOLIO_PROJECT_ARG="${ORCH_PORTFOLIO_PROJECT:-}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --assign) ASSIGN=1 ;;
    --no-validate) VALIDATE_PROMPT=0 ;;
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

load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"
source "$TK/lib/state_persist.sh"
source "$TK/lib/tmux_helpers.sh"
source "$TK/lib/worktree_helpers.sh"
source "$TK/lib/prompt_integrity.sh"

[ -f "$PROMPT_FILE" ] || { echo "prompt file not found: $PROMPT_FILE" >&2; exit 1; }

: "${AGENT_SESSION_PREFIX:=}" "${GH_REPO:?}" "${GH_CONFIG_DIR:?}"
: "${ORCH_TMUX_TIMEOUT_SEC:=10}"
: "${ORCH_GH_TIMEOUT_SEC:=5}"
: "${ORCH_TMUX_DEGRADED_EXIT_CODE:=75}"
: "${ORCH_SUBMIT_FALLBACK_CJ:=1}"

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

if [ "$VALIDATE_PROMPT" -eq 1 ]; then
  validate_canonical_prompt "$PROMPT_FILE"
  validate_prompt_integrity "$PROMPT_FILE"
else
  audit "DISPATCH VALIDATION BYPASSED agent=${AGENT} ticket=#${TICKET#\#} prompt=$(basename "$PROMPT_FILE")"
fi

TICKET_NUM=${TICKET#\#}

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
  else
    orch_run_timeout "$ORCH_GH_TIMEOUT_SEC" env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh issue edit "$TICKET_NUM" \
      --repo "$GH_REPO" \
      --add-assignee "$gh_login" 2>&1 | tail -3 || true
  fi
  audit "DISPATCH assignee=${gh_login} ticket=#${TICKET_NUM}"
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

  matrix_workdir=$(agent_repo_root "$AGENT" 2>/dev/null || true)
  canonical_url=$(portfolio_canonical_clone_url_for_loaded_project)
  if [[ -n "$canonical_url" && -n "$matrix_workdir" && -d "$matrix_workdir/.git" ]]; then
    if ! portfolio_workdir_origin_matches_canonical "$matrix_workdir" "$canonical_url"; then
      actual_origin=$(portfolio_workdir_origin_url "$matrix_workdir" 2>/dev/null || printf '<unset>')
      echo "context-mismatch: agent=$AGENT workdir=$matrix_workdir origin=$actual_origin canonical=$canonical_url" >&2
      exit 4
    fi
  fi

  if [[ "${PORTFOLIO_REQUIRE_PREFLIGHT:-1}" == "1" ]]; then
    preflight_status=$(portfolio_preflight_target_status "$AGENT" 2>/dev/null || true)
    case "$preflight_status" in
      ok)
        ;;
      missing|stale|jq_missing)
        echo "portfolio_preflight_required: agent=$AGENT status=$preflight_status report=$(portfolio_preflight_report_path); rerun scripts/portfolio_session_start.sh" >&2
        exit 4
        ;;
      not_found|not_ready)
        echo "portfolio_target_not_ready: agent=$AGENT status=$preflight_status report=$(portfolio_preflight_report_path)" >&2
        exit 4
        ;;
      *)
        echo "portfolio_preflight_required: agent=$AGENT status=${preflight_status:-unknown} report=$(portfolio_preflight_report_path)" >&2
        exit 4
        ;;
    esac
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

# Build the one-liner the agent reads. Multi-line tmux paste-buffer
# would also work, but a one-liner is safer across Claude Code versions.
ONELINER="Read $STAGED and execute it end-to-end. Stay strictly in scope. Verify your git identity matches the agent name before commit. Report final status."

# Send via send-keys (multi-line text already inside the file referenced).
# Use $PANE_TARGET (full session:window.pane) so we hit the right pane in
# universal mode — under AGENT_PANES, multiple fleets can share a session
# layout where send-keys to the bare session name is ambiguous.
dry_run_exec "tmux send-keys -t $PANE_TARGET \"$ONELINER\"" \
  orch_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" tmux send-keys -t "$PANE_TARGET" "$ONELINER"
if ! dry_run_enabled; then
  sleep 0.5
fi
# Submit (Claude Code 2.x: plain Enter; some versions need C-j — we send
# Enter first, then a fallback C-j if the prompt looks unsubmitted).
dry_run_exec "tmux send-keys -t $PANE_TARGET Enter" \
  orch_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" tmux send-keys -t "$PANE_TARGET" Enter
if [ "${ORCH_SUBMIT_FALLBACK_CJ}" = "1" ]; then
  if ! dry_run_enabled; then
    sleep 0.5
  fi
  dry_run_exec "tmux send-keys -t $PANE_TARGET C-j" \
    orch_run_timeout "$ORCH_TMUX_TIMEOUT_SEC" tmux send-keys -t "$PANE_TARGET" C-j
fi
if ! dry_run_enabled; then
  sleep 1.0
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

# Optional: assign on GitHub. The 5 agent accounts (RBOKCLIclaude/codex/...)
# are standardized; map agent name → gh login.
assign_ticket_if_requested
