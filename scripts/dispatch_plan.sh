#!/usr/bin/env bash
# scripts/dispatch_plan.sh - priority/dependency plan for issue dispatch.
#
# Usage:
#   dispatch_plan.sh <project_short|config_path> [--tsv|--json] [--ready-only] [--include-shipped-suspect]
#   dispatch_plan.sh <project_short|config_path> --priority-set <list> [--priority-set-override]
#   dispatch_plan.sh <project_short|config_path> --priority-set <list> --strict-priority-set
#   dispatch_plan.sh <project_short|config_path> --atomize [--dry-run]
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
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/config_resolver.sh"
source "$TK/lib/process_safety.sh"
source "$TK/lib/github_identity.sh"
source "$TK/lib/dispatch_plan_headers.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: dispatch_plan.sh <project> [--tsv|--json] [--ready-only] [--atomize] [--dry-run] [--priority-set <list>] [--hotspots]}
FORMAT="tsv"
READY_ONLY=0
INCLUDE_SHIPPED_SUSPECT=0
ATOMIZE=0
PRIORITY_SET=""
PRIORITY_SET_OVERRIDE=0
PRIORITY_SET_STRICT=0
HOTSPOTS=0
HOTSPOT_ACCEPT_RISK=""
HOTSPOT_REFUSE_ON_BLOCKER=0
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tsv) FORMAT="tsv" ;;
    --json) FORMAT="json" ;;
    --ready-only) READY_ONLY=1 ;;
    --include-shipped-suspect) INCLUDE_SHIPPED_SUSPECT=1 ;;
    --atomize) ATOMIZE=1 ;;
    --hotspots) HOTSPOTS=1 ;;
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
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

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
: "${DISPATCH_PLAN_INCLUDE_SHIPPED_SUSPECT:=0}"
: "${DISPATCH_PLAN_GH_TIMEOUT_SEC:=5}"
: "${DISPATCH_PLAN_HOTSPOT_PR_LIMIT:=50}"
: "${DISPATCH_PLAN_HOTSPOT_REFUSE_EXIT_CODE:=7}"

if [ "$DISPATCH_PLAN_INCLUDE_SHIPPED_SUSPECT" = "1" ]; then
  INCLUDE_SHIPPED_SUSPECT=1
