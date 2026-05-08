#!/usr/bin/env bash
# scripts/docs_impact_gate.sh — documentation impact gate runner (#260).
#
# Usage:
#   docs_impact_gate.sh classify [--paths-from <file>]
#       Print "<category>\t<path>" for each repo-relative path supplied on
#       --paths-from or stdin (one path per line). Exit 0 always.
#
#   docs_impact_gate.sh summarize [--paths-from <file>]
#       Print "<category>=<count>" lines, sorted by category. Exit 0 always.
#
#   docs_impact_gate.sh check [--paths-from <file>] [--declaration-from <file>]
#                              [--evidence-out <file>] [--quiet] [--soft]
#       Run the full gate. Exit 0 on pass or warn (or always on --soft);
#       exit 1 on block. Writes evidence markdown to --evidence-out when
#       supplied; otherwise prints the evidence to stdout.
#
#   docs_impact_gate.sh declare --outcome <value> [--note <text>]
#                                [--followup <ref>]
#       Print a Docs-Impact declaration block to stdout, suitable for
#       pasting into a commit message trailer or PR body.
#
#   docs_impact_gate.sh render-evidence --paths-from <file>
#                                        [--declaration-from <file>]
#       Render the evidence markdown without making a pass/fail decision.
#
# The gate runner is project-agnostic. Override path classification with
# the DOCS_GATE_*_PATTERN env vars documented in lib/docs_impact_gate.sh.
#
# Validation grade: gxp-grade-dev. Exit codes are stable. Output goes to
# stdout (evidence) and stderr (operator messages); the two streams are
# never interleaved.

set -euo pipefail

TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../lib/docs_impact_gate.sh
source "$TK/lib/docs_impact_gate.sh"

# Single shared scratch dir; cleaned up on EXIT. Using a registered
# directory rather than per-function RETURN traps keeps cleanup robust
# under `set -u` and avoids re-installing traps for each subcommand.
DOCS_GATE_TMP_DIR=""

docs_gate_tmp_init() {
  if [[ -z "$DOCS_GATE_TMP_DIR" ]]; then
    DOCS_GATE_TMP_DIR=$(mktemp -d)
  fi
}

docs_gate_tmp_cleanup() {
  if [[ -n "${DOCS_GATE_TMP_DIR:-}" && -d "$DOCS_GATE_TMP_DIR" ]]; then
    rm -rf "$DOCS_GATE_TMP_DIR"
  fi
}

trap docs_gate_tmp_cleanup EXIT

docs_gate_tmp_file() {
  docs_gate_tmp_init
  local name="${1:-tmp}"
  local path="$DOCS_GATE_TMP_DIR/$name.$$.$RANDOM"
  : >"$path"
  printf '%s' "$path"
}

usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  printf 'docs_impact_gate: %s\n' "$*" >&2
  exit 2
}

read_path_input() {
  local source="${1-}"
  if [[ -z "$source" || "$source" == "-" ]]; then
    cat
  else
    [[ -f "$source" ]] || die "paths file not found: $source"
    cat "$source"
  fi
}

read_declaration_input() {
  local source="${1-}"
  if [[ -z "$source" ]]; then
    return 0
  fi
  if [[ "$source" == "-" ]]; then
    cat
    return 0
  fi
  [[ -f "$source" ]] || die "declaration file not found: $source"
  cat "$source"
}

cmd_classify() {
  local paths_from=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --paths-from) paths_from=${2:?missing value for --paths-from}; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) die "classify: unknown arg: $1" ;;
    esac
  done
  read_path_input "$paths_from" | docs_gate_classify_stream
}

cmd_summarize() {
  local paths_from=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --paths-from) paths_from=${2:?missing value for --paths-from}; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) die "summarize: unknown arg: $1" ;;
    esac
  done
  read_path_input "$paths_from" \
    | docs_gate_classify_stream \
    | docs_gate_summarize_stream
}

cmd_declare() {
  local outcome="" note="" followup=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --outcome) outcome=${2:?missing value for --outcome}; shift 2 ;;
      --note) note=${2:?missing value for --note}; shift 2 ;;
      --followup) followup=${2:?missing value for --followup}; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) die "declare: unknown arg: $1" ;;
    esac
  done
  [[ -n "$outcome" ]] || die "declare: --outcome is required"
  if ! docs_gate_outcome_is_valid "$outcome"; then
    die "declare: outcome '$outcome' is not one of: ${DOCS_GATE_VALID_OUTCOMES[*]}"
  fi
  if [[ "$outcome" == "no-docs-needed" && -z "$note" ]]; then
    die "declare: outcome=no-docs-needed requires --note <rationale>"
  fi
  if [[ "$outcome" == "follow-up" && -z "$followup" ]]; then
    die "declare: outcome=follow-up requires --followup <issue-ref>"
  fi

  printf 'Docs-Impact: %s\n' "$outcome"
  if [[ -n "$note" ]]; then
    printf 'Docs-Impact-Note: %s\n' "$note"
  fi
  if [[ -n "$followup" ]]; then
    printf 'Docs-Impact-Followup: %s\n' "$followup"
  fi
}

