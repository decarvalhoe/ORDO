#!/usr/bin/env bash
# lib/dispatch_matrix.sh — direct-dispatch matrix gate helpers.
#
# Direct dispatch is the authorized urgent exception path: an operator
# bypasses the normal local issue-pack handoff and writes a brief into
# an agent pane directly. Per epic #249 + ticket #253, this exception
# requires a current "dispatch matrix" naming the target row; this
# library renders, parses, and validates that matrix without driving
# tmux or GitHub mutations on its own. It is intentionally read-only
# wrt ORDO state and external systems.
#
# Functions:
#   dispatch_matrix_columns                    — print canonical column order
#   dispatch_matrix_default_path               — resolve default matrix file
#   dispatch_matrix_header                     — print TSV header
#   dispatch_matrix_init <path>                — write empty matrix
#   dispatch_matrix_render_row k=v ...         — render one TSV row from kvargs
#   dispatch_matrix_find_row <path> <issue>    — find first row by issue#
#   dispatch_matrix_field <row> <column>       — extract a TSV column value
#   dispatch_matrix_evaluate_row <path> <issue>
#       — classify readiness against current state (assignments, worktree,
#         hot-spot conflicts) and return a single-token reason on stderr.
#         exit 0  -> ready
#         exit 80 -> blocked   (row marks blockers / GH issue closed)
#         exit 81 -> dirty     (worktree has uncommitted changes)
#         exit 82 -> conflict  (owned_paths overlap another active agent)
#         exit 83 -> owned     (agent already has a different active issue)
#         exit 84 -> missing   (matrix file or row not present)
#         exit 85 -> malformed (row missing required columns)
#
# These codes avoid the 75-79 range already used by dispatch_ticket
# (tmux degraded, context mismatch, not-ready, heavy validators,
# not-consumed) so callers can disambiguate gate refusal from later
# pane-side failures.
#
# Pure library; no top-level side effects. Source it from a CLI that has
# already loaded a project config (audit_log/state_persist depend on
# $PROJECT being set, which keeps state isolated per portfolio).

if [[ -n "${ORCH_DISPATCH_MATRIX_LIB_LOADED:-}" ]]; then
  return 0
fi
ORCH_DISPATCH_MATRIX_LIB_LOADED=1

: "${ORCH_DISPATCH_MATRIX_FILE:=}"
: "${ORCH_DISPATCH_MATRIX_BLOCKED_EXIT_CODE:=80}"
: "${ORCH_DISPATCH_MATRIX_DIRTY_EXIT_CODE:=81}"
: "${ORCH_DISPATCH_MATRIX_CONFLICT_EXIT_CODE:=82}"
: "${ORCH_DISPATCH_MATRIX_OWNED_EXIT_CODE:=83}"
: "${ORCH_DISPATCH_MATRIX_MISSING_EXIT_CODE:=84}"
: "${ORCH_DISPATCH_MATRIX_MALFORMED_EXIT_CODE:=85}"

dispatch_matrix_columns() {
  printf '%s\n' \
    repo issue priority validation_mode target_agent tmux_target \
    base_branch owned_paths forbidden_paths readiness blockers notes
}

dispatch_matrix_header() {
  local cols
  cols=$(dispatch_matrix_columns | paste -sd $'\t' -)
  printf '%s\n' "$cols"
}

dispatch_matrix_default_path() {
  if [[ -n "$ORCH_DISPATCH_MATRIX_FILE" ]]; then
    printf '%s\n' "$ORCH_DISPATCH_MATRIX_FILE"
    return 0
  fi
  if command -v state_file >/dev/null 2>&1; then
    state_file dispatch_matrix.tsv
    return 0
  fi
  printf '%s\n' "${ORCH_STATE_BASE:-/tmp}/dispatch_matrix.tsv"
}

dispatch_matrix_init() {
  local path=${1:?usage: dispatch_matrix_init <path>}
  local dir
  dir=$(dirname "$path")
  mkdir -p "$dir"
  dispatch_matrix_header > "$path"
}

