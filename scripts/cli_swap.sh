#!/usr/bin/env bash
# scripts/cli_swap.sh — swap an agent's CLI tool (graceful exit + relaunch).
#
# Usage: cli_swap.sh <project_short|config_path> <agent> <to_cli> [--model NAME] [--reasoning EFFORT]
#   to_cli: codex | claude | auto
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
TO_CLI=${3:?missing target CLI (codex|claude|auto)}
MODEL_OVERRIDE=""
REASONING_OVERRIDE=""
shift 3
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model)
      MODEL_OVERRIDE="${2:?--model requires a value}"
      shift 2
      ;;
    --reasoning)
      REASONING_OVERRIDE="${2:?--reasoning requires a value}"
      shift 2
      ;;
    *)
      echo "unknown flag: $1" >&2
      exit 2
      ;;
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
source "$TK/lib/tmux_helpers.sh"

: "${AGENT_SESSION_PREFIX:=}" "${AGENT_REPO_PREFIX:=}"

PANE="${AGENT_SESSION_PREFIX}${AGENT}"
PANE_TARGET=$(agent_target "$AGENT")
REPO="${AGENT_REPO_PREFIX}${AGENT}"

tmux has-session -t "$PANE" 2>/dev/null || {
  echo "tmux pane $PANE not found" >&2
  exit 1
}

# Detect current CLI by capturing the pane and looking for tell-tales.
detect_cli() {
  local body
  if tmux list-panes -t "$PANE" 2>/dev/null | grep -q '(dead)'; then
    echo "dead"
    return
  fi

  body=$(tmux capture-pane -t "$PANE" -p -S -50 2>/dev/null | tr -d '\r')
  if printf '%s' "$body" | grep -qE 'OpenAI Codex \(v[0-9]'; then
    echo "codex"
  elif printf '%s' "$body" | grep -qE '\? for shortcuts' \
    && printf '%s' "$body" | grep -qE '^❯ ?$|^❯ +$'; then
    echo "claude"
  elif printf '%s' "$body" | grep -qE '1 shell · ↓ to manage|claude --resume'; then
    echo "claude"
  else
    local last_non_empty
    last_non_empty=$(printf '%s\n' "$body" | awk 'NF { line=$0 } END { print line }')
    if printf '%s' "$last_non_empty" | grep -qE '[#$>] *$|node[0-9].*:~'; then
      echo "shell"
    else
      echo "unknown"
    fi
  fi
}

build_target_cmd() {
  case "$TARGET_CLI" in
    codex)
      local model="${MODEL_OVERRIDE:-gpt-5.5}"
      local cmd="codex -m ${model}"
      if [ -n "$REASONING_OVERRIDE" ]; then
        cmd="${cmd} -c model_reasoning_effort=${REASONING_OVERRIDE}"
      fi
      cmd="${cmd} --dangerously-bypass-approvals-and-sandbox"
      printf '%s' "$cmd"
      ;;
    claude)
      if [ -n "$MODEL_OVERRIDE" ]; then
        printf '%s' "claude --model ${MODEL_OVERRIDE}"
      else
        printf '%s' "claude"
      fi
      ;;
    *)
      echo "unsupported to_cli: $TARGET_CLI (supported: codex|claude)" >&2
      exit 2
      ;;
  esac
}

resolve_auto_target() {
  case "$CURRENT" in
    claude)
      printf '%s' "codex"
      ;;
    codex)
      printf '%s' "claude"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

CURRENT=$(detect_cli)
TARGET_CLI=$TO_CLI

if [ "$TO_CLI" = "auto" ]; then
  TARGET_CLI=$(resolve_auto_target)
  if [ -z "$TARGET_CLI" ]; then
    audit "CLI_SWAP agent=${AGENT} from=${CURRENT} to=auto model=${MODEL_OVERRIDE:-default} status=refused-auto-target"
    echo "refusing auto swap — could not resolve a fallback target from current CLI: $CURRENT" >&2
    exit 6
  fi
fi

if [ "$CURRENT" = "$TARGET_CLI" ]; then
  audit "CLI_SWAP agent=${AGENT} from=${CURRENT} to=${TARGET_CLI} model=${MODEL_OVERRIDE:-default} reasoning=${REASONING_OVERRIDE:-default} status=already-on-target"
  exit 0
fi

if [ "$CURRENT" = "unknown" ]; then
  audit "CLI_SWAP agent=${AGENT} from=unknown to=${TARGET_CLI} model=${MODEL_OVERRIDE:-default} status=refused-undetected"
  echo "refusing to send keystrokes — could not detect current CLI; capture pane and update detect_cli first" >&2
  exit 4
fi

cmd=$(build_target_cmd)

# Step 1: exit current CLI gracefully (both Claude Code and Codex TUI accept /exit).
if [ "$CURRENT" != "shell" ] && [ "$CURRENT" != "dead" ]; then
  tmux send-keys -t "$PANE" "/exit"
  sleep 0.5
  tmux send-keys -t "$PANE" Enter
  # Wait up to 10s for shell prompt or a dead pane to appear.
  new_cli="$CURRENT"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    new_cli=$(detect_cli)
    if [ "$new_cli" = "shell" ] || [ "$new_cli" = "dead" ]; then
      break
    fi
  done
  if [ "$new_cli" != "shell" ] && [ "$new_cli" != "dead" ]; then
    audit "CLI_SWAP agent=${AGENT} from=${CURRENT} to=${TARGET_CLI} model=${MODEL_OVERRIDE:-default} status=refused-post-exit-state-${new_cli}"
    echo "refusing to relaunch — pane did not return to shell after /exit (final=$new_cli)" >&2
    exit 5
  fi
fi

# Step 2: relaunch target CLI in a fresh pane process to avoid stale keystrokes.
tmux respawn-pane -k -t "$PANE_TARGET" "cd ${REPO} && exec ${cmd}"

# Step 3: verify launch (give the CLI 8s to render its prompt).
sleep 8
final=$(detect_cli)
audit "CLI_SWAP agent=${AGENT} from=${CURRENT} to=${TARGET_CLI} model=${MODEL_OVERRIDE:-default} reasoning=${REASONING_OVERRIDE:-default} status=${final}"

if [ "$final" != "$TARGET_CLI" ]; then
  echo "WARN: pane $PANE did not reach $TARGET_CLI prompt (final=$final)" >&2
  exit 3
fi

exit 0
