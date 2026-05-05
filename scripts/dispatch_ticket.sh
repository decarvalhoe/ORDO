#!/usr/bin/env bash
# scripts/dispatch_ticket.sh — send a prepared dispatch markdown to an agent.
# Usage: dispatch_ticket.sh <project_short|config_path> <agent> <ticket_number> <prompt_file>
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

CFG_ARG=${1:?usage: dispatch_ticket.sh <project> <agent> <ticket#> <prompt-file>}
AGENT=${2:?missing agent name}
TICKET=${3:?missing ticket number}
PROMPT_FILE=${4:?missing prompt-file path}
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

[ -f "$PROMPT_FILE" ] || { echo "prompt file not found: $PROMPT_FILE" >&2; exit 1; }

: "${AGENT_SESSION_PREFIX:=}" "${GH_REPO:?}" "${GH_CONFIG_DIR:?}"

PANE="${AGENT_SESSION_PREFIX}${AGENT}"
tmux has-session -t "$PANE" 2>/dev/null || {
  echo "tmux pane $PANE not found" >&2
  exit 1
}

# Persist a stable copy alongside the orchestrator state for audit trail.
# Idempotent: if the caller already placed the brief at the staging path, skip
# the copy (cp would error "are the same file" and `set -e` would abort the
# script before any tmux send happens — silent dispatch failure).
TICKET_NUM=${TICKET#\#}
STAGED="/tmp/dispatch-${AGENT}-${TICKET_NUM}.md"
if [ "$(readlink -f "$PROMPT_FILE")" != "$(readlink -f "$STAGED" 2>/dev/null)" ]; then
  cp "$PROMPT_FILE" "$STAGED"
fi

# Build the one-liner the agent reads. Multi-line tmux paste-buffer
# would also work, but a one-liner is safer across Claude Code versions.
ONELINER="Read $STAGED and execute it end-to-end. Stay strictly in scope. Verify your git identity matches the agent name before commit. Report final status."

# Send via send-keys (multi-line text already inside the file referenced).
tmux send-keys -t "$PANE" "$ONELINER"
sleep 0.5
# Submit (Claude Code 2.x: plain Enter; some versions need C-j — we send
# Enter first, then a fallback C-j if the prompt looks unsubmitted).
tmux send-keys -t "$PANE" Enter
sleep 1.0

audit "DISPATCH agent=${AGENT} ticket=#${TICKET_NUM} prompt=$(basename "$STAGED")"

# Optional: assign on GitHub. The 5 agent accounts (RBOKCLIclaude/codex/...)
# are standardized; map agent name → gh login.
if [ "${5:-}" = "--assign" ]; then
  gh_login="RBOKCLI${AGENT}"
  GH_CONFIG_DIR="$GH_CONFIG_DIR" gh issue edit "$TICKET_NUM" \
    --repo "$GH_REPO" \
    --add-assignee "$gh_login" 2>&1 | tail -3 || true
  audit "DISPATCH assignee=${gh_login} ticket=#${TICKET_NUM}"
fi
