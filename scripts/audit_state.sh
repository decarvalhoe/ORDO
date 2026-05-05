#!/usr/bin/env bash
# scripts/audit_state.sh — snapshot of agents + branches + open PRs + backlog.
# Usage: audit_state.sh <project_short|config_path>
#
# Surviving log signature:
#   AUDIT START project=<id>
#   AUDIT END project=<id> backlog=<count>
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TK/lib/config_resolver.sh"
source "$TK/lib/agent_inventory.sh"

CFG_ARG=${1:?usage: audit_state.sh <project_short|config_path>}
load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"
source "$TK/lib/state_persist.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${AGENT_SESSION_PREFIX:=}" "${AGENT_WINDOW_INDEX:=0}" "${DEFAULT_BRANCH:=main}"

# Resolve the fleet to a unified (label, pane, workdir) triple list.
# Two input forms supported, AGENT_PANES takes precedence (universal mode):
#   AGENT_PANES=("rbok-claude:0.0|/root/repos/RBOK-claude" ...)
# Fallback (legacy single-fleet):
#   AGENTS=(claude codex ...) + AGENT_SESSION_PREFIX + AGENT_REPO_PREFIX + AGENT_WINDOW_INDEX
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

audit "AUDIT START project=$PROJECT agents=${#UNIT_LABELS[@]}"

print_section() { printf '\n=== %s ===\n' "$1"; }

# 1. Agent repos — git state per clone (branch, dirty, head, ahead).
print_section "agents (git state)"
for i in "${!UNIT_LABELS[@]}"; do
  label=${UNIT_LABELS[$i]}
  d=${UNIT_WORKDIRS[$i]}
  if [ -d "$d/.git" ]; then
    branch=$(git -C "$d" branch --show-current 2>/dev/null || echo "(detached)")
    head=$(git -C "$d" log -1 --format='%h %s' 2>/dev/null | head -c 80)
    dirty=$(git -C "$d" status --porcelain 2>/dev/null | wc -l)
    if [ "$branch" != "$DEFAULT_BRANCH" ] && [ -n "$branch" ]; then
      ahead=$(git -C "$d" rev-list --count "${DEFAULT_BRANCH}..${branch}" 2>/dev/null || echo "?")
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
for i in "${!UNIT_PANES[@]}"; do
  pane=${UNIT_PANES[$i]}
  # tmux has-session matches by session name only — strip pane suffix for the test.
  if tmux has-session -t "${pane%%:*}" 2>/dev/null; then
    last=$(tmux capture-pane -t "$pane" -p 2>/dev/null | grep -v '^$' | tail -1 | head -c 80)
    printf '  %-22s | %s\n' "$pane" "$last"
  else
    printf '  %-22s | NOT FOUND\n' "$pane"
  fi
done

# 3. Open PRs on the project repo.
print_section "open PRs"
GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr list \
  --repo "$GH_REPO" \
  --state open \
  --json number,title,headRefName,mergeStateStatus,author \
  --limit 20 2>/dev/null \
  | python3 -c "import sys,json; data=json.loads(sys.stdin.read() or '[]'); [print(f'  #{d[\"number\"]:5} [{d[\"mergeStateStatus\"]:10}] {d[\"author\"][\"login\"]:20} {d[\"headRefName\"]:50} {d[\"title\"]}') for d in data] or print('  (none)')"

# 4. Recent CI runs on the default branch.
print_section "CI on $DEFAULT_BRANCH"
GH_CONFIG_DIR="$GH_CONFIG_DIR" gh run list \
  --repo "$GH_REPO" \
  --branch "$DEFAULT_BRANCH" \
  --limit 5 \
  --json status,conclusion,name,headSha 2>/dev/null \
  | python3 -c "import sys,json; data=json.loads(sys.stdin.read() or '[]'); [print(f'  {d[\"name\"]:35} {d[\"status\"]:11} {str(d[\"conclusion\"]):8} {d[\"headSha\"][:8]}') for d in data] or print('  (none)')"

# 5. Backlog count (issues labeled type:backlog).
print_section "backlog"
backlog=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh issue list \
  --repo "$GH_REPO" \
  --state open \
  --label type:backlog \
  --json number 2>/dev/null \
  | python3 -c "import sys,json; print(len(json.loads(sys.stdin.read() or '[]')))" 2>/dev/null \
  || echo 0)
printf '  open type:backlog issues = %s\n' "$backlog"

audit "AUDIT END project=$PROJECT backlog=$backlog"
