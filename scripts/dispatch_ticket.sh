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
# shellcheck source=../lib/api_rate_limiter.sh
source "$TK/lib/api_rate_limiter.sh"
# shellcheck source=../lib/scope_check.sh
source "$TK/lib/scope_check.sh"

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
# Issue #710: operator override for the pre-dispatch loadavg/nproc
# backoff gate. The dispatcher refuses to promote an assignment when
# loadavg/cpus exceeds ORCH_HOST_LOAD_DISPATCH_BACKOFF_RATIO (default
# 0.85); --ignore-host-load (or ORCH_DISPATCH_IGNORE_HOST_LOAD=1)
# bypasses the refusal with an explicit audit row so the override is
# always traceable.
IGNORE_HOST_LOAD="${ORCH_DISPATCH_IGNORE_HOST_LOAD:-0}"
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
    --ignore-host-load) IGNORE_HOST_LOAD=1 ;;
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
# shellcheck source=lib/dispatch_workdir_preflight.sh
source "$TK/lib/dispatch_workdir_preflight.sh"
# shellcheck source=lib/mcp_permission_preflight.sh
source "$TK/lib/mcp_permission_preflight.sh"
# shellcheck source=lib/recovery_context.sh
source "$TK/lib/recovery_context.sh"

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
# 80 is reserved for the MCP permission preflight (#342). It is a
# policy-style denial in the same family as 77/78/79 — the brief never
# lands in the agent pane because at least one required MCP tool would
# trigger an interactive per-workdir grant prompt that the orchestrator
# cannot answer remotely.
: "${ORCH_MCP_PERMISSION_BLOCKED_EXIT_CODE:=80}"
: "${ORCH_DISPATCH_PANE_OCCUPIED_EXIT_CODE:=$ORCH_DISPATCH_NOT_READY_EXIT_CODE}"

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

