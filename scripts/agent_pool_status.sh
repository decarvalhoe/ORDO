#!/usr/bin/env bash
# scripts/agent_pool_status.sh — compact, universal status for an agent fleet.
#
# Usage:
#   agent_pool_status.sh <project_short|config_path> [--tsv|--json]
#
# Works with both AGENT_PANES universal fleets and legacy AGENTS configs.
# It avoids pane captures by design; tmux is used only for metadata.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/config_resolver.sh"

CFG_ARG=${1:?usage: agent_pool_status.sh <project> [--tsv|--json]}
FORMAT="tsv"
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tsv) FORMAT="tsv" ;;
    --json) FORMAT="json" ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

load_project_config "$CFG_ARG"
source "$TK/lib/agent_inventory.sh"

: "${DEFAULT_BRANCH:=main}"
: "${AGENT_POOL_GIT_TIMEOUT_SEC:=5}"
: "${AGENT_POOL_TMUX_TIMEOUT_SEC:=3}"
: "${AGENT_POOL_PR_LIMIT:=100}"
: "${AGENT_POOL_FETCH:=0}"

run_timeout() {
  local seconds=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

git_value() {
  local repo=$1
  shift
  run_timeout "$AGENT_POOL_GIT_TIMEOUT_SEC" git -C "$repo" "$@" 2>/dev/null || true
}

git_quiet() {
  local repo=$1
  shift
  run_timeout "$AGENT_POOL_GIT_TIMEOUT_SEC" git -C "$repo" "$@" >/dev/null 2>&1
}

pane_value() {
  local pane=$1 format=$2
  run_timeout "$AGENT_POOL_TMUX_TIMEOUT_SEC" tmux display-message -p -t "$pane" "$format" 2>/dev/null || true
}

prs_json="[]"
if [ -n "${GH_REPO:-}" ] && command -v gh >/dev/null 2>&1; then
  prs_json=$(GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" gh pr list \
    --repo "$GH_REPO" \
    --base "$DEFAULT_BRANCH" \
    --state open \
    --limit "$AGENT_POOL_PR_LIMIT" \
    --json number,headRefName,headRefOid,mergeStateStatus,isDraft,updatedAt,title 2>/dev/null || printf '[]')
fi

json_items=()
if [ "$FORMAT" = "tsv" ]; then
  printf 'label\tpane\talive\tcommand\tworkdir\tbranch\thead\tupstream\tahead\tbehind\tdirty\tbase_current\tpr\tpr_state\tpr_sha\tsignals\n'
fi

while IFS='|' read -r label pane workdir; do
  [ -n "$label$pane$workdir" ] || continue

  alive=0
  command=""
  if run_timeout "$AGENT_POOL_TMUX_TIMEOUT_SEC" tmux has-session -t "${pane%%:*}" >/dev/null 2>&1; then
    alive=1
    command=$(pane_value "$pane" '#{pane_current_command}')
  fi

  branch=""
  head=""
  upstream=""
  ahead=""
  behind=""
  dirty=""
  base_current=""
  signals=()
  if [ -d "$workdir/.git" ]; then
    if [ "$AGENT_POOL_FETCH" = "1" ]; then
      git_quiet "$workdir" fetch origin "$DEFAULT_BRANCH" || true
    fi
    branch=$(git_value "$workdir" branch --show-current)
    head=$(git_value "$workdir" rev-parse --short HEAD)
    upstream=$(git_value "$workdir" rev-parse --abbrev-ref --symbolic-full-name '@{u}')
    dirty=$(git_value "$workdir" status --porcelain | wc -l | tr -d ' ')
    [ "${dirty:-0}" != "0" ] && signals+=("dirty")
    if [ -n "$upstream" ]; then
      counts=$(git_value "$workdir" rev-list --left-right --count "$upstream...HEAD")
      behind=${counts%%[[:space:]]*}
      ahead=${counts##*[[:space:]]}
      [ "${behind:-0}" != "0" ] && signals+=("behind-upstream")
    fi
    if [ -n "$branch" ] && [ "$branch" != "$DEFAULT_BRANCH" ]; then
      base_ref="origin/$DEFAULT_BRANCH"
      if git_quiet "$workdir" rev-parse --verify "$base_ref"; then
        if git_quiet "$workdir" merge-base --is-ancestor "$base_ref" HEAD; then
          base_current=1
        else
          base_current=0
          signals+=("needs-rebase")
        fi
      fi
    fi
  fi

  pr_json=$(printf '%s' "$prs_json" | jq -c --arg branch "$branch" '
    map(select(.headRefName == $branch)) | first // {}
  ')
  pr=$(printf '%s' "$pr_json" | jq -r '.number // ""')
  pr_state=$(printf '%s' "$pr_json" | jq -r '.mergeStateStatus // ""')
  pr_sha=$(printf '%s' "$pr_json" | jq -r '(.headRefOid // "")[0:8]')
  case "$pr_state" in
    BEHIND) signals+=("pr-behind") ;;
    DIRTY) signals+=("conflict") ;;
  esac
  signal_text=$(IFS=,; printf '%s' "${signals[*]}")

  if [ "$FORMAT" = "json" ]; then
    json_items+=("$(jq -nc \
      --arg label "$label" \
      --arg pane "$pane" \
      --argjson alive "$alive" \
      --arg command "$command" \
      --arg workdir "$workdir" \
      --arg branch "$branch" \
      --arg head "$head" \
      --arg upstream "$upstream" \
      --arg ahead "$ahead" \
      --arg behind "$behind" \
      --arg dirty "$dirty" \
      --arg base_current "$base_current" \
      --arg pr "$pr" \
      --arg pr_state "$pr_state" \
      --arg pr_sha "$pr_sha" \
      --arg signals "$signal_text" \
      '{label:$label,pane:$pane,alive:$alive,command:$command,workdir:$workdir,branch:$branch,head:$head,upstream:$upstream,ahead:$ahead,behind:$behind,dirty:$dirty,base_current:$base_current,pr:$pr,pr_state:$pr_state,pr_sha:$pr_sha,signals:($signals | split(",") | map(select(length > 0)))}')")
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$label" "$pane" "$alive" "$command" "$workdir" "$branch" "$head" \
      "$upstream" "$ahead" "$behind" "$dirty" "$base_current" "$pr" \
      "$pr_state" "$pr_sha" "$signal_text"
  fi
done < <(agent_inventory_entries)

if [ "$FORMAT" = "json" ]; then
  printf '%s\n' "${json_items[@]}" | jq -s '.'
fi