fi

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
  local title=$1 body=$2 text
  text="${title}"$'\n'"${body}"

  if grep -Eiq '(^|[[:space:][:punct:]])(pr[eé]condition bloquante|blocking precondition|blocked until|bloqu[eé][[:space:]]+jusqu|requires validation[[:space:]]+before[[:space:]]+implementation|validation required[[:space:]]+before[[:space:]]+implementation|validation.*requise.*avant[[:space:]]+impl[eé]mentation)([[:space:][:punct:]]|$)' <<< "$text"; then
    printf 'precondition:blocking-precondition\n'
  fi

  if grep -Eiq '(^|[[:space:][:punct:]])(figma[[:space:]-]*first|design validation required|required design validation|requires design validation|requires validation from design|validation from design required|validation design requise|code connect[[:space:]]+(access|seat)[[:space:]]+(required|blocked|missing|pending)|developer seat required|(blocked|waiting|pending)[[:space:]]+(on|by|for|until)[[:space:]]+(the[[:space:]]+)?(figma|design[[:space:]]+(handoff|validation|review|sign[-[:space:]]?off))|figma[[:space:]]+(handoff|preflight|asset|spec|design|export|file)[[:space:]]+(required|requise|pending|missing|blocked|n[eé]cessaire)|figma[[:space:]]+(required|requise|needed|n[eé]cessaire)[[:space:]]+before[[:space:]]+(implementation|coding|impl[eé]mentation|d[eé]veloppement))([[:space:][:punct:]]|$)' <<< "$text"; then
    printf 'design:figma-or-design-gate\n'
  fi

  if grep -Eiq '(^|[[:space:][:punct:]])((a|à)[[:space:]]+arbitrer|d[eé]pend[[:space:]]+de|pending arbitration|needs arbitration|arbitration required|inputs?[[:space:]]+agence|agency inputs?|hosting decision|placement decision|external asset required|asset.*(required|missing)|decision required|pending decision)([[:space:][:punct:]]|$)' <<< "$text"; then
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
shipped_pr_for_issue() {
  local issue=${1:?usage: shipped_pr_for_issue <issue-number>}
  if [[ -n "${SHIPPED_PR_CACHE[$issue]:-}" ]]; then
    printf '%s\n' "${SHIPPED_PR_CACHE[$issue]}"
    return 0
  fi

  local base_ref search since prs_json match
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

  match=$(printf '%s' "$prs_json" | jq -r --arg issue "$issue" '
    def text: ((.title // "") + "\n" + (.body // "") + "\n" + (.headRefName // ""));
    def issue_re($n): "(^|[^0-9])#?" + $n + "([^0-9]|$)";
    [ .[]? | select(text | test(issue_re($issue))) ][0] // empty
    | if . == "" then "" else "\(.number)|\(.url)|\(.mergedAt)" end
  ' 2>/dev/null || true)

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

priority_for_labels() {
  local labels=$1
  local lower=${labels,,}
  case "$lower" in
    *priority:p0*|*priority-p0*|*p0*) printf 'P0|1000\n' ;;
    *priority:p1*|*priority-p1*|*p1*) printf 'P1|800\n' ;;
    *priority:p2*|*priority-p2*|*p2*) printf 'P2|600\n' ;;
    *priority:p3*|*priority-p3*|*p3*) printf 'P3|400\n' ;;
    *priority:p4*|*priority-p4*|*p4*) printf 'P4|100\n' ;;
    *) printf 'P3|300\n' ;;
  esac
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

if [ "$HOTSPOTS" = "1" ]; then
  dispatch_plan_hotspots_main
  exit $?
fi