# Issue #465: a staged dispatch brief pins the agent's branch to a base
# SHA captured at brief-render time. During a merge wave, several PRs can
# advance `<remote>/<default_branch>` between staging and submit, leaving
# the agent to fork off an older base than reality. When the branch later
# integrates, the merge wave commits silently roll back. The helpers
# below extract the brief's pinned base SHA and compare it against the
# current default-branch head before the brief lands in the agent pane.
#
# Output of dispatch_extract_pinned_base_sha is the lowercase hex SHA
# parsed from the canonical phrase "accepted immutable base: <ref> at
# <sha>"; falls back to any hex SHA following "accepted immutable base"
# on the same line when the renderer omits the "at" delimiter. An empty
# stdout means no pinned base was advertised, in which case the freshness
# guard treats the brief as unconstrained.
dispatch_extract_pinned_base_sha() {
  local prompt_file=${1:?usage: dispatch_extract_pinned_base_sha <prompt-file>}
  [ -f "$prompt_file" ] || return 0
  local line tail
  line=$(grep -m1 -iE \
    'accepted immutable base[^A-Za-z0-9]+[^[:space:]]+[^A-Za-z0-9]+at[^A-Za-z0-9]+[0-9a-fA-F]{7,40}' \
    "$prompt_file" 2>/dev/null || true)
  if [ -n "$line" ]; then
    tail=${line#*[Aa]ccepted immutable base}
    if [[ "$tail" =~ [^A-Za-z0-9]at[^A-Za-z0-9]+([0-9a-fA-F]{7,40}) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]'
      return 0
    fi
  fi
  line=$(grep -m1 -iE \
    'accepted immutable base[^A-Za-z0-9]+[0-9a-fA-F]{7,40}' \
    "$prompt_file" 2>/dev/null || true)
  if [ -n "$line" ]; then
    tail=${line#*[Aa]ccepted immutable base}
    if [[ "$tail" =~ [^A-Za-z0-9]+([0-9a-fA-F]{7,40}) ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]'
      return 0
    fi
  fi
  return 0
}

# Compare the brief's pinned base SHA against the current
# `<remote>/<default_branch>` head in $workdir. Behavior:
#   - Pinned == current: emit `DISPATCH BASE_FRESH` and return 0.
#   - Pinned != current, worktree clean and HEAD is an ancestor of
#     `origin/<default_branch>` (no agent commits, no uncommitted changes):
#     emit `DISPATCH BASE_STALE_REFRESH old=<sha> new=<sha>` and return
#     the stale-refresh exit code so the orchestrator can regenerate the
#     brief and redispatch the (still-clean) worktree.
#   - Pinned != current with dirty or post-default-branch commits: emit
#     `DISPATCH REFUSED reason=stale_base_dirty` and return the
#     stale-dirty exit code; never reset/recreate automatically.
#   - No pinned SHA in the brief, workdir is not a git checkout, or
#     `origin/<default_branch>` is unreadable: emit
#     `DISPATCH BASE_FRESHNESS_CHECK skipped reason=<why>` and return 0.
# Globals consumed: AGENT, TICKET_NUM, DEFAULT_BRANCH, REFUSE_STALE_BASE,
#   ORCH_DISPATCH_STALE_BASE_REFRESH_EXIT_CODE (default 81),
#   ORCH_DISPATCH_STALE_BASE_DIRTY_EXIT_CODE (default 82).
dispatch_assert_pinned_base_freshness() {
  local prompt_file=${1:?usage: dispatch_assert_pinned_base_freshness <prompt-file> <workdir>}
  local workdir=${2:?usage: dispatch_assert_pinned_base_freshness <prompt-file> <workdir>}
  local enforce=${REFUSE_STALE_BASE:-1}
  case "$enforce" in
    1|yes|true|on) enforce=1 ;;
    0|no|false|off) enforce=0 ;;
    *)
      printf 'invalid REFUSE_STALE_BASE value: %s\n' "$enforce" >&2
      return 2
      ;;
  esac
  if [ "$enforce" -ne 1 ]; then
    audit "DISPATCH BASE_FRESHNESS_CHECK skipped agent=${AGENT} ticket=#${TICKET_NUM} reason=opt_out"
    return 0
  fi
  if [ ! -d "$workdir/.git" ] && [ ! -f "$workdir/.git" ]; then
    audit "DISPATCH BASE_FRESHNESS_CHECK skipped agent=${AGENT} ticket=#${TICKET_NUM} reason=workdir_not_git workdir=${workdir}"
    return 0
  fi

  local pinned_sha
  pinned_sha=$(dispatch_extract_pinned_base_sha "$prompt_file" 2>/dev/null || true)
  if [ -z "$pinned_sha" ]; then
    audit "DISPATCH BASE_FRESHNESS_CHECK skipped agent=${AGENT} ticket=#${TICKET_NUM} reason=no_pinned_base"
    return 0
  fi

  local default_branch=${DEFAULT_BRANCH:-main}
  # Best-effort: refresh remote refs so the comparison sees the latest
  # merge-wave commits. A network/auth failure here is non-fatal — the
  # rev-parse below still operates on whatever refs are already on disk
  # and the audit line records the degraded state.
  git -C "$workdir" fetch --quiet origin 2>/dev/null \
    || audit "DISPATCH BASE_FRESHNESS_CHECK fetch_failed agent=${AGENT} ticket=#${TICKET_NUM} workdir=${workdir}"

  local current_sha
  current_sha=$(git -C "$workdir" rev-parse --verify --quiet "origin/${default_branch}" 2>/dev/null || true)
  if [ -z "$current_sha" ]; then
    audit "DISPATCH BASE_FRESHNESS_CHECK skipped agent=${AGENT} ticket=#${TICKET_NUM} reason=no_remote_ref ref=origin/${default_branch}"
    return 0
  fi

  if [ "$current_sha" = "$pinned_sha" ]; then
    audit "DISPATCH BASE_FRESH agent=${AGENT} ticket=#${TICKET_NUM} pinned=${pinned_sha} current=${current_sha}"
    return 0
  fi

  local dirty head_in_default ahead_count
  dirty=$(git -C "$workdir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  head_in_default=0
  if git -C "$workdir" merge-base --is-ancestor HEAD "origin/${default_branch}" 2>/dev/null; then
    head_in_default=1
  fi
  ahead_count=$(git -C "$workdir" rev-list --count "origin/${default_branch}..HEAD" 2>/dev/null || printf '0')

  if [ "${dirty:-0}" -eq 0 ] && [ "$head_in_default" -eq 1 ]; then
    audit "DISPATCH BASE_STALE_REFRESH agent=${AGENT} ticket=#${TICKET_NUM} workdir=${workdir} old=${pinned_sha} new=${current_sha} worktree=clean_unstarted action=regenerate-brief"
    printf 'dispatch_ticket: pinned base %s is stale (origin/%s now %s); brief must be regenerated before redispatch — worktree=%s is clean and unstarted\n' \
      "$pinned_sha" "$default_branch" "$current_sha" "$workdir" >&2
    return "${ORCH_DISPATCH_STALE_BASE_REFRESH_EXIT_CODE:-81}"
  fi

  audit "DISPATCH REFUSED reason=stale_base_dirty agent=${AGENT} ticket=#${TICKET_NUM} workdir=${workdir} old=${pinned_sha} new=${current_sha} dirty=${dirty:-0} ahead=${ahead_count:-0} action=operator-required"
  printf 'dispatch_ticket: pinned base %s is stale (origin/%s now %s); REFUSED auto-refresh — worktree %s has dirty=%s ahead=%s; operator must reconcile before redispatch\n' \
    "$pinned_sha" "$default_branch" "$current_sha" "$workdir" "${dirty:-0}" "${ahead_count:-0}" >&2
  return "${ORCH_DISPATCH_STALE_BASE_DIRTY_EXIT_CODE:-82}"
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

# Issue #598: refuse closed GitHub issues before prompt submission. A
# closed/superseded ticket would otherwise consume an agent slot and
# create false busy capacity. Default-on (REFUSE_CLOSED_ISSUE=1) so
# every dispatcher inherits the guard ; opt out with REFUSE_CLOSED_ISSUE=0
# for legacy callers / fixtures that intentionally dispatch a closed
# ticket (e.g. PR-merged follow-up paths). Only runs for numeric
# tickets ; non-numeric labels (custom dispatch shorthands) are
# untouched. Refusal exits 0 so the orchestrator picks another ticket
# instead of failing the dispatch loop.
case "${REFUSE_CLOSED_ISSUE:-1}" in
  1|yes|true|on) REFUSE_CLOSED_ISSUE=1 ;;
  0|no|false|off) REFUSE_CLOSED_ISSUE=0 ;;
  *)
    printf 'invalid REFUSE_CLOSED_ISSUE value: %s\n' "${REFUSE_CLOSED_ISSUE}" >&2
    exit 2
    ;;
