#!/usr/bin/env bash
# dispatch_plan_headers.sh — header-aware allowlist for dispatch_plan
# atomization.
#
# Sourced by scripts/dispatch_plan.sh. Provides the non-atomize header
# allowlist (English + French defaults, plus a project-level
# DISPATCH_PLAN_NON_ATOMIZE_HEADERS override) and the body walker that
# extracts only atomizable checklist items, skipping items that sit under
# acceptance / definition-of-done style sections.
#
# Issue #294: bilingual repositories produced false-positive atomization on
# valid acceptance checklists because the original allowlist was English-only
# and hand-maintained.

# Normalize a markdown header line for comparison:
#   - drop leading `#` markers, asterisks, underscores, whitespace
#   - drop trailing colon, asterisks, underscores, whitespace
#   - fold common Latin-script diacritics to their ASCII base
#   - lowercase
#   - replace any non-[a-z0-9] run with a single space
#   - collapse whitespace and trim
#
# Examples:
#   "## Acceptance Criteria"       -> "acceptance criteria"
#   "### Critères d'acceptation:"  -> "criteres d acceptation"
#   "## **Definition of Done**"    -> "definition of done"
dispatch_plan_normalize_header_line() {
  local line=${1:-}
  printf '%s' "$line" \
    | sed -E 's/^[[:space:]]*#+[[:space:]]*//' \
    | sed -E 's/[[:space:]]*[:*_]+[[:space:]]*$//' \
    | sed -E 's/[Éé]/e/g; s/[Èè]/e/g; s/[Êê]/e/g; s/[Ëë]/e/g;
              s/[Àà]/a/g; s/[Ââ]/a/g; s/[Ää]/a/g;
              s/[Çç]/c/g;
              s/[Îî]/i/g; s/[Ïï]/i/g;
              s/[Ôô]/o/g; s/[Öö]/o/g;
              s/[Ùù]/u/g; s/[Ûû]/u/g; s/[Üü]/u/g;
              s/[Ÿÿ]/y/g;
              s/[ñÑ]/n/g' \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//'
}

# Bilingual default allowlist of headers that mark a non-atomization section.
# One normalized form per line. Add entries here when a generally useful
# variant is missing; project-specific variants belong in
# DISPATCH_PLAN_NON_ATOMIZE_HEADERS instead.
dispatch_plan_default_non_atomize_headers() {
  cat <<'EOF'
acceptance criteria
acceptance
definition of done
done definition
definition of ready
done criteria
dod
criteres d acceptation
criteres d acceptance
criteres dacceptation
criteres d acceptabilite
definition de fini
definition de termine
definition de pret
criteres de validation
verification criteria
verification
validation criteria
EOF
}

# Effective allowlist = defaults + DISPATCH_PLAN_NON_ATOMIZE_HEADERS, each
# entry passed through the same normalization as the body header. Entries in
# DISPATCH_PLAN_NON_ATOMIZE_HEADERS may be separated by newlines, commas, or
# semicolons; surrounding whitespace is trimmed.
dispatch_plan_non_atomize_headers() {
  dispatch_plan_default_non_atomize_headers \
    | while IFS= read -r entry || [[ -n "$entry" ]]; do
        [[ -n "$entry" ]] || continue
        dispatch_plan_normalize_header_line "$entry"
        printf '\n'
      done

  if [[ -n "${DISPATCH_PLAN_NON_ATOMIZE_HEADERS:-}" ]]; then
    printf '%s\n' "$DISPATCH_PLAN_NON_ATOMIZE_HEADERS" \
      | tr ',;' '\n' \
      | while IFS= read -r entry || [[ -n "$entry" ]]; do
          entry=${entry#"${entry%%[![:space:]]*}"}
          entry=${entry%"${entry##*[![:space:]]}"}
          [[ -n "$entry" ]] || continue
          dispatch_plan_normalize_header_line "$entry"
          printf '\n'
        done
  fi
}

# Return 0 when the (raw) header line should mark a non-atomization section.
# Comparison is against the normalized form of every allowlist entry.
dispatch_plan_is_non_atomize_header() {
  local header_line=${1:-}
  local normalized
  normalized=$(dispatch_plan_normalize_header_line "$header_line")
  [[ -n "$normalized" ]] || return 1

  local entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    if [[ "$normalized" == "$entry" ]]; then
      return 0
    fi
  done < <(dispatch_plan_non_atomize_headers)
  return 1
}

# Header-aware checklist extractor. Walks the issue body line by line,
# tracks the current section, and emits only `- [ ]` items that sit OUTSIDE
# a non-atomize section. The first line of the body counts as the
# "atomize" zone (no header yet), so checklists that appear before any
# header are still extracted — this preserves the original behavior for
# issues that do not use sections at all.
#
# The section flag flips on every header line: a non-atomize header enters
# the skip zone, any other header exits it. There is no nesting model; a
# `### Sub-section` under `## Acceptance Criteria` stays in the skip zone
# until another header at any level appears.
dispatch_plan_atomize_tasks() {
  local body=${1:-}
  local in_skip=0
  local line trimmed item

  while IFS= read -r line || [[ -n "$line" ]]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    if [[ "$trimmed" =~ ^#+[[:space:]] ]] || [[ "$trimmed" =~ ^#+$ ]]; then
      if dispatch_plan_is_non_atomize_header "$trimmed"; then
        in_skip=1
      else
        in_skip=0
      fi
      continue
    fi
    if [[ "$in_skip" -eq 1 ]]; then
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\][[:space:]]+(.+)$ ]]; then
      item=${BASH_REMATCH[1]}
      printf '%s\n' "$item"
    fi
  done <<< "$body"
}
