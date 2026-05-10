#!/usr/bin/env bash
# scripts/audit_state.sh — snapshot of agents + branches + open PRs + backlog.
# Usage: audit_state.sh <project_short|config_path>
#
# Surviving log signature:
#   AUDIT START project=<id>
#   AUDIT END project=<id> backlog=<ready-count> backlog_source=dispatch_plan_ready
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TK/lib/config_resolver.sh"
source "$TK/lib/agent_inventory.sh"
source "$TK/lib/process_safety.sh"
source "$TK/lib/ready_queue.sh"

CFG_ARG=${1:?usage: audit_state.sh <project_short|config_path>}
load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"
source "$TK/lib/state_persist.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${AGENT_SESSION_PREFIX:=}" "${AGENT_WINDOW_INDEX:=0}" "${DEFAULT_BRANCH:=main}"
: "${AUDIT_GIT_TIMEOUT_SEC:=5}"
: "${AUDIT_TMUX_TIMEOUT_SEC:=3}"
: "${AUDIT_GH_TIMEOUT_SEC:=5}"
: "${AUDIT_READY_QUEUE_TIMEOUT_SEC:=30}"

# Resolve the fleet to a unified (label, pane, workdir) triple list.
# Two input forms supported, AGENT_PANES takes precedence (universal mode):
#   AGENT_PANES=("builder|terminal-b:0.0|/workspace/product-builder" ...)
# Fallback (legacy single-fleet):
#   AGENTS=(planner builder ...) + AGENT_SESSION_PREFIX + AGENT_REPO_PREFIX + AGENT_WINDOW_INDEX
declare -a UNIT_LABELS=()
declare -a UNIT_PANES=()
declare -a UNIT_WORKDIRS=()
if [ -n "${AGENT_PANES+x}" ] && [ "${#AGENT_PANES[@]}" -gt 0 ]; then
  while IFS='|' read -r label pane workdir; do
    UNIT_LABELS+=("$label")
    UNIT_PANES+=("$pane")
    UNIT_WORKDIRS+=("$workdir")
  done < <(agent_inventory_entries)
else
  : "${AGENT_REPO_PREFIX:?need AGENT_PANES (universal) or AGENT_REPO_PREFIX (legacy)}"
  for a in "${AGENTS[@]}"; do
    UNIT_LABELS+=("$a")
    UNIT_PANES+=("${AGENT_SESSION_PREFIX}${a}:${AGENT_WINDOW_INDEX}.0")
    UNIT_WORKDIRS+=("${AGENT_REPO_PREFIX}${a}")
  done
fi

CONFIG_PATH_DISPLAY=${ORCH_CONFIG_PATH:-unknown}
audit "AUDIT START project=$PROJECT config=$CONFIG_PATH_DISPLAY agents=${#UNIT_LABELS[@]}"

print_section() { printf '\n=== %s ===\n' "$1"; }

# 0. Loaded config — visible in stdout so live audit captures cannot hide a
# short-name/sample-profile mismatch.
print_section "config"
printf '  project:        %s\n' "$PROJECT"
printf '  config:         %s\n' "$CONFIG_PATH_DISPLAY"

# 1. Agent repos — git state per clone (branch, dirty, head, ahead).
print_section "agents (git state)"
for i in "${!UNIT_LABELS[@]}"; do
  label=${UNIT_LABELS[$i]}
  d=${UNIT_WORKDIRS[$i]}
  if [ -d "$d/.git" ]; then
    branch=$(orch_run_timeout "$AUDIT_GIT_TIMEOUT_SEC" git -C "$d" branch --show-current 2>/dev/null || echo "(detached)")
    head=$(orch_run_timeout "$AUDIT_GIT_TIMEOUT_SEC" git -C "$d" log -1 --format='%h %s' 2>/dev/null | head -c 80)
    dirty=$(orch_run_timeout "$AUDIT_GIT_TIMEOUT_SEC" git -C "$d" status --porcelain 2>/dev/null | wc -l)
    if [ "$branch" != "$DEFAULT_BRANCH" ] && [ -n "$branch" ]; then
      ahead=$(orch_run_timeout "$AUDIT_GIT_TIMEOUT_SEC" git -C "$d" rev-list --count "${DEFAULT_BRANCH}..${branch}" 2>/dev/null || echo "?")
    else
      ahead="-"
    fi
    printf '  %-22s branch=%-45s dirty=%-3s ahead=%-3s | %s\n' "$label" "$branch" "$dirty" "$ahead" "$head"
  else
    printf '  %-22s repo MISSING at %s\n' "$label" "$d"
  fi