esac
if [ "$REFUSE_CLOSED_ISSUE" -eq 1 ] && [[ "$TICKET_NUM" =~ ^[0-9]+$ ]]; then
  issue_state_json=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh issue view "$TICKET_NUM" \
    --repo "$GH_REPO" \
    --json state,closedAt 2>/dev/null || printf '{}')
  # Defensive jq: a malformed payload (array, non-object, parse error) yields
  # an empty state value and the guard becomes a no-op. Existing fixtures
  # that stub `gh issue view` with non-issue payloads (e.g. test fixtures
  # whose stubs return arrays) keep their pre-#598 behavior.
  issue_state_value=$(printf '%s' "$issue_state_json" | jq -r 'if type == "object" then (.state // "") else "" end' 2>/dev/null || printf '')
  issue_closed_at=$(printf '%s' "$issue_state_json" | jq -r 'if type == "object" then (.closedAt // "") else "" end' 2>/dev/null || printf '')
  if [ "$issue_state_value" = "CLOSED" ]; then
    audit "DISPATCH REFUSED reason=issue_closed agent=${AGENT} ticket=#${TICKET_NUM} closedAt=${issue_closed_at:-unknown}"
    printf 'dispatch_ticket: REFUSED #%s — issue closed at %s; pick a still-open ticket\n' \
      "$TICKET_NUM" "${issue_closed_at:-unknown}" >&2
    exit 0
  fi
fi

# Issue #488: refuse dispatch when the rendered brief carries
# `scope classification: unknown` or `out_of_scope`. The orchestrator
# would otherwise mark the lane occupied while the worker short-circuits
# with needs_scope_clarification, leaving the assignments ledger stale
# and the lane appearing busy while doing no work. Run BEFORE prompt
# validation, BEFORE assignment persistence, and BEFORE any tmux pane
# writes so no side effect survives a scope refusal. Default-on; opt
# out for legacy callers / fixtures that pre-date the #343 Scope
# Posture block via ORCH_SCOPE_DISPATCH_PREFLIGHT=0. Briefs that lack
# the Scope Posture block entirely classify as `missing` and pass
# (backward compatibility) — the preflight only refuses unknown,
# out_of_scope, or brief-malformed.
if [ "${ORCH_SCOPE_DISPATCH_PREFLIGHT:-1}" != "0" ]; then
  __scope_preflight_rc=0
  ordo_scope_dispatch_preflight "$PROMPT_FILE" || __scope_preflight_rc=$?
  if [ "$__scope_preflight_rc" -ne 0 ]; then
    audit "DISPATCH REFUSED reason=scope_${ORDO_SCOPE_DISPATCH_PREFLIGHT_CLASSIFICATION:-unknown} agent=${AGENT} ticket=#${TICKET_NUM} active_project_key=${ORDO_SCOPE_DISPATCH_PREFLIGHT_ACTIVE_KEY:-<unknown>} prompt=$(basename "$PROMPT_FILE") remediation=bind-ORCH_SCOPE_IN_SCOPE_PROJECTS-or-redispatch-with-correct-active-key"
    printf 'dispatch_ticket: REFUSED #%s — scope classification %s for active project key %s; assignment NOT recorded, pane NOT occupied\n' \
      "$TICKET_NUM" \
      "${ORDO_SCOPE_DISPATCH_PREFLIGHT_CLASSIFICATION:-unknown}" \
      "${ORDO_SCOPE_DISPATCH_PREFLIGHT_ACTIVE_KEY:-<unknown>}" >&2
    exit "${ORCH_SCOPE_REFUSED_EXIT_CODE:-82}"
  fi
  unset __scope_preflight_rc
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

