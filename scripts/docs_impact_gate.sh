#!/usr/bin/env bash
# scripts/docs_impact_gate.sh — documentation impact gate runner (#260, #316).
#
# Two operating modes share the same script:
#
# 1. Classification / declaration mode (#260):
#
#    docs_impact_gate.sh classify [--paths-from <file>]
#        Print "<category>\t<path>" for each repo-relative path supplied on
#        --paths-from or stdin (one path per line). Exit 0 always.
#
#    docs_impact_gate.sh summarize [--paths-from <file>]
#        Print "<category>=<count>" lines, sorted by category. Exit 0 always.
#
#    docs_impact_gate.sh check [--paths-from <file>] [--declaration-from <file>]
#                              [--evidence-out <file>] [--quiet] [--soft]
#        Run the full gate. Exit 0 on pass or warn (or always on --soft);
#        exit 1 on block. Writes evidence markdown to --evidence-out when
#        supplied; otherwise prints the evidence to stdout.
#
#    docs_impact_gate.sh declare --outcome <value> [--note <text>]
#                                [--followup <ref>]
#        Print a Docs-Impact declaration block to stdout, suitable for
#        pasting into a commit message trailer or PR body.
#
#    docs_impact_gate.sh render-evidence --paths-from <file>
#                                        [--declaration-from <file>]
#        Render the evidence markdown without making a pass/fail decision.
#
# 2. Multi-agent template guard mode (#316):
#
#    docs_impact_gate.sh --diff <file> --pr-body <file> [--warn-only] [--json]
#        Refuse (or warn) when a PR changes a multi-agent template under
#        DOCS_IMPACT_GUARDED_PATHS without rendering the docs-impact
#        checklist in the PR body.
#
# The first argument selects the mode: a known subcommand name dispatches
# to that subcommand; a flag (e.g. --diff) selects multi-agent template
# guard mode. The runner is project-agnostic — override path
# classification with the DOCS_GATE_*_PATTERN env vars documented in
# lib/docs_impact_gate.sh, and override guarded paths/headers with the
# DOCS_IMPACT_* env vars below.
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

# --- Multi-agent template guard mode (#316) -------------------------------

DEFAULT_GUARDED_PATHS='docs/templates/multi-agent/'
DEFAULT_BLOCK_HEADERS='Docs Impact|Documentation Impact|Impact docs|Impact documentation'

template_gate_usage() {
  cat <<'EOF' >&2
usage: docs_impact_gate.sh --diff <file> --pr-body <file> [--warn-only] [--json]

Pass "-" for either --diff or --pr-body to read from stdin (only one of the
two may be "-" in a single invocation).

Exits 0 when no guarded paths changed or when the docs-impact block is
present. Exits 4 when guarded paths changed and the block is missing,
unless --warn-only or DOCS_IMPACT_GATE_MODE=warn keeps the warning text
but exits 0.
EOF
}

template_read_input() {
  local source=$1
  if [[ "$source" == "-" ]]; then
    cat
  else
    [[ -e "$source" ]] || {
      printf 'docs_impact_gate.sh: input not found: %s\n' "$source" >&2
      exit 2
    }
    cat -- "$source"
  fi
}

