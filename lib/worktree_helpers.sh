#!/usr/bin/env bash
# worktree_helpers.sh — optional per-ticket git worktree management.
#
# Requires audit_log.sh to be sourced first for PROJECT/state_dir/audit.
# When state_persist.sh is already sourced, cleanup can use assignments.json to
# preserve active worktrees.

: "${DEFAULT_BRANCH:=main}"
: "${USE_WORKTREES:=0}"

_ORCH_WORKTREE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_ORCH_WORKTREE_LIB_DIR/agent_inventory.sh" ]]; then
  # shellcheck source=lib/agent_inventory.sh
  source "$_ORCH_WORKTREE_LIB_DIR/agent_inventory.sh"
fi

worktree_enabled() {
  [[ "${USE_WORKTREES:-0}" == "1" ]]
}

agent_repo_root() {
  local agent=${1:?usage: agent_repo_root <agent>}
  # Universal mode: if AGENT_PANES is set and $agent matches the configured
  # label or the basename of an entry's workdir, return that workdir directly.
  # This lets multi-fleet projects drive dispatch_ticket / recover with
  # explicit labels, without picking one AGENT_WORKDIR_TEMPLATE that could only
  # describe one fleet at a time.
  if declare -F agent_inventory_find >/dev/null 2>&1 \
    && [ -n "${AGENT_PANES+x}" ] \
    && [ "${#AGENT_PANES[@]}" -gt 0 ]; then
    local entry label pane workdir
    entry=$(agent_inventory_find "$agent" 2>/dev/null || true)
    if [[ -n "$entry" ]]; then
      IFS='|' read -r label pane workdir <<< "$entry"
      printf '%s\n' "$workdir"
      return 0
    fi
  fi
  # Legacy fallback
  # shellcheck disable=SC2059
  printf "$AGENT_WORKDIR_TEMPLATE" "$agent"
}

worktree_root_dir() {
  printf '%s\n' "${ORCH_WORKTREES_DIR:-$(state_dir)/worktrees}"
}

worktree_feature_branch() {
  local ticket=${1:?usage: worktree_feature_branch <ticket>}
  ticket=${ticket#\#}
  printf 'feat/issue-%s\n' "$ticket"
}

worktree_path() {
  local agent=${1:?usage: worktree_path <agent> <ticket>}
  local ticket=${2:?usage: worktree_path <agent> <ticket>}
  local branch slug
  branch=$(worktree_feature_branch "$ticket")
  slug=${branch//\//-}
  printf '%s/%s/%s\n' "$(worktree_root_dir)" "$agent" "$slug"
}

agent_assignment_workdir() {
  local agent=${1:?usage: agent_assignment_workdir <agent>}
  if ! declare -F state_get >/dev/null 2>&1; then
    return 0
  fi
  state_get assignments | jq -r --arg agent "$agent" '.[$agent].workdir // ""'
}

agent_effective_workdir() {
  local agent=${1:?usage: agent_effective_workdir <agent>}
  local assigned=''
  if worktree_enabled; then
    assigned=$(agent_assignment_workdir "$agent" 2>/dev/null || true)
  fi

  if [[ -n "$assigned" ]]; then
    printf '%s\n' "$assigned"
    return 0
  fi

  agent_repo_root "$agent"
}

detect_agent_cli() {
  local target=${1:?usage: detect_agent_cli <tmux-target>}
  local body
  body=$(tmux capture-pane -t "$target" -p -S -50 2>/dev/null | tr -d '\r')

  if printf '%s' "$body" | grep -qE 'OpenAI Codex \(v[0-9]|gpt-5\.[0-9]|permissions: YOLO mode'; then
    printf '%s\n' "codex"
  elif printf '%s' "$body" | grep -qE '\? for shortcuts' \
    && printf '%s' "$body" | grep -qE '^❯ ?$|^❯ +$'; then
    printf '%s\n' "claude"
  elif printf '%s' "$body" | grep -qE '1 shell · ↓ to manage|claude --resume'; then
    printf '%s\n' "claude"
  else
    printf '%s\n' "unknown"
  fi
}

agent_known_launch_command() {
  local cli=${1:?usage: agent_known_launch_command <cli>}
  local model="${ORCH_CODEX_MODEL:-gpt-5.5}"
  local sandbox="${ORCH_CODEX_SANDBOX:-danger-full-access}"
  local approval="${ORCH_CODEX_APPROVAL:-never}"
  case "$cli" in
    codex)
      printf '%s\n' "exec codex -m ${model} -s ${sandbox} -a ${approval}"
      ;;
    claude)
      printf '%s\n' "exec claude"
      ;;
    *)
      return 1
      ;;
  esac
}

