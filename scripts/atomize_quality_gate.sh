#!/usr/bin/env bash
# scripts/atomize_quality_gate.sh — atomize child-issue quality classifier (#766).
#
# Standalone CLI wrapping lib/atomize_quality_checks.sh. Reads a proposed
# child-issue body + the parent issue JSON, runs the ten gate checks,
# and emits a single outcome on stdout:
#
#     pass | warn | refused
#
# with a reason key per failed check. No mutations: this PR ships only
# classification. The auto-create caller (filed as a follow-up to #766)
# decides whether to refuse, warn, or override based on the operator's
# ORCH_ATOMIZE_QUALITY_GATE setting.
#
# Usage:
#
#   scripts/atomize_quality_gate.sh classify-child \
#       --parent-issue-json /tmp/parent.json \
#       --child-body /tmp/child.md \
#       [--child-title "<conv-commit title>"] \
#       [--child-labels-json /tmp/labels.json] \
#       [--scope-claims-json /tmp/claims.json] \
#       [--siblings-json /tmp/siblings.json] \
#       [--mode warn|enforce|off] \
#       [--format tsv|json]
#
#   scripts/atomize_quality_gate.sh check <name> --child-body FILE [...]
#       Run a single named check and exit 0/1 with the reason on stderr.
#       <name> is the gate suffix (scope_declared, no_overlap, ...).
#
# Mode resolution: --mode flag > ORCH_ATOMIZE_QUALITY_GATE env > "warn".
#
# Exit codes:
#
#   0   on pass, warn, or off (so the CLI does not break warn-mode
#       callers that pipe stdout into a logger)
#   1   on refused (mode=enforce and at least one check failed)
#   2   on usage error (missing required file, unknown subcommand)
#
# Output format defaults to TSV for cheap shell consumption; --format
# json emits one compact JSON object on stdout.

set -euo pipefail

TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../lib/atomize_quality_checks.sh
. "$TK/lib/atomize_quality_checks.sh"

atomize_gate_usage() {
  cat <<'USAGE'
Usage:
  atomize_quality_gate.sh classify-child \
      --parent-issue-json FILE --child-body FILE \
      [--child-title TITLE] [--child-labels-json FILE] \
      [--scope-claims-json FILE] [--siblings-json FILE] \
      [--mode warn|enforce|off] [--format tsv|json]
  atomize_quality_gate.sh check <name> --child-body FILE [...]
USAGE
}

atomize_gate_die() {
  printf 'atomize_quality_gate.sh: %s\n' "$*" >&2
  exit 2
}

atomize_gate_resolve_mode() {
  local cli_mode=${1:-}
  local mode
  if [ -n "$cli_mode" ]; then
    mode=$cli_mode
  elif [ -n "${ORCH_ATOMIZE_QUALITY_GATE:-}" ]; then
    mode=${ORCH_ATOMIZE_QUALITY_GATE}
  else
    mode=warn
  fi
  case "$mode" in
    off|warn|enforce) printf '%s' "$mode" ;;
    *) atomize_gate_die "invalid mode '$mode' (expected off|warn|enforce)" ;;
  esac
}

atomize_gate_resolve_labels() {
  local labels_json=${1:-}
  local body=${2:-}
  if [ -n "$labels_json" ] && [ -s "$labels_json" ]; then
    if command -v jq >/dev/null 2>&1; then
      jq -r '.[]?' "$labels_json" 2>/dev/null
      return 0
    fi
  fi
  if [ -n "$body" ] && [ -f "$body" ]; then
    atomize_labels_from_body "$body"
  fi
}

atomize_gate_resolve_title() {
  local cli_title=${1:-}
  local body=${2:-}
  if [ -n "$cli_title" ]; then
    printf '%s' "$cli_title"
    return 0
  fi
  if [ -n "$body" ] && [ -f "$body" ]; then
    # Prefer an explicit `Title:` header at the top of the body; fall
    # back to the first markdown H1. grep is permitted to find nothing,
    # so the pipelines are wrapped in `|| true` to avoid tripping the
    # caller's `set -o pipefail`.
    local title
    title=$({ grep -E '^[[:space:]]*Title:[[:space:]]*' "$body" 2>/dev/null \
      | head -n 1 \
      | sed -E 's/^[[:space:]]*Title:[[:space:]]*//'; } || true)
    if [ -z "$title" ]; then
      title=$({ grep -E '^#[[:space:]]+' "$body" 2>/dev/null \
        | head -n 1 \
        | sed -E 's/^#[[:space:]]+//'; } || true)
    fi
    printf '%s' "$title"
  fi
}