# Render one TSV row from k=v args. Unknown keys are ignored. Missing
# values become empty cells. Tabs/newlines inside values are squashed
# to spaces so a row stays one TSV line.
dispatch_matrix_render_row() {
  declare -A _kv=()
  local arg key val
  for arg in "$@"; do
    case "$arg" in
      *=*)
        key=${arg%%=*}
        val=${arg#*=}
        val=${val//$'\t'/ }
        val=${val//$'\n'/ }
        _kv[$key]=$val
        ;;
    esac
  done
  local -a out=()
  local col
  while IFS= read -r col; do
    out+=("${_kv[$col]:-}")
  done < <(dispatch_matrix_columns)
  (IFS=$'\t'; printf '%s\n' "${out[*]}")
}

# Find the first row matching an issue number (column 2). Output is the
# raw TSV line. Returns 1 if no row matched or the file is missing.
dispatch_matrix_find_row() {
  local path=${1:?usage: dispatch_matrix_find_row <path> <issue>}
  local issue=${2:?usage: dispatch_matrix_find_row <path> <issue>}
  local issue_norm=${issue#\#}
  [[ -f "$path" ]] || return 1
  awk -F'\t' -v want="$issue_norm" '
    NR == 1 { next }
    {
      cell = $2
      sub(/^#/, "", cell)
      if (cell == want) { print; found = 1; exit }
    }
    END { exit (found ? 0 : 1) }
  ' "$path"
}

# Extract a named column from a TSV row. Returns "" if the column or
# row is malformed.
dispatch_matrix_field() {
  local row=${1-}
  local column=${2:?usage: dispatch_matrix_field <row> <column>}
  local idx=0 col found=0
  local -a columns=()

  # Read the full column stream before searching. This avoids closing a
  # process-substitution pipe early when the requested column is near the
  # front, which can leak an intermittent "printf: Broken pipe" diagnostic
  # into callers that intentionally capture stderr as the gate reason.
  mapfile -t columns < <(dispatch_matrix_columns)
  for col in "${columns[@]}"; do
    idx=$((idx + 1))
    if [[ "$col" == "$column" ]]; then
      found=1
      break
    fi
  done
  [[ "$found" -eq 1 ]] || return 1
  awk -F'\t' -v i="$idx" '{ print $i }' <<< "$row"
}

# Split owned/forbidden_paths into a comma- or whitespace-separated list.
_dispatch_matrix_split_paths() {
  local raw=${1-}
  [[ -n "$raw" ]] || return 0
  printf '%s\n' "$raw" | tr ',;' '\n' | awk 'NF'
}

# Read the current ORDO assignments map (agent -> {ticket, ...}). Empty
# JSON object if state_persist is unavailable or the file is missing.
_dispatch_matrix_assignments_json() {
  if command -v state_get >/dev/null 2>&1; then
    state_get assignments 2>/dev/null || printf '{}\n'
    return 0
  fi
  printf '{}\n'
}

# Detect path overlap between two newline-separated path-glob lists.
# Trivial substring match: an exact equality, or one being a prefix of
# the other up to a path separator. Good enough for hot-spot conflicts
# without pulling in a full glob engine.
_dispatch_matrix_paths_overlap() {
  local a=$1
  local b=$2
  [[ -n "$a" && -n "$b" ]] || return 1
  local pa pb
  while IFS= read -r pa; do
    [[ -n "$pa" ]] || continue
    while IFS= read -r pb; do
      [[ -n "$pb" ]] || continue
      if [[ "$pa" == "$pb" ]]; then
        return 0
      fi
      if [[ "$pa" == "$pb"/* || "$pb" == "$pa"/* ]]; then
        return 0
      fi
    done <<< "$b"
  done <<< "$a"
  return 1
}

# Evaluate one matrix row against current ORDO + worktree state.
# Prints a one-token reason to stderr ("ready", "blocked:<why>", etc.)
# and returns one of the exit codes documented at the top of the file.
dispatch_matrix_evaluate_row() {
  local path=${1:?usage: dispatch_matrix_evaluate_row <path> <issue>}
  local issue=${2:?usage: dispatch_matrix_evaluate_row <path> <issue>}
  local row
  if ! [[ -f "$path" ]]; then
    printf 'missing:matrix-file\n' >&2
    return "$ORCH_DISPATCH_MATRIX_MISSING_EXIT_CODE"
  fi
  if ! row=$(dispatch_matrix_find_row "$path" "$issue"); then
    printf 'missing:row-not-found\n' >&2
    return "$ORCH_DISPATCH_MATRIX_MISSING_EXIT_CODE"
  fi

  local repo issue_cell agent owned forbidden readiness blockers branch
  repo=$(dispatch_matrix_field "$row" repo)
  issue_cell=$(dispatch_matrix_field "$row" issue)
  agent=$(dispatch_matrix_field "$row" target_agent)
  branch=$(dispatch_matrix_field "$row" base_branch)
  owned=$(dispatch_matrix_field "$row" owned_paths)
  forbidden=$(dispatch_matrix_field "$row" forbidden_paths)
  readiness=$(dispatch_matrix_field "$row" readiness)
  blockers=$(dispatch_matrix_field "$row" blockers)

  if [[ -z "$repo" || -z "$issue_cell" || -z "$agent" || -z "$branch" ]]; then
    printf 'malformed:missing-required-column\n' >&2
    return "$ORCH_DISPATCH_MATRIX_MALFORMED_EXIT_CODE"
  fi

  case "$readiness" in
    blocked)
      printf 'blocked:%s\n' "${blockers:-row-marked-blocked}" >&2
      return "$ORCH_DISPATCH_MATRIX_BLOCKED_EXIT_CODE"
      ;;
    dirty)
      printf 'dirty:%s\n' "${blockers:-row-marked-dirty}" >&2
      return "$ORCH_DISPATCH_MATRIX_DIRTY_EXIT_CODE"
      ;;
    conflicting|conflict)
      printf 'conflict:%s\n' "${blockers:-row-marked-conflicting}" >&2
      return "$ORCH_DISPATCH_MATRIX_CONFLICT_EXIT_CODE"
      ;;
    owned)
      printf 'owned:%s\n' "${blockers:-row-marked-owned}" >&2
      return "$ORCH_DISPATCH_MATRIX_OWNED_EXIT_CODE"
      ;;
  esac

  # If readiness was left blank, infer from blockers text. Any value
  # there means the row is not safe to dispatch.
  if [[ -z "$readiness" && -n "$blockers" ]]; then
    printf 'blocked:%s\n' "$blockers" >&2
    return "$ORCH_DISPATCH_MATRIX_BLOCKED_EXIT_CODE"
  fi

  # Cross-check ORDO assignments: refuse if the named agent is already
  # busy on a different ticket.
  local assignments other_ticket
  assignments=$(_dispatch_matrix_assignments_json)
  if command -v jq >/dev/null 2>&1; then
    other_ticket=$(jq -r --arg agent "$agent" '
      .[$agent] // {} | .ticket // ""
    ' <<< "$assignments" 2>/dev/null || printf '')
  else
    other_ticket=""
  fi
  if [[ -n "$other_ticket" && "$other_ticket" != "$issue_cell" && "$other_ticket" != "${issue_cell#\#}" ]]; then
    printf 'owned:agent=%s busy with #%s\n' "$agent" "$other_ticket" >&2
    return "$ORCH_DISPATCH_MATRIX_OWNED_EXIT_CODE"
  fi

  # Cross-check hot-spot conflicts: refuse if any other matrix row owns
  # an overlapping path against a different agent that is currently
  # active (per assignments).
  local owned_lines
  owned_lines=$(_dispatch_matrix_split_paths "$owned" || printf '')
  if [[ -n "$owned_lines" ]]; then
    local other_row other_agent other_owned other_owned_lines
    while IFS= read -r other_row; do
      [[ -n "$other_row" ]] || continue
      [[ "$other_row" == "$row" ]] && continue
      other_agent=$(dispatch_matrix_field "$other_row" target_agent)
      [[ -n "$other_agent" && "$other_agent" != "$agent" ]] || continue
      other_owned=$(dispatch_matrix_field "$other_row" owned_paths)
      other_owned_lines=$(_dispatch_matrix_split_paths "$other_owned" || printf '')
      if _dispatch_matrix_paths_overlap "$owned_lines" "$other_owned_lines"; then
        printf 'conflict:hot-spot-shared-with=%s\n' "$other_agent" >&2
        return "$ORCH_DISPATCH_MATRIX_CONFLICT_EXIT_CODE"
      fi
    done < <(awk 'NR > 1' "$path")
  fi

  # Worktree clean check: only when an agent workdir resolves and is a
  # git checkout. Missing dirs are not treated as dirty here; the
  # broader preflight (portfolio_assert_workdir_ready) owns
  # missing-clone refusal.
  local workdir=""
  if command -v agent_repo_root >/dev/null 2>&1; then
    workdir=$(agent_repo_root "$agent" 2>/dev/null || printf '')
  fi
  if [[ -n "$workdir" && -d "$workdir/.git" ]]; then
    if ! git -C "$workdir" diff --quiet 2>/dev/null \
      || ! git -C "$workdir" diff --cached --quiet 2>/dev/null; then
      printf 'dirty:workdir=%s\n' "$workdir" >&2
      return "$ORCH_DISPATCH_MATRIX_DIRTY_EXIT_CODE"
    fi
  fi

  # forbidden_paths is informational here — it travels with the brief
  # to the agent so the canonical "Boundaries / interdictions" section
  # of the dispatch markdown can reference it. We keep it in the row
  # without further enforcement; mutating other workdirs is already
  # blocked by the agent-side scope rules and by the path-overlap
  # check above.
  : "${forbidden:=}"

  printf 'ready\n' >&2
  return 0
}