# Issue #305: per-agent launch contract lookup.
#
# Echoes the configured launch command for <label> on stdout (without the
# leading `exec `, which `agent_launch_command` adds) and returns 0 when a
# match is found. Returns 1 when no contract matches, 2 on usage error.
#
# Contract source: the `AGENT_LAUNCH_CONTRACTS` array, populated by the
# project/portfolio profile, where each entry is `label|launch-command`.
# Example:
#
#   AGENT_LAUNCH_CONTRACTS=(
#     "rbok-claude|claude --name rbok-claude --debug-file /tmp/claude-rbok-claude.log --append-system-prompt /root/.claude/CLAUDE.md"
#   )
#
# This is the universal mechanism for preserving per-agent identity (--name,
# debug log path, posture prompt) across `agent_product_switch` hard mode
# respawns. Without it, the fallback in `agent_known_launch_command` would
# respawn the agent CLI with only the model/effort flags and silently drop
# every per-agent flag set by the original fleet provisioner.
agent_launch_contract() {
  local label=${1:?usage: agent_launch_contract <label>}
  if [ -z "${AGENT_LAUNCH_CONTRACTS+x}" ] || [ "${#AGENT_LAUNCH_CONTRACTS[@]}" -eq 0 ]; then
    return 1
  fi
  local entry entry_label entry_cmd
  for entry in "${AGENT_LAUNCH_CONTRACTS[@]}"; do
    entry_label=${entry%%|*}
    entry_cmd=${entry#*|}
    if [[ "$entry_label" == "$label" ]]; then
      [[ -n "$entry_cmd" && "$entry_cmd" != "$entry" ]] || return 1
      printf '%s\n' "$entry_cmd"
      return 0
    fi
  done
  return 1
}

agent_launch_command() {
  local target=${1:?usage: agent_launch_command <tmux-target> [<label>]}
  local label=${2:-}
  local configured="${AGENT_LAUNCH_COMMAND:-}"
  if [[ -n "$configured" ]]; then
    printf '%s\n' "exec ${configured}"
    return 0
  fi

  if [[ -n "$label" ]]; then
    local contract
    if contract=$(agent_launch_contract "$label"); then
      printf '%s\n' "exec ${contract}"
      return 0
    fi
  fi

  local cli="${ORCH_AGENT_CLI:-preserve}"
  if [[ "$cli" == "preserve" ]]; then
    cli=$(detect_agent_cli "$target")
    if [[ "$cli" == "unknown" ]]; then
      local session_name logical_name
      session_name=${target%%:*}
      logical_name=${session_name##*-}
      case "$logical_name" in
        codex|claude)
          cli=$logical_name
          ;;
      esac
    fi
  fi
  if agent_known_launch_command "$cli"; then
    return 0
  fi

  printf 'agent launch command required: set AGENT_LAUNCH_COMMAND, AGENT_LAUNCH_CONTRACTS, or ORCH_AGENT_CLI for target=%s detected=%s\n' \
    "$target" "$cli" >&2
  return 2
}

# Issue #305: emit, on stdout, the identity tokens that <cmd> is missing for
# the given <cli>. Empty stdout means the launch command preserves agent
# identity. Tokens are CLI-specific:
#
#   claude → --name, --debug-file, --append-system-prompt
#   codex  → --name, --debug-file (model/sandbox/approval are already covered
#            by `agent_known_launch_command`'s -m/-s/-a defaults)
#   other  → no required tokens (returns empty)
#
# This is purely an inspection helper: it does not mutate state and does not
# refuse on its own. The caller (e.g. `agent_product_switch` hard mode) is
# free to warn, gate, or ignore based on the returned tokens.
agent_launch_command_missing_identity_tokens() {
  local cmd=${1:?usage: agent_launch_command_missing_identity_tokens <cmd> <cli>}
  local cli=${2:?usage: agent_launch_command_missing_identity_tokens <cmd> <cli>}
  local required=()
  case "$cli" in
    claude)
      required=(--name --debug-file --append-system-prompt)
      ;;
    codex)
      required=(--name --debug-file)
      ;;
    *)
      return 0
      ;;
  esac
  local token
  for token in "${required[@]}"; do
    case " $cmd " in
      *" $token "*|*" $token="*) ;;
      *) printf '%s\n' "$token" ;;
    esac
  done
}

worktree_create() {
  local agent=${1:?usage: worktree_create <agent> <ticket>}
  local ticket=${2:?usage: worktree_create <agent> <ticket>}
  local repo_root path branch base_ref

  repo_root=$(agent_repo_root "$agent")
  [ -d "$repo_root/.git" ] || {
    printf 'agent repo missing: %s\n' "$repo_root" >&2
    return 1
  }

  if ! worktree_enabled; then
    printf '%s\n' "$repo_root"
    return 0
  fi

  path=$(worktree_path "$agent" "$ticket")
  branch=$(worktree_feature_branch "$ticket")
  base_ref="origin/$DEFAULT_BRANCH"

  if git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s\n' "$path"
    return 0
  fi

  mkdir -p "$(dirname "$path")"
  git -C "$repo_root" fetch --quiet origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
  if ! git -C "$repo_root" worktree add -B "$branch" "$path" "$base_ref" >/dev/null 2>&1; then
    git -C "$repo_root" worktree add -B "$branch" "$path" "$DEFAULT_BRANCH" >/dev/null 2>&1
  fi

  printf '%s\n' "$path"
}

