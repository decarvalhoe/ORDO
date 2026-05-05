#!/usr/bin/env bash
# scripts/audit_state.sh — snapshot of agents + branches + open PRs + backlog.
# Usage: audit_state.sh <project_short|config_path>
#
# Surviving log signature:
#   AUDIT START project=<id>
#   AUDIT END project=<id> backlog=<count>
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

CFG_ARG=${1:?usage: audit_state.sh <project_short|config_path>}
case "$CFG_ARG" in
  wp|realisons-wp)   CFG="$TK/examples/realisons-wp.config.sh" ;;
  nomos)             CFG="$TK/examples/nomos.config.sh" ;;
  rbok)              CFG="$TK/examples/rbok.config.sh" ;;
  42t|42-training)   CFG="$TK/examples/42t.config.sh" ;;
  *)                 CFG="$CFG_ARG" ;;
esac
[ -f "$CFG" ] || { echo "config not found: $CFG" >&2; exit 1; }
source "$CFG"

source "$TK/lib/audit_log.sh"
source "$TK/lib/state_persist.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}" "${AGENT_SESSION_PREFIX:=}" "${DEFAULT_BRANCH:=main}"

audit "AUDIT START project=$PROJECT"

print_section() { printf '\n=== %s ===\n' "$1"; }

# 1. Agent panes — git state per clone + tmux activity hint.
print_section "agents"
for a in "${AGENTS[@]}"; do
  d="${AGENT_REPO_PREFIX:-}${a}"
  if [ -d "$d/.git" ]; then
    branch=$(git -C "$d" branch --show-current 2>/dev/null || echo "(detached)")
    head=$(git -C "$d" log -1 --format='%h %s' 2>/dev/null | head -c 80)
    dirty=$(git -C "$d" status --porcelain 2>/dev/null | wc -l)
    printf '  %-10s branch=%s dirty=%s | %s\n' "$a" "$branch" "$dirty" "$head"
  else
    printf '  %-10s repo MISSING at %s\n' "$a" "$d"
  fi
done

# 2. Tmux pane idle/busy hint.
print_section "tmux panes"
for a in "${AGENTS[@]}"; do
  pane="${AGENT_SESSION_PREFIX}${a}"
  if tmux has-session -t "$pane" 2>/dev/null; then
    last=$(tmux capture-pane -t "$pane" -p 2>/dev/null | grep -v '^$' | tail -1 | head -c 80)
    printf '  %-25s | %s\n' "$pane" "$last"
  else
    printf '  %-25s | NOT FOUND\n' "$pane"
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