# Issue #710: pre-dispatch host load backoff. Refuse to promote an
# assignment when the 1-min loadavg/nproc ratio exceeds
# ORCH_HOST_LOAD_DISPATCH_BACKOFF_RATIO (default 0.85). Multi-agent
# waves on the shared host saturate fork latency past validation
# timeouts and surface false `validator-hang` reports (2026-05-16
# evidence: 8-agent round at loadavg 10+, `bash -c true` taking 2s,
# `timeout 120 bash tests/...` killed at the ceiling). The probe is
# lighter than orch_host_load_gate (no fork/disk/ps), so it runs on
# every dispatch. --ignore-host-load (or
# ORCH_DISPATCH_IGNORE_HOST_LOAD=1) bypasses with an audit row.
case "$IGNORE_HOST_LOAD" in
  1|yes|true|on) IGNORE_HOST_LOAD=1 ;;
  *) IGNORE_HOST_LOAD=0 ;;
esac
# Auto-bypass in hermetic test sandboxes — when ORCH_STATE_BASE or
# ORCH_LOG_DIR point into /tmp/, the runner is the toolkit-ci shell test
# harness (not a real operator). The host loadavg of the CI runner is
# unrelated to the dispatch contract under test.
if [ "$IGNORE_HOST_LOAD" -ne 1 ]; then
  case "${ORCH_STATE_BASE:-}" in /tmp/*|/var/tmp/*) IGNORE_HOST_LOAD=1 ;; esac
fi
if [ "$IGNORE_HOST_LOAD" -ne 1 ]; then
  case "${ORCH_LOG_DIR:-}" in /tmp/*|/var/tmp/*) IGNORE_HOST_LOAD=1 ;; esac
fi
if [ "$IGNORE_HOST_LOAD" -eq 1 ]; then
  audit "DISPATCH HOST_LOAD_BACKOFF override agent=${AGENT} ticket=#${TICKET_NUM} reason=operator-ignore-host-load"
else
  __orch_host_load_rc=0
  orch_host_load_dispatch_backoff_check \
    "dispatch:${PROJECT:-unknown}:${AGENT}:#${TICKET_NUM}" \
    || __orch_host_load_rc=$?
  if [ "$__orch_host_load_rc" -ne 0 ]; then
    audit "DISPATCH REFUSED reason=host_overloaded agent=${AGENT} ticket=#${TICKET_NUM} loadavg=${ORCH_HOST_LOAD_DISPATCH_BACKOFF_LAST_LOADAVG:-unknown} cpus=${ORCH_HOST_LOAD_DISPATCH_BACKOFF_LAST_CPUS:-unknown} ratio=${ORCH_HOST_LOAD_DISPATCH_BACKOFF_LAST_RATIO:-unknown} threshold=${ORCH_HOST_LOAD_DISPATCH_BACKOFF_RATIO:-0.85} remediation=wait-or-ignore-host-load-or-ci-delegated"
    printf 'dispatch_ticket: REFUSED #%s — host_overloaded; pass --ignore-host-load (or set ORCH_DISPATCH_IGNORE_HOST_LOAD=1) to override, or switch the brief to validation_policy=ci-delegated\n' \
      "$TICKET_NUM" >&2
    exit "$__orch_host_load_rc"
  fi
  unset __orch_host_load_rc
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

dispatch_assignment_payload() {
  local status=${1:-}
  local reason=${2:-}
  local updated_at=${3:-}
  local -a issue_arg=()

  if [[ "$TICKET_NUM" =~ ^[0-9]+$ ]]; then
    issue_arg=(--argjson issue "$TICKET_NUM")
  else
    issue_arg=(--arg issue "$TICKET_NUM")
  fi

  jq -n \
    --arg branch "${BRANCH:-}" \
    --arg workdir "${WORKDIR:-}" \
    --arg repo_root "$(agent_repo_root "$AGENT")" \
    --arg prompt_file "${STAGED:-}" \
    --arg dispatched_at "${DISPATCHED_AT:-}" \
    --arg head_at_dispatch "${HEAD_AT_DISPATCH:-}" \
    --arg route_mode "${DISPATCH_ROUTE:-}" \
    --arg context_proof_route "${PANE_CONTEXT_PROOF_ROUTE:-}" \
    --arg context_proof_live_workdir "${PANE_CONTEXT_PROOF_LIVE_PATH:-}" \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg updated_at "$updated_at" \
    "${issue_arg[@]}" \
    '{
      ticket: ($issue | tostring),
      issue: $issue,
      branch: (if $branch == "" then null else $branch end),
      workdir: $workdir,
      repo_root: $repo_root,
      prompt_file: $prompt_file,
      dispatched_at: $dispatched_at,
      head_at_dispatch: (if $head_at_dispatch == "" then null else $head_at_dispatch end)
    }
    + (if $route_mode == "" then {} else {route_mode: $route_mode} end)
    + (if $context_proof_route == "" then {} else {context_proof_route: $context_proof_route} end)
    + (if $context_proof_live_workdir == "" then {} else {context_proof_live_workdir: $context_proof_live_workdir} end)
    + (if $status == "" then {} else {status: $status} end)
    + (if $reason == "" then {} else {reason: $reason} end)
    + (if $updated_at == "" then {} else {updated_at: $updated_at} end)'
}

record_dispatch_assignment_pending() {
  local status=${1:?usage: record_dispatch_assignment_pending <status> [reason]}
  local reason=${2:-}
  local pending_file pending_tmp payload updated_at

  updated_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  pending_file=$(state_file assignments_pending.json)
  pending_tmp="${pending_file}.tmp.$$"
  payload=$(dispatch_assignment_payload "$status" "$reason" "$updated_at")

  mkdir -p "$(dirname "$pending_file")"
  state_get assignments_pending | jq \
    --arg agent "$AGENT" \
    --argjson record "$payload" \
    '.[$agent] = $record' > "$pending_tmp"
  mv "$pending_tmp" "$pending_file"
  audit "DISPATCH ASSIGNMENT_PENDING agent=${AGENT} ticket=#${TICKET_NUM} status=${status} reason=${reason:-none} ledger=${pending_file}"
}

promote_dispatch_assignment() {
  local assignment_file assignment_tmp pending_file pending_tmp payload

  assignment_file=$(state_file assignments.json)
  assignment_tmp="${assignment_file}.tmp.$$"
  payload=$(dispatch_assignment_payload "" "" "")

  mkdir -p "$(dirname "$assignment_file")"
  state_get assignments | jq \
    --arg agent "$AGENT" \
    --argjson record "$payload" \
    '.[$agent] = $record' > "$assignment_tmp"
  mv "$assignment_tmp" "$assignment_file"

  pending_file=$(state_file assignments_pending.json)
  pending_tmp="${pending_file}.tmp.$$"
  state_get assignments_pending | jq --arg agent "$AGENT" 'del(.[$agent])' > "$pending_tmp"
  mv "$pending_tmp" "$pending_file"

  audit "DISPATCH ASSIGNMENT_PROMOTED agent=${AGENT} ticket=#${TICKET_NUM} ledger=${assignment_file}"
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
        # Issue #362: when the readiness check tags the refusal as
        # destructive (dirty or in_progress_op), capture a fresh
        # RECOVERY_CONTEXT_PROOF so any downstream destructive action
        # the operator/orchestrator might authorize (rebase --abort,
        # merge --abort, reset, clean, external workdir edits) can
        # re-validate the proof before mutation. The proof captures the
        # workdir branch/head/porcelain/unmerged/in-progress markers
        # alongside agent ownership and PR mergeability — local clone
        # state and PR mergeability stay separate fields so an operator
        # can tell "do we need a local destructive recovery?" from "is
        # the PR still failing to merge?".
        recovery_proof_path=""
        if [[ "${PORTFOLIO_WORKDIR_READINESS_DESTRUCTIVE:-0}" = "1" ]]; then
          recovery_proof_path=$(recovery_context_capture "$matrix_workdir" \
            --agent "$AGENT" --ticket "$TICKET_NUM" \
            --pr "$TICKET_NUM" \
            --reason "matrix_workdir_not_ready:${PORTFOLIO_WORKDIR_READINESS_STATE:-unknown}" \
            2>/dev/null || true)
        fi
        audit "DISPATCH REFUSED reason=matrix_workdir_not_ready state=${PORTFOLIO_WORKDIR_READINESS_STATE:-unknown} branch=${PORTFOLIO_WORKDIR_READINESS_BRANCH:-} upstream=${PORTFOLIO_WORKDIR_READINESS_UPSTREAM:-} ahead=${PORTFOLIO_WORKDIR_READINESS_AHEAD:-0} behind=${PORTFOLIO_WORKDIR_READINESS_BEHIND:-0} dirty=${PORTFOLIO_WORKDIR_READINESS_DIRTY:-0} dirty_modified=${PORTFOLIO_WORKDIR_READINESS_DIRTY_MODIFIED:-0} dirty_untracked=${PORTFOLIO_WORKDIR_READINESS_DIRTY_UNTRACKED:-0} in_progress=${PORTFOLIO_WORKDIR_READINESS_IN_PROGRESS:-} recovery_action=${PORTFOLIO_WORKDIR_READINESS_RECOVERY_ACTION:-none} destructive=${PORTFOLIO_WORKDIR_READINESS_DESTRUCTIVE:-0} recovery_context_proof=${recovery_proof_path:-none} agent=${AGENT} project=${project_for_portfolio} workdir=${matrix_workdir}"
        if [[ -n "$recovery_proof_path" ]]; then
          printf 'recovery_context_proof: %s — re-validate with recovery_context_assert_fresh before any rebase --abort / merge --abort / reset / clean on %s\n' \
            "$recovery_proof_path" "$matrix_workdir" >&2
        fi
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
  live_pane_cwd=""
  if live_pane_cwd=$(tmux_pane_current_path "$PANE_TARGET" 2>/dev/null); then
    occupied_assignment=""
    if occupied_assignment=$(worktree_active_assignment_for_path "$live_pane_cwd" 2>/dev/null); then
      IFS=$'\t' read -r occupied_project occupied_agent occupied_issue occupied_workdir <<< "$occupied_assignment"
      occupied_signal=$(worktree_active_assignment_signal "$occupied_project" "$occupied_issue")
      audit "DISPATCH REFUSED reason=pane_occupied signal=${occupied_signal} agent=${AGENT} ticket=#${TICKET_NUM} pane=${PANE_TARGET} live_workdir=${live_pane_cwd} occupied_project=${occupied_project} occupied_agent=${occupied_agent} occupied_ticket=#${occupied_issue} occupied_workdir=${occupied_workdir}"
      printf 'dispatch not ready: pane=%s %s live_workdir=%s occupied_agent=%s occupied_workdir=%s; wait, recover, or preempt before redispatch\n' \
        "$PANE_TARGET" "$occupied_signal" "$live_pane_cwd" "$occupied_agent" "$occupied_workdir" >&2
      exit "$ORCH_DISPATCH_PANE_OCCUPIED_EXIT_CODE"
    fi
  fi
fi

WORKDIR=$(agent_repo_root "$AGENT")

# Issue #683: refuse cross-project dispatches before worktree creation,
# tmux respawn, and the brief paste. The portfolio/matrix path already
# refuses with `duplicate_clone_remote_mismatch` (~line 744 above) when
# `matrix_workdir`'s origin diverges from the loaded project's canonical
# clone URL. The non-portfolio direct-dispatch path had no equivalent
# guard: a dispatch into a fleet slot whose `AGENT_WORKDIR` is a clone
# of the wrong project would silently respawn the pane in a wrong-remote
# workdir and leave the worker to declare a context mismatch
# post-dispatch. The preflight here closes that gap; mode is configurable
# via ORCH_DISPATCH_WORKDIR_ORIGIN_GUARD so operators can roll out
# enforcement gradually (warn → enforce). The check operates on the
# source clone (`agent_repo_root`); the worktree subsequently created by
# `worktree_create` inherits this clone's `origin`, so checking the
# source is sufficient.
__dispatch_workdir_preflight_rc=0
dispatch_workdir_origin_preflight "$AGENT" "$TICKET_NUM" "$WORKDIR" \
  || __dispatch_workdir_preflight_rc=$?
if [ "$__dispatch_workdir_preflight_rc" -ne 0 ]; then
  exit "$__dispatch_workdir_preflight_rc"
fi
unset __dispatch_workdir_preflight_rc

BRANCH=""
if worktree_enabled; then
  BRANCH=$(worktree_feature_branch "$TICKET_NUM")
  if dry_run_enabled; then
    WORKDIR=$(worktree_path "$AGENT" "$TICKET_NUM")
    dry_run_note "git -C $(agent_repo_root "$AGENT") worktree add -B $BRANCH $WORKDIR origin/$DEFAULT_BRANCH"
  else
    WORKDIR=$(worktree_create "$AGENT" "$TICKET_NUM")
  fi
fi

# Routing-surface guard (#376, #498, #539). Refuse before staging or sending when
# the prompt body, the staging filename slug, the pinned cwd, the resolved pane
# and the target workdir-side git identity disagree about which agent is being
# addressed. When USE_WORKTREES=1 the identity surface is the effective ticket
# worktree, not the shared repository root.
if dispatch_router_assert_consistency \
    "$AGENT" "$TICKET_NUM" "$PANE_TARGET" "$PROMPT_FILE" "$WORKDIR"; then
  :
else
  exit "$ORCH_DISPATCH_ROUTE_MISMATCH_EXIT_CODE"
fi

if worktree_enabled && ! dry_run_enabled; then
  if ! worktree_assert_agent_identity "$AGENT" "$WORKDIR"; then
    audit "DISPATCH ROUTE_MISMATCH agent=${AGENT} ticket=#${TICKET_NUM} pane=${PANE_TARGET} workdir=${WORKDIR} prompt=${PROMPT_FILE##*/} mismatched_fields=worktree_identity expected_name=${WORKTREE_IDENTITY_EXPECTED_NAME:-} actual_name=${WORKTREE_IDENTITY_ACTUAL_NAME:-} expected_email=${WORKTREE_IDENTITY_EXPECTED_EMAIL:-} actual_email=${WORKTREE_IDENTITY_ACTUAL_EMAIL:-} reason=worktree_identity_mismatch"
    exit "$ORCH_DISPATCH_ROUTE_MISMATCH_EXIT_CODE"
  fi
  if [[ -n "${WORKTREE_IDENTITY_EXPECTED_NAME:-}${WORKTREE_IDENTITY_EXPECTED_EMAIL:-}" ]]; then
    audit "DISPATCH ROUTE_WORKTREE_IDENTITY_OK agent=${AGENT} ticket=#${TICKET_NUM} workdir=${WORKDIR} expected_name=${WORKTREE_IDENTITY_EXPECTED_NAME:-} expected_email=${WORKTREE_IDENTITY_EXPECTED_EMAIL:-}"
  fi