atomize_gate_run_one() {
  local name=$1
  shift
  local parent_json=$1 child_body=$2 child_title=$3 child_labels=$4 claims=$5 siblings=$6
  local parent_priority parent_number
  parent_priority=$(atomize_parent_priority "$parent_json" 2>/dev/null || true)
  parent_number=$(atomize_parent_number "$parent_json" 2>/dev/null || true)
  case "$name" in
    scope_declared)    atomize_check_scope_declared    "$child_body" ;;
    no_overlap)        atomize_check_no_overlap        "$child_body" "$claims" ;;
    filiation)         atomize_check_filiation         "$child_body" "$parent_number" "$child_labels" ;;
    acceptance)        atomize_check_acceptance        "$child_body" ;;
    priority)          atomize_check_priority          "$child_labels" "$parent_priority" ;;
    effort)            atomize_check_effort            "$child_labels" ;;
    title_format)      atomize_check_title_format      "$child_title" ;;
    no_duplicate)      atomize_check_no_duplicate      "$child_body" "$child_title" "$siblings" ;;
    test_plan)         atomize_check_test_plan         "$child_body" ;;
    dependency_graph)  atomize_check_dependency_graph  "$child_body" "$parent_json" ;;
    *) atomize_gate_die "unknown check '$name'" ;;
  esac
}

ATOMIZE_GATE_CHECKS=(
  scope_declared
  no_overlap
  filiation
  acceptance
  priority
  effort
  title_format
  no_duplicate
  test_plan
  dependency_graph
)

atomize_gate_emit_tsv() {
  local outcome=$1
  local mode=$2
  local reasons=$3
  local checks=$4
  printf '%s\t%s\t%s\t%s\n' "$outcome" "$mode" "$reasons" "$checks"
}

atomize_gate_emit_json() {
  local outcome=$1
  local mode=$2
  local reasons_csv=$3
  local checks_csv=$4
  command -v jq >/dev/null 2>&1 || {
    # Fallback hand-roll: outcome and mode are constrained tokens; csv
    # contents are gate keys / reasons that we control.
    printf '{"outcome":"%s","mode":"%s","reasons":[%s],"checks":[%s]}\n' \
      "$outcome" "$mode" \
      "$(printf '%s' "$reasons_csv" | awk -v RS=',' 'NF { printf "%s\"%s\"", (first++ ? "," : ""), $0 }')" \
      "$(printf '%s' "$checks_csv" | awk -v RS=',' 'NF {
          split($0, kv, "="); printf "%s{\"name\":\"%s\",\"status\":\"%s\"}", (first++ ? "," : ""), kv[1], kv[2]
        }')"
    return 0
  }
  jq -c -n \
    --arg outcome "$outcome" \
    --arg mode "$mode" \
    --arg reasons "$reasons_csv" \
    --arg checks "$checks_csv" \
    '{
       outcome: $outcome,
       mode: $mode,
       reasons: ($reasons | split(",") | map(select(length > 0))),
       checks: ($checks | split(",") | map(select(length > 0))
                | map(split("=") | {name: .[0], status: .[1]}))
     }'
}

