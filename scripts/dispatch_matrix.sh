#!/usr/bin/env bash
# scripts/dispatch_matrix.sh — operator CLI for the direct-dispatch matrix
# gate (ticket #253, parent epic #249).
#
# Direct dispatch is the authorized urgent exception path: an operator
# bypasses the normal local issue-pack handoff and writes a brief into
# an agent pane directly. This CLI is the gate that procedure goes
# through. It builds, prints, and validates a "dispatch matrix" file
# from ORDO read-only state plus GitHub issue/PR data, and refuses
# dispatch when a row is blocked, dirty, conflicting, or already owned.
#
# Usage:
#   dispatch_matrix.sh <project|config> init [--matrix <path>]
#   dispatch_matrix.sh <project|config> build [--matrix <path>] [--issue <n> ...]
#   dispatch_matrix.sh <project|config> add <issue> [k=v ...] [--matrix <path>]
#   dispatch_matrix.sh <project|config> print [--matrix <path>]
#   dispatch_matrix.sh <project|config> gate <issue> [--matrix <path>]
#
# Recognized k=v keys for `add` (mirrors the matrix columns):
#   repo= issue= priority= validation_mode= target_agent= tmux_target=
#   base_branch= owned_paths= forbidden_paths= readiness= blockers= notes=
#
# Exit codes (gate):
#   0  = ready, dispatch authorized
#   80 = blocked
#   81 = dirty
#   82 = conflict (hot-spot path overlap)
#   83 = owned   (agent already busy on a different issue)
#   84 = missing (matrix file or row not present)
#   85 = malformed (row missing required columns)
#
# This script does not perform tmux sends or GitHub mutations on its
# own; it is read-only over external state. It is meant to run before
# `scripts/dispatch_ticket.sh` on the authorized direct-dispatch path.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../lib/dry_run.sh
source "$TK/lib/dry_run.sh"
# shellcheck source=../lib/config_resolver.sh
source "$TK/lib/config_resolver.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

usage() {
  cat <<'EOF' >&2
usage:
  dispatch_matrix.sh <project|config> init [--matrix <path>]
  dispatch_matrix.sh <project|config> build [--matrix <path>] [--issue <n> ...]
  dispatch_matrix.sh <project|config> add <issue> [k=v ...] [--matrix <path>]
  dispatch_matrix.sh <project|config> print [--matrix <path>]
  dispatch_matrix.sh <project|config> gate <issue> [--matrix <path>]
EOF
}

CFG_ARG=${1:-}
[[ -n "$CFG_ARG" ]] || { usage; exit 2; }
SUB=${2:-}
[[ -n "$SUB" ]] || { usage; exit 2; }
shift 2 || true

load_project_config "$CFG_ARG"

# shellcheck source=../lib/audit_log.sh
source "$TK/lib/audit_log.sh"
# shellcheck source=../lib/state_persist.sh
source "$TK/lib/state_persist.sh"
# shellcheck source=../lib/worktree_helpers.sh
[[ -f "$TK/lib/worktree_helpers.sh" ]] && source "$TK/lib/worktree_helpers.sh"
# shellcheck source=../lib/dispatch_matrix.sh
source "$TK/lib/dispatch_matrix.sh"

MATRIX_PATH=""
ISSUE_FILTER=()
ISSUE_ARG=""
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --matrix)
      MATRIX_PATH=${2:?missing value for --matrix}
      shift 2
      ;;
    --issue)
      ISSUE_FILTER+=("${2:?missing value for --issue}")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

[[ -n "$MATRIX_PATH" ]] || MATRIX_PATH=$(dispatch_matrix_default_path)

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'dispatch_matrix: jq is required for %s\n' "$SUB" >&2
    exit 2
  fi
}

cmd_init() {
  if [[ -s "$MATRIX_PATH" ]]; then
    printf 'dispatch_matrix: %s already exists; refusing to overwrite\n' "$MATRIX_PATH" >&2
    return 1
  fi
  if dry_run_enabled; then
    dry_run_note "init dispatch_matrix at $MATRIX_PATH"
  else
    dispatch_matrix_init "$MATRIX_PATH"
  fi
  audit "DISPATCH_MATRIX init path=${MATRIX_PATH}"
  printf '%s\n' "$MATRIX_PATH"
}