fi

# Issue #465: pinned-base freshness guard. Runs after the worktree is
# materialised (so $WORKDIR resolves to the agent's effective checkout)
# and before the brief is staged or pasted into the pane. A stale pin
# triggers either a refresh signal (clean worktree) or an operator-
# required refusal (dirty / committed worktree); see
# dispatch_assert_pinned_base_freshness for the full contract.
__dispatch_base_freshness_rc=0
dispatch_assert_pinned_base_freshness "$PROMPT_FILE" "$WORKDIR" \
  || __dispatch_base_freshness_rc=$?
if [ "$__dispatch_base_freshness_rc" -ne 0 ]; then
  exit "$__dispatch_base_freshness_rc"
fi
unset __dispatch_base_freshness_rc

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

if worktree_enabled; then
  if ! dry_run_enabled; then
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

# MCP permission preflight (#342). Verify, BEFORE the brief lands in the
# agent pane, that every MCP tool the prompt will require has been granted
# for this agent's target workdir. Otherwise the agent stalls at an
# interactive per-workdir grant prompt that the orchestrator cannot answer.
# Universal: pattern catalog and per-CLI resolver hook are both
# operator-configurable (see lib/mcp_permission_preflight.sh).
if [ "${ORCH_MCP_PREFLIGHT_DISABLE:-0}" != "1" ]; then
  # The preflight reads the source PROMPT_FILE: in dry-run the STAGED copy
  # may not have been made yet, and the file content is identical anyway.
  # mcp_preflight_for_dispatch returns non-zero when blocked; capture
  # stdout regardless and let the .decision field drive control flow.
  preflight_decision_json=$(mcp_preflight_for_dispatch "$PROMPT_FILE" "$AGENT" "$WORKDIR" 2>/dev/null || true)
  if [ -n "$preflight_decision_json" ]; then
    preflight_decision=$(printf '%s' "$preflight_decision_json" | jq -r '.decision // "granted"' 2>/dev/null || printf 'granted')
    preflight_required=$(printf '%s' "$preflight_decision_json" | jq -r '.required_mcps | join(",")' 2>/dev/null || printf '')
    preflight_blocking=$(printf '%s' "$preflight_decision_json" | jq -r '.blocking | join(",")' 2>/dev/null || printf '')
    if [ "$preflight_decision" = "blocked" ]; then
      audit "DISPATCH_PREFLIGHT MCP_BLOCKED agent=${AGENT} ticket=#${TICKET_NUM} workdir=${WORKDIR} required=${preflight_required} blocking=${preflight_blocking}"
      printf 'MCP permission preflight blocked dispatch: agent=%s workdir=%s blocking=%s\n' \
        "$AGENT" "$WORKDIR" "$preflight_blocking" >&2
      printf '%s\n' "$preflight_decision_json" >&2
      # Honor the block in dry-run too: a dry-run that silently swallows a
      # real-world dispatch denial is misleading. The exit code is the same
      # in both modes so CI gates and the wave dispatcher classify it
      # identically.
      exit "$ORCH_MCP_PERMISSION_BLOCKED_EXIT_CODE"
    elif [ -n "$preflight_required" ]; then
      audit "DISPATCH_PREFLIGHT MCP_OK agent=${AGENT} ticket=#${TICKET_NUM} workdir=${WORKDIR} required=${preflight_required}"
    fi
  fi
