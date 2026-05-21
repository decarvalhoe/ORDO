#!/usr/bin/env bash
# scripts/dispatch_plan.sh - priority/dependency plan for issue dispatch.
#
# Usage:
#   dispatch_plan.sh <project_short|config_path> [--tsv|--json] [--ready-only] [--include-shipped-suspect] [--active-backlog]
#   dispatch_plan.sh <project_short|config_path> --ci-overlap [--tsv|--json]
#   dispatch_plan.sh <project_short|config_path> --priority-set <list> [--priority-set-override]
#   dispatch_plan.sh <project_short|config_path> --priority-set <list> --strict-priority-set
#   dispatch_plan.sh <project_short|config_path> --atomize [--dry-run]
#       [--apply] [--max-children-per-cycle <N>]
#   dispatch_plan.sh <project_short|config_path> --hotspots [--tsv|--json]
#       [--accept-risk <pattern[,pattern...]>] [--refuse-on-blocker]
#
# The planner is deliberately model-agnostic. It reads GitHub issues, infers
# dependencies from issue text, ranks dispatch candidates, and can split large
# checklist-driven parent issues into child issues while carrying parent scope.
#
# File hotspot detection (issue #271):
#   --hotspots scans open pull requests and reports which ones touch
#   coordination surfaces (README, PRODUCT, docs index, package metadata, CI
#   workflow files, central scripts) so multi-agent waves can detect the same
#   shared file being edited in parallel before dispatch. Defaults live in
#   lib/file_hotspots.sh and can be replaced or extended via the project
#   profile (ORDO_FILE_HOTSPOT_PATTERNS / ORDO_FILE_HOTSPOT_EXTRA).
#
# Stale-parent detection (issue #118):
#   Before classifying an issue as `ready`, the planner looks for evidence that
#   most of its scope is already shipped — either via a merged PR that
#   references the issue or via an issue comment using ship language
#   ("shipped in #N", "fixed by PR #N", "closed by #N", ...). When evidence is
#   found, the issue is downgraded to `shipped_suspect`. If the parent body
#   still contains unchecked tasks, the status is further promoted to
#   `stale_parent` and the unchecked tasks are extracted as `[followup #N]`
#   children at `--atomize` time, each carrying the shipped evidence in its
#   body. The goal is to avoid the "already_aligned" no-op pattern where an
#   agent dispatches a stale parent and finds the work already merged.
#
# Priority ticket sets:
#   --priority-set <n,n,n>      Operator-supplied allowlist of ticket numbers.
#                               Every entry is resolved against issues and PRs;
#                               a found/missing/state/assignee table is written
#                               to stderr. While any allowlisted open ready
#                               issue exists, the queue refuses to dispatch
#                               non-allowlisted tickets (filters them out).
#                               With --atomize, child creation is scoped to the
#                               allowlist even when no allowlisted issue is
#                               ready, so unrelated parents cannot leak into
#                               dry-run or mutation output.
#   --priority-set-override     Disable the refusal — allow dispatching outside
#                               the allowlist even when an allowlisted ready
#                               ticket remains.
#   --strict-priority-set       Operator-scoped wave: filter the queue to the
#                               allowlist regardless of readiness so a ready
#                               older ticket cannot leak into the dispatch
#                               candidates. The output keeps every allowlisted
#                               ticket with its status (ready, blocked,
#                               atomize, shipped_suspect, ...) so the operator
#                               can remediate from the same table. A
#                               per-ticket status summary is also printed to
#                               stderr. Mutually exclusive with
#                               --priority-set-override and requires
#                               --priority-set. See issue #266.
#
# CI-pending file overlap planning:
#   --ci-overlap inspects open PRs targeting the default branch, keeps only
#   PRs with pending/queued/in-progress checks, reads their changed files, and
#   compares them with issue-declared ownership files. Issue bodies can declare
#   scope under headings such as "Scope files:", "Ownership files:", "Allowed
#   files:", or "Files touched:". Rows are classified as `parallel_safe`,
#   `blocked_by_files`, `blocked_by_ci_dependency`, or
#   `needs_human_decision`; safe rows include a brief note forbidding files
#   already touched by CI-pending PRs.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/config_resolver.sh"
source "$TK/lib/process_safety.sh"
source "$TK/lib/github_identity.sh"
source "$TK/lib/dispatch_plan_headers.sh"
source "$TK/lib/label_helpers.sh"
# portfolio_config.sh exposes portfolio_gated_dependencies_for_issue and
# portfolio_gated_dependency_waived (#666). Sanitized test harnesses that
# copy a subset of lib/ may omit it; fall back to no-op stubs so legacy
# fixtures keep working while real deployments get the policy.
if [[ -f "$TK/lib/portfolio_config.sh" ]]; then
  source "$TK/lib/portfolio_config.sh"
fi
if ! declare -F portfolio_gated_dependencies_for_issue >/dev/null 2>&1; then
  portfolio_gated_dependencies_for_issue() { return 0; }
fi
if ! declare -F portfolio_gated_dependency_waived >/dev/null 2>&1; then
  portfolio_gated_dependency_waived() { return 1; }
fi
# dispatch_capacity.sh exposes dispatch_capacity_local_assigned_issues (#499).
# Sanitized test harnesses that copy a subset of lib/ may omit it; fall back to
# an empty local-assignment set so legacy fixtures keep their previous behavior.
if [[ -f "$TK/lib/dispatch_capacity.sh" ]]; then
  source "$TK/lib/dispatch_capacity.sh"
fi
if ! declare -F dispatch_capacity_local_assigned_issues >/dev/null 2>&1; then
  dispatch_capacity_local_assigned_issues() { return 0; }
fi

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: dispatch_plan.sh <project> [--tsv|--json] [--ready-only] [--active-backlog] [--atomize] [--dry-run] [--apply] [--max-children-per-cycle <N>] [--priority-set <list>] [--hotspots] [--with-agent-capacity]}
FORMAT="tsv"
READY_ONLY=0
INCLUDE_SHIPPED_SUSPECT=0
ACTIVE_BACKLOG=0
ATOMIZE=0
ATOMIZE_MAX_CHILDREN_PER_CYCLE=0
PRIORITY_SET=""
PRIORITY_SET_OVERRIDE=0
PRIORITY_SET_STRICT=0
HOTSPOTS=0
HOTSPOT_ACCEPT_RISK=""
HOTSPOT_REFUSE_ON_BLOCKER=0
CI_OVERLAP=0
WITH_AGENT_CAPACITY=0
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tsv) FORMAT="tsv" ;;
    --json) FORMAT="json" ;;
    --ready-only) READY_ONLY=1 ;;
    --include-shipped-suspect) INCLUDE_SHIPPED_SUSPECT=1 ;;
    --active-backlog) ACTIVE_BACKLOG=1 ;;
    --atomize) ATOMIZE=1 ;;
    --apply) ATOMIZE=1 ;;
    --max-children-per-cycle)
      ATOMIZE_MAX_CHILDREN_PER_CYCLE=${2:?missing value for --max-children-per-cycle}
      shift
      ;;
    --max-children-per-cycle=*) ATOMIZE_MAX_CHILDREN_PER_CYCLE=${1#--max-children-per-cycle=} ;;
    --hotspots) HOTSPOTS=1 ;;
    --ci-overlap) CI_OVERLAP=1 ;;
    --accept-risk)
      HOTSPOT_ACCEPT_RISK=${2:?missing value for --accept-risk}
      shift
      ;;
    --accept-risk=*) HOTSPOT_ACCEPT_RISK=${1#--accept-risk=} ;;
    --refuse-on-blocker) HOTSPOT_REFUSE_ON_BLOCKER=1 ;;
    --priority-set)
      PRIORITY_SET=${2:?missing value for --priority-set}
      shift
      ;;
    --priority-set=*) PRIORITY_SET=${1#--priority-set=} ;;
    --priority-set-override) PRIORITY_SET_OVERRIDE=1 ;;
    --strict-priority-set) PRIORITY_SET_STRICT=1 ;;
    --with-agent-capacity) WITH_AGENT_CAPACITY=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# Issue #454: project profiles can opt the fleet-aware join in by default
# without needing every operator to remember the flag. Operator-supplied
# `--with-agent-capacity` always wins (set above); the env var only
# promotes the default when the CLI was silent.
if [ "$WITH_AGENT_CAPACITY" -eq 0 ] \
  && [ "${DISPATCH_PLAN_WITH_AGENT_CAPACITY:-0}" = "1" ]; then
  WITH_AGENT_CAPACITY=1
fi

if [ "$PRIORITY_SET_STRICT" -eq 1 ] && [ -z "$PRIORITY_SET" ]; then
  echo "--strict-priority-set requires --priority-set <list>" >&2
  exit 2
fi
if [ "$PRIORITY_SET_STRICT" -eq 1 ] && [ "$PRIORITY_SET_OVERRIDE" -eq 1 ]; then
  echo "--strict-priority-set and --priority-set-override are mutually exclusive" >&2
  exit 2
fi

load_project_config "$CFG_ARG"
source "$TK/lib/audit_log.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}"
: "${DISPATCH_PLAN_LIMIT:=100}"
: "${DISPATCH_PLAN_ATOMIZE_MIN_TASKS:=3}"
: "${DISPATCH_PLAN_PARENT_CONTEXT_CHARS:=3500}"
: "${DISPATCH_PLAN_DRY_RUN_VERIFY_EXISTING:=0}"
: "${DISPATCH_PLAN_SHIPPED_GATE:=1}"
: "${DISPATCH_PLAN_SHIPPED_LOOKBACK_DAYS:=30}"
: "${DISPATCH_PLAN_SHIPPED_PR_LIMIT:=10}"
: "${DISPATCH_PLAN_SHIPPED_MATCH_MODE:=closing-keyword}"
: "${DISPATCH_PLAN_INCLUDE_SHIPPED_SUSPECT:=0}"

case "$DISPATCH_PLAN_SHIPPED_MATCH_MODE" in
  closing-keyword|timeline-close|mention) : ;;
  *)
    echo "DISPATCH_PLAN_SHIPPED_MATCH_MODE must be one of: closing-keyword, timeline-close, mention (got: $DISPATCH_PLAN_SHIPPED_MATCH_MODE)" >&2
    exit 2
    ;;
esac
: "${DISPATCH_PLAN_ACTIVE_BACKLOG:=0}"
: "${DISPATCH_PLAN_GH_TIMEOUT_SEC:=5}"
: "${DISPATCH_PLAN_HOTSPOT_PR_LIMIT:=50}"
: "${DISPATCH_PLAN_HOTSPOT_REFUSE_EXIT_CODE:=7}"
: "${DISPATCH_PLAN_CI_OVERLAP_PR_LIMIT:=50}"
: "${DISPATCH_PLAN_ATOMIZE_MAX_CHILDREN_PER_CYCLE:=0}"

if [ "$ATOMIZE_MAX_CHILDREN_PER_CYCLE" = "0" ] \
  && [ "$DISPATCH_PLAN_ATOMIZE_MAX_CHILDREN_PER_CYCLE" != "0" ]; then
  ATOMIZE_MAX_CHILDREN_PER_CYCLE=$DISPATCH_PLAN_ATOMIZE_MAX_CHILDREN_PER_CYCLE
fi
if ! [[ "$ATOMIZE_MAX_CHILDREN_PER_CYCLE" =~ ^[0-9]+$ ]]; then
  echo "--max-children-per-cycle requires a non-negative integer (got: $ATOMIZE_MAX_CHILDREN_PER_CYCLE)" >&2
  exit 2
fi

if [ "$DISPATCH_PLAN_INCLUDE_SHIPPED_SUSPECT" = "1" ]; then
  INCLUDE_SHIPPED_SUSPECT=1
fi
if [ "$DISPATCH_PLAN_ACTIVE_BACKLOG" = "1" ]; then
  ACTIVE_BACKLOG=1