cmd_render_evidence() {
  local paths_from="" declaration_from=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --paths-from) paths_from=${2:?missing value for --paths-from}; shift 2 ;;
      --declaration-from) declaration_from=${2:?missing value for --declaration-from}; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) die "render-evidence: unknown arg: $1" ;;
    esac
  done
  [[ -n "$paths_from" ]] || die "render-evidence: --paths-from is required"

  local tmp_paths tmp_classified tmp_summary tmp_decl
  tmp_paths=$(docs_gate_tmp_file paths)
  tmp_classified=$(docs_gate_tmp_file classified)
  tmp_summary=$(docs_gate_tmp_file summary)
  tmp_decl=$(docs_gate_tmp_file decl)

  read_path_input "$paths_from" >"$tmp_paths"
  docs_gate_classify_stream <"$tmp_paths" >"$tmp_classified"
  docs_gate_summarize_stream <"$tmp_classified" >"$tmp_summary"
  read_declaration_input "$declaration_from" | docs_gate_parse_declaration >"$tmp_decl"

  local summary declaration
  summary=$(cat "$tmp_summary")
  declaration=$(cat "$tmp_decl")

  docs_gate_render_evidence "informational" "render-only invocation" \
    "$summary" "$declaration" "$tmp_classified"
}

cmd_check() {
  local paths_from="" declaration_from="" evidence_out="" quiet=0 soft=0
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --paths-from) paths_from=${2:?missing value for --paths-from}; shift 2 ;;
      --declaration-from) declaration_from=${2:?missing value for --declaration-from}; shift 2 ;;
      --evidence-out) evidence_out=${2:?missing value for --evidence-out}; shift 2 ;;
      --quiet) quiet=1; shift ;;
      --soft) soft=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "check: unknown arg: $1" ;;
    esac
  done

  local tmp_paths tmp_classified tmp_summary tmp_decl
  tmp_paths=$(docs_gate_tmp_file paths)
  tmp_classified=$(docs_gate_tmp_file classified)
  tmp_summary=$(docs_gate_tmp_file summary)
  tmp_decl=$(docs_gate_tmp_file decl)

  read_path_input "$paths_from" >"$tmp_paths"
  if [[ ! -s "$tmp_paths" ]]; then
    if [[ "$quiet" -ne 1 ]]; then
      printf 'docs_impact_gate: no paths supplied; treating as pass\n' >&2
    fi
    if [[ -n "$evidence_out" ]]; then
      docs_gate_render_evidence "pass" "no paths supplied" "" "" /dev/null \
        >"$evidence_out"
    fi
    return 0
  fi

  docs_gate_classify_stream <"$tmp_paths" >"$tmp_classified"
  docs_gate_summarize_stream <"$tmp_classified" >"$tmp_summary"
  read_declaration_input "$declaration_from" | docs_gate_parse_declaration >"$tmp_decl"

  local summary declaration decide_line decision reason
  summary=$(cat "$tmp_summary")
  declaration=$(cat "$tmp_decl")
  decide_line=$(docs_gate_decide "$summary" "$declaration")
  decision=${decide_line%%$'\t'*}
  reason=${decide_line#*$'\t'}
  if [[ "$reason" == "$decide_line" ]]; then
    reason=""
  fi

  local evidence
  evidence=$(docs_gate_render_evidence "$decision" "$reason" \
    "$summary" "$declaration" "$tmp_classified")

  if [[ -n "$evidence_out" ]]; then
    printf '%s\n' "$evidence" >"$evidence_out"
  elif [[ "$quiet" -ne 1 ]]; then
    printf '%s\n' "$evidence"
  fi

  if [[ "$quiet" -ne 1 ]]; then
    printf 'docs_impact_gate: decision=%s reason=%s\n' "$decision" "$reason" >&2
  fi

  case "$decision" in
    pass|warn) return 0 ;;
    block)
      if [[ "$soft" -eq 1 ]]; then
        if [[ "$quiet" -ne 1 ]]; then
          printf 'docs_impact_gate: --soft active; reporting block as advisory\n' >&2
        fi
        return 0
      fi
      return 1
      ;;
    *)
      printf 'docs_impact_gate: unknown decision: %s\n' "$decision" >&2
      return 2
      ;;
  esac
}

main() {
  if [[ "$#" -eq 0 ]]; then
    usage
    exit 2
  fi
  local command=$1
  shift
  case "$command" in
    classify) cmd_classify "$@" ;;
    summarize) cmd_summarize "$@" ;;
    check) cmd_check "$@" ;;
    declare) cmd_declare "$@" ;;
    render-evidence) cmd_render_evidence "$@" ;;
    -h|--help|help) usage ;;
    *) die "unknown command: $command" ;;
  esac
}

main "$@"