fi

if dry_run_enabled; then
  dry_run_note "record assignment agent=$AGENT ticket=$TICKET_NUM workdir=$WORKDIR branch=${BRANCH:-default}"
else
  DISPATCHED_AT=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  # rbok#500: persist the assigned workdir's HEAD at dispatch time so cycle
  # comparisons can mechanically distinguish post-dispatch commits from a
  # pre-existing branch head. Empty when the workdir is not a git checkout
  # (e.g. fixtures that bypass worktree creation); consumers treat null as
  # "no comparison possible".
  HEAD_AT_DISPATCH=$(git -C "$WORKDIR" rev-parse HEAD 2>/dev/null || true)
  record_dispatch_assignment_pending "pending"
fi

# Build the one-liner the terminal agent reads.
ONELINER="Read $STAGED and execute it end-to-end. Stay strictly in scope. Verify your git identity matches the agent name before commit. Report final status."

# Submit via paste-buffer, then Enter as a separate terminal event. Use
# $PANE_TARGET (full session:window.pane) so universal fleets with shared
# sessions still hit the intended pane.
#
# Per-pane fan-out jitter (#409): when an orchestrator wave dispatches
# back-to-back to twelve panes, every agent CLI fires its first
# /v1/messages request inside the same ~50ms window and we trip
# Anthropic's per-org rate limit. A 50–250 ms randomised sleep before
# each submit staggers those starts so the burst is spread across a
# ~3 second window instead of arriving as a single thundering herd.
# Honors ORDO_API_RATE_LIMIT_DISABLE=1 for tests and operator escape.
if dry_run_enabled; then
  dry_run_note "tmux load-buffer -b orch_send_<pid>_<rand>_<ns> <dispatch-text>  # #595 unique buffer per invocation"
  dry_run_note "tmux paste-buffer -b orch_send_<pid>_<rand>_<ns> -t $PANE_TARGET -d"
  dry_run_note "tmux send-keys -t $PANE_TARGET Enter"