atomize_gate_classify_child() {
  local parent_json="" child_body="" child_title="" child_labels_json="" claims="" siblings=""
  local mode_arg="" format="tsv"
  while [ $# -gt 0 ]; do
    case "$1" in
      --parent-issue-json)  parent_json=${2:?--parent-issue-json takes a path}; shift 2 ;;
      --child-body)         child_body=${2:?--child-body takes a path};         shift 2 ;;
      --child-title)        child_title=${2:?--child-title takes a value};      shift 2 ;;
      --child-labels-json)  child_labels_json=${2:?--child-labels-json takes a path}; shift 2 ;;
      --scope-claims-json)  claims=${2:?--scope-claims-json takes a path};      shift 2 ;;
      --siblings-json)      siblings=${2:?--siblings-json takes a path};        shift 2 ;;
      --mode)               mode_arg=${2:?--mode takes a value};                shift 2 ;;
      --format)             format=${2:?--format takes tsv|json};               shift 2 ;;
      -h|--help)            atomize_gate_usage; exit 0 ;;
      *) atomize_gate_die "unknown classify-child flag '$1'" ;;
    esac
  done
  [ -n "$parent_json" ] || atomize_gate_die "--parent-issue-json is required"
  [ -n "$child_body" ]  || atomize_gate_die "--child-body is required"
  [ -f "$parent_json" ] || atomize_gate_die "--parent-issue-json file not found: $parent_json"
  [ -f "$child_body" ]  || atomize_gate_die "--child-body file not found: $child_body"
  case "$format" in
    tsv|json) ;;
    *) atomize_gate_die "invalid --format '$format' (expected tsv|json)" ;;
  esac

  local mode
  mode=$(atomize_gate_resolve_mode "$mode_arg")

  if [ "$mode" = "off" ]; then
    if [ "$format" = "json" ]; then
      atomize_gate_emit_json "pass" "off" "" ""
    else
      atomize_gate_emit_tsv  "pass" "off" "" ""
    fi
    return 0
  fi

  local labels title
  labels=$(atomize_gate_resolve_labels "$child_labels_json" "$child_body")
  title=$(atomize_gate_resolve_title "$child_title" "$child_body")

  local reasons_csv="" checks_csv="" failures=0 check
  for check in "${ATOMIZE_GATE_CHECKS[@]}"; do
    local reason_capture
    if reason_capture=$(atomize_gate_run_one "$check" \
        "$parent_json" "$child_body" "$title" "$labels" "$claims" "$siblings" 2>&1 >/dev/null); then
      checks_csv+="${check}=pass,"
    else
      failures=$((failures + 1))
      local key=""
      key=$(printf '%s' "$reason_capture" \
        | awk -F'[ =]+' '/^reason=/ { print $2; exit }')
      [ -n "$key" ] || key="${check}_failed"
      reasons_csv+="${key},"
      checks_csv+="${check}=fail,"
      # Re-emit the structured reason so callers piping 2>&1 can see it.
      printf '%s\n' "$reason_capture" >&2
    fi
  done
  reasons_csv=${reasons_csv%,}
  checks_csv=${checks_csv%,}

  local outcome rc
  if [ "$failures" -eq 0 ]; then
    outcome="pass"; rc=0
  elif [ "$mode" = "enforce" ]; then
    outcome="refused"; rc=1
  else
    outcome="warn"; rc=0
  fi

  if [ "$format" = "json" ]; then
    atomize_gate_emit_json "$outcome" "$mode" "$reasons_csv" "$checks_csv"
  else
    atomize_gate_emit_tsv  "$outcome" "$mode" "$reasons_csv" "$checks_csv"
  fi
  return "$rc"
}

atomize_gate_check_one() {
  local name=${1:-}
  shift || true
  [ -n "$name" ] || atomize_gate_die "check requires a check name"
  local parent_json="" child_body="" child_title="" child_labels_json="" claims="" siblings=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --parent-issue-json)  parent_json=$2;       shift 2 ;;
      --child-body)         child_body=$2;        shift 2 ;;
      --child-title)        child_title=$2;       shift 2 ;;
      --child-labels-json)  child_labels_json=$2; shift 2 ;;
      --scope-claims-json)  claims=$2;            shift 2 ;;
      --siblings-json)      siblings=$2;          shift 2 ;;
      -h|--help)            atomize_gate_usage; exit 0 ;;
      *) atomize_gate_die "unknown check flag '$1'" ;;
    esac
  done
  local labels title
  labels=$(atomize_gate_resolve_labels "$child_labels_json" "$child_body")
  title=$(atomize_gate_resolve_title "$child_title" "$child_body")
  atomize_gate_run_one "$name" \
    "$parent_json" "$child_body" "$title" "$labels" "$claims" "$siblings"
}

main() {
  local sub=${1:-}
  if [ -z "$sub" ] || [ "$sub" = "-h" ] || [ "$sub" = "--help" ]; then
    atomize_gate_usage
    [ -z "$sub" ] && exit 2 || exit 0
  fi
  shift
  case "$sub" in
    classify-child) atomize_gate_classify_child "$@" ;;
    check)          atomize_gate_check_one      "$@" ;;
    *)              atomize_gate_die "unknown subcommand '$sub'" ;;
  esac
}

main "$@"
