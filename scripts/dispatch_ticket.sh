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

source "$TK/lib/dry_run.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: dispatch_ticket.sh <project> <agent> <ticket#> <prompt-file> [--assign] [--no-validate] [--dry-run]}
AGENT=${2:?missing agent name}
TICKET=${3:?missing ticket number}
PROMPT_FILE=${4:?missing prompt-file path}
shift 4

ASSIGN=0
VALIDATE_PROMPT=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --assign) ASSIGN=1 ;;
    --no-validate) VALIDATE_PROMPT=0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
  shift
done

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
source "$TK/lib/tmux_helpers.sh"
source "$TK/lib/worktree_helpers.sh"

[ -f "$PROMPT_FILE" ] || { echo "prompt file not found: $PROMPT_FILE" >&2; exit 1; }

: "${AGENT_SESSION_PREFIX:=}" "${GH_REPO:?}" "${GH_CONFIG_DIR:?}"

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
else
  audit "DISPATCH VALIDATION BYPASSED agent=${AGENT} ticket=#${TICKET#\#} prompt=$(basename "$PROMPT_FILE")"
fi

PANE_TARGET=$(agent_target "$AGENT")
PANE="${PANE_TARGET%%:*}"  # session name only — what tmux has-session expects
tmux has-session -t "$PANE" 2>/dev/null || {
  echo "tmux pane $PANE_TARGET (session $PANE) not found" >&2
  exit 1
}

# Persist a stable copy alongside the orchestrator state for audit trail.
# Idempotent: if the caller already placed the brief at the staging path, skip
# the copy (cp would error "are the same file" and `set -e` would abort the
# script before any tmux send happens — silent dispatch failure).
TICKET_NUM=${TICKET#\#}
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
    tmux respawn-pane -k -t "$PANE_TARGET" -c "$WORKDIR" "$tmux_cmd"
    sleep 2
  fi
fi

if ! dry_run_enabled; then
  dispatched_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  assignment_file=$(state_file assignments.json)
  assignment_tmp="${assignment_file}.tmp.$$"
  state_get assignments | jq \
    --arg agent "$AGENT" \
    --arg branch "$BRANCH" \
    --arg workdir "$WORKDIR" \
    --arg repo_root "$(agent_repo_root "$AGENT")" \
    --arg prompt_file "$STAGED" \
    --arg dispatched_at "$dispatched_at" \
    --argjson issue "$TICKET_NUM" \
    '.[$agent] = {
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
dry_run_exec "tmux send-keys -t $PANE_TARGET \"$ONELINER\"" tmux send-keys -t "$PANE_TARGET" "$ONELINER"
if ! dry_run_enabled; then
  sleep 0.5
fi
# Submit (Claude Code 2.x: plain Enter; some versions need C-j — we send
# Enter first, then a fallback C-j if the prompt looks unsubmitted).
dry_run_exec "tmux send-keys -t $PANE_TARGET Enter" tmux send-keys -t "$PANE_TARGET" Enter
if ! dry_run_enabled; then
  sleep 1.0
fi

audit "DISPATCH agent=${AGENT} ticket=#${TICKET_NUM} prompt=$(basename "$STAGED")"

# Optional: assign on GitHub. The 5 agent accounts (RBOKCLIclaude/codex/...)
# are standardized; map agent name → gh login.
if [ "$ASSIGN" -eq 1 ]; then
  gh_login="RBOKCLI${AGENT}"
  dry_run_exec "gh issue edit $TICKET_NUM --repo $GH_REPO --add-assignee $gh_login" \
    env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh issue edit "$TICKET_NUM" \
    --repo "$GH_REPO" \
    --add-assignee "$gh_login" 2>&1 | tail -3 || true
  audit "DISPATCH assignee=${gh_login} ticket=#${TICKET_NUM}"
fi