else
  api_rate_limiter_jitter
  # Issue #508: assignment promotion requires prompt-execution proof. Do not
  # allow the lower-level consume check to be disabled for live dispatch.
  if ! ORCH_DISPATCH_VERIFY_CONSUMED=1 terminal_dispatch_submit "$PANE_TARGET" "$ONELINER"; then
    audit "DISPATCH PROMPT_EXECUTION_PROOF_FAILED agent=${AGENT} ticket=#${TICKET_NUM} pane=${PANE_TARGET} reason=${DISPATCH_SUBMIT_LAST_REASON:-not-consumed} attempts=${DISPATCH_SUBMIT_ATTEMPT:-0}"
    record_dispatch_assignment_pending "failed" "${DISPATCH_SUBMIT_LAST_REASON:-not-consumed}"
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
  audit "DISPATCH PROMPT_EXECUTION_PROOF_OK agent=${AGENT} ticket=#${TICKET_NUM} pane=${PANE_TARGET} attempts=${DISPATCH_SUBMIT_ATTEMPT:-1} proof=${DISPATCH_SUBMIT_LAST_PROOF:-unknown}"
  record_dispatch_assignment_pending "submitted"
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
    record_dispatch_assignment_pending "failed" "$proof_reason"
    exit "${ORCH_CONTEXT_MISMATCH_EXIT_CODE:-76}"
  fi
