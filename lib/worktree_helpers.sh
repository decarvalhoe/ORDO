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
  if [[ -n "${ORCH_WORKTREES_DIR:-}" ]]; then
    printf '%s\n' "$ORCH_WORKTREES_DIR"
    return 0
  fi
  if declare -F state_dir >/dev/null 2>&1; then
    printf '%s/worktrees\n' "$(state_dir)"
    return 0
  fi
  [[ -n "${PROJECT:-}" ]] || return 1
  printf '%s/%s/worktrees\n' "$(worktree_state_base)" "$PROJECT"
}

worktree_state_base() {
  if [[ -n "${ORCH_STATE_BASE:-}" ]]; then
    printf '%s\n' "$ORCH_STATE_BASE"
  elif [[ -n "${XDG_DATA_HOME:-}" ]]; then
    printf '%s/orch-state\n' "$XDG_DATA_HOME"
  else
    printf '%s/.local/share/orch-state\n' "${HOME:-/root}"
  fi
}

worktree_feature_branch() {
  local ticket=${1:?usage: worktree_feature_branch <ticket>}
  ticket=${ticket#\#}
  # Issue #628: when a caller (typically `ci_autofix.sh`) targets an
  # existing open PR, the worktree must check out the PR's actual head
  # branch (e.g. `fix/issue-603-...`) — not a synthetic
  # `feat/issue-<PR-number>` that would diverge from the PR head and
  # hide remediation commits from GitHub. The override is opt-in via
  # ORCH_DISPATCH_BRANCH_OVERRIDE so the default `feat/issue-<N>`
  # routing for issue dispatches is unchanged.
  if [[ -n "${ORCH_DISPATCH_BRANCH_OVERRIDE:-}" ]]; then
    printf '%s\n' "$ORCH_DISPATCH_BRANCH_OVERRIDE"
    return 0
  fi
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

worktree_live_agent_workdir() {
  local agent=${1:?usage: worktree_live_agent_workdir <agent> <pane-current-path>}
  local candidate=${2:?usage: worktree_live_agent_workdir <agent> <pane-current-path>}
  local root agent_root normalized_candidate remainder slug

  worktree_enabled || return 1
  root=$(worktree_root_dir 2>/dev/null || true)
  [[ -n "$root" ]] || return 1

  root=$(_worktree_normalize_path "$root")
  normalized_candidate=$(_worktree_normalize_path "$candidate")
  root=${root%/}
  normalized_candidate=${normalized_candidate%/}
  agent_root="$root/$agent"

  case "$normalized_candidate/" in
    "$agent_root"/*)
      remainder=${normalized_candidate#"$agent_root"/}
      slug=${remainder%%/*}
      [[ -n "$slug" ]] || return 1
      printf '%s/%s/%s\n' "$root" "$agent" "$slug"
      return 0
      ;;
  esac

  return 1
}

worktree_live_agent_workdir_from_root_name() {
  local agent=${1:?usage: worktree_live_agent_workdir_from_root_name <agent> <pane-current-path> <root-basename>}
  local candidate=${2:?usage: worktree_live_agent_workdir_from_root_name <agent> <pane-current-path> <root-basename>}
  local root_name=${3:?usage: worktree_live_agent_workdir_from_root_name <agent> <pane-current-path> <root-basename>}
  local normalized_candidate marker prefix remainder slug

  root_name=$(basename -- "$root_name")
  [[ -n "$root_name" && "$root_name" != "." && "$root_name" != "/" ]] || return 1

  normalized_candidate=$(_worktree_normalize_path "$candidate")
  normalized_candidate=${normalized_candidate%/}
  marker="/$root_name/$agent/"

  case "$normalized_candidate/" in
    *"$marker"*)
      prefix=${normalized_candidate%%"$marker"*}
      remainder=${normalized_candidate#*"$marker"}
      slug=${remainder%%/*}
      [[ -n "$slug" ]] || return 1
      printf '%s/%s/%s/%s\n' "$prefix" "$root_name" "$agent" "$slug"
      return 0
      ;;
  esac

  return 1
}

agent_git_identity() {
  local agent=${1:?usage: agent_git_identity <agent>}
  local name="" email="" entry entry_agent entry_name entry_email entry_extra

  if [[ -n "${AGENT_GIT_IDENTITIES+x}" && "${#AGENT_GIT_IDENTITIES[@]}" -gt 0 ]]; then
    for entry in "${AGENT_GIT_IDENTITIES[@]}"; do
      IFS='|' read -r entry_agent entry_name entry_email entry_extra <<< "$entry"
      if [[ -n "$entry_extra" ]]; then
        printf 'AGENT_GIT_IDENTITIES entry malformed (need agent|name|email): %s\n' "$entry" >&2
        return 2
      fi
      if [[ "$entry_agent" == "$agent" ]]; then
        name=$entry_name
        email=$entry_email
        break
      fi
    done
  fi

  if [[ -z "$name" && -n "${AGENT_GIT_IDENTITY_NAME_TEMPLATE:-}" ]]; then
    # shellcheck disable=SC2059
    name=$(printf "$AGENT_GIT_IDENTITY_NAME_TEMPLATE" "$agent")
  fi
  if [[ -z "$email" && -n "${AGENT_GIT_IDENTITY_EMAIL_TEMPLATE:-}" ]]; then
    # shellcheck disable=SC2059
    email=$(printf "$AGENT_GIT_IDENTITY_EMAIL_TEMPLATE" "$agent")
  fi

  if [[ -z "$name$email" ]]; then
    return 1
  fi
  if [[ -z "$name" || -z "$email" ]]; then
    printf 'incomplete git identity for agent=%s name=%s email=%s\n' \
      "$agent" "${name:-<empty>}" "${email:-<empty>}" >&2
    return 2
  fi

  printf '%s\n%s\n' "$name" "$email"
}

worktree_configure_identity() {
  local agent=${1:?usage: worktree_configure_identity <agent> <worktree-path> [repo-root]}
  local path=${2:?usage: worktree_configure_identity <agent> <worktree-path> [repo-root]}
  local repo_root=${3:-}
  local identity=() identity_output identity_status=0 name email

  identity_output=$(agent_git_identity "$agent") || identity_status=$?
  if [[ "$identity_status" -eq 1 ]]; then
    return 0
  fi
  [[ "$identity_status" -eq 0 ]] || return "$identity_status"
  mapfile -t identity <<< "$identity_output"
  name=${identity[0]-}
  email=${identity[1]-}
  [[ -n "$name$email" ]] || return 0
  [[ -n "$name" && -n "$email" ]] || return 2

  if [[ -z "$repo_root" ]]; then
    repo_root=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)
  fi
  [[ -n "$repo_root" ]] || return 1

  git -C "$repo_root" config extensions.worktreeConfig true
  git -C "$path" config --worktree user.name "$name"
  git -C "$path" config --worktree user.email "$email"
}

worktree_assert_agent_identity() {
  local agent=${1:?usage: worktree_assert_agent_identity <agent> <worktree-path>}
  local path=${2:?usage: worktree_assert_agent_identity <agent> <worktree-path>}
  local identity=() identity_output identity_status=0 expected_name expected_email actual_name actual_email

  # Side-channel fields for callers that want structured audit details.
  # shellcheck disable=SC2034
  WORKTREE_IDENTITY_EXPECTED_NAME=""
  # shellcheck disable=SC2034
  WORKTREE_IDENTITY_EXPECTED_EMAIL=""
  # shellcheck disable=SC2034
  WORKTREE_IDENTITY_ACTUAL_NAME=""
  # shellcheck disable=SC2034
  WORKTREE_IDENTITY_ACTUAL_EMAIL=""

  identity_output=$(agent_git_identity "$agent") || identity_status=$?
  if [[ "$identity_status" -eq 1 ]]; then
    return 0
  fi
  [[ "$identity_status" -eq 0 ]] || return "$identity_status"
  mapfile -t identity <<< "$identity_output"
  expected_name=${identity[0]-}
  expected_email=${identity[1]-}
  [[ -n "$expected_name$expected_email" ]] || return 0
  [[ -n "$expected_name" && -n "$expected_email" ]] || return 2

  actual_name=$(git -C "$path" config user.name 2>/dev/null || true)
  actual_email=$(git -C "$path" config user.email 2>/dev/null || true)

  # shellcheck disable=SC2034
  WORKTREE_IDENTITY_EXPECTED_NAME="$expected_name"
  # shellcheck disable=SC2034
  WORKTREE_IDENTITY_EXPECTED_EMAIL="$expected_email"
  # shellcheck disable=SC2034
  WORKTREE_IDENTITY_ACTUAL_NAME="$actual_name"
  # shellcheck disable=SC2034
  WORKTREE_IDENTITY_ACTUAL_EMAIL="$actual_email"

  if [[ "$actual_name" != "$expected_name" || "$actual_email" != "$expected_email" ]]; then
    printf 'worktree git identity mismatch: agent=%s workdir=%s expected_name=%s actual_name=%s expected_email=%s actual_email=%s\n' \
      "$agent" "$path" "$expected_name" "${actual_name:-<empty>}" "$expected_email" "${actual_email:-<empty>}" >&2
    return 1
  fi
}

agent_assignment_workdir() {
  local agent=${1:?usage: agent_assignment_workdir <agent>}
  local assignments_file

  if declare -F state_get >/dev/null 2>&1; then
    state_get assignments | jq -r --arg agent "$agent" '.[$agent].workdir // ""'
    return 0
  fi

  command -v jq >/dev/null 2>&1 || return 0
  [[ -n "${PROJECT:-}" ]] || return 0
  assignments_file="$(worktree_state_base)/$PROJECT/assignments.json"
  [[ -s "$assignments_file" ]] || return 0
  jq -r --arg agent "$agent" '.[$agent].workdir // ""' "$assignments_file" 2>/dev/null || true
}

agent_assignment_field() {
  local agent=${1:?usage: agent_assignment_field <agent> <field>}
  local field=${2:?usage: agent_assignment_field <agent> <field>}
  local assignments_file

  if declare -F state_get >/dev/null 2>&1; then
    state_get assignments | jq -r --arg agent "$agent" --arg field "$field" '.[$agent][$field] // ""'
    return 0
  fi

  command -v jq >/dev/null 2>&1 || return 0
  [[ -n "${PROJECT:-}" ]] || return 0
  assignments_file="$(worktree_state_base)/$PROJECT/assignments.json"
  [[ -s "$assignments_file" ]] || return 0
  jq -r --arg agent "$agent" --arg field "$field" '.[$agent][$field] // ""' "$assignments_file" 2>/dev/null || true
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
    worktree_configure_identity "$agent" "$path" "$repo_root"
    printf '%s\n' "$path"
    return 0
  fi

  mkdir -p "$(dirname "$path")"
  git -C "$repo_root" fetch --quiet origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || true
  if ! git -C "$repo_root" worktree add -B "$branch" "$path" "$base_ref" >/dev/null 2>&1; then
    git -C "$repo_root" worktree add -B "$branch" "$path" "$DEFAULT_BRANCH" >/dev/null 2>&1
  fi
  worktree_configure_identity "$agent" "$path" "$repo_root"

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

_worktree_normalize_path() {
  local path=${1:?usage: _worktree_normalize_path <path>}
  local parent base resolved

  if command -v readlink >/dev/null 2>&1; then
    if [[ -e "$path" ]]; then
      readlink -f -- "$path" 2>/dev/null || printf '%s\n' "${path%/}"
      return 0
    fi
    parent=$(dirname -- "$path")
    base=$(basename -- "$path")
    if [[ -e "$parent" ]]; then
      resolved=$(readlink -f -- "$parent" 2>/dev/null || printf '%s' "$parent")
      printf '%s/%s\n' "${resolved%/}" "$base"
      return 0
    fi
  fi

  printf '%s\n' "${path%/}"
}

worktree_assignment_path_matches() {
  local candidate=${1:?usage: worktree_assignment_path_matches <candidate> <assignment-workdir>}
  local assignment_workdir=${2:?usage: worktree_assignment_path_matches <candidate> <assignment-workdir>}
  local normalized_candidate normalized_assignment

  normalized_candidate=$(_worktree_normalize_path "$candidate")
  normalized_assignment=$(_worktree_normalize_path "$assignment_workdir")
  normalized_candidate=${normalized_candidate%/}
  normalized_assignment=${normalized_assignment%/}
  [[ -n "$normalized_candidate" && -n "$normalized_assignment" ]] || return 1

  case "$normalized_candidate/" in
    "$normalized_assignment"/*) return 0 ;;
    *) return 1 ;;
  esac
}

worktree_active_assignment_signal() {
  local project=${1:-unknown}
  local issue=${2:-unknown}

  project=${project//[^A-Za-z0-9_.-]/_}
  issue=${issue//[^A-Za-z0-9_.-]/_}
  [[ -n "$project" ]] || project=unknown
  [[ -n "$issue" ]] || issue=unknown
  printf 'pane-occupied:%s#%s\n' "$project" "$issue"
}

worktree_active_assignment_for_path() {
  local candidate=${1:?usage: worktree_active_assignment_for_path <pane-current-path>}
  local state_base assignments_file project agent issue workdir

  command -v jq >/dev/null 2>&1 || return 1
  state_base=${ORCH_STATE_BASE:-${XDG_DATA_HOME:-/root/.local/share}/orch-state}
  [[ -n "$candidate" && -d "$state_base" ]] || return 1
  local home_dir=${HOME:-}
  case "$state_base" in
    /) return 1 ;;
  esac
  if [[ -n "$home_dir" && ( "$state_base" == "$home_dir" || "$state_base" == "$home_dir/" ) ]]; then
    return 1
  fi

  while IFS= read -r assignments_file; do
    [[ -s "$assignments_file" ]] || continue
    project=$(basename "$(dirname "$assignments_file")")
    while IFS=$'\t' read -r agent issue workdir; do
      [[ -n "$agent$issue$workdir" && -n "$workdir" ]] || continue
      if worktree_assignment_path_matches "$candidate" "$workdir"; then
        # shellcheck disable=SC2034 # consumed by callers that prefer globals.
        ORCH_ACTIVE_ASSIGNMENT_PROJECT=$project
        # shellcheck disable=SC2034
        ORCH_ACTIVE_ASSIGNMENT_AGENT=$agent
        # shellcheck disable=SC2034
        ORCH_ACTIVE_ASSIGNMENT_ISSUE=$issue
        # shellcheck disable=SC2034
        ORCH_ACTIVE_ASSIGNMENT_WORKDIR=$workdir
        printf '%s\t%s\t%s\t%s\n' "$project" "$agent" "$issue" "$workdir"
        return 0
      fi
    done < <(jq -r '
      to_entries[]
      | select((.value.parked // false) != true)
      | [
          .key,
          ((.value.issue // .value.ticket // "unknown") | tostring),
          (.value.workdir // "")
        ]
      | @tsv
    ' "$assignments_file" 2>/dev/null || true)
  done < <(find "$state_base" -mindepth 2 -maxdepth 2 -type f -name assignments.json 2>/dev/null | sort)

  return 1
}

_worktree_tmux_run() {
  local timeout_sec=${ORCH_TMUX_TIMEOUT_SEC:-10}

  if command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_sec" tmux "$@"
  else
    tmux "$@"
  fi
}

_worktree_tmux_current_path() {
  local pane=${1:?usage: _worktree_tmux_current_path <pane-target>}
  local out

  command -v tmux >/dev/null 2>&1 || return 1
  out=$(_worktree_tmux_run display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null) || return 1
  out=${out%$'\n'}
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

_worktree_tmux_list_pane_paths() {
  local format raw pane path

  command -v tmux >/dev/null 2>&1 || return 1
  format=$'#{pane_id}\t#{pane_current_path}'
  raw=$(_worktree_tmux_run list-panes -a -F "$format" 2>/dev/null) || return 1
  while IFS=$'\t' read -r pane path; do
    [[ -n "$pane$path" && -n "$path" ]] || continue
    printf '%s\t%s\n' "$pane" "$path"
  done <<< "$raw"
}

worktree_live_pane_for_path() {
  local candidate=${1:?usage: worktree_live_pane_for_path <candidate-worktree-path>}
  local pane live_path label assigned_workdir

  while IFS=$'\t' read -r pane live_path; do
    [[ -n "$pane$live_path" && -n "$live_path" ]] || continue
    if worktree_assignment_path_matches "$live_path" "$candidate"; then
      printf '%s\t%s\n' "$pane" "$live_path"
      return 0
    fi
  done < <(_worktree_tmux_list_pane_paths 2>/dev/null || true)

  if declare -F agent_inventory_entries >/dev/null 2>&1; then
    while IFS='|' read -r label pane assigned_workdir; do
      [[ -n "$label$pane$assigned_workdir" && -n "$pane" ]] || continue
      live_path=$(_worktree_tmux_current_path "$pane" 2>/dev/null || true)
      [[ -n "$live_path" ]] || continue
      if worktree_assignment_path_matches "$live_path" "$candidate"; then
        printf '%s\t%s\n' "$pane" "$live_path"
        return 0
      fi
    done < <(agent_inventory_entries 2>/dev/null || true)
  fi

  return 1
}

worktree_cleanup_stale() {
  local root assignments path agent repo_root keep live_match live_pane live_path

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
      if live_match=$(worktree_live_pane_for_path "$path" 2>/dev/null); then
        IFS=$'\t' read -r live_pane live_path <<< "$live_match"
        audit "WORKTREE CLEANUP skipped path=$path reason=live-pane-cwd pane=${live_pane:-unknown} pane_current_path=${live_path:-unknown}"
        continue
      fi
      worktree_remove "$path"
      audit "WORKTREE CLEANUP removed path=$path"
    fi
  done < <(find "$root" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort)
}