issues_json=$(run_gh issue list \
  --repo "$GH_REPO" \
  --state open \
  --limit "$DISPATCH_PLAN_LIMIT" \
  --json number,title,labels,assignees,body,updatedAt,url)

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
  score=${priority_pair#*|}
  deps=$(deps_from_body "$body")
  text_blockers=$(text_blockers_from_issue "$title" "$body")
  parent=${ISSUE_PARENT[$number]:-}
  tasks=$(checkbox_tasks "$body")
  task_count=$(printf '%s\n' "$tasks" | sed '/^$/d' | wc -l | tr -d ' ')

  labels_lower=${labels,,}
  title_lower=${title,,}
  body_upper=${body^^}
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
  signals+=("priority:${priority}")
  [ "$atomized_child" -eq 1 ] && signals+=("atomized-child")
  [ "$dispatch_single_pr" -eq 1 ] && signals+=("dispatchable-parent")
  [ -n "$parent" ] && signals+=("parent:#${parent}")
  [ -n "$deps" ] && signals+=("has-deps")
  [ "$text_blocker_count" -gt 0 ] && signals+=("text-blocked")
  if [ "${#sibling_blockers[@]}" -gt 0 ]; then
    signals+=("semantic-dependency:${semantic_reason}")
    signals+=("blocked_by_sibling")
    for sibling in "${sibling_blockers[@]}"; do
      signals+=("blocked_by_sibling:#${sibling}")
    done
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

  shipped_pr=""
  shipped_comment=""
  ship_evidence=""
  if [ "$DISPATCH_PLAN_SHIPPED_GATE" = "1" ] && { [ "$status" = "ready" ] || [ "$status" = "atomize" ]; }; then
    shipped_pr=$(shipped_pr_for_issue "$number" || true)
    if [ -n "$shipped_pr" ]; then
      shipped_pr_number=${shipped_pr%%|*}
      shipped_pr_url=${shipped_pr#*|}
      shipped_pr_url=${shipped_pr_url%%|*}
      status="shipped_suspect"
      score=$((score - 300))
      signals+=("stale-suspect")
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
        status="shipped_suspect"
        score=$((score - 300))
        signals+=("stale-suspect")
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

  agent_hint=$(agent_hint_for_issue "$title" "$labels" "$body")
  signal_text=$(signals_join "${signals[@]}")

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
    '{issue:$issue,priority:$priority,score:$score,status:$status,agent_hint:$agent_hint,assignees:($assignees|split(",")|map(select(length>0))),deps:($deps|split(",")|map(select(length>0))),blockers:($blockers|split(",")|map(select(length>0))),atomize_tasks:$atomize_tasks,parent:(if $parent == "" then null else ($parent|tonumber) end),signals:($signals|split(",")|map(select(length>0))),title:$title,url:$url}' >> "$json_file"

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
    filtered_rows=$(mktemp)
    filtered_json=$(mktemp)
    while IFS=$'\t' read -r row_num row_rest; do
      [ -n "$row_num" ] || continue
      case ",${PRIORITY_SET}," in
        *",${row_num},"*) printf '%s\t%s\n' "$row_num" "$row_rest" >> "$filtered_rows" ;;
      esac
    done < "$rows_file"
    jq -c --arg set "$PRIORITY_SET" '
      ($set | split(",") | map(tonumber)) as $allow
      | select(.issue as $i | $allow | index($i) != null)
    ' "$json_file" > "$filtered_json"
    mv "$filtered_rows" "$rows_file"
    mv "$filtered_json" "$json_file"
    printf 'priority-set: strict mode — filtering to allowlist regardless of readiness\n' >&2
    summary=""
    while IFS=$'\t' read -r srow_num _ _ srow_status _; do
      [ -n "$srow_num" ] || continue
      summary="$summary #$srow_num=$srow_status"
    done < "$rows_file"
    if [ -z "$summary" ]; then
      printf 'strict-priority-set: allowlist statuses: (no allowlisted tickets are open in this repo)\n' >&2
    else
      printf 'strict-priority-set: allowlist statuses:%s\n' "$summary" >&2
    fi
  else
    any_priority_ready=0
    while IFS=$'\t' read -r prow_num _ _ prow_status _; do
      [ -n "$prow_num" ] || continue
      case ",${PRIORITY_SET}," in
        *",${prow_num},"*)
          if [ "$prow_status" = "ready" ]; then
            any_priority_ready=1
            break
          fi
          ;;
      esac
    done < "$rows_file"

    if [ "$any_priority_ready" -eq 1 ] && [ "$PRIORITY_SET_OVERRIDE" -eq 0 ]; then
      filtered_rows=$(mktemp)
      filtered_json=$(mktemp)
      while IFS=$'\t' read -r row_num row_rest; do
        [ -n "$row_num" ] || continue
        case ",${PRIORITY_SET}," in
          *",${row_num},"*) printf '%s\t%s\n' "$row_num" "$row_rest" >> "$filtered_rows" ;;
        esac
      done < "$rows_file"
      jq -c --arg set "$PRIORITY_SET" '
        ($set | split(",") | map(tonumber)) as $allow
        | select(.issue as $i | $allow | index($i) != null)
      ' "$json_file" > "$filtered_json"
      mv "$filtered_rows" "$rows_file"
      mv "$filtered_json" "$json_file"
      printf 'priority-set: refusing non-allowlisted dispatch (override with --priority-set-override)\n' >&2
    elif [ "$any_priority_ready" -eq 1 ] && [ "$PRIORITY_SET_OVERRIDE" -eq 1 ]; then
      printf 'priority-set: override active — non-allowlisted tickets retained in queue\n' >&2
    else
      printf 'priority-set: no allowlisted ready tickets — queue unchanged (use --strict-priority-set to filter to the allowlist anyway)\n' >&2
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

  while IFS=$'\t' read -r parent_num parent_title parent_url task atomize_kind ship_evidence; do
    : "${atomize_kind:=regular}"
    : "${ship_evidence:=}"
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
  done < "$atomize_file"
fi
