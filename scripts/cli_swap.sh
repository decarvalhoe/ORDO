#!/usr/bin/env bash
# scripts/cli_swap.sh — swap an agent's CLI tool (graceful exit + relaunch).
#
# Usage: cli_swap.sh <project_short|config_path> <agent> <to_cli> [--model NAME] [--reasoning EFFORT]
#   to_cli: codex | claude
#   --model: optional model override (e.g. "gpt-5.5", "opus-4-7")
#   --reasoning: optional reasoning effort for codex CLI (low|medium|high|xhigh)
#                Sets `model_reasoning_effort` via `-c` override.
#                Ignored for claude.
#
# Use case: an agent CLI hits its rate limit / forfait / quota. The orchestrator
# cascades to the next-best CLI on the same pane, preserving the agent's git
# identity and repo path (only the CLI tool changes).
#
# Surviving log signature:
#   CLI_SWAP agent=<name> from=<auto> to=<to_cli> model=<model>
#
# The script is idempotent: if the pane is already on the target CLI, it
# detects via prompt fingerprint and exits 0 without re-launching.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

CFG_ARG=${1:?usage: cli_swap.sh <project> <agent> <to_cli> [--model NAME] [--reasoning EFFORT]}
AGENT=${2:?missing agent name}
TO_CLI=${3:?missing target CLI (codex|claude)}
MODEL_OVERRIDE=""
REASONING_OVERRIDE=""
shift 3
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)     MODEL_OVERRIDE="${2:?--model requires a value}"; shift 2 ;;
    --reasoning) REASONING_OVERRIDE="${2:?--reasoning requires a value}"; shift 2 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
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

: "${AGENT_SESSION_PREFIX:=}" "${AGENT_REPO_PREFIX:=}"

PANE="${AGENT_SESSION_PREFIX}${AGENT}"
REPO="${AGENT_REPO_PREFIX}${AGENT}"

tmux has-session -t "$PANE" 2>/dev/null || {
  echo "tmux pane $PANE not found" >&2
  exit 1
}

# Detect current CLI by capturing the pane and looking for tell-tales.
detect_cli() {
  local body
  body=$(tmux capture-pane -t "$PANE" -p -S -25 2>/dev/null | tr '\n' ' ')
  if echo "$body" | grep -qE "OpenAI Codex \(v[0-9]"; then
    echo "codex"
  elif echo "$body" | grep -qE "1 shell · ↓ to manage|claude --resume"; then
    echo "claude"
  elif echo "$body" | grep -qE "^.*[#$] *$|node[0-9].*:~"; then
    echo "shell"
  else
    echo "unknown"
  fi
}

CURRENT=$(detect_cli)

if [ "$CURRENT" = "$TO_CLI" ]; then
  audit "CLI_SWAP agent=${AGENT} from=${CURRENT} to=${TO_CLI} model=${MODEL_OVERRIDE:-default} reasoning=${REASONING_OVERRIDE:-default} status=already-on-target"
  exit 0
fi

# Step 1: exit current CLI gracefully (both Claude Code and Codex TUI accept /exit).
if [ "$CURRENT" != "shell" ] && [ "$CURRENT" != "unknown" ]; then
  tmux send-keys -t "$PANE" "/exit"
  sleep 0.5
  tmux send-keys -t "$PANE" Enter
  # Wait up to 10s for shell prompt to return.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    new_cli=$(detect_cli)
    [ "$new_cli" = "shell" ] && break
  done
fi

# Step 2: ensure shell ready in the right cwd (some CLIs change cwd).
tmux send-keys -t "$PANE" "cd ${REPO}"
sleep 0.3
tmux send-keys -t "$PANE" Enter
sleep 0.5

# Step 3: launch target CLI.
case "$TO_CLI" in
  codex)
    model="${MODEL_OVERRIDE:-gpt-5.5}"
    cmd="codex -m ${model}"
    if [ -n "$REASONING_OVERRIDE" ]; then
      cmd+=" -c model_reasoning_effort=${REASONING_OVERRIDE}"
    fi
    cmd+=" --dangerously-bypass-approvals-and-sandbox"
    ;;
  claude)
    # Claude Code uses the latest configured model by default (Opus is highest).
    # If MODEL_OVERRIDE is set, pass via --model.
    if [ -n "$MODEL_OVERRIDE" ]; then
      cmd="claude --model ${MODEL_OVERRIDE}"
    else
      cmd="claude"
    fi
    ;;
  *)
    echo "unsupported to_cli: $TO_CLI (supported: codex|claude)" >&2
    exit 2
    ;;
esac

tmux send-keys -t "$PANE" "$cmd"
sleep 0.3
tmux send-keys -t "$PANE" Enter

# Step 4: verify launch (give the CLI 8s to render its prompt).
sleep 8
final=$(detect_cli)
audit "CLI_SWAP agent=${AGENT} from=${CURRENT} to=${TO_CLI} model=${MODEL_OVERRIDE:-default} reasoning=${REASONING_OVERRIDE:-default} status=${final}"

if [ "$final" != "$TO_CLI" ]; then
  echo "WARN: pane $PANE did not reach $TO_CLI prompt (final=$final)" >&2
  exit 3
fi

exit 0
