#!/usr/bin/env bash
# lib/atomize_quality_checks.sh — atomic gate-check functions for #766.
#
# Ten independent gate checks consumed by scripts/atomize_quality_gate.sh
# (the standalone classifier) and, in a follow-up issue, by dispatch_plan
# --atomize. Each check is a small pure function:
#
#   * returns 0 on pass, 1 on fail
#   * emits a single structured reason line on stderr when it fails, of
#     the form "reason=<key> detail=<short text>"
#   * does NOT mutate the filesystem, does NOT call gh, does NOT touch
#     state outside the files passed as arguments
#
# The classifier wraps these functions, accumulates reasons, and decides
# pass | warn | refused based on ORCH_ATOMIZE_QUALITY_GATE / --mode.
#
# Parent-issue JSON shape (as produced by `gh issue view N --json
# number,title,body,labels`):
#
#   { "number": 762,
#     "title": "...",
#     "body":  "...",
#     "labels": [ { "name": "priority:P1" }, ... ] }
#
# Child input is two artifacts:
#
#   * a markdown body file (the would-be `gh issue create --body-file`)
#   * an optional labels JSON array (string list); when omitted, labels
#     are parsed from a `Labels:` line at the top of the body
#
# Sibling overlap and duplicate checks consult, when available:
#
#   * scope-claims ledger (#721 sub-A) — JSON object keyed by agent
#   * siblings JSON — array of { "title": "...", "scope_files": [...] }
#     covering open + closed children of the same parent
#
# These two inputs are passed in by the caller; callers without them
# (e.g. a smoke test on a freshly imported ticket) pass /dev/null and
# the checks degrade to no-op pass, which matches the "skip when ledger
# absent" convention used elsewhere in this toolkit.

# ---------------------------------------------------------------------------
# Reason emitter
# ---------------------------------------------------------------------------