fi

# Local assignment ledger lookup (#499): operators should not duplicate-dispatch
# issues already held by another agent in the local ORDO ledger. We snapshot
# the issue numbers once, surface a `local-assigned` signal on matching rows,
# expose a `local_assigned` boolean in JSON output, and subtract them from the
# `--ready-only` queue so they cannot leak in as dispatch candidates. The
# bracketed form (`,42,99,`) is used so substring lookups are exact and do not
# match shared digit suffixes.
LOCAL_ASSIGNED_SET=","
while IFS= read -r _local_assigned_num; do
  [ -n "$_local_assigned_num" ] || continue
  LOCAL_ASSIGNED_SET+="${_local_assigned_num},"
done < <(dispatch_capacity_local_assigned_issues 2>/dev/null)
unset _local_assigned_num

run_gh() {
  orch_github_identity_guard_for_command "dispatch_plan" "$@"
  orch_run_timeout "$DISPATCH_PLAN_GH_TIMEOUT_SEC" env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh "$@"
}

issue_numbers_from_text() {
  grep -Eo '#[0-9]+' | tr -d '#' | sort -n -u | paste -sd, - || true
}

deps_from_body() {
  local body=$1
  { printf '%s\n' "$body" \
    | grep -Ei '(^|[[:space:]])(depends on|blocked by|dependencies?|requires?):' \
    | issue_numbers_from_text; } || true
}

text_blockers_from_issue() {
  local title=$1 body=$2 text decision_resolved=0
  text="${title}"$'\n'"${body}"

  # Issue #778: explicit operator marker clears the arbitration text-blocked
  # check so meta-issues whose subject is arbitration discipline (rather than a
  # pending decision) stay dispatchable. Matches anywhere in the body.
  if grep -Eiq '(^|[[:space:][:punct:]])(decision status:[[:space:]]*(resolved|cleared|done)|decision:[[:space:]]*(made|resolved|cleared|done))([[:space:][:punct:]]|$)' <<< "$body"; then
    decision_resolved=1
  fi

  if grep -Eiq '(^|[[:space:][:punct:]])(pr[eé]condition bloquante|blocking precondition|blocked until|bloqu[eé][[:space:]]+jusqu|requires validation[[:space:]]+before[[:space:]]+implementation|validation required[[:space:]]+before[[:space:]]+implementation|validation.*requise.*avant[[:space:]]+impl[eé]mentation)([[:space:][:punct:]]|$)' <<< "$text"; then
    printf 'precondition:blocking-precondition\n'
  fi

  if grep -Eiq '(^|[[:space:][:punct:]])(figma[[:space:]-]*first|design validation required|required design validation|requires design validation|requires validation from design|validation from design required|validation design requise|code connect[[:space:]]+(access|seat)[[:space:]]+(required|blocked|missing|pending)|developer seat required|(blocked|waiting|pending)[[:space:]]+(on|by|for|until)[[:space:]]+(the[[:space:]]+)?(figma|design[[:space:]]+(handoff|validation|review|sign[-[:space:]]?off))|figma[[:space:]]+(handoff|preflight|asset|spec|design|export|file)[[:space:]]+(required|requise|pending|missing|blocked|n[eé]cessaire)|figma[[:space:]]+(required|requise|needed|n[eé]cessaire)[[:space:]]+before[[:space:]]+(implementation|coding|impl[eé]mentation|d[eé]veloppement))([[:space:][:punct:]]|$)' <<< "$text"; then
    printf 'design:figma-or-design-gate\n'
  fi

  if [ "$decision_resolved" -eq 0 ] && grep -Eiq '(^|[[:space:][:punct:]])((a|à)[[:space:]]+arbitrer|d[eé]pend[[:space:]]+de|pending arbitration|needs arbitration|arbitration required|inputs?[[:space:]]+agence|agency inputs?|hosting decision|placement decision|external asset required|asset.*(required|missing)|decision required|pending decision)([[:space:][:punct:]]|$)' <<< "$text"; then
    printf 'arbitration:decision-required\n'
  fi

  if grep -Eiq '(^|[[:space:][:punct:]])(traductions?.*(manquantes?|requises?|attendues?|[aà][[:space:]]+(fournir|recevoir|valider))|translations?.*(required|missing|pending|needed)|plugin retenu|plugin choice|choix[[:space:]]+du[[:space:]]+plugin|structure[[:space:]]+d.?url|url strategy|strat[eé]gie[[:space:]]+url|hreflang|source content model|mod[eè]le[[:space:]]+de[[:space:]]+contenu[[:space:]]+source|contenu source.*(multilingue|[aà][[:space:]]+fournir)|multilingual.*(dependency|source content|plugin|url|translation))([[:space:][:punct:]]|$)' <<< "$text"; then
    printf 'multilingual:external-content-or-routing\n'
  fi
}

parent_from_body() {
  local body=$1
  { printf '%s\n' "$body" \
    | grep -Ei '(^|[[:space:]])(parent issue|parent|epic|child of):' \
    | issue_numbers_from_text \
    | awk -F, '{print $1}'; } || true
}

atomized_child_from_issue() {
  local title=$1 body=$2 parent=$3
  local title_lower=${title,,}
  local body_lower=${body,,}
  if [ -n "$parent" ]; then
    if [[ "$title_lower" == "[parent #${parent}]"* || "$title_lower" == "[followup #${parent}]"* ]]; then
      printf '1\n'
      return 0
    fi
    if [[ "$body_lower" == *"generated by:"*"dispatch_plan --atomize"* ]]; then
      printf '1\n'
      return 0
    fi
  fi
  printf '0\n'
}

semantic_sibling_dependency_reason() {
  local title=$1 body=$2
  local text
  text=$(printf '%s\n%s\n' "$title" "$body" | tr '[:upper:]' '[:lower:]')
  if grep -Eq '\ball[[:space:]-]+(siblings?|children|child|subtasks?|issues?|prs?|pull requests)[^[:cntrl:]]{0,80}\b(merged|closed|complete|completed|done)\b|\ball[[:space:]-]+merged\b' <<< "$text"; then
    printf 'all-siblings-complete\n'
  elif grep -Eq '\breturn[[:space:]-]+to[[:space:]-]+zero\b' <<< "$text"; then
    printf 'return-to-zero\n'
  elif grep -Eq '\bverify[[:space:]-]+completion\b|\bverify[^[:cntrl:]]{0,80}\b(all|parent|siblings?|children)[^[:cntrl:]]{0,80}\b(complete|completed|closed|merged|done)\b' <<< "$text"; then
    printf 'verify-completion\n'
  elif grep -Eq '\b(promote|promotion)[^[:cntrl:]]{0,80}\b(after|once|when)\b|\b(after|once|when)[^[:cntrl:]]{0,80}\b(promote|promotion)\b' <<< "$text"; then
    printf 'promote-after\n'
  elif grep -Eq '\b(deploy|deployment|release)[^[:cntrl:]]{0,80}\b(after|once|when)\b|\b(after|once|when)[^[:cntrl:]]{0,80}\b(deploy|deployment|release)\b' <<< "$text"; then
    printf 'deploy-after\n'
  elif grep -Eq '\bclose[[:space:]-]+(the[[:space:]-]+)?parent\b|\bparent[^[:cntrl:]]{0,60}\b(can|ready|safe|should|must)[^[:cntrl:]]{0,40}\b(close|closed)\b' <<< "$text"; then
    printf 'close-parent\n'
  fi
  return 0
}

checkbox_tasks() {
  # Header-aware atomization checklist extractor. Items under acceptance,
  # definition-of-done, validation, evidence/preuves, review-checklist,
  # risks, and notes sections (English + French defaults from #294, plus
  # the original English allowlist from #265) are skipped via the lib's
  # default non-atomize header set. Projects with their own conventions
  # extend the allowlist via DISPATCH_PLAN_NON_ATOMIZE_HEADERS rather
  # than editing this function. The remainder is returned as candidate
  # atomization tasks.
  local body=$1
  dispatch_plan_atomize_tasks "$body" || true
}

contains_number() {
  local number=$1 open_numbers=$2
  grep -qx "$number" <<< "$open_numbers"
}

# In-flight scope-claim conflict detection (#721 sub-A). The planner
# enriches `--ready-only` rows with a `conflict_with` field listing
# in-flight ticket numbers whose claimed scope intersects the
# candidate's expected scope. The heuristic extracts path-like tokens
# out of the candidate's parent/title/body and matches them against
# `assignments_scope_claims.json`. When no path token can be derived
# from the candidate (the planner has no scope hint), the field falls
# back to `["unknown"]` so operators see the heuristic abstained
# rather than confirming "no conflict". An empty ledger always returns
# `[]` — the heuristic cannot conflict when nothing is in flight.
dispatch_plan_extract_candidate_paths() {
  local text=${1:-}
  printf '%s' "$text" \
    | grep -oE '[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_./-]+\.[A-Za-z][A-Za-z0-9]*' \
    | sort -u || true
}

