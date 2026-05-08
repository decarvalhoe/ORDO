#!/usr/bin/env bash
# scripts/docs_impact_gate.sh — guard PRs that touch multi-agent templates
# without rendering the docs-impact checklist (#316).
#
# Background:
#   docs/templates/multi-agent/docs-impact.md defines a checklist that PR
#   authors should render in the PR body whenever they change one of the
#   multi-agent templates. The checklist is enforced manually today, which
#   means template behavior and downstream onboarding docs can drift without
#   a traceable docs-impact record.
#
# Behavior:
#   1. Read the list of changed paths (from a file or stdin).
#   2. Filter for paths under DOCS_IMPACT_GUARDED_PATHS (default:
#      docs/templates/multi-agent/). Globs supported.
#   3. If any guarded path was changed, scan the PR body for a docs-impact
#      block — a markdown header matching DOCS_IMPACT_BLOCK_HEADERS followed
#      by at least one `- [ ]` or `- [x]` checklist item.
#   4. Exit:
#        0   no guarded paths changed (no-op).
#        0   guarded paths changed AND the block is present.
#        4   guarded paths changed AND the block is missing
#            (override with --warn-only or DOCS_IMPACT_GATE_MODE=warn to
#            keep the message but exit 0).
#
# Usage:
#   bash scripts/docs_impact_gate.sh \
#     --diff <file>          # one changed path per line; "-" reads stdin
#     --pr-body <file>       # PR body text; "-" reads stdin
#     [--warn-only]          # downgrade missing-block to warning
#     [--json]               # JSON status output instead of text
#
# Either --diff or --pr-body may use "-" but not both.
#
# Env knobs:
#   DOCS_IMPACT_GUARDED_PATHS  Newline / comma / semicolon separated list of
#                              path prefixes (or globs) that trigger the gate.
#                              Default: docs/templates/multi-agent/
#   DOCS_IMPACT_BLOCK_HEADERS  Pipe-separated regex alternation of headers
#                              that count as a docs-impact block.
#                              Default: Docs Impact|Documentation Impact|Impact docs|Impact documentation
#   DOCS_IMPACT_GATE_MODE      "block" (default) or "warn". --warn-only wins.
set -euo pipefail

DEFAULT_GUARDED_PATHS='docs/templates/multi-agent/'
DEFAULT_BLOCK_HEADERS='Docs Impact|Documentation Impact|Impact docs|Impact documentation'

usage() {
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

DIFF_FILE=""
PR_BODY_FILE=""
WARN_ONLY=0
FORMAT="text"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --diff)
      DIFF_FILE=${2:?missing value for --diff}
      shift 2
      ;;
    --diff=*)
      DIFF_FILE=${1#--diff=}
      shift
      ;;
    --pr-body)
      PR_BODY_FILE=${2:?missing value for --pr-body}
      shift 2
      ;;
    --pr-body=*)
      PR_BODY_FILE=${1#--pr-body=}
      shift
      ;;
    --warn-only)
      WARN_ONLY=1
      shift
      ;;
    --json)
      FORMAT="json"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown arg: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$DIFF_FILE" || -z "$PR_BODY_FILE" ]]; then
  printf 'docs_impact_gate.sh: --diff and --pr-body are required\n' >&2
  usage
  exit 2
fi

if [[ "$DIFF_FILE" == "-" && "$PR_BODY_FILE" == "-" ]]; then
  printf 'docs_impact_gate.sh: only one of --diff / --pr-body may read from stdin\n' >&2
  exit 2
fi

read_input() {
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
guarded_paths_list() {
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
path_is_guarded() {
  local path=$1 entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if [[ "$entry" == *'*'* || "$entry" == *'?'* || "$entry" == *'['*']'* ]]; then
      # Treat entry as a glob pattern.
      # shellcheck disable=SC2053  # intentional glob match
      if [[ "$path" == $entry ]]; then
        return 0
      fi
    else
      # Treat entry as a path prefix. A trailing slash means directory match.
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
  done < <(guarded_paths_list)
  return 1
}

filter_guarded_paths() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -n "$line" ]] || continue
    [[ "$line" == \#* ]] && continue
    if path_is_guarded "$line"; then
      printf '%s\n' "$line"
    fi
  done
}

# Effective header alternation. Defaults are pipe-separated regexes; the
# override is appended with a `|` so callers can extend without losing the
# defaults.
block_header_pattern() {
  local override=${DOCS_IMPACT_BLOCK_HEADERS:-}
  if [[ -n "$override" ]]; then
    printf '%s|%s' "$DEFAULT_BLOCK_HEADERS" "$override"
  else
    printf '%s' "$DEFAULT_BLOCK_HEADERS"
  fi
}

# Returns 0 when the body contains a docs-impact block: a markdown header
# whose text matches block_header_pattern, followed (within 60 lines, after
# zero or more blank/comment lines) by at least one `- [ ]` or `- [x]`
# checklist item before the next header at the same or higher level.
body_has_block() {
  local body=$1
  local headers
  headers=$(block_header_pattern)
  # awk gives clean state-machine semantics across the body. We do not rely
  # on multiline bash regex to keep behavior identical across bash versions.
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
        # Header line.
        if (line ~ header_re) {
          in_block = 1
          remaining = 60
          next
        } else if (in_block == 1) {
          # A different header ends the block scan without finding a checklist.
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

DIFF_RAW=$(read_input "$DIFF_FILE")
if [[ "$PR_BODY_FILE" == "-" && "$DIFF_FILE" == "-" ]]; then
  : # already refused above
fi
PR_BODY_RAW=$(read_input "$PR_BODY_FILE")

GUARDED_HITS=$(printf '%s\n' "$DIFF_RAW" | filter_guarded_paths || true)
GUARDED_COUNT=0
if [[ -n "$GUARDED_HITS" ]]; then
  GUARDED_COUNT=$(printf '%s\n' "$GUARDED_HITS" | sed '/^$/d' | wc -l | tr -d ' ')
fi

emit_status() {
  local status=$1 message=$2
  case "$FORMAT" in
    json)
      local hits_json
      if [[ -z "$GUARDED_HITS" ]]; then
        hits_json='[]'
      else
        hits_json=$(printf '%s\n' "$GUARDED_HITS" \
          | sed '/^$/d' \
          | awk 'BEGIN{printf "["} NR>1{printf ","} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); printf "\"%s\"", $0} END{printf "]"}')
      fi
      printf '{"status":"%s","guarded_paths_changed":%s,"guarded_hits":%s,"message":"%s"}\n' \
        "$status" "$GUARDED_COUNT" "$hits_json" \
        "$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      ;;
    *)
      printf 'docs_impact_gate: status=%s guarded_paths=%d %s\n' \
        "$status" "$GUARDED_COUNT" "$message"
      if [[ -n "$GUARDED_HITS" ]]; then
        printf '%s\n' "$GUARDED_HITS" | sed 's/^/  - /'
      fi
      ;;
  esac
}

if [[ "$GUARDED_COUNT" -eq 0 ]]; then
  emit_status "ok" "no guarded paths changed"
  exit 0
fi

if body_has_block "$PR_BODY_RAW"; then
  emit_status "ok" "docs-impact block present"
  exit 0
fi

GATE_MODE=${DOCS_IMPACT_GATE_MODE:-block}
if [[ "$WARN_ONLY" -eq 1 || "$GATE_MODE" == "warn" ]]; then
  emit_status "warn" "docs-impact block missing; warning only"
  exit 0
fi

emit_status "block" "docs-impact block missing; required for multi-agent template changes"
exit 4
