#!/usr/bin/env bash
# worktree_helpers.sh — optional per-ticket git worktree management.
#
# Requires audit_log.sh to be sourced first for PROJECT/state_dir/audit.
# When state_persist.sh is already sourced, cleanup can use assignments.json to
# preserve active worktrees.

: "${DEFAULT_BRANCH:=main}"
: "${USE_WORKTREES:=0}"

worktree_enabled() {
  [[ "${USE_WORKTREES:-0}" == "1" ]]
}

agent_repo_root() {
  local agent=${1:?usage: agent_repo_root <agent>}
  # Universal mode: if AGENT_PANES is set and $agent matches the basename
  # of an entry's workdir, return that workdir directly. Lets multi-fleet
  # projects (e.g. RBOK with PRIMARY rbok-* and SECONDARY no-prefix) drive
  # dispatch_ticket / recover with explicit labels, without picking one
  # AGENT_WORKDIR_TEMPLATE that could only describe one fleet at a time.
  if [ -n "${AGENT_PANES+x}" ] && [ "${#AGENT_PANES[@]}" -gt 0 ]; then
    local entry workdir
    for entry in "${AGENT_PANES[@]}"; do
      workdir=${entry##*|}
      if [ "$agent" = "$(basename "$workdir")" ]; then
        printf '%s\n' "$workdir"
        return 0
      fi
    done
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

  if printf '%s' "$body" | grep -qE 'OpenAI Codex \(v[0-9]'; then
    printf '%s\n' "codex"
  elif printf '%s' "$body" | grep -qE '\? for shortcuts' \
    && printf '%s' "$body" | grep -qE '^❯ ?$|^❯ +$'; then
    printf '%s\n' "claude"
  elif printf '%s' "$body" | grep -qE '1 shell · ↓ to manage|claude --resume'; then
    printf '%s\n' "claude"
  else
    printf '%s\n' "claude"
  fi
}

agent_launch_command() {
  local target=${1:?usage: agent_launch_command <tmux-target>}
  case "$(detect_agent_cli "$target")" in
    codex)
      printf '%s\n' "exec codex -m gpt-5.5 --dangerously-bypass-approvals-and-sandbox"
      ;;
    *)
      printf '%s\n' "exec claude"
      ;;
  esac
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

worktree_cleanup_stale() {
  local root assignments path agent repo_root keep

  worktree_enabled || return 0
  root=$(worktree_root_dir)
  [ -d "$root" ] || return 0

  assignments='{}'
  if declare -F state_get >/dev/null 2>&1; then
    assignments=$(state_get assignments)
  fi

  if declare -p AGENTS >/dev/null 2>&1; then
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