# Effective guarded-path list (defaults + override). Each entry is trimmed.
template_guarded_paths_list() {
  local override=${DOCS_IMPACT_GUARDED_PATHS:-}
  local entries
  entries="$DEFAULT_GUARDED_PATHS"
  if [[ -n "$override" ]]; then
    entries+=$'\n'"$override"
  fi
  printf '%s' "$entries" \
    | tr ',;' '\n' \
    | while IFS= read -r entry || [[ -n "$entry" ]]; do
        entry=${entry#"${entry%%[![:space:]]*}"}
        entry=${entry%"${entry##*[![:space:]]}"}
        [[ -n "$entry" ]] || continue
        printf '%s\n' "$entry"
      done
}

# Returns 0 when `path` is under any guarded prefix or matches any guarded
# glob.
template_path_is_guarded() {
  local path=$1 entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if [[ "$entry" == *'*'* || "$entry" == *'?'* || "$entry" == *'['*']'* ]]; then
      # shellcheck disable=SC2053  # intentional glob match
      if [[ "$path" == $entry ]]; then
        return 0
      fi
    else
      if [[ "$entry" == */ ]]; then
        if [[ "$path" == "$entry"* ]]; then
          return 0
        fi
      else
        if [[ "$path" == "$entry" || "$path" == "$entry"/* ]]; then
          return 0
        fi
      fi
    fi
  done < <(template_guarded_paths_list)
  return 1
}

template_filter_guarded_paths() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -n "$line" ]] || continue
    [[ "$line" == \#* ]] && continue
    if template_path_is_guarded "$line"; then
      printf '%s\n' "$line"
    fi
  done
}

template_block_header_pattern() {
  local override=${DOCS_IMPACT_BLOCK_HEADERS:-}
  if [[ -n "$override" ]]; then
    printf '%s|%s' "$DEFAULT_BLOCK_HEADERS" "$override"
  else
    printf '%s' "$DEFAULT_BLOCK_HEADERS"
  fi
}

template_body_has_block() {
  local body=$1
  local headers
  headers=$(template_block_header_pattern)
  printf '%s\n' "$body" | awk -v headers="$headers" '
    BEGIN {
      in_block = 0
      remaining = 0
      header_re = "^[[:space:]]*#+[[:space:]]*((\\*\\*)|_|\\*)?(" headers ")((\\*\\*)|_|\\*)?[[:space:]]*:?[[:space:]]*$"
      IGNORECASE = 1
    }
    {
      line = $0
      if (line ~ /^[[:space:]]*#+[[:space:]]+/) {
        if (line ~ header_re) {
          in_block = 1
          remaining = 60
          next
        } else if (in_block == 1) {
          in_block = 0
          remaining = 0
        }
      }
      if (in_block == 1) {
        if (line ~ /^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]+/) {
          found = 1
          exit 0
        }
        remaining = remaining - 1
        if (remaining <= 0) {
          in_block = 0
        }
      }
    }
    END {
      if (found == 1) { exit 0 } else { exit 1 }
    }
  '
}

cmd_template_gate() {
  local diff_file="" pr_body_file="" warn_only=0 format="text"
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --diff)
        diff_file=${2:?missing value for --diff}
        shift 2
        ;;
      --diff=*)
        diff_file=${1#--diff=}
        shift
        ;;
      --pr-body)
        pr_body_file=${2:?missing value for --pr-body}
        shift 2
        ;;
      --pr-body=*)
        pr_body_file=${1#--pr-body=}
        shift
        ;;
      --warn-only)
        warn_only=1
        shift
        ;;
      --json)
        format="json"
        shift
        ;;
      -h|--help)
        template_gate_usage
        return 0
        ;;
      *)
        printf 'unknown arg: %s\n' "$1" >&2
        template_gate_usage
        exit 2
        ;;
    esac
  done

  if [[ -z "$diff_file" || -z "$pr_body_file" ]]; then
    printf 'docs_impact_gate.sh: --diff and --pr-body are required\n' >&2
    template_gate_usage
    exit 2
  fi

  if [[ "$diff_file" == "-" && "$pr_body_file" == "-" ]]; then
    printf 'docs_impact_gate.sh: only one of --diff / --pr-body may read from stdin\n' >&2
    exit 2
  fi

  local diff_raw pr_body_raw guarded_hits guarded_count
  diff_raw=$(template_read_input "$diff_file")
  pr_body_raw=$(template_read_input "$pr_body_file")

  guarded_hits=$(printf '%s\n' "$diff_raw" | template_filter_guarded_paths || true)
  guarded_count=0
  if [[ -n "$guarded_hits" ]]; then
    guarded_count=$(printf '%s\n' "$guarded_hits" | sed '/^$/d' | wc -l | tr -d ' ')
  fi

  template_emit_status() {
    local status=$1 message=$2
    case "$format" in
      json)
        local hits_json
        if [[ -z "$guarded_hits" ]]; then
          hits_json='[]'
        else
          hits_json=$(printf '%s\n' "$guarded_hits" \
            | sed '/^$/d' \
            | awk 'BEGIN{printf "["} NR>1{printf ","} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); printf "\"%s\"", $0} END{printf "]"}')
        fi
        printf '{"status":"%s","guarded_paths_changed":%s,"guarded_hits":%s,"message":"%s"}\n' \
          "$status" "$guarded_count" "$hits_json" \
          "$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        ;;
      *)
        printf 'docs_impact_gate: status=%s guarded_paths=%d %s\n' \
          "$status" "$guarded_count" "$message"
        if [[ -n "$guarded_hits" ]]; then
          printf '%s\n' "$guarded_hits" | sed 's/^/  - /'
        fi
        ;;
    esac
  }

  if [[ "$guarded_count" -eq 0 ]]; then
    template_emit_status "ok" "no guarded paths changed"
    return 0
  fi

  if template_body_has_block "$pr_body_raw"; then
    template_emit_status "ok" "docs-impact block present"
    return 0
  fi

  local gate_mode=${DOCS_IMPACT_GATE_MODE:-block}
  if [[ "$warn_only" -eq 1 || "$gate_mode" == "warn" ]]; then
    template_emit_status "warn" "docs-impact block missing; warning only"
    return 0
  fi

  template_emit_status "block" "docs-impact block missing; required for multi-agent template changes"
  exit 4
}

main() {
  if [[ "$#" -eq 0 ]]; then
    usage
    exit 2
  fi
  local command=$1
  case "$command" in
    classify) shift; cmd_classify "$@" ;;
    summarize) shift; cmd_summarize "$@" ;;
    check) shift; cmd_check "$@" ;;
    declare) shift; cmd_declare "$@" ;;
    render-evidence) shift; cmd_render_evidence "$@" ;;
    -h|--help|help) usage ;;
    --diff|--diff=*|--pr-body|--pr-body=*|--warn-only|--json)
      cmd_template_gate "$@"
      ;;
    *) die "unknown command: $command" ;;
  esac
}

main "$@"