worktree_remove() {
  local path=${1:?usage: worktree_remove <path>}
  local common_dir repo_root root

  [ -e "$path" ] || return 0
  common_dir=$(git -C "$path" rev-parse --git-common-dir 2>/dev/null || true)
  if [[ -n "$common_dir" ]]; then
    repo_root=$(cd "$common_dir/.." && pwd)
    git -C "$repo_root" worktree remove --force "$path" >/dev/null 2>&1 || true
  fi

  if [ -e "$path" ]; then
    root=$(worktree_root_dir)
    case "$path" in
      "$root"/*) rm -rf "$path" ;;
    esac
  fi
}

# Decide whether <path> resolves inside an active git worktree.
#
# Resolution strategy (first match wins):
#   1. explicit second argument — treated as the worktree root verbatim;
#   2. `git rev-parse --show-toplevel` in the current shell, if `git` is
#      available and we are inside a working tree;
#   3. `$PWD` as a last resort — every script ORDO ships starts from the
#      operator's chosen workdir, so this matches the "current worktree"
#      heuristic the visual lane already used.
#
# The candidate path may not exist yet — for write-intent checks, the
# function falls back to its parent directory so a not-yet-created
# evidence file is still classified correctly.
#
# Returns:
#   0 — the path resolves inside the chosen worktree root (in-worktree hit)
#   1 — the path resolves outside the chosen root
#   2 — usage error (missing path)
#
# Pure read-only — no state mutated, no side effects.
worktree_path_is_inside() {
  local candidate=${1:?usage: worktree_path_is_inside <path> [<worktree-root>]}
  local explicit=${2:-}
  local root resolved parent base
  if [[ -n "$explicit" ]]; then
    root=$explicit
  elif command -v git >/dev/null 2>&1 \
    && root=$(git rev-parse --show-toplevel 2>/dev/null) \
    && [[ -n "$root" ]]; then
    :
  else
    root=$PWD
  fi
  if command -v readlink >/dev/null 2>&1; then
    root=$(readlink -f -- "$root" 2>/dev/null || printf '%s' "$root")
  fi
  root=${root%/}
  [[ -n "$root" ]] || root=/
  if [[ -e "$candidate" ]]; then
    resolved=$(readlink -f -- "$candidate" 2>/dev/null || printf '%s' "$candidate")
  else
    parent=$(dirname -- "$candidate")
    if [[ -e "$parent" ]]; then
      base=$(basename -- "$candidate")
      resolved=$(readlink -f -- "$parent" 2>/dev/null || printf '%s' "$parent")
      resolved="$resolved/$base"
    else
      resolved=$candidate
    fi
  fi
  case "$resolved/" in
    "$root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

worktree_cleanup_stale() {
  local root assignments path agent repo_root keep

  worktree_enabled || return 0
  root=$(worktree_root_dir)
  [ -d "$root" ] || return 0

  assignments='{}'
  if declare -F state_get >/dev/null 2>&1; then
    assignments=$(state_get assignments)
  fi

  # Walk every known agent repo to prune stale worktree refs. Universal
  # mode (AGENT_PANES) is preferred when set so SECONDARY fleets aren't
  # leaked. Falls back to the legacy AGENTS array.
  if declare -F agent_inventory_entries >/dev/null 2>&1 \
    && [ -n "${AGENT_PANES+x}" ] \
    && [ "${#AGENT_PANES[@]}" -gt 0 ]; then
    local entry label pane
    while IFS='|' read -r label pane repo_root; do
      if [ -d "$repo_root/.git" ]; then
        git -C "$repo_root" worktree prune --expire now >/dev/null 2>&1 || true
      fi
    done < <(agent_inventory_entries)
  elif declare -p AGENTS >/dev/null 2>&1; then
    for agent in "${AGENTS[@]}"; do
      repo_root=$(agent_repo_root "$agent")
      if [ -d "$repo_root/.git" ]; then
        git -C "$repo_root" worktree prune --expire now >/dev/null 2>&1 || true
      fi
    done
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    keep=$(jq -r --arg path "$path" 'to_entries | map(select(.value.workdir == $path)) | length' <<< "$assignments")
    if [[ "$keep" -eq 0 ]]; then
      worktree_remove "$path"
      audit "WORKTREE CLEANUP removed path=$path"
    fi
  done < <(find "$root" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort)
}