done

# 2. Tmux pane activity hint (last non-empty line).
print_section "tmux panes (last activity line)"
if ! orch_tmux_probe; then
  printf '  tmux_degraded: %s\n' "${ORCH_TMUX_DEGRADED_REASON:-tmux probe failed}"
else
  for i in "${!UNIT_PANES[@]}"; do
    pane=${UNIT_PANES[$i]}
    # tmux has-session matches by session name only — strip pane suffix for the test.
    if orch_run_timeout "$AUDIT_TMUX_TIMEOUT_SEC" tmux has-session -t "${pane%%:*}" 2>/dev/null; then
      last=$(orch_run_timeout "$AUDIT_TMUX_TIMEOUT_SEC" tmux capture-pane -t "$pane" -p 2>/dev/null | grep -v '^$' | tail -1 | head -c 80)
      printf '  %-22s | %s\n' "$pane" "$last"
    else
      printf '  %-22s | NOT FOUND\n' "$pane"
    fi
  done
fi

# 3. Open PRs on the project repo.
print_section "open PRs"
pr_json=$(orch_run_timeout "$AUDIT_GH_TIMEOUT_SEC" env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr list \
  --repo "$GH_REPO" \
  --state open \
  --json number,title,headRefName,mergeStateStatus,author \
  --limit 20 2>/dev/null || printf '[]')
printf '%s\n' "$pr_json" \
  | python3 -c "import sys,json; data=json.loads(sys.stdin.read() or '[]'); [print(f'  #{d[\"number\"]:5} [{d[\"mergeStateStatus\"]:10}] {d[\"author\"][\"login\"]:20} {d[\"headRefName\"]:50} {d[\"title\"]}') for d in data] or print('  (none)')"

# 4. Recent CI runs on the default branch.
print_section "CI on $DEFAULT_BRANCH"
ci_json=$(orch_run_timeout "$AUDIT_GH_TIMEOUT_SEC" env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh run list \
  --repo "$GH_REPO" \
  --branch "$DEFAULT_BRANCH" \
  --limit 5 \
  --json status,conclusion,name,headSha 2>/dev/null || printf '[]')
printf '%s\n' "$ci_json" \
  | python3 -c "import sys,json; data=json.loads(sys.stdin.read() or '[]'); [print(f'  {d[\"name\"]:35} {d[\"status\"]:11} {str(d[\"conclusion\"]):8} {d[\"headSha\"][:8]}') for d in data] or print('  (none)')"

# 5. Backlog count from the same ready queue used for dispatch.
print_section "backlog"
ready_queue_err=$(mktemp)
backlog_source="dispatch_plan_ready"
if backlog=$(ORDO_READY_QUEUE_TIMEOUT_SEC="$AUDIT_READY_QUEUE_TIMEOUT_SEC" \
    ordo_ready_queue_count "$CFG_ARG" 2>"$ready_queue_err"); then
  printf '  dispatch_plan --ready-only ready issues = %s\n' "$backlog"
else
  backlog=0
  backlog_source="dispatch_plan_ready_unavailable"
  ready_queue_reason=$(tr '\n' ' ' < "$ready_queue_err" | head -c 160)
  printf '  dispatch_plan --ready-only ready issues = unavailable'
  if [ -n "$ready_queue_reason" ]; then
    printf ' (%s)' "$ready_queue_reason"
  fi
  printf '\n'
fi
rm -f "$ready_queue_err"

audit "AUDIT END project=$PROJECT backlog=$backlog backlog_source=$backlog_source"