# atomize_emit_reason <reason-key> <short-detail>
#
# Single source of truth for the stderr reason format so consumers can
# parse it with a fixed grammar. Keeps detail single-line by replacing
# embedded newlines with spaces.
atomize_emit_reason() {
  local key=${1:?usage: atomize_emit_reason <key> <detail>}
  local detail=${2:-}
  detail=${detail//$'\n'/ }
  printf 'reason=%s detail=%s\n' "$key" "$detail" >&2
}

# ---------------------------------------------------------------------------
# Body parsing helpers
# ---------------------------------------------------------------------------

# atomize_extract_section <body-file> <header-regex>
#
# Print the lines belonging to the section whose header matches
# <header-regex> (an extended-regex anchored to the start of a line).
# The section ends at the next markdown header at the same or shallower
# depth, or at end-of-file. Header line itself is not emitted.
atomize_extract_section() {
  local body=${1:?usage: atomize_extract_section <body-file> <header-regex>}
  local header_re=${2:?usage: atomize_extract_section <body-file> <header-regex>}
  [ -f "$body" ] || return 0
  awk -v re="$header_re" '
    BEGIN { in_block = 0; depth = 0 }
    {
      if (match($0, "^(#+)[[:space:]]+")) {
        cur_depth = RLENGTH - 1
        # match the captured hashes ourselves
        n = 0
        while (substr($0, n + 1, 1) == "#") n++
        cur_depth = n
        if ($0 ~ re) {
          in_block = 1
          depth = cur_depth
          next
        }
        if (in_block == 1 && cur_depth <= depth) {
          in_block = 0
        }
      }
      if (in_block == 1) print
    }
  ' "$body"
}

# atomize_extract_scope_files <body-file>
#
# Print one path per line for the scope declared in the child body. Two
# forms are accepted, matching the two conventions used elsewhere in the
# toolkit:
#
#   scope_files=a/b.sh c/d.sh        (whitespace-separated, one line)
#   - a/b.sh                          (bullet list under the Allowed
#   - c/d.sh                           files (operator-scope) section)
atomize_extract_scope_files() {
  local body=${1:?usage: atomize_extract_scope_files <body-file>}
  [ -f "$body" ] || return 0
  local section
  # form 1: a scope_files=... line anywhere in the body. grep is allowed
  # to find nothing here, so the pipeline is wrapped to always succeed
  # under callers that set -o pipefail.
  { grep -E '^[[:space:]]*scope_files=' "$body" 2>/dev/null \
      | sed -E 's/^[[:space:]]*scope_files=//' \
      | tr ' \t' '\n' \
      | awk 'NF'; } || true
  # form 2: bullets under "Allowed files (operator-scope)"
  section=$(atomize_extract_section "$body" \
    '^#+[[:space:]]+Allowed[[:space:]]+files([[:space:]]*[(]operator-scope[)])?[[:space:]]*$')
  if [ -n "$section" ]; then
    printf '%s\n' "$section" \
      | awk '
          /^[[:space:]]*-[[:space:]]+/ {
            sub(/^[[:space:]]*-[[:space:]]+/, "")
            sub(/[[:space:]]+$/, "")
            if (length($0) > 0) print
          }
        '
  fi
  return 0
}

# atomize_normalize_title <raw-title>
#
# Strip a leading conventional-commit prefix `feat(...):`, collapse
# whitespace, lowercase. Used to fingerprint sibling children and to
# compare titles modulo trivial drift.
atomize_normalize_title() {
  local raw=${1:-}
  printf '%s' "$raw" \
    | sed -E 's/^[[:space:]]*(feat|fix|chore|refactor|test|docs)\([^)]*\):[[:space:]]*//I' \
    | tr '[:upper:]' '[:lower:]' \
    | tr -s '[:space:]' ' ' \
    | sed -E 's/^ //; s/ $//'
}

# atomize_fingerprint <title> <scope-files-multiline>
#
# Stable fingerprint = normalized-title + "|" + sorted-unique scope.
atomize_fingerprint() {
  local title=${1:-}
  local scope_text=${2:-}
  local norm
  norm=$(atomize_normalize_title "$title")
  local sorted
  sorted=$(printf '%s\n' "$scope_text" | awk 'NF' | sort -u | tr '\n' ' ' | sed -E 's/ $//')
  printf '%s|%s' "$norm" "$sorted"
}

# atomize_labels_from_body <body-file>
#
# Extract a labels list from a `Labels:` line in the body header. Emits
# one label per line. Empty when no such line is present.
atomize_labels_from_body() {
  local body=${1:?usage: atomize_labels_from_body <body-file>}
  [ -f "$body" ] || return 0
  { grep -E '^[[:space:]]*Labels:[[:space:]]*' "$body" 2>/dev/null \
      | head -n 1 \
      | sed -E 's/^[[:space:]]*Labels:[[:space:]]*//' \
      | tr ',' '\n' \
      | awk 'NF { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, ""); print }'; } || true
}

# atomize_label_value <labels-multiline> <prefix>
#
# Echo the suffix of the first label that starts with <prefix>. Returns
# empty when no label matches.
atomize_label_value() {
  local labels=${1:-}
  local prefix=${2:?usage: atomize_label_value <labels> <prefix>}
  printf '%s\n' "$labels" \
    | awk -v p="$prefix" '
        index($0, p) == 1 {
          print substr($0, length(p) + 1)
          exit
        }
      '
}

# atomize_parent_priority <parent-json-file>
#
# Echo the priority label value (e.g. "P1") for the parent issue, or
# empty if none.
atomize_parent_priority() {
  local parent=${1:-}
  [ -n "$parent" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$parent" ] || return 0
  jq -r '
    [ (.labels // [])[]
      | (.name // .)
      | tostring
      | select(startswith("priority:"))
      | sub("^priority:"; "")
    ]
    | first // ""
  ' "$parent" 2>/dev/null || true
}

# atomize_parent_number <parent-json-file>
#
# Echo the parent issue number (integer) or empty.
atomize_parent_number() {
  local parent=${1:-}
  [ -n "$parent" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$parent" ] || return 0
  jq -r '.number // empty' "$parent" 2>/dev/null || true
}

# atomize_parent_body_field <parent-json-file>
#
# Echo the parent body markdown to stdout.
atomize_parent_body_field() {
  local parent=${1:-}
  [ -n "$parent" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  [ -f "$parent" ] || return 0
  jq -r '.body // ""' "$parent" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Gate checks
# ---------------------------------------------------------------------------

# 1. atomize_check_scope_declared <child-body>
#
# Child body must declare at least one allowed path under the operator
# scope, either as `scope_files=...` or as a bullet list under the
# Allowed files (operator-scope) section. An empty scope is the
# dispatcher's hard refusal trigger (see #721), so the gate refuses
# rather than warns.
atomize_check_scope_declared() {
  local body=${1:?usage: atomize_check_scope_declared <child-body>}
  local files
  files=$(atomize_extract_scope_files "$body")
  if [ -z "$files" ]; then
    atomize_emit_reason "scope_declared_missing" \
      "child body has no scope_files= line and no Allowed files bullets"
    return 1
  fi
  return 0
}

# 2. atomize_check_no_overlap <child-body> <scope-claims-json>
#
# Child scope_files must not intersect the union of scope_files held by
# OTHER in-flight assignments in the scope-claims ledger. When the
# ledger is missing or empty, the check passes (matches the fail-soft
# convention of dispatch_capacity_scope_claim_files).
atomize_check_no_overlap() {
  local body=${1:?usage: atomize_check_no_overlap <child-body> <ledger>}
  local ledger=${2:-}
  local files
  files=$(atomize_extract_scope_files "$body")
  if [ -z "$files" ]; then
    return 0
  fi
  if [ -z "$ledger" ] || [ ! -s "$ledger" ]; then
    return 0
  fi
  command -v jq >/dev/null 2>&1 || return 0
  local active
  active=$(jq -r '
    [ to_entries[]?
      | (.value.scope_files // [])[]?
    ]
    | unique
    | .[]?
  ' "$ledger" 2>/dev/null || true)
  if [ -z "$active" ]; then
    return 0
  fi
  local clash
  clash=$(comm -12 \
    <(printf '%s\n' "$files" | awk 'NF' | sort -u) \
    <(printf '%s\n' "$active" | awk 'NF' | sort -u) \
    | head -n 5 | tr '\n' ',' | sed -E 's/,$//')
  if [ -n "$clash" ]; then
    atomize_emit_reason "no_overlap_failed" \
      "child scope intersects active siblings: $clash"
    return 1
  fi
  return 0
}

# 3. atomize_check_filiation <child-body> <parent-number> [<labels-multiline>]
#
# Parent traceability requires BOTH a `Parent: #N` line in the child
# body and the `atomized-child` + `parent:#N` labels. Either alone is
# insufficient because dispatchers and search-by-label tools each
# consume only one of the two channels.
atomize_check_filiation() {
  local body=${1:?usage: atomize_check_filiation <child-body> <parent-number> [labels]}
  local parent_num=${2:-}
  local labels=${3:-}
  if [ -z "$parent_num" ]; then
    atomize_emit_reason "filiation_parent_unknown" \
      "parent issue number not provided"
    return 1
  fi
  if ! grep -Eq "^[[:space:]]*Parent:[[:space:]]*#${parent_num}([[:space:]]|$)" "$body" 2>/dev/null; then
    atomize_emit_reason "filiation_body_missing" \
      "child body has no 'Parent: #${parent_num}' line"
    return 1
  fi
  if [ -z "$labels" ]; then
    labels=$(atomize_labels_from_body "$body")
  fi
  if ! printf '%s\n' "$labels" | grep -Fxq "atomized-child"; then
    atomize_emit_reason "filiation_label_missing" \
      "labels miss 'atomized-child'"
    return 1
  fi
  if ! printf '%s\n' "$labels" | grep -Fxq "parent:#${parent_num}"; then
    atomize_emit_reason "filiation_label_missing" \
      "labels miss 'parent:#${parent_num}'"
    return 1
  fi
  return 0
}

# 4. atomize_check_acceptance <child-body>
#
# Child body must contain an Acceptance Criteria section with at least
# two bullets, each non-trivial (more than just whitespace after the
# checkbox or dash). Checkboxes are required because the rest of the
# toolkit treats unchecked DoD items as the verifiable shape.
atomize_check_acceptance() {
  local body=${1:?usage: atomize_check_acceptance <child-body>}
  local section
  section=$(atomize_extract_section "$body" \
    '^#+[[:space:]]+Acceptance[[:space:]]+Criteria[[:space:]]*$')
  if [ -z "$section" ]; then
    atomize_emit_reason "acceptance_section_missing" \
      "child body has no '## Acceptance Criteria' section"
    return 1
  fi
  local count
  count=$(printf '%s\n' "$section" \
    | awk '
        /^[[:space:]]*-[[:space:]]+\[[ xX]\][[:space:]]+[^[:space:]]/ { c++ }
        END { print c + 0 }
      ')
  if [ "${count:-0}" -lt 2 ]; then
    atomize_emit_reason "acceptance_bullets_insufficient" \
      "expected >=2 testable bullets, found ${count:-0}"
    return 1
  fi
  return 0
}

# 5. atomize_check_priority <child-labels> <parent-priority>
#
# Child priority label must be either the parent's priority or exactly
# one notch less critical (parent P_n -> child P_n or P_{n+1}). When
# the parent has no priority label the check passes (nothing to inherit
# from). When the child has no priority label the check fails.
atomize_check_priority() {
  local child_labels=${1:-}
  local parent_priority=${2:-}
  if [ -z "$parent_priority" ]; then
    return 0
  fi
  local child_priority
  child_priority=$(atomize_label_value "$child_labels" "priority:")
  if [ -z "$child_priority" ]; then
    atomize_emit_reason "priority_child_missing" \
      "child has no priority:* label (parent is $parent_priority)"
    return 1
  fi
  local parent_n child_n
  parent_n=$(printf '%s' "$parent_priority" | sed -E 's/^P//')
  child_n=$(printf '%s' "$child_priority" | sed -E 's/^P//')
  if ! [[ "$parent_n" =~ ^[0-9]+$ ]] || ! [[ "$child_n" =~ ^[0-9]+$ ]]; then
    atomize_emit_reason "priority_format_invalid" \
      "expected P<n>, got parent=$parent_priority child=$child_priority"
    return 1
  fi
  if [ "$child_n" -eq "$parent_n" ] || [ "$child_n" -eq "$((parent_n + 1))" ]; then
    return 0
  fi
  atomize_emit_reason "priority_out_of_band" \
    "child $child_priority not in {$parent_priority, P$((parent_n + 1))}"
  return 1
}

# 6. atomize_check_effort <child-labels>
#
# Effort sizing must be explicit (effort:S|M|L). Anything else, including
# absence, fails.
atomize_check_effort() {
  local child_labels=${1:-}
  local value
  value=$(atomize_label_value "$child_labels" "effort:")
  case "$value" in
    S|M|L)
      return 0 ;;
    "")
      atomize_emit_reason "effort_label_missing" \
        "child has no effort:S|M|L label"
      return 1 ;;
    *)
      atomize_emit_reason "effort_label_invalid" \
        "effort:$value not in {S,M,L}"
      return 1 ;;
  esac
}

# 7. atomize_check_title_format <title>
#
# Conventional-commit style title with non-empty type, scope, and
# summary. Accepts the six types used elsewhere in this toolkit's
# commit log (feat, fix, chore, refactor, test, docs).
atomize_check_title_format() {
  local title=${1:-}
  if [ -z "$title" ]; then
    atomize_emit_reason "title_empty" \
      "child title is empty"
    return 1
  fi
  if printf '%s' "$title" \
      | grep -Eq '^(feat|fix|chore|refactor|test|docs)\([a-z0-9_./:#-]+\): .+$'; then
    return 0
  fi
  atomize_emit_reason "title_format_invalid" \
    "expected '<type>(<scope>): <summary>', got: $title"
  return 1
}

# 8. atomize_check_no_duplicate <child-body> <child-title> <siblings-json>
#
# Compute fingerprint = normalized(title) + sorted scope_files and
# refuse when any sibling (open or closed) matches. Siblings JSON is
# an array of { title, scope_files }. When the file is empty / absent
# the check passes (no ledger -> nothing to compare against).
atomize_check_no_duplicate() {
  local body=${1:?usage: atomize_check_no_duplicate <body> <title> <siblings>}
  local title=${2:-}
  local siblings=${3:-}
  if [ -z "$siblings" ] || [ ! -s "$siblings" ]; then
    return 0
  fi
  command -v jq >/dev/null 2>&1 || return 0
  local scope_text fp_self
  scope_text=$(atomize_extract_scope_files "$body")
  fp_self=$(atomize_fingerprint "$title" "$scope_text")
  # Walk the siblings file with a fingerprint comparison done in
  # bash so the helper stays portable across jq versions (the older
  # `gsub`/`ascii_downcase` combos vary in support).
  local i count
  count=$(jq 'length' "$siblings" 2>/dev/null || printf '0')
  i=0
  while [ "$i" -lt "${count:-0}" ]; do
    local s_title s_scope fp_other
    s_title=$(jq -r ".[$i].title // \"\"" "$siblings" 2>/dev/null)
    s_scope=$(jq -r ".[$i].scope_files // [] | .[]?" "$siblings" 2>/dev/null)
    fp_other=$(atomize_fingerprint "$s_title" "$s_scope")
    if [ "$fp_self" = "$fp_other" ]; then
      atomize_emit_reason "no_duplicate_failed" \
        "fingerprint collides with sibling: $s_title"
      return 1
    fi
    i=$((i + 1))
  done
  return 0
}

# 9. atomize_check_test_plan <child-body>
#
# A child must declare at least one verifiable Test plan checkbox.
atomize_check_test_plan() {
  local body=${1:?usage: atomize_check_test_plan <body>}
  local section
  section=$(atomize_extract_section "$body" \
    '^#+[[:space:]]+Test[[:space:]]+plan[[:space:]]*$')
  if [ -z "$section" ]; then
    atomize_emit_reason "test_plan_section_missing" \
      "child body has no '## Test plan' section"
    return 1
  fi
  if ! printf '%s\n' "$section" \
      | grep -Eq '^[[:space:]]*-[[:space:]]+\[[ xX]\][[:space:]]+[^[:space:]]'; then
    atomize_emit_reason "test_plan_checkbox_missing" \
      "Test plan section has no '- [ ]' bullets"
    return 1
  fi
  return 0
}

# 10. atomize_check_dependency_graph <child-body> <parent-json>
#
# If the child declares `Depends on: #X`, the parent's "Atomic tasks"
# section must list #X strictly before this child. The check only
# requires #X to appear in the parent's Atomic tasks list; ordering is
# enforced by line position. When the child declares no dependency the
# check passes.
atomize_check_dependency_graph() {
  local body=${1:?usage: atomize_check_dependency_graph <body> <parent-json>}
  local parent=${2:-}
  local deps
  deps=$(grep -E '^[[:space:]]*Depends[[:space:]]+on:[[:space:]]*' "$body" 2>/dev/null \
    | head -n 1 \
    | sed -E 's/^[[:space:]]*Depends[[:space:]]+on:[[:space:]]*//' \
    | grep -oE '#[0-9]+' \
    | sed -E 's/^#//' || true)
  if [ -z "$deps" ]; then
    return 0
  fi
  if [ -z "$parent" ] || [ ! -s "$parent" ]; then
    atomize_emit_reason "dependency_parent_unknown" \
      "child Depends on declared but parent JSON unavailable"
    return 1
  fi
  command -v jq >/dev/null 2>&1 || return 0
  local parent_body atomic
  parent_body=$(atomize_parent_body_field "$parent")
  if [ -z "$parent_body" ]; then
    atomize_emit_reason "dependency_parent_body_empty" \
      "parent issue body is empty"
    return 1
  fi
  local tmp
  tmp=$(mktemp 2>/dev/null) || return 1
  printf '%s\n' "$parent_body" > "$tmp"
  atomic=$(atomize_extract_section "$tmp" \
    '^#+[[:space:]]+Atomic[[:space:]]+tasks[[:space:]]*$')
  rm -f "$tmp"
  if [ -z "$atomic" ]; then
    atomize_emit_reason "dependency_atomic_section_missing" \
      "parent body has no 'Atomic tasks' section"
    return 1
  fi
  local dep
  for dep in $deps; do
    if ! printf '%s\n' "$atomic" | grep -Eq "#${dep}([[:space:]]|$|[^0-9])"; then
      atomize_emit_reason "dependency_not_in_atomic" \
        "parent Atomic tasks does not list #${dep}"
      return 1
    fi
  done
  return 0
}

# atomize_quality_checks_loaded — marker used by tests to confirm the
# library sourced cleanly under `set -u`.
atomize_quality_checks_loaded() {
  printf 'atomize_quality_checks_loaded\n'
}