cmd_print() {
  if [[ ! -f "$MATRIX_PATH" ]]; then
    printf 'dispatch_matrix: %s not found\n' "$MATRIX_PATH" >&2
    return "$ORCH_DISPATCH_MATRIX_MISSING_EXIT_CODE"
  fi
  cat "$MATRIX_PATH"
}

# Build a fresh matrix from ORDO read-only state plus GitHub issue/PR
# data. Existing rows are preserved when their issue still matches an
# open GitHub issue; stale rows are dropped. New rows are added with
# readiness=blocked when the issue itself is closed/PRed.
cmd_build() {
  require_jq
  if [[ ! -f "$MATRIX_PATH" ]]; then
    dispatch_matrix_init "$MATRIX_PATH"
  fi

  : "${GH_REPO:?GH_REPO must be set in the project config}"
  local gh_args=(issue list --repo "$GH_REPO" --state open
    --json number,title,labels,assignees,state,url --limit 200)
  if [[ "${#ISSUE_FILTER[@]}" -gt 0 ]]; then
    # Per-issue refresh: pull each via gh issue view rather than list.
    local out_tmp
    out_tmp="${MATRIX_PATH}.tmp.$$"
    {
      dispatch_matrix_header
      awk 'NR > 1' "$MATRIX_PATH"
    } > "$out_tmp"
    local issue_n payload status labels priority assignees agent_login row
    for issue_n in "${ISSUE_FILTER[@]}"; do
      issue_n=${issue_n#\#}
      payload=$(gh issue view "$issue_n" --repo "$GH_REPO" \
        --json number,title,labels,assignees,state,url 2>/dev/null || printf '{}')
      status=$(jq -r '.state // ""' <<< "$payload")
      labels=$(jq -r '[.labels[]?.name] | join(",")' <<< "$payload")
      assignees=$(jq -r '[.assignees[]?.login] | join(",")' <<< "$payload")
      agent_login=${assignees%%,*}
      priority=""
      case ",$labels," in
        *,priority:P0,*) priority=P0 ;;
        *,priority:P1,*) priority=P1 ;;
        *,priority:P2,*) priority=P2 ;;
        *,priority:P3,*) priority=P3 ;;
        *,priority:P4,*) priority=P4 ;;
      esac
      readiness=ready
      blockers=""
      if [[ "$status" != "OPEN" ]]; then
        readiness=blocked
        blockers="github-state=${status:-unknown}"
      fi
      row=$(dispatch_matrix_render_row \
        "repo=$GH_REPO" \
        "issue=$issue_n" \
        "priority=$priority" \
        "validation_mode=ci-delegated" \
        "target_agent=$agent_login" \
        "tmux_target=" \
        "base_branch=${DEFAULT_BRANCH:-main}" \
        "owned_paths=" \
        "forbidden_paths=" \
        "readiness=$readiness" \
        "blockers=$blockers" \
        "notes=built-by=dispatch_matrix")
      # Replace existing row for this issue if present, else append.
      awk -F'\t' -v want="$issue_n" -v new="$row" '
        NR == 1 { print; next }
        {
          cell = $2
          sub(/^#/, "", cell)
          if (cell == want) { print new; replaced = 1 } else { print }
        }
        END { if (!replaced) print new }
      ' "$out_tmp" > "$out_tmp.next"
      mv "$out_tmp.next" "$out_tmp"
    done
    mv "$out_tmp" "$MATRIX_PATH"
  else
    local list_payload
    list_payload=$(gh "${gh_args[@]}" 2>/dev/null || printf '[]')
    local row issue_n labels assignees agent_login priority gh_state
    {
      dispatch_matrix_header
      while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        issue_n=$(jq -r '.number' <<< "$row")
        labels=$(jq -r '[.labels[]?.name] | join(",")' <<< "$row")
        assignees=$(jq -r '[.assignees[]?.login] | join(",")' <<< "$row")
        gh_state=$(jq -r '.state // ""' <<< "$row")
        agent_login=${assignees%%,*}
        priority=""
        case ",$labels," in
          *,priority:P0,*) priority=P0 ;;
          *,priority:P1,*) priority=P1 ;;
          *,priority:P2,*) priority=P2 ;;
          *,priority:P3,*) priority=P3 ;;
          *,priority:P4,*) priority=P4 ;;
        esac
        # Preserve owned/forbidden paths and notes from any prior row.
        local prior owned forbidden readiness blockers notes
        prior=$(dispatch_matrix_find_row "$MATRIX_PATH" "$issue_n" 2>/dev/null || printf '')
        owned=$(dispatch_matrix_field "$prior" owned_paths)
        forbidden=$(dispatch_matrix_field "$prior" forbidden_paths)
        readiness=$(dispatch_matrix_field "$prior" readiness)
        blockers=$(dispatch_matrix_field "$prior" blockers)
        notes=$(dispatch_matrix_field "$prior" notes)
        if [[ -n "$gh_state" && "$gh_state" != "OPEN" ]]; then
          readiness=blocked
          [[ -n "$blockers" ]] || blockers="github-state=${gh_state}"
        fi
        [[ -n "$readiness" ]] || readiness=ready
        dispatch_matrix_render_row \
          "repo=$GH_REPO" \
          "issue=$issue_n" \
          "priority=$priority" \
          "validation_mode=ci-delegated" \
          "target_agent=$agent_login" \
          "tmux_target=" \
          "base_branch=${DEFAULT_BRANCH:-main}" \
          "owned_paths=$owned" \
          "forbidden_paths=$forbidden" \
          "readiness=$readiness" \
          "blockers=$blockers" \
          "notes=$notes"
      done < <(jq -c '.[]' <<< "$list_payload")
    } > "${MATRIX_PATH}.tmp.$$"
    mv "${MATRIX_PATH}.tmp.$$" "$MATRIX_PATH"
  fi
  audit "DISPATCH_MATRIX build path=${MATRIX_PATH} repo=${GH_REPO}"
  printf '%s\n' "$MATRIX_PATH"
}