fi

# Issue #573: post-context-proof acceptance proof. The pane has been
# verified active (PROMPT_EXECUTION_PROOF_OK) and in the right workdir
# (CONTEXT_PROOF_OK), but those signals don't prove the agent is
# working on THIS ticket — a stale prior transcript can satisfy both.
# Verify the brief filename or literal ticket number is visible in the
# recent pane scrollback before promoting the assignment. Default-on,
# opt-out via REQUIRE_ACCEPTANCE_PROOF=0 for legacy callers / fixtures.
case "${REQUIRE_ACCEPTANCE_PROOF:-1}" in
  1|yes|true|on) REQUIRE_ACCEPTANCE_PROOF=1 ;;
  0|no|false|off) REQUIRE_ACCEPTANCE_PROOF=0 ;;
  *)
    printf 'invalid REQUIRE_ACCEPTANCE_PROOF value: %s\n' "${REQUIRE_ACCEPTANCE_PROOF}" >&2
    exit 2
    ;;
esac
if [ "$REQUIRE_ACCEPTANCE_PROOF" -eq 1 ] && ! dry_run_enabled; then
  if pane_acceptance_proof "$PANE_TARGET" "$AGENT" "$TICKET_NUM"; then
    audit "DISPATCH ACCEPTANCE_PROOF_OK agent=${AGENT} ticket=#${TICKET_NUM} pane=${PANE_TARGET} reason=${PANE_ACCEPTANCE_PROOF_REASON:-unknown}"
  else
    audit "DISPATCH ACCEPTANCE_PROOF_FAILED agent=${AGENT} ticket=#${TICKET_NUM} pane=${PANE_TARGET} reason=${PANE_ACCEPTANCE_PROOF_REASON:-no-acceptance-evidence}"
    printf 'dispatch-acceptance-failed: agent=%s ticket=#%s pane=%s reason=%s — pane shows no evidence of working on this ticket; assignment NOT promoted\n' \
      "$AGENT" "$TICKET_NUM" "$PANE_TARGET" "${PANE_ACCEPTANCE_PROOF_REASON:-no-acceptance-evidence}" >&2
    record_dispatch_assignment_pending "failed" "${PANE_ACCEPTANCE_PROOF_REASON:-no-acceptance-evidence}"
    exit "${ORCH_ACCEPTANCE_PROOF_EXIT_CODE:-77}"
  fi
fi

if ! dry_run_enabled; then
  promote_dispatch_assignment
fi

# Optional: assign on GitHub using the configured agent-label to login mapping.
assign_ticket_if_requested
