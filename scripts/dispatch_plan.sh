#!/usr/bin/env bash
# scripts/dispatch_plan.sh - priority/dependency plan for issue dispatch.
#
# Usage:
#   dispatch_plan.sh <project_short|config_path> [--tsv|--json] [--ready-only]
#   dispatch_plan.sh <project_short|config_path> --atomize [--dry-run]
#
# The planner is deliberately model-agnostic. It reads GitHub issues, infers
# dependencies from issue text, ranks dispatch candidates, and can split large
# checklist-driven parent issues into child issues while carrying parent scope.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/config_resolver.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: dispatch_plan.sh <project> [--tsv|--json] [--ready-only] [--atomize] [--dry-run]}
FORMAT="tsv"
READY_ONLY=0
ATOMIZE=0
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tsv) FORMAT="tsv" ;;
    --json) FORMAT="json" ;;
    --ready-only) READY_ONLY=1 ;;
    --atomize) ATOMIZE=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

load_project_config "$CFG_ARG"
source "$TK/lib/audit_log.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}"
: "${DISPATCH_PLAN_LIMIT:=100}"
: "${DISPATCH_PLAN_ATOMIZE_MIN_TASKS:=3}"
: "${DISPATCH_PLAN_PARENT_CONTEXT_CHARS:=3500}"

run_gh() {
  GH_CONFIG_DIR="$GH_CONFIG_DIR" gh "$@"
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

parent_from_body() {
  local body=$1
  { printf '%s\n' "$body" \
    | grep -Ei '(^|[[:space:]])(parent|epic|child of):' \
    | issue_numbers_from_text \
    | awk -F, '{print $1}'; } || true
}

checkbox_tasks() {
  local body=$1
  { printf '%s\n' "$body" \
    | grep -E '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\][[:space:]]+' \
    | grep -Ev '#[0-9]+' \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\][[:space:]]+//'; } || true
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
  local label labels
  local -a label_array=()
  labels=${DISPATCH_PLAN_ATOMIZE_LABELS:-ordo:atomized,ordo:child}
  [ -n "$labels" ] || return 0
  IFS=, read -r -a label_array <<< "$labels"
  for label in "${label_array[@]}"; do
    [ -n "$label" ] || continue
    run_gh issue edit "$issue_number" --repo "$GH_REPO" --add-label "$label" >/dev/null 2>&1 || true
  done
}

issues_json=$(run_gh issue list \
  --repo "$GH_REPO" \
  --state open \
  --limit "$DISPATCH_PLAN_LIMIT" \
  --json number,title,labels,assignees,body,updatedAt,url)

open_numbers=$(printf '%s' "$issues_json" | jq -r '.[].number')
rows_file=$(mktemp)
json_file=$(mktemp)
atomize_file=$(mktemp)
cleanup() {
  rm -f "$rows_file" "$json_file" "$atomize_file"
}
trap cleanup EXIT

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
  parent=$(parent_from_body "$body")
  tasks=$(checkbox_tasks "$body")
  task_count=$(printf '%s\n' "$tasks" | sed '/^$/d' | wc -l | tr -d ' ')

  labels_lower=${labels,,}
  title_lower=${title,,}
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
  blocker_text=$(signals_join "${blockers[@]}")

  status="ready"
  signals=()
  signals+=("priority:${priority}")
  [ -n "$parent" ] && signals+=("parent:#${parent}")
  [ -n "$deps" ] && signals+=("has-deps")
  if [ "${#blockers[@]}" -gt 0 ]; then
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
  [ "$assignee_count" -eq 0 ] && signals+=("unassigned")

  agent_hint=$(agent_hint_for_issue "$title" "$labels" "$body")
  signal_text=$(signals_join "${signals[@]}")

  if [ "$READY_ONLY" -eq 1 ] && [ "$status" != "ready" ]; then
    continue
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
    while IFS= read -r task; do
      [ -n "$task" ] || continue
      printf '%s\t%s\t%s\t%s\n' "$number" "$title" "$url" "$task" >> "$atomize_file"
    done <<< "$tasks"
  fi
done < <(printf '%s' "$issues_json" | jq -r '.[] | @base64')

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

  while IFS=$'\t' read -r parent_num parent_title parent_url task; do
    child_title="[parent #${parent_num}] ${task}"
    parent_body=$(printf '%s' "$issues_json" | jq -r --argjson n "$parent_num" '.[] | select(.number == $n) | .body // ""')
    context=$(truncate_context "$parent_body")
    fingerprint=$(fingerprint_text "${GH_REPO}|${parent_num}|${task}")
    trace_id="ORDO-ATOMIZE:${fingerprint}"
    existing_child=$(atomize_existing_child "$fingerprint" || true)
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
      printf -- "- Generated by: \`dispatch_plan --atomize\`\n"
      printf -- '- Scope policy: this child inherits parent requirements; parent remains the source of truth.\n\n'
      printf '## Child Objective\n\n%s\n\n' "$task"
      printf '## Scope Inherited From Parent\n\n'
      printf '%s\n\n' "$context"
      printf '## Constraints\n\n'
      printf -- '- Stay inside the parent issue scope and requirements.\n'
      printf -- '- Do not close or shrink parent requirements from this child.\n'
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
      run_gh issue comment "$parent_num" --repo "$GH_REPO" \
        --body "Atomized child created: ${created_url}

Trace: ${trace_id}" >/dev/null 2>&1 || true
    fi
    rm -f "$body_file"
  done < "$atomize_file"
fi