cmd_add() {
  ISSUE_ARG=${EXTRA_ARGS[0]:-}
  [[ -n "$ISSUE_ARG" ]] || { usage; exit 2; }
  local -a kv=("${EXTRA_ARGS[@]:1}")
  if [[ ! -f "$MATRIX_PATH" ]]; then
    dispatch_matrix_init "$MATRIX_PATH"
  fi
  # Default repo+base_branch from project config if not overridden.
  local row
  row=$(dispatch_matrix_render_row \
    "repo=${GH_REPO:-}" \
    "issue=${ISSUE_ARG#\#}" \
    "validation_mode=ci-delegated" \
    "base_branch=${DEFAULT_BRANCH:-main}" \
    "${kv[@]}")
  if dispatch_matrix_find_row "$MATRIX_PATH" "$ISSUE_ARG" >/dev/null 2>&1; then
    awk -F'\t' -v want="${ISSUE_ARG#\#}" -v new="$row" '
      NR == 1 { print; next }
      {
        cell = $2
        sub(/^#/, "", cell)
        if (cell == want) { print new; replaced = 1 } else { print }
      }
      END { if (!replaced) print new }
    ' "$MATRIX_PATH" > "${MATRIX_PATH}.tmp.$$"
    mv "${MATRIX_PATH}.tmp.$$" "$MATRIX_PATH"
  else
    printf '%s\n' "$row" >> "$MATRIX_PATH"
  fi
  audit "DISPATCH_MATRIX add issue=${ISSUE_ARG#\#} path=${MATRIX_PATH}"
}

cmd_gate() {
  ISSUE_ARG=${EXTRA_ARGS[0]:-}
  [[ -n "$ISSUE_ARG" ]] || { usage; exit 2; }
  local reason rc=0
  if reason=$(dispatch_matrix_evaluate_row "$MATRIX_PATH" "$ISSUE_ARG" 2>&1 1>/dev/null); then
    rc=0
  else
    rc=$?
  fi
  if [[ "$rc" -eq 0 ]]; then
    audit "DISPATCH_MATRIX gate result=ready issue=${ISSUE_ARG#\#}"
    printf 'ready\n'
    return 0
  fi
  audit "DISPATCH_MATRIX gate result=refused issue=${ISSUE_ARG#\#} reason=${reason}"
  printf 'refused: %s\n' "$reason" >&2
  return "$rc"
}

case "$SUB" in
  init)  cmd_init ;;
  build) cmd_build ;;
  add)   cmd_add ;;
  print) cmd_print ;;
  gate)  cmd_gate ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