dispatch_plan_compute_conflict_with() {
  local issue_number=${1:?usage: dispatch_plan_compute_conflict_with <issue> <text>}
  local text=${2:-}
  declare -F dispatch_capacity_scope_claims_json >/dev/null 2>&1 || { printf '[]'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '[]'; return 0; }

  local claims_json
  claims_json=$(dispatch_capacity_scope_claims_json)
  if [ -z "$claims_json" ] || [ "$(printf '%s' "$claims_json" | jq -r 'length')" = "0" ]; then
    printf '[]'
    return 0
  fi

  local paths
  paths=$(dispatch_plan_extract_candidate_paths "$text")
  if [ -z "$paths" ]; then
    printf '["unknown"]'
    return 0
  fi

  local paths_json
  paths_json=$(printf '%s\n' "$paths" | jq -R . | jq -s .)

  printf '%s' "$claims_json" | jq -c \
    --argjson paths "$paths_json" \
    --arg issue "$issue_number" '
      [ to_entries[]
        | select((.value.ticket // "") != $issue)
        | select(((.value.scope_files // []) | any(. as $f | $paths | index($f))) // false)
        | (.value.ticket // empty)
        | tonumber? // empty
      ] | unique | sort
    '
}

declare -A DEP_STATE_CACHE=()
dep_state() {
  local dep=${1:?usage: dep_state <issue-number>}
  local open_numbers=${2:?usage: dep_state <issue-number> <open-number-list>}
  if [[ -n "${DEP_STATE_CACHE[$dep]:-}" ]]; then
    printf '%s\n' "${DEP_STATE_CACHE[$dep]}"
    return 0
  fi
  if contains_number "$dep" "$open_numbers"; then
    DEP_STATE_CACHE[$dep]="OPEN"
    printf 'OPEN\n'
    return 0
  fi
  local state
  state=$(run_gh issue view "$dep" --repo "$GH_REPO" --json state 2>/dev/null \
    | jq -r '.state // "UNKNOWN"' || printf 'UNKNOWN')
  DEP_STATE_CACHE[$dep]="$state"
  printf '%s\n' "$state"
}

shipped_since_date() {
  local days=$DISPATCH_PLAN_SHIPPED_LOOKBACK_DAYS
  [ "${days:-0}" -gt 0 ] || return 0
  if date -u -d "${days} days ago" +%F >/dev/null 2>&1; then
    date -u -d "${days} days ago" +%F
  elif date -u -v-"${days}"d +%F >/dev/null 2>&1; then
    date -u -v-"${days}"d +%F
  fi
}

declare -A SHIPPED_PR_CACHE=()
# shipped_pr_for_issue locates the merged PR that actually shipped the issue.
# Match policy is controlled by DISPATCH_PLAN_SHIPPED_MATCH_MODE (#778):
#   closing-keyword (default): require a GitHub closing keyword
#     (close[sd]?, fix(e[sd])?, resolve[sd]?) immediately before the issue
#     reference in the PR body. A bare mention (Prerequisites, See also,
#     Follow-up) does NOT flag shipped_suspect.
#   timeline-close: ask the issue's closing-PR references on GitHub.
#     Strict: only PRs that GitHub recognizes as closing the issue match.
#   mention: legacy behavior; any reference to the issue number in the PR
#     title, body, or headRefName matches. Kept for back-compat audits but
#     prone to false shipped_suspect when issues are merely referenced.
shipped_pr_for_issue() {
  local issue=${1:?usage: shipped_pr_for_issue <issue-number>}
  if [[ -n "${SHIPPED_PR_CACHE[$issue]:-}" ]]; then
    printf '%s\n' "${SHIPPED_PR_CACHE[$issue]}"
    return 0
  fi

  local base_ref search since prs_json match mode
  mode=${DISPATCH_PLAN_SHIPPED_MATCH_MODE:-closing-keyword}
  base_ref=${DEFAULT_BRANCH:-main}
  search="$issue"
  since=$(shipped_since_date || true)
  if [ -n "$since" ]; then
    search="${search} merged:>=${since}"
  fi

  prs_json=$(run_gh pr list \
    --repo "$GH_REPO" \
    --state merged \
    --base "$base_ref" \
    --search "$search" \
    --json number,title,body,url,mergedAt,headRefName \
    --limit "$DISPATCH_PLAN_SHIPPED_PR_LIMIT" 2>/dev/null || printf '[]')

  case "$mode" in
    closing-keyword)
      match=$(printf '%s' "$prs_json" | jq -r --arg issue "$issue" '
        def closing_re($n):
          "(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\\b[[:space:]:]+(?:[A-Za-z0-9._/-]+)?#?" + $n + "(?:[^0-9]|$)";
        [ .[]? | select((.body // "") | test(closing_re($issue))) ][0] // empty
        | if . == "" then "" else "\(.number)|\(.url)|\(.mergedAt)" end
      ' 2>/dev/null || true)
      ;;
    timeline-close)
      local closing_json
      closing_json=$(run_gh issue view "$issue" \
        --repo "$GH_REPO" \
        --json closedByPullRequestsReferences 2>/dev/null || printf '{}')
      match=$(jq -r --argjson prs "$prs_json" '
        [ (.closedByPullRequestsReferences // [])[]?
          | select(.state == "MERGED")
          | .number ] as $closing
        | [ $prs[]? | select(.number as $n | $closing | index($n)) ][0] // empty
        | if . == "" then "" else "\(.number)|\(.url)|\(.mergedAt)" end
      ' <<< "$closing_json" 2>/dev/null || true)
      ;;
    mention)
      match=$(printf '%s' "$prs_json" | jq -r --arg issue "$issue" '
        def text: ((.title // "") + "\n" + (.body // "") + "\n" + (.headRefName // ""));
        def issue_re($n): "(^|[^0-9])#?" + $n + "([^0-9]|$)";
        [ .[]? | select(text | test(issue_re($issue))) ][0] // empty
        | if . == "" then "" else "\(.number)|\(.url)|\(.mergedAt)" end
      ' 2>/dev/null || true)
      ;;
  esac

  SHIPPED_PR_CACHE[$issue]="$match"
  printf '%s\n' "$match"
}

declare -A SHIPPED_COMMENT_CACHE=()
shipped_comment_for_issue() {
  local issue=${1:?usage: shipped_comment_for_issue <issue-number>}
  if [[ -n "${SHIPPED_COMMENT_CACHE[$issue]:-}" ]]; then
    printf '%s\n' "${SHIPPED_COMMENT_CACHE[$issue]}"
    return 0
  fi

  local since comments_json match
  since=$(shipped_since_date || true)

  comments_json=$(run_gh issue view "$issue" \
    --repo "$GH_REPO" \
    --json comments 2>/dev/null || printf '{}')

  match=$(printf '%s' "$comments_json" | jq -r --arg since "$since" '
    def is_ship: test("(?i)\\b(shipped|merged|fixed|addressed|completed|resolved|closes?|closed)\\s+(in|by|via)\\s+(pr\\s*)?#?[0-9]+");
    def ship_pr: capture("(?i)\\b(?:shipped|merged|fixed|addressed|completed|resolved|closes?|closed)\\s+(?:in|by|via)\\s+(?:pr\\s*)?#?(?<n>[0-9]+)").n;
    [ .comments[]?
      | select((.body // "") | is_ship)
      | select(($since == "") or ((.createdAt // "") >= $since))
      | { pr: ((.body // "") | ship_pr),
          url: (.url // ""),
          createdAt: (.createdAt // ""),
          author: ((.author.login // "") | tostring) }
      | select(.pr != null and .pr != "")
    ][0] // empty
    | if . == "" then "" else "\(.pr)|\(.url)|\(.createdAt)|\(.author)" end
  ' 2>/dev/null || true)

  SHIPPED_COMMENT_CACHE[$issue]="$match"
  printf '%s\n' "$match"
}

OPEN_PRS_JSON_CACHE=""
OPEN_PRS_JSON_CACHE_LOADED=0
ensure_open_prs_json_cache() {
  if [ "$OPEN_PRS_JSON_CACHE_LOADED" -eq 0 ]; then
    local base_ref
    base_ref=${DEFAULT_BRANCH:-main}
    OPEN_PRS_JSON_CACHE=$(run_gh pr list \
      --repo "$GH_REPO" \
      --state open \
      --base "$base_ref" \
      --json number,title,body,url,headRefName \
      --limit "$DISPATCH_PLAN_LIMIT" 2>/dev/null || printf '[]')
    OPEN_PRS_JSON_CACHE_LOADED=1
  fi
}

open_prs_json() {
  ensure_open_prs_json_cache
  printf '%s\n' "$OPEN_PRS_JSON_CACHE"
}

open_prs_for_issue() {
  local issue=${1:?usage: open_prs_for_issue <issue-number>}
  ensure_open_prs_json_cache
  printf '%s\n' "$OPEN_PRS_JSON_CACHE" | jq -r --arg issue "$issue" '
    def text: ((.title // "") + "\n" + (.body // "") + "\n" + (.headRefName // ""));
    def issue_re($n): "(^|[^0-9])#?" + $n + "([^0-9]|$)";
    [ .[]? | select(text | test(issue_re($issue))) | .number ] | unique | join(",")
  ' 2>/dev/null || true
}

priority_for_labels() {
  local labels=$1
  label_helpers_priority_for_labels "$labels" "${DISPATCH_PLAN_REPO_LABEL_NAMES:-}"
}

dispatch_plan_fetch_repo_label_names() {
  local labels_json
  labels_json=$(run_gh label list --repo "$GH_REPO" --limit 200 --json name 2>/dev/null || true)
  printf '%s' "$labels_json" | jq -r 'if type == "array" then .[]?.name else empty end' 2>/dev/null || true
}

dispatch_plan_priority_labels_from_issues() {
  local issues_payload=${1:-[]}
  printf '%s' "$issues_payload" \
    | jq -r '.[]?.labels[]?.name // empty | select(test("^priority:P[0-9]$"))' 2>/dev/null \
    || true
}

dispatch_plan_required_label_names() {
  local issues_payload=${1:-[]}
  {
    printf '%s\n' "${DISPATCH_PLAN_REQUIRED_LABELS:-}"
    printf '%s\n' "${DISPATCH_PLAN_REQUIRED_PRIORITY_LABELS:-}"
    dispatch_plan_priority_labels_from_issues "$issues_payload"
  } | label_helpers_normalize_labels | awk '!seen[$0]++'
}

dispatch_plan_label_preflight() {
  local issues_payload=${1:-[]}
  local available=${DISPATCH_PLAN_REPO_LABEL_NAMES:-}
  local required missing label

  [ -n "$(label_helpers_normalize_labels "$available")" ] || return 0
  required=$(dispatch_plan_required_label_names "$issues_payload")
  [ -n "$required" ] || return 0
  missing=$(label_helpers_missing_labels "$available" "$required")
  [ -n "$missing" ] || return 0

  while IFS= read -r label; do
    [ -n "$label" ] || continue
    printf 'label-preflight: missing label %s repo=%s project=%s\n' "$label" "$GH_REPO" "$PROJECT" >&2
    audit "DISPATCH_PLAN label-preflight missing_label=${label} repo=${GH_REPO} project=${PROJECT}"
  done <<< "$missing"
}

agent_hint_for_issue() {
  local title=$1 labels=$2 body=$3
  local title_labels="${title} ${labels}"
  local body_text=$body
  title_labels=${title_labels,,}
  body_text=${body_text,,}
  case "$title_labels" in
    *ci*|*deploy*|*docker*|*infra*|*devops*|*workflow*|*jelastic*) printf 'devops\n'; return 0 ;;
    *backend*|*fastapi*|*sqlalchemy*|*api*|*migration*) printf 'backend\n'; return 0 ;;
    *frontend*|*react*|*next.js*|*nextjs*|*uxui*|*figma*|*routing*|*client*) printf 'frontend\n'; return 0 ;;
    *doc*|*adr*|*architecture*) printf 'architecture\n'; return 0 ;;
  esac
  case "$body_text" in
    *ci*|*deploy*|*docker*|*infra*|*devops*|*workflow*|*jelastic*) printf 'devops\n'; return 0 ;;
    *backend*|*fastapi*|*sqlalchemy*|*api*|*migration*) printf 'backend\n'; return 0 ;;
    *frontend*|*react*|*next.js*|*nextjs*|*uxui*|*figma*|*routing*) printf 'frontend\n'; return 0 ;;
    *doc*|*adr*|*architecture*) printf 'architecture\n'; return 0 ;;
    *) printf 'any\n'; return 0 ;;
  esac
}

signals_join() {
  local old_ifs=$IFS
  IFS=,
  printf '%s' "$*"
  IFS=$old_ifs
}

truncate_context() {
  local text=$1
  printf '%s' "$text" | head -c "$DISPATCH_PLAN_PARENT_CONTEXT_CHARS"
}

fingerprint_text() {
  local text=${1:?usage: fingerprint_text <text>}
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$text" | sha256sum | awk '{print substr($1, 1, 16)}'
  else
    printf '%s' "$text" | cksum | awk '{print $1 "-" $2}'
  fi
}

atomize_existing_child() {
  local fingerprint=${1:?usage: atomize_existing_child <fingerprint>}
  run_gh issue list \
    --repo "$GH_REPO" \
    --state all \
    --search "ORDO-ATOMIZE:${fingerprint}" \
    --json number,url \
    --limit 1 2>/dev/null \
    | jq -r '.[0] // empty | "\(.number)|\(.url)"'
}

atomize_add_labels() {
  local issue_number=${1:?usage: atomize_add_labels <issue-number>}
  local label labels label_rc label_err
  local -a label_array=()
  labels=${DISPATCH_PLAN_ATOMIZE_LABELS:-ordo:atomized,ordo:child}
  [ -n "$labels" ] || return 0
  IFS=, read -r -a label_array <<< "$labels"
  for label in "${label_array[@]}"; do
    [ -n "$label" ] || continue
    label_rc=0
    label_err=$(run_gh issue edit "$issue_number" --repo "$GH_REPO" --add-label "$label" 2>&1 >/dev/null) \
      || label_rc=$?
    if [[ "$label_rc" -eq "$ORCH_GITHUB_IDENTITY_MISMATCH_EXIT_CODE" ]]; then
      printf '%s\n' "$label_err" >&2
      return "$label_rc"
    fi
  done
}

priority_set_normalize() {
  local raw=$1
  printf '%s' "$raw" \
    | tr -s ',[:space:]' '\n' \
    | sed 's/^#//' \
    | grep -E '^[0-9]+$' \
    | awk '!seen[$0]++' \
    | paste -sd, -
}

priority_set_resolve_one() {
  local n=${1:?usage: priority_set_resolve_one <number>}
  local pr_json issue_json kind state assignees title
  pr_json=$(run_gh pr view "$n" --repo "$GH_REPO" --json number,state,assignees,title 2>/dev/null || true)
  state=$(printf '%s' "$pr_json" | jq -r '.state // empty' 2>/dev/null || true)
  if [ -n "$state" ]; then
    kind="pr"
    assignees=$(printf '%s' "$pr_json" | jq -r '[.assignees[]?.login] | join(",")' 2>/dev/null || true)
    title=$(printf '%s' "$pr_json" | jq -r '.title // ""' 2>/dev/null || true)
    [ -n "$assignees" ] || assignees="-"
    printf '%s\tfound\t%s\t%s\t%s\t%s\t%s\n' "$n" "$GH_REPO" "$kind" "$state" "$assignees" "$title"
    return 0
  fi
  issue_json=$(run_gh issue view "$n" --repo "$GH_REPO" --json number,state,assignees,title 2>/dev/null || true)
  state=$(printf '%s' "$issue_json" | jq -r '.state // empty' 2>/dev/null || true)
  if [ -n "$state" ]; then
    kind="issue"
    assignees=$(printf '%s' "$issue_json" | jq -r '[.assignees[]?.login] | join(",")' 2>/dev/null || true)
    title=$(printf '%s' "$issue_json" | jq -r '.title // ""' 2>/dev/null || true)
    [ -n "$assignees" ] || assignees="-"
    printf '%s\tfound\t%s\t%s\t%s\t%s\t%s\n' "$n" "$GH_REPO" "$kind" "$state" "$assignees" "$title"
    return 0
  fi
  printf '%s\tmissing\t%s\t-\t-\t-\t-\n' "$n" "$GH_REPO"
}

priority_set_emit_table() {
  local set_csv=$1 resolution_file=$2
  local entry
  local -a entries=()
  IFS=, read -r -a entries <<< "$set_csv"
  printf 'priority-set: %s repo=%s\n' "$set_csv" "$GH_REPO" >&2
  printf 'ticket\tfound\trepo\tkind\tstate\tassignees\ttitle\n' >&2
  : > "$resolution_file"
  for entry in "${entries[@]}"; do
    [ -n "$entry" ] || continue
    local row
    row=$(priority_set_resolve_one "$entry")
    printf '#%s\n' "$row" >&2
    printf '%s\n' "$row" >> "$resolution_file"
  done
}

priority_set_filter_tsv_file() {
  local set_csv=${1:?usage: priority_set_filter_tsv_file <set_csv> <file>}
  local file=${2:?usage: priority_set_filter_tsv_file <set_csv> <file>}
  local filtered
  filtered=$(mktemp)
  awk -v set=",${set_csv}," 'BEGIN{FS="\t"} index(set, "," $1 ",") {print}' "$file" > "$filtered"
  mv "$filtered" "$file"
}

dispatch_plan_hotspots_main() {
  # shellcheck source=../lib/file_hotspots.sh
  source "$TK/lib/file_hotspots.sh"

  local prs_json pr_b64 pr_json pr_number pr_title pr_url pr_branch pr_author pr_updated pr_labels
  local files_json paths matched_csv pr_agent
  local rows_file json_file
  rows_file=$(mktemp)
  json_file=$(mktemp)
  trap 'rm -f "$rows_file" "$json_file"' RETURN

  prs_json=$(run_gh pr list \
    --repo "$GH_REPO" \
    --state open \
    --limit "$DISPATCH_PLAN_HOTSPOT_PR_LIMIT" \
    --json number,title,url,headRefName,updatedAt,author,labels,isDraft 2>/dev/null \
    || printf '[]')

  while IFS= read -r pr_b64; do
    [ -n "$pr_b64" ] || continue
    pr_json=$(printf '%s' "$pr_b64" | base64 -d)
    pr_number=$(printf '%s' "$pr_json" | jq -r '.number')
    pr_title=$(printf '%s' "$pr_json" | jq -r '.title // ""')
    pr_url=$(printf '%s' "$pr_json" | jq -r '.url // ""')
    pr_branch=$(printf '%s' "$pr_json" | jq -r '.headRefName // ""')
    pr_author=$(printf '%s' "$pr_json" | jq -r '.author.login // ""')
    pr_updated=$(printf '%s' "$pr_json" | jq -r '.updatedAt // ""')
    pr_labels=$(printf '%s' "$pr_json" | jq -r '[.labels[]?.name] | join(",")')

    files_json=$(run_gh pr view "$pr_number" --repo "$GH_REPO" --json files 2>/dev/null \
      || printf '{"files":[]}')
    paths=$(printf '%s' "$files_json" | jq -r '.files[]?.path' 2>/dev/null || true)
    matched_csv=$(printf '%s\n' "$paths" | file_hotspots_filter_paths | sort -u | paste -sd, -)
    [ -n "$matched_csv" ] || continue

    pr_agent=$(file_hotspots_pr_agent "$pr_author" "$pr_labels")

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$pr_number" "$pr_agent" "$matched_csv" "$pr_branch" "$pr_updated" "$pr_title" \
      >> "$rows_file"

    jq -nc \
      --argjson pr "$pr_number" \
      --arg agent "$pr_agent" \
      --arg matched "$matched_csv" \
      --arg branch "$pr_branch" \
      --arg updated "$pr_updated" \
      --arg title "$pr_title" \
      --arg url "$pr_url" \
      '{pr:$pr, agent:$agent, hotspots:($matched|split(",")|map(select(length>0))), branch:$branch, updatedAt:$updated, title:$title, url:$url}' \
      >> "$json_file"
  done < <(printf '%s' "$prs_json" | jq -r '.[] | @base64')

  dispatch_plan_hotspots_emit "$rows_file" "$json_file"
}

dispatch_plan_hotspots_emit() {
  local rows_file=$1 json_file=$2
  local pr_num pr_agent matched_csv pr_branch pr_updated pr_title hotspot
  declare -A HOTSPOT_PRS=()
  declare -A HOTSPOT_AGENTS=()
  declare -A HOTSPOT_ORDER=()

  local accept_csv=${HOTSPOT_ACCEPT_RISK:-}
  declare -A ACCEPTED_HOTSPOTS=()
  if [ -n "$accept_csv" ]; then
    local ar
    while IFS= read -r ar; do
      [ -n "$ar" ] || continue
      ACCEPTED_HOTSPOTS[$ar]=1
    done < <(printf '%s\n' "$accept_csv" | tr ',' '\n')
  fi

  while IFS=$'\t' read -r pr_num pr_agent matched_csv pr_branch pr_updated pr_title; do
    [ -n "$pr_num" ] || continue
    local -a matched_array=()
    IFS=, read -r -a matched_array <<< "$matched_csv"
    for hotspot in "${matched_array[@]}"; do
      [ -n "$hotspot" ] || continue
      if [ -n "${HOTSPOT_PRS[$hotspot]:-}" ]; then
        HOTSPOT_PRS[$hotspot]+=",#${pr_num}"
        HOTSPOT_AGENTS[$hotspot]+=",${pr_agent}"
        HOTSPOT_ORDER[$hotspot]+=$'\n'"${pr_updated}"$'\t'"#${pr_num}"
      else
        HOTSPOT_PRS[$hotspot]="#${pr_num}"
        HOTSPOT_AGENTS[$hotspot]="${pr_agent}"
        HOTSPOT_ORDER[$hotspot]="${pr_updated}"$'\t'"#${pr_num}"
      fi
    done
  done < "$rows_file"

  local blocker_count=0
  local out_rows out_json
  out_rows=$(mktemp)
  out_json=$(mktemp)

  local hotspot_keys=()
  if [ "${#HOTSPOT_PRS[@]}" -gt 0 ]; then
    while IFS= read -r key; do
      hotspot_keys+=("$key")
    done < <(printf '%s\n' "${!HOTSPOT_PRS[@]}" | LC_ALL=C sort)
  fi

  for hotspot in "${hotspot_keys[@]}"; do
    local prs_csv agents_csv unique_agents_csv pr_count agent_count accepted classification recommendation suggested_order
    prs_csv=${HOTSPOT_PRS[$hotspot]}
    agents_csv=${HOTSPOT_AGENTS[$hotspot]}
    pr_count=$(printf '%s' "$prs_csv" | tr ',' '\n' | grep -c '^#' || true)
    unique_agents_csv=$(printf '%s' "$agents_csv" | tr ',' '\n' | awk 'NF && !seen[$0]++' | paste -sd, -)
    agent_count=$(printf '%s\n' "$unique_agents_csv" | tr ',' '\n' | awk 'NF' | wc -l | tr -d ' ')
    accepted=0
    [ -n "${ACCEPTED_HOTSPOTS[$hotspot]:-}" ] && accepted=1
    classification=$(file_hotspots_classify "$pr_count" "$agent_count" "$accepted")
    recommendation=$(file_hotspots_recommendation "$classification")
    suggested_order=$(printf '%s\n' "${HOTSPOT_ORDER[$hotspot]}" | awk 'NF' | LC_ALL=C sort -k1,1 | awk '{print $2}' | paste -sd, -)
    [ "$classification" = "blocker" ] && blocker_count=$((blocker_count + 1))
    printf '%s\t%d\t%s\t%s\t%s\t%s\t%s\n' \
      "$hotspot" "$pr_count" "$prs_csv" "$unique_agents_csv" "$classification" "$recommendation" "$suggested_order" \
      >> "$out_rows"
    jq -nc \
      --arg hotspot "$hotspot" \
      --argjson pr_count "$pr_count" \
      --arg prs "$prs_csv" \
      --arg agents "$unique_agents_csv" \
      --arg classification "$classification" \
      --arg recommendation "$recommendation" \
      --arg suggested_order "$suggested_order" \
      --argjson accepted "$accepted" \
      '{hotspot:$hotspot, pr_count:$pr_count, prs:($prs|split(",")|map(select(length>0))), agents:($agents|split(",")|map(select(length>0))), classification:$classification, recommendation:$recommendation, suggested_order:($suggested_order|split(",")|map(select(length>0))), accepted_risk:($accepted == 1)}' \
      >> "$out_json"
  done

  if [ "$FORMAT" = "json" ]; then
    if [ -s "$out_json" ]; then
      jq -s '.' "$out_json"
    else
      printf '[]\n'
    fi
  else
    printf 'hotspot\tpr_count\tprs\tagents\tclassification\trecommendation\tsuggested_order\n'
    if [ -s "$out_rows" ]; then
      cat "$out_rows"
    fi
  fi

  rm -f "$out_rows" "$out_json" "$rows_file" "$json_file"

  if [ "$blocker_count" -gt 0 ] && [ "$HOTSPOT_REFUSE_ON_BLOCKER" = "1" ]; then
    audit "DISPATCH_PLAN hotspots-blocker project=$PROJECT count=$blocker_count"
    return "$DISPATCH_PLAN_HOTSPOT_REFUSE_EXIT_CODE"
  fi
  audit "DISPATCH_PLAN hotspots project=$PROJECT count=${#HOTSPOT_PRS[@]} blocker=$blocker_count"
  return 0
}

ci_rollup_classification() {
  jq -r '
    [ .statusCheckRollup[]?
      | ((.state // .status // .conclusion // .bucket // "") | tostring | ascii_downcase)
    ] as $states
    | if ($states | length) == 0 then "unknown"
      elif any($states[]; test("pending|queued|in_progress|waiting|requested|expected")) then "pending"
      elif any($states[]; test("fail|error|cancel|timed|action_required")) then "failing"
      else "success"
      end
  '
}

issue_scope_files() {
  local body=$1
  printf '%s\n' "$body" \
    | awk '
      function emit(line) {
        gsub(/`/, "", line)
        sub(/^[[:space:]]*[-*][[:space:]]*/, "", line)
        sub(/^[[:space:]]*[0-9]+[.)][[:space:]]*/, "", line)
        sub(/[[:space:]]+#.*$/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        sub(/[,;]$/, "", line)
        if (line ~ /\// && line !~ /[[:space:]]/ && line !~ /^https?:\/\//) {
          print line
        }
      }
      /^[[:space:]]*$/ {
        if (in_scope) {
          in_scope = 0
        }
        next
      }
      {
        lower = tolower($0)
        if (lower ~ /^[[:space:]]*([-*][[:space:]]*)?(#+[[:space:]]*)?(scope files|ownership files|owned files|files touched|allowed files|file scope)[[:space:]]*:/ || lower ~ /^[[:space:]]*([-*][[:space:]]*)?(#+[[:space:]]*)?fichiers autoris/) {
          in_scope = 1
          line = $0
          sub(/^[[:space:]]*[-*][[:space:]]*/, "", line)
          sub(/^[^:]+:[[:space:]]*/, "", line)
          if (line != "") {
            emit(line)
          }
          next
        }
        if (in_scope) {
          emit($0)
        }
      }
    ' \
    | awk 'NF && !seen[$0]++' \
    | paste -sd, -
}

ci_scope_overlaps_file() {
  local scope=$1
  local changed_file=$2
  [ -n "$scope" ] && [ -n "$changed_file" ] || return 1
  if [ "$scope" = "$changed_file" ]; then
    return 0
  fi
  # shellcheck disable=SC2053 # RHS must stay unquoted here to evaluate issue-declared globs.
  if [[ "$scope" == *[\*\?\[]* ]] && [[ "$changed_file" == $scope ]]; then
    return 0
  fi
  if [[ "$scope" == */ ]] && [[ "$changed_file" == "$scope"* ]]; then
    return 0
  fi
  if [[ "$changed_file" == "$scope"/* ]]; then
    return 0
  fi
  return 1
}

ci_array_contains() {
  local needle=$1
  shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

tsv_field() {
  local value=$1
  printf '%s' "$value" | tr '\t\r\n' '   '
}

dispatch_plan_ci_overlap_main() {
  local base_ref prs_json pr_b64 pr_json pr_number pr_title pr_state files_json changed_file
  local pending_files_file rows_file json_file issues_json open_numbers issue_b64 issue_json
  base_ref=${DEFAULT_BRANCH:-main}
  pending_files_file=$(mktemp)
  rows_file=$(mktemp)
  json_file=$(mktemp)
  trap 'rm -f "$pending_files_file" "$rows_file" "$json_file"' RETURN

  prs_json=$(run_gh pr list \
    --repo "$GH_REPO" \
    --state open \
    --base "$base_ref" \
    --limit "$DISPATCH_PLAN_CI_OVERLAP_PR_LIMIT" \
    --json number,title,url,headRefName,statusCheckRollup,isDraft 2>/dev/null \
    || printf '[]')

  while IFS= read -r pr_b64; do
    [ -n "$pr_b64" ] || continue
    pr_json=$(printf '%s' "$pr_b64" | base64 -d)
    pr_number=$(printf '%s' "$pr_json" | jq -r '.number')
    pr_title=$(printf '%s' "$pr_json" | jq -r '.title // ""')
    pr_state=$(printf '%s' "$pr_json" | ci_rollup_classification)
    [ "$pr_state" = "pending" ] || continue
    files_json=$(run_gh pr view "$pr_number" --repo "$GH_REPO" --json files 2>/dev/null \
      || printf '{"files":[]}')
    while IFS= read -r changed_file; do
      [ -n "$changed_file" ] || continue
      printf '#%s\t%s\t%s\n' "$pr_number" "$changed_file" "$pr_title" >> "$pending_files_file"
    done < <(printf '%s' "$files_json" | jq -r '.files[]?.path' 2>/dev/null || true)
  done < <(printf '%s' "$prs_json" | jq -r '.[] | @base64')

  issues_json=$(run_gh issue list \
    --repo "$GH_REPO" \
    --state open \
    --limit "$DISPATCH_PLAN_LIMIT" \
    --json number,title,labels,assignees,body,updatedAt,url)
  open_numbers=$(printf '%s' "$issues_json" | jq -r '.[].number')
  all_pending_files=$(cut -f2 "$pending_files_file" 2>/dev/null | awk 'NF && !seen[$0]++' | paste -sd, -)

  while IFS= read -r issue_b64; do
    [ -n "$issue_b64" ] || continue
    issue_json=$(printf '%s' "$issue_b64" | base64 -d)
    number=$(printf '%s' "$issue_json" | jq -r '.number')
    title=$(printf '%s' "$issue_json" | jq -r '.title // ""')
    body=$(printf '%s' "$issue_json" | jq -r '.body // ""')
    labels=$(printf '%s' "$issue_json" | jq -r '[.labels[]?.name] | join(",")')
    assignees=$(printf '%s' "$issue_json" | jq -r '[.assignees[]?.login] | join(",")')
    assignee_count=$(printf '%s' "$issue_json" | jq '[.assignees[]?] | length')
    deps=$(deps_from_body "$body")
    text_blockers=$(text_blockers_from_issue "$title" "$body")
    scope_files=$(issue_scope_files "$body")

    labels_lower=${labels,,}
    title_lower=${title,,}
    body_upper=${body^^}
    tasks=$(checkbox_tasks "$body")
    task_count=$(printf '%s\n' "$tasks" | sed '/^$/d' | wc -l | tr -d ' ')
    atomized_child=0
    if [[ "$labels_lower" == *ordo:child* || "$labels_lower" == *ordo:atomized* || "$body_upper" == *ORDO-ATOMIZE:* ]]; then
      atomized_child=1
    fi
    dispatch_single_pr=0
    if [[ "$labels_lower" == *dispatch:single-pr* || "$labels_lower" == *ordo:dispatchable-parent* || "$body_upper" == *ORDO-DISPATCHABLE-PARENT* ]]; then
      dispatch_single_pr=1
      task_count=0
    fi
    needs_atomize=0
    if [[ "$labels_lower" == *needs:atomize* || "$labels_lower" == *atomize* || "$labels_lower" == *size:xl* ]]; then
      needs_atomize=1
    elif [[ "$labels_lower" == *epic* || "$title_lower" == epic:* || "$title_lower" == "[epic]"* || "$title_lower" == *"[epic]"* ]]; then
      needs_atomize=1
    elif [[ "$labels_lower" == *meta* || "$title_lower" == "[meta]"* || "$title_lower" == *"[meta]"* || "$title_lower" == *"meta-ticket"* || "$title_lower" == *consolidation* ]]; then
      needs_atomize=1
    elif [ "${task_count:-0}" -ge "$DISPATCH_PLAN_ATOMIZE_MIN_TASKS" ]; then
      needs_atomize=1
    fi
    [ "$atomized_child" -eq 1 ] && needs_atomize=0
    [ "$dispatch_single_pr" -eq 1 ] && needs_atomize=0

    label_blocked=0
    if [[ "$labels_lower" == *blocked* || "$labels_lower" == *"status:blocked"* || "$labels_lower" == *"needs:external"* || "$labels_lower" == *"external_wait"* ]]; then
      label_blocked=1
    fi

    blockers=()
    if [ -n "$deps" ]; then
      IFS=, read -r -a dep_array <<< "$deps"
      for dep in "${dep_array[@]}"; do
        [ -n "$dep" ] || continue
        state=$(dep_state "$dep" "$open_numbers")
        case "$state" in
          OPEN|UNKNOWN) blockers+=("#${dep}:${state}") ;;
        esac
      done
    fi
    if [ -n "$text_blockers" ]; then
      while IFS= read -r text_blocker; do
        [ -n "$text_blocker" ] || continue
        blockers+=("$text_blocker")
      done <<< "$text_blockers"
    fi

    status="ready"
    if [ "$label_blocked" -eq 1 ]; then
      status="blocked"
    elif [ "${#blockers[@]}" -gt 0 ]; then
      status="blocked"
    elif [ "$needs_atomize" -eq 1 ]; then
      status="atomize"
    elif [ "$assignee_count" -gt 0 ]; then
      status="assigned"
    fi

    overlap_prs=()
    overlap_files=()
    if [ -n "$scope_files" ] && [ -s "$pending_files_file" ]; then
      IFS=, read -r -a scope_array <<< "$scope_files"
      while IFS=$'\t' read -r pending_pr pending_file _pending_title; do
        if [ -z "$pending_pr" ] || [ -z "$pending_file" ]; then
          continue
        fi
        for scope_file in "${scope_array[@]}"; do
          [ -n "$scope_file" ] || continue
          if ci_scope_overlaps_file "$scope_file" "$pending_file"; then
            ci_array_contains "$pending_pr" "${overlap_prs[@]}" || overlap_prs+=("$pending_pr")
            ci_array_contains "$pending_file" "${overlap_files[@]}" || overlap_files+=("$pending_file")
          fi
        done
      done < "$pending_files_file"
    fi
    overlap_pr_text=$(signals_join "${overlap_prs[@]}")
    overlap_file_text=$(signals_join "${overlap_files[@]}")

    classification="parallel_safe"
    parallel_safe="true"
    blocked_reason=""
    suggested_next_action="dispatch_with_ci_overlap_brief"
    if [ "$status" = "blocked" ] && [ -n "$deps" ]; then
      classification="blocked_by_ci_dependency"
      parallel_safe="false"
      blocked_reason="dependency_blocker"
      suggested_next_action="wait_for_dependency_before_dispatch"
      brief_note="Issue has dependency blockers; do not dispatch during CI-pending wave."
    elif [ "$status" != "ready" ]; then
      classification="needs_human_decision"
      parallel_safe="false"
      blocked_reason="issue_status:${status}"
      suggested_next_action="resolve_dispatch_status_before_ci_overlap_dispatch"
      brief_note="Issue is ${status}; resolve the dispatch status before using CI-overlap planning."
    elif [ -z "$scope_files" ]; then
      classification="needs_human_decision"
      parallel_safe="false"
      blocked_reason="missing_scope_files"
      suggested_next_action="add_scope_files_to_issue_before_dispatch"
      brief_note="Add a Scope files section to the issue before dispatching while CI is pending."
    elif [ -n "$overlap_file_text" ]; then
      classification="blocked_by_files"
      parallel_safe="false"
      blocked_reason="pending_pr_file_overlap"
      suggested_next_action="wait_for_ci_or_rescope_away_from_pending_files"
      brief_note="Pending CI PRs ${overlap_pr_text} already touch ${overlap_file_text}; do not dispatch until CI settles or scope changes."
    elif [ -n "$all_pending_files" ]; then
      brief_note="Forbidden while CI pending: ${all_pending_files}. Stay within declared scope: ${scope_files}."
    else
      brief_note="No CI-pending PR files detected; normal dispatch rules apply."
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$number" "$status" "$classification" "$parallel_safe" "$scope_files" "$overlap_pr_text" \
      "$overlap_file_text" "$blocked_reason" "$suggested_next_action" "$(tsv_field "$brief_note")" \
      "$(tsv_field "$title")" >> "$rows_file"

    jq -nc \
      --argjson issue "$number" \
      --arg status "$status" \
      --arg classification "$classification" \
      --arg parallel_safe "$parallel_safe" \
      --arg scope_files "$scope_files" \
      --arg overlap_prs "$overlap_pr_text" \
      --arg overlap_files "$overlap_file_text" \
      --arg blocked_reason "$blocked_reason" \
      --arg suggested_next_action "$suggested_next_action" \
      --arg brief_note "$brief_note" \
      --arg title "$title" \
      '{issue:$issue,status:$status,classification:$classification,parallel_safe:($parallel_safe == "true"),scope_files:($scope_files|split(",")|map(select(length>0))),overlap_prs:($overlap_prs|split(",")|map(select(length>0))),overlap_files:($overlap_files|split(",")|map(select(length>0))),blocked_reason:$blocked_reason,suggested_next_action:$suggested_next_action,brief_note:$brief_note,title:$title}' \
      >> "$json_file"
  done < <(printf '%s' "$issues_json" | jq -r '.[] | @base64')

  if [ "$FORMAT" = "json" ]; then
    jq -s 'sort_by((.parallel_safe | not), .classification, .issue)' "$json_file"
  else
    printf 'issue\tstatus\tclassification\tparallel_safe\tscope_files\toverlap_prs\toverlap_files\tblocked_reason\tsuggested_next_action\tbrief_note\ttitle\n'
    sort -t "$(printf '\t')" -k3,3 -k1,1n "$rows_file"
  fi
}

if [ "$HOTSPOTS" = "1" ]; then
  dispatch_plan_hotspots_main
  exit $?
fi

if [ "$CI_OVERLAP" = "1" ]; then
  dispatch_plan_ci_overlap_main
  exit $?
fi

issues_json=$(run_gh issue list \
  --repo "$GH_REPO" \
  --state open \
  --limit "$DISPATCH_PLAN_LIMIT" \
  --json number,title,labels,assignees,body,updatedAt,url)
DISPATCH_PLAN_REPO_LABEL_NAMES=$(dispatch_plan_fetch_repo_label_names)
dispatch_plan_label_preflight "$issues_json"

open_numbers=$(printf '%s' "$issues_json" | jq -r '.[].number')
declare -A ISSUE_PARENT=()
declare -A ISSUE_ATOMIZED_CHILD=()
declare -A ISSUE_SEMANTIC_DEP_REASON=()
declare -A OPEN_ATOMIZED_SIBLINGS_BY_PARENT=()
rows_file=$(mktemp)
json_file=$(mktemp)
atomize_file=$(mktemp)
priority_resolution_file=$(mktemp)
cleanup() {
  rm -f "$rows_file" "$json_file" "$atomize_file" "$priority_resolution_file"
}
trap cleanup EXIT

while IFS= read -r issue_b64; do
  issue_json=$(printf '%s' "$issue_b64" | base64 -d)
  number=$(printf '%s' "$issue_json" | jq -r '.number')
  title=$(printf '%s' "$issue_json" | jq -r '.title // ""')
  body=$(printf '%s' "$issue_json" | jq -r '.body // ""')
  parent=$(parent_from_body "$body")
  atomized_child=$(atomized_child_from_issue "$title" "$body" "$parent")
  semantic_reason=$(semantic_sibling_dependency_reason "$title" "$body")
  ISSUE_PARENT[$number]=$parent
  ISSUE_ATOMIZED_CHILD[$number]=$atomized_child
  ISSUE_SEMANTIC_DEP_REASON[$number]=$semantic_reason
  if [ "$atomized_child" -eq 1 ] && [ -n "$parent" ]; then
    if [ -n "${OPEN_ATOMIZED_SIBLINGS_BY_PARENT[$parent]:-}" ]; then
      OPEN_ATOMIZED_SIBLINGS_BY_PARENT[$parent]="${OPEN_ATOMIZED_SIBLINGS_BY_PARENT[$parent]},${number}"
    else
      OPEN_ATOMIZED_SIBLINGS_BY_PARENT[$parent]=$number
    fi
  fi
done < <(printf '%s' "$issues_json" | jq -r '.[] | @base64')

while IFS= read -r issue_b64; do
  issue_json=$(printf '%s' "$issue_b64" | base64 -d)
  number=$(printf '%s' "$issue_json" | jq -r '.number')
  title=$(printf '%s' "$issue_json" | jq -r '.title // ""')
  body=$(printf '%s' "$issue_json" | jq -r '.body // ""')
  url=$(printf '%s' "$issue_json" | jq -r '.url // ""')
  labels=$(printf '%s' "$issue_json" | jq -r '[.labels[]?.name] | join(",")')
  assignees=$(printf '%s' "$issue_json" | jq -r '[.assignees[]?.login] | join(",")')
  assignee_count=$(printf '%s' "$issue_json" | jq '[.assignees[]?] | length')
  priority_pair=$(priority_for_labels "$labels")
  priority=${priority_pair%%|*}
  priority_rest=${priority_pair#*|}
  score=${priority_rest%%|*}
  priority_rest=${priority_rest#*|}
  priority_rank=${priority_rest%%|*}
  priority_status=${priority_rest#*|}
  if [ "$priority" = "none" ]; then
    priority=""
  fi
  deps=$(deps_from_body "$body")
  text_blockers=$(text_blockers_from_issue "$title" "$body")
  parent=${ISSUE_PARENT[$number]:-}
  tasks=$(checkbox_tasks "$body")
  task_count=$(printf '%s\n' "$tasks" | sed '/^$/d' | wc -l | tr -d ' ')

  labels_lower=${labels,,}
  title_lower=${title,,}
  body_upper=${body^^}
  labels_csv=",${labels_lower},"
  atomized_child=0
  if [[ "$labels_lower" == *ordo:child* || "$labels_lower" == *ordo:atomized* || "$body_upper" == *ORDO-ATOMIZE:* ]]; then
    atomized_child=1
  fi
  if [ "$atomized_child" -eq 0 ]; then
    atomized_child=${ISSUE_ATOMIZED_CHILD[$number]:-0}
  fi
  semantic_reason=${ISSUE_SEMANTIC_DEP_REASON[$number]:-}
  # Explicit "this is a single-PR parent" markers that suppress atomization
  # even if the body still contains task-style checklists. Use the body marker
  # ORDO-DISPATCHABLE-PARENT or one of the labels dispatch:single-pr /
  # ordo:dispatchable-parent. See issue #265 and docs/dispatch-planning.md.
  dispatch_single_pr=0
  if [[ "$labels_lower" == *dispatch:single-pr* || "$labels_lower" == *ordo:dispatchable-parent* ]]; then
    dispatch_single_pr=1
  fi
  if [[ "$body_upper" == *ORDO-DISPATCHABLE-PARENT* ]]; then
    dispatch_single_pr=1
  fi
  if [ "$dispatch_single_pr" -eq 1 ]; then
    tasks=""
    task_count=0
  fi

  active_backlog_issue=0
  if [ "$ACTIVE_BACKLOG" = "1" ] \
    || [[ "$labels_csv" == *",dispatch:active-backlog,"* ]] \
    || [[ "$labels_csv" == *",ordo:active-backlog,"* ]] \
    || [[ "$body_upper" == *ORDO-ACTIVE-BACKLOG* ]]; then
    active_backlog_issue=1
  fi

  explicit_shipped_label=0
  if [[ "$labels_csv" == *",shipped,"* ]] \
    || [[ "$labels_csv" == *",status:shipped,"* ]] \
    || [[ "$labels_csv" == *",resolution:shipped,"* ]] \
    || [[ "$labels_csv" == *",dispatch:shipped,"* ]] \
    || [[ "$labels_csv" == *",ordo:shipped,"* ]]; then
    explicit_shipped_label=1
    active_backlog_issue=0
  fi

  needs_atomize=0
  if [[ "$labels_lower" == *needs:atomize* || "$labels_lower" == *atomize* || "$labels_lower" == *size:xl* ]]; then
    needs_atomize=1
  elif [[ "$labels_lower" == *epic* || "$title_lower" == epic:* || "$title_lower" == "[epic]"* || "$title_lower" == *"[epic]"* ]]; then
    needs_atomize=1
  elif [[ "$labels_lower" == *meta* || "$title_lower" == "[meta]"* || "$title_lower" == *"[meta]"* || "$title_lower" == *"meta-ticket"* || "$title_lower" == *consolidation* ]]; then
    needs_atomize=1
  elif [ "${task_count:-0}" -ge "$DISPATCH_PLAN_ATOMIZE_MIN_TASKS" ]; then
    needs_atomize=1
  fi
  if [ "$atomized_child" -eq 1 ]; then
    needs_atomize=0
  fi
  if [ "$dispatch_single_pr" -eq 1 ]; then
    needs_atomize=0
  fi

  label_blocked=0
  if [[ "$labels_lower" == *blocked* || "$labels_lower" == *"status:blocked"* || "$labels_lower" == *"needs:external"* || "$labels_lower" == *"external_wait"* ]]; then
    label_blocked=1
  fi

  blockers=()
  text_blocker_count=0
  sibling_blockers=()
  open_pr_blockers=()
  gated_blockers=()
  gated_waivers=()
  gated_deps_declared=$(portfolio_gated_dependencies_for_issue "$number")
  gated_waived_full=0
  if [ -n "$gated_deps_declared" ] && portfolio_gated_dependency_waived "$number"; then
    gated_waived_full=1
  fi
  if [ -n "$deps" ]; then
    IFS=, read -r -a dep_array <<< "$deps"
    for dep in "${dep_array[@]}"; do
      [ -n "$dep" ] || continue
      state=$(dep_state "$dep" "$open_numbers")
      case "$state" in
        OPEN|UNKNOWN) blockers+=("#${dep}:${state}") ;;
      esac
    done
  fi
  if [ -n "$text_blockers" ]; then
    while IFS= read -r text_blocker; do
      [ -n "$text_blocker" ] || continue
      blockers+=("$text_blocker")
      text_blocker_count=$((text_blocker_count + 1))
    done <<< "$text_blockers"
  fi
  open_prs=$(open_prs_for_issue "$number")
  if [ -n "$open_prs" ]; then
    IFS=, read -r -a open_pr_array <<< "$open_prs"
    for open_pr in "${open_pr_array[@]}"; do
      [ -n "$open_pr" ] || continue
      blockers+=("open_pr:#${open_pr}")
      open_pr_blockers+=("$open_pr")
    done
  fi
  if [ -n "$gated_deps_declared" ] && [ "$gated_waived_full" -eq 0 ]; then
    IFS=, read -r -a gated_dep_array <<< "$gated_deps_declared"
    for gated_dep in "${gated_dep_array[@]}"; do
      [ -n "$gated_dep" ] || continue
      if portfolio_gated_dependency_waived "$number" "$gated_dep"; then
        gated_waivers+=("$gated_dep")
        continue
      fi
      gated_state=$(dep_state "$gated_dep" "$open_numbers")
      case "$gated_state" in
        OPEN|UNKNOWN)
          blockers+=("gated:#${gated_dep}:${gated_state}")
          gated_blockers+=("$gated_dep")
          ;;
      esac
    done
  fi
  if [ "$atomized_child" -eq 1 ] && [ -n "$parent" ] && [ -n "$semantic_reason" ]; then
    sibling_numbers=${OPEN_ATOMIZED_SIBLINGS_BY_PARENT[$parent]:-}
    if [ -n "$sibling_numbers" ]; then
      IFS=, read -r -a sibling_array <<< "$sibling_numbers"
      for sibling in "${sibling_array[@]}"; do
        [ -n "$sibling" ] || continue
        [ "$sibling" = "$number" ] && continue
        [ -n "${ISSUE_SEMANTIC_DEP_REASON[$sibling]:-}" ] && continue
        blockers+=("sibling:#${sibling}:OPEN")
        sibling_blockers+=("$sibling")
      done
    fi
  fi
  blocker_text=$(signals_join "${blockers[@]}")

  status="ready"
  signals=()
  if [ -n "$priority" ]; then
    signals+=("priority:${priority}")
  elif [ "$priority_status" = "unsupported" ]; then
    signals+=("priority-label-unsupported:${priority_rank}")
  fi
  [ "$atomized_child" -eq 1 ] && signals+=("atomized-child")
  [ "$dispatch_single_pr" -eq 1 ] && signals+=("dispatchable-parent")
  [ -n "$parent" ] && signals+=("parent:#${parent}")
  [ -n "$deps" ] && signals+=("has-deps")
  [ "$text_blocker_count" -gt 0 ] && signals+=("text-blocked")
  if [ "${#open_pr_blockers[@]}" -gt 0 ]; then
    signals+=("open-pr")
    for open_pr in "${open_pr_blockers[@]}"; do
      signals+=("open_pr:#${open_pr}")
    done
  fi
  if [ "${#sibling_blockers[@]}" -gt 0 ]; then
    signals+=("semantic-dependency:${semantic_reason}")
    signals+=("blocked_by_sibling")
    for sibling in "${sibling_blockers[@]}"; do
      signals+=("blocked_by_sibling:#${sibling}")
    done
  fi
  if [ -n "$gated_deps_declared" ]; then
    signals+=("has-gated-deps")
    if [ "$gated_waived_full" -eq 1 ]; then
      signals+=("gated-deps-waived")
    fi
    if [ "${#gated_waivers[@]}" -gt 0 ]; then
      for gated_waiver in "${gated_waivers[@]}"; do
        signals+=("gated-dep-waived:#${gated_waiver}")
      done
    fi
    if [ "${#gated_blockers[@]}" -gt 0 ]; then
      signals+=("gated-by-policy")
      for gated_blocker in "${gated_blockers[@]}"; do
        signals+=("gated-by:#${gated_blocker}")
      done
    fi
  fi
  if [ "$label_blocked" -eq 1 ]; then
    status="blocked"
    signals+=("blocked")
    signals+=("label-blocked")
    score=$((score - 500))
  elif [ "${#blockers[@]}" -gt 0 ]; then
    status="blocked"
    signals+=("blocked")
    score=$((score - 500))
  elif [ "$explicit_shipped_label" -eq 1 ]; then
    status="shipped_suspect"
    signals+=("explicit-shipped-label")
    signals+=("shipped-suspect")
    score=$((score - 300))
  elif [ "$needs_atomize" -eq 1 ]; then
    status="atomize"
    signals+=("needs-atomization")
    score=$((score - 50))
  elif [ "$assignee_count" -gt 0 ]; then
    status="assigned"
    signals+=("assigned")
    score=$((score - 200))
  else
    signals+=("ready")
  fi
  [ "$active_backlog_issue" -eq 1 ] && signals+=("active-backlog")

  shipped_pr=""
  shipped_comment=""
  ship_evidence=""
  if [ "$DISPATCH_PLAN_SHIPPED_GATE" = "1" ] && { [ "$status" = "ready" ] || [ "$status" = "atomize" ]; }; then
    shipped_pr=$(shipped_pr_for_issue "$number" || true)
    if [ -n "$shipped_pr" ]; then
      shipped_pr_number=${shipped_pr%%|*}
      shipped_pr_url=${shipped_pr#*|}
      shipped_pr_url=${shipped_pr_url%%|*}
      if [ "$active_backlog_issue" -eq 1 ]; then
        signals+=("shipped-advisory")
      else
        status="shipped_suspect"
        score=$((score - 300))
        signals+=("stale-suspect")
      fi
      signals+=("shipped-suspect")
      signals+=("merged-pr:#${shipped_pr_number}")
      ship_evidence="pr:#${shipped_pr_number}@${shipped_pr_url}"
    else
      shipped_comment=$(shipped_comment_for_issue "$number" || true)
      if [ -n "$shipped_comment" ]; then
        shipped_comment_pr=${shipped_comment%%|*}
        shipped_comment_rest=${shipped_comment#*|}
        shipped_comment_url=${shipped_comment_rest%%|*}
        shipped_comment_author=${shipped_comment##*|}
        if [ "$active_backlog_issue" -eq 1 ]; then
          signals+=("shipped-advisory")
        else
          status="shipped_suspect"
          score=$((score - 300))
          signals+=("stale-suspect")
        fi
        signals+=("shipped-suspect")
        signals+=("shipped-comment:#${shipped_comment_pr}")
        signals+=("comment-by:${shipped_comment_author}")
        ship_evidence="comment:#${shipped_comment_pr}@${shipped_comment_url}|author:${shipped_comment_author}"
      fi
    fi
    if [ "$status" = "shipped_suspect" ] && [ "${task_count:-0}" -gt 0 ] && [ "$atomized_child" -eq 0 ]; then
      status="stale_parent"
      needs_atomize=1
      signals+=("stale-parent")
      signals+=("followup-available")
    fi
  fi
  [ "$assignee_count" -eq 0 ] && signals+=("unassigned")

  local_assigned=0
  if [[ "$LOCAL_ASSIGNED_SET" == *",${number},"* ]]; then
    local_assigned=1
    signals+=("local-assigned")
  fi

  agent_hint=$(agent_hint_for_issue "$title" "$labels" "$body")
  conflict_with_json='[]'
  if [ "$READY_ONLY" -eq 1 ]; then
    conflict_with_json=$(dispatch_plan_compute_conflict_with \
      "$number" "${title}"$'\n'"${body}")
    case "$conflict_with_json" in
      '['*) : ;;
      *) conflict_with_json='[]' ;;
    esac
    if [ "$conflict_with_json" != '[]' ] && [ "$conflict_with_json" != '["unknown"]' ]; then
      signals+=("conflict-with:$(printf '%s' "$conflict_with_json" | jq -r '. | join("+")')")
    fi
  fi
  signal_text=$(signals_join "${signals[@]}")
  gated_by_text=$(signals_join "${gated_blockers[@]}")
  gated_waivers_text=$(signals_join "${gated_waivers[@]}")

  if [ "$READY_ONLY" -eq 1 ] && [ "$local_assigned" -eq 1 ]; then
    continue
  fi
  if [ "$READY_ONLY" -eq 1 ] && [ "$status" != "ready" ]; then
    if [ "$INCLUDE_SHIPPED_SUSPECT" != "1" ] || { [ "$status" != "shipped_suspect" ] && [ "$status" != "stale_parent" ]; }; then
      continue
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$number" "$priority" "$score" "$status" "$agent_hint" "$assignees" "$deps" \
    "$blocker_text" "$task_count" "$parent" "$signal_text" "$title" >> "$rows_file"

  jq -nc \
    --argjson issue "$number" \
    --arg priority "$priority" \
    --argjson score "$score" \
    --arg status "$status" \
    --arg agent_hint "$agent_hint" \
    --arg assignees "$assignees" \
    --arg deps "$deps" \
    --arg blockers "$blocker_text" \
    --argjson atomize_tasks "$task_count" \
    --arg parent "$parent" \
    --arg signals "$signal_text" \
    --arg title "$title" \
    --arg url "$url" \
    --arg gated_deps "$gated_deps_declared" \
    --arg gated_by "$gated_by_text" \
    --arg gated_waivers "$gated_waivers_text" \
    --argjson gated_waived_full "$gated_waived_full" \
    --argjson local_assigned "$local_assigned" \
    --argjson conflict_with "$conflict_with_json" \
    --argjson ready_only "$READY_ONLY" \
    '{issue:$issue,priority:$priority,score:$score,status:$status,agent_hint:$agent_hint,assignees:($assignees|split(",")|map(select(length>0))),deps:($deps|split(",")|map(select(length>0))),blockers:($blockers|split(",")|map(select(length>0))),atomize_tasks:$atomize_tasks,parent:(if $parent == "" then null else ($parent|tonumber) end),signals:($signals|split(",")|map(select(length>0))),title:$title,url:$url,gated_deps:($gated_deps|split(",")|map(select(length>0))|map(tonumber)),gated_by:($gated_by|split(",")|map(select(length>0))|map(tonumber)),gated_waivers:($gated_waivers|split(",")|map(select(length>0))|map(tonumber)),gated_waived:($gated_waived_full == 1),local_assigned:($local_assigned == 1)} + (if $ready_only == 1 then {conflict_with:$conflict_with} else {} end)' >> "$json_file"

  if [ "$needs_atomize" -eq 1 ] && [ -n "$tasks" ]; then
    atomize_kind="regular"
    if [ "$status" = "stale_parent" ]; then
      atomize_kind="followup"
    fi
    while IFS= read -r task; do
      [ -n "$task" ] || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$number" "$title" "$url" "$task" "$atomize_kind" "$ship_evidence" >> "$atomize_file"
    done <<< "$tasks"
  fi
done < <(printf '%s' "$issues_json" | jq -r '.[] | @base64')

if [ -n "$PRIORITY_SET" ]; then
  PRIORITY_SET=$(priority_set_normalize "$PRIORITY_SET")
  if [ -z "$PRIORITY_SET" ]; then
    echo "--priority-set: no valid ticket numbers parsed" >&2
    exit 2
  fi
  priority_set_emit_table "$PRIORITY_SET" "$priority_resolution_file"

  if [ "$PRIORITY_SET_STRICT" -eq 1 ]; then
    filtered_json=$(mktemp)
    priority_set_filter_tsv_file "$PRIORITY_SET" "$rows_file"
    priority_set_filter_tsv_file "$PRIORITY_SET" "$atomize_file"
    jq -c --arg set "$PRIORITY_SET" '
      ($set | split(",") | map(tonumber)) as $allow
      | select(.issue as $i | $allow | index($i) != null)
    ' "$json_file" > "$filtered_json"
    mv "$filtered_json" "$json_file"
    printf 'priority-set: strict mode — filtering to allowlist regardless of readiness\n' >&2
    summary=$(awk 'BEGIN{FS="\t"} NF {printf " #%s=%s", $1, $4}' "$rows_file")
    if [ -z "$summary" ]; then
      printf 'strict-priority-set: allowlist statuses: (no allowlisted tickets are open in this repo)\n' >&2
    else
      printf 'strict-priority-set: allowlist statuses:%s\n' "$summary" >&2
    fi
  else
    if [ "$ATOMIZE" -eq 1 ] && [ "$PRIORITY_SET_OVERRIDE" -eq 0 ]; then
      priority_set_filter_tsv_file "$PRIORITY_SET" "$atomize_file"
      printf 'priority-set: atomize mode — filtering child creation to allowlist\n' >&2
    fi

    any_priority_ready=0
    if awk -v set=",${PRIORITY_SET}," 'BEGIN{FS="\t"} index(set, "," $1 ",") && $4 == "ready" {found=1} END{exit found ? 0 : 1}' "$rows_file"; then
      any_priority_ready=1
    fi

    if [ "$any_priority_ready" -eq 1 ] && [ "$PRIORITY_SET_OVERRIDE" -eq 0 ]; then
      filtered_json=$(mktemp)
      priority_set_filter_tsv_file "$PRIORITY_SET" "$rows_file"
      priority_set_filter_tsv_file "$PRIORITY_SET" "$atomize_file"
      jq -c --arg set "$PRIORITY_SET" '
        ($set | split(",") | map(tonumber)) as $allow
        | select(.issue as $i | $allow | index($i) != null)
      ' "$json_file" > "$filtered_json"
      mv "$filtered_json" "$json_file"
      printf 'priority-set: refusing non-allowlisted dispatch (override with --priority-set-override)\n' >&2
    elif [ "$any_priority_ready" -eq 1 ] && [ "$PRIORITY_SET_OVERRIDE" -eq 1 ]; then
      printf 'priority-set: override active — non-allowlisted tickets retained in queue\n' >&2
    else
      printf 'priority-set: no allowlisted ready tickets — queue unchanged (use --strict-priority-set to filter to the allowlist anyway)\n' >&2
    fi
  fi
fi

# Issue #454: opt-in fleet-aware join for `--ready-only`. The supervisor
# was previously expected to read `agent_pool_status.sh --tsv` and
# `dispatch_plan.sh --ready-only` in parallel and join `dirty,dirty_after_pr`
# rows against the ready queue by hand. With `--with-agent-capacity` the
# planner runs that snapshot itself, prints a compact per-agent capacity
# advisory to stderr (above the queue, so it scrolls with the queue
# output), and — when the fleet has zero dispatchable slots — tags every
# remaining ready row with `fleet-blocked` plus a per-agent
# `fleet-blocked:<label>:<reason>` signal so the ready output cannot be
# read in isolation as "go dispatch this now".
#
# The join is opt-in: existing callers (orch_loop, portfolio_status,
# scripted dashboards) keep their JSON shape and TSV column count by
# default. Enabling it requires either `--with-agent-capacity` on the
# CLI or `DISPATCH_PLAN_WITH_AGENT_CAPACITY=1` in the project profile.
if [ "$WITH_AGENT_CAPACITY" -eq 1 ] && [ "$READY_ONLY" -eq 1 ]; then
  capacity_snapshot=""
  capacity_status=0
  capacity_snapshot=$(orch_run_timeout "${DISPATCH_PLAN_AGENT_CAPACITY_TIMEOUT_SEC:-15}" \
    "$TK/scripts/agent_pool_status.sh" "$CFG_ARG" --json 2>/dev/null) || capacity_status=$?
  if [ "$capacity_status" -ne 0 ] || [ -z "$capacity_snapshot" ]; then
    printf 'agent-capacity: snapshot unavailable (status=%s) — ready queue emitted without fleet join\n' \
      "$capacity_status" >&2
    audit "DISPATCH_PLAN agent_capacity snapshot_unavailable project=$PROJECT status=$capacity_status"
  else
    fleet_count=$(printf '%s' "$capacity_snapshot" | jq -r 'length // 0' 2>/dev/null || printf '0')
    if [ "$fleet_count" = "0" ]; then
      printf 'agent-capacity: fleet snapshot empty for project=%s — no agents configured\n' \
        "$PROJECT" >&2
      audit "DISPATCH_PLAN agent_capacity empty_fleet project=$PROJECT"
    else
      dispatchable_count=$(printf '%s' "$capacity_snapshot" \
        | jq -r '[.[] | select(.dispatchable == true)] | length' 2>/dev/null || printf '0')
      blocked_count=$((fleet_count - dispatchable_count))
      printf 'agent-capacity: project=%s total=%s dispatchable=%s blocked=%s\n' \
        "$PROJECT" "$fleet_count" "$dispatchable_count" "$blocked_count" >&2
      printf 'agent\tcapacity_class\tdispatchable\tblocked_reason\tremediation\n' >&2
      printf '%s' "$capacity_snapshot" \
        | jq -r '.[] | [.label, .capacity_class, (if .dispatchable then "yes" else "no" end), (.blocked_reason // ""), (.remediation // "")] | @tsv' \
          2>/dev/null >&2 || true
      audit "DISPATCH_PLAN agent_capacity advisory project=$PROJECT total=$fleet_count dispatchable=$dispatchable_count blocked=$blocked_count"

      if [ "$dispatchable_count" = "0" ] && [ -s "$rows_file" ]; then
        # Build the per-agent fleet-blocked tags from the snapshot so
        # operators see why the queue is stalled (e.g.
        # fleet-blocked:RBOK-codex:dirty_after_pr) right next to the
        # ticket number. We keep the suffix machine-friendly (no spaces)
        # so existing signals consumers (orch_loop, dashboards) can
        # split on `:` without quoting.
        fleet_blocked_tag="fleet-blocked"
        per_agent_tags=$(printf '%s' "$capacity_snapshot" \
          | jq -r '.[] | select(.dispatchable == false) | "fleet-blocked:\(.label):\((.blocked_reason // "blocked"))"' \
            2>/dev/null | paste -sd, -)
        if [ -n "$per_agent_tags" ]; then
          fleet_blocked_tag="${fleet_blocked_tag},${per_agent_tags}"
        fi

        # Enrich the TSV signals column (col 11) in place.
        awk -v tag="$fleet_blocked_tag" 'BEGIN{FS=OFS="\t"} NF {
          if ($11 == "") { $11 = tag } else { $11 = $11 "," tag }
          print
        }' "$rows_file" > "$rows_file.fleet" && mv "$rows_file.fleet" "$rows_file"

        # Enrich the JSON signals array.
        jq -c --arg tag "$fleet_blocked_tag" '
          . as $row
          | ($tag | split(",") | map(select(length > 0))) as $extra
          | $row + {signals: ((.signals // []) + $extra)}
        ' "$json_file" > "$json_file.fleet" && mv "$json_file.fleet" "$json_file"

        audit "DISPATCH_PLAN agent_capacity fleet_blocked project=$PROJECT tag=${fleet_blocked_tag}"
      fi
    fi
  fi
fi

if [ "$FORMAT" = "json" ]; then
  jq -s 'sort_by(-.score, .issue)' "$json_file"
else
  printf 'issue\tpriority\tscore\tstatus\tagent_hint\tassignees\tdeps\tblockers\tatomize_tasks\tparent\tsignals\ttitle\n'
  sort -t "$(printf '\t')" -k3,3nr -k1,1n "$rows_file"
fi

if [ "$ATOMIZE" -eq 1 ]; then
  if [ ! -s "$atomize_file" ]; then
    audit "DISPATCH_PLAN atomize none project=$PROJECT"
    exit 0
  fi

  # Per-parent children ledger for the AUTO_ATOMIZE_SUMMARY stderr lines
  # consumed by orch_loop's auto-atomize step (#763). We emit one summary
  # line per parent at the end of the run so the caller can record the
  # parent->children mapping in audit + ledger without re-reading the
  # repo. Order of parents matches first-seen order in atomize_file so
  # the summary mirrors the priority ranking applied upstream.
  declare -A AUTO_ATOMIZE_PARENT_CHILDREN=()
  declare -a AUTO_ATOMIZE_PARENT_ORDER=()
  atomize_created_count=0

  while IFS=$'\t' read -r parent_num parent_title parent_url task atomize_kind ship_evidence; do
    : "${atomize_kind:=regular}"
    : "${ship_evidence:=}"
    if [ "$ATOMIZE_MAX_CHILDREN_PER_CYCLE" -gt 0 ] \
      && [ "$atomize_created_count" -ge "$ATOMIZE_MAX_CHILDREN_PER_CYCLE" ]; then
      audit "DISPATCH_PLAN atomize cap-reached project=$PROJECT max_per_cycle=$ATOMIZE_MAX_CHILDREN_PER_CYCLE created=$atomize_created_count"
      break
    fi
    if [ "$atomize_kind" = "followup" ]; then
      child_title="[followup #${parent_num}] ${task}"
      fingerprint=$(fingerprint_text "${GH_REPO}|${parent_num}|${task}|followup")
    else
      child_title="[parent #${parent_num}] ${task}"
      fingerprint=$(fingerprint_text "${GH_REPO}|${parent_num}|${task}")
    fi
    parent_body=$(printf '%s' "$issues_json" | jq -r --argjson n "$parent_num" '.[] | select(.number == $n) | .body // ""')
    context=$(truncate_context "$parent_body")
    trace_id="ORDO-ATOMIZE:${fingerprint}"
    existing_child=""
    if ! dry_run_enabled || [ "$DISPATCH_PLAN_DRY_RUN_VERIFY_EXISTING" = "1" ]; then
      existing_child=$(atomize_existing_child "$fingerprint" || true)
    fi
    if [ -n "$existing_child" ]; then
      existing_num=${existing_child%%|*}
      existing_url=${existing_child#*|}
      if dry_run_enabled; then
        dry_run_note "skip existing atomized child parent=#${parent_num} child=#${existing_num} trace=${trace_id} url=${existing_url}"
      else
        audit "DISPATCH_PLAN atomize existing parent=#${parent_num} child=#${existing_num} trace=${trace_id} url=${existing_url}"
      fi
      continue
    fi
    body_file=$(mktemp)
    {
      printf '<!-- %s -->\n\n' "$trace_id"
      printf '## ORDO Trace\n\n'
      printf -- '- Parent issue: #%s\n' "$parent_num"
      printf -- '- Parent URL: %s\n' "$parent_url"
      printf -- '- Parent title: %s\n' "$parent_title"
      printf -- "- Child fingerprint: \`%s\`\n" "$fingerprint"
      if [ "$atomize_kind" = "followup" ]; then
        printf -- "- Generated by: \`dispatch_plan --atomize\` (follow-up extracted from stale parent)\n"
        printf -- '- Scope policy: parent appears mostly shipped; this child captures a remaining unchecked task.\n\n'
      else
        printf -- "- Generated by: \`dispatch_plan --atomize\`\n"
        printf -- '- Scope policy: this child inherits parent requirements; parent remains the source of truth.\n\n'
      fi
      printf '## Child Objective\n\n%s\n\n' "$task"
      if [ "$atomize_kind" = "followup" ]; then
        printf '## Stale Parent Evidence\n\n'
        if [ -n "$ship_evidence" ]; then
          printf '%s\n' "$ship_evidence" | tr '|' '\n' | awk 'NF{print "- "$0}'
          printf '\n'
        else
          # shellcheck disable=SC2016 # backticks here are literal markdown, not command substitution
          printf -- '- Parent flagged as `stale_parent` by `dispatch_plan` based on shipped scope detection.\n\n'
        fi
      fi
      printf '## Scope Inherited From Parent\n\n'
      printf '%s\n\n' "$context"
      printf '## Constraints\n\n'
      if [ "$atomize_kind" = "followup" ]; then
        printf -- '- Treat this child as a focused follow-up: do NOT redo work already shipped via the evidence above.\n'
        # shellcheck disable=SC2016 # backticks here are literal markdown, not command substitution
        printf -- '- Verify the unchecked task is still required before implementing; if already covered, close as `already_aligned` with a link.\n'
      else
        printf -- '- Stay inside the parent issue scope and requirements.\n'
        printf -- '- Do not close or shrink parent requirements from this child.\n'
      fi
      printf -- '- Report any dependency or scope ambiguity back on the parent issue.\n'
    } > "$body_file"

    child_num=""
    if dry_run_enabled; then
      dry_run_note "gh issue create --repo $GH_REPO --title \"$child_title\" --body-file <generated> # parent=$parent_num trace=$trace_id"
    else
      created=$(run_gh issue create --repo "$GH_REPO" --title "$child_title" --body-file "$body_file" 2>&1)
      created_url=$(printf '%s\n' "$created" | tail -1)
      child_num=$(printf '%s\n' "$created_url" | grep -Eo '[0-9]+$' || true)
      audit "DISPATCH_PLAN atomized parent=#${parent_num} child=${created_url} trace=${trace_id}"
      if [ -n "$child_num" ]; then
        atomize_add_labels "$child_num"
      fi
      comment_rc=0
      comment_err=$(run_gh issue comment "$parent_num" --repo "$GH_REPO" \
        --body "Atomized child created: ${created_url}

Trace: ${trace_id}" 2>&1 >/dev/null) || comment_rc=$?
      if [[ "$comment_rc" -eq "$ORCH_GITHUB_IDENTITY_MISMATCH_EXIT_CODE" ]]; then
        printf '%s\n' "$comment_err" >&2
        exit "$comment_rc"
      fi
    fi
    rm -f "$body_file"
    atomize_created_count=$((atomize_created_count + 1))
    if [ -z "${AUTO_ATOMIZE_PARENT_CHILDREN[$parent_num]:-}" ]; then
      AUTO_ATOMIZE_PARENT_ORDER+=("$parent_num")
      AUTO_ATOMIZE_PARENT_CHILDREN[$parent_num]="${child_num}"
    else
      AUTO_ATOMIZE_PARENT_CHILDREN[$parent_num]="${AUTO_ATOMIZE_PARENT_CHILDREN[$parent_num]},${child_num}"
    fi
  done < "$atomize_file"

  for auto_atomize_parent in "${AUTO_ATOMIZE_PARENT_ORDER[@]}"; do
    printf 'AUTO_ATOMIZE_SUMMARY parent=%s children=%s project=%s max_per_cycle=%s\n' \
      "$auto_atomize_parent" \
      "${AUTO_ATOMIZE_PARENT_CHILDREN[$auto_atomize_parent]}" \
      "$PROJECT" \
      "$ATOMIZE_MAX_CHILDREN_PER_CYCLE" >&2
  done
fi
