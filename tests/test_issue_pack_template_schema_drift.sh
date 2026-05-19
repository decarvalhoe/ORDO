#!/usr/bin/env bash
# tests/test_issue_pack_template_schema_drift.sh — schema drift guard for
# the issue-pack child-issue template required headings. Implements
# issue #448 (parent epic #249).
#
# What this asserts:
#   1. templates/issue-pack/child-issue.md retains every canonical level-2
#      heading the EPIC #249 standard handoff flow depends on:
#        - ## Task
#        - ## Ownership Boundaries
#        - ## Acceptance Criteria
#        - ## Validation
#        - ## Risks
#      A quiet rename (e.g. "## Task" -> "## Description") trips this
#      guard before the handoff template silently drifts away from the
#      atomization parser.
#   2. The parser-side helper used by `scripts/dispatch_plan.sh --atomize`
#      still recognizes the one canonical heading the parser must treat
#      as a non-atomize section: "Acceptance Criteria". The check is
#      grep-based against the helper sources because the parser exposes
#      no stable named entry-point for a one-shot string match.
#
# What this does NOT assert:
#   - Headings beyond the canonical set declared in the source ticket.
#   - The order of headings inside the template.
#   - That nuclear-epic.md or issue-pack-ready.md mirror the child-issue
#     heading set; those templates intentionally use a different shape
#     (epic = outcome/scope/grade; notification = payload tables) per
#     docs/issue-pack-handoff.md.
#   - Parsing logic correctness; that is owned by lib/dispatch_plan_headers.sh
#     and its own unit tests.
#
# Exit codes:
#   0 — no drift detected
#   1 — at least one required heading is missing in the template, or the
#       parser-side helper no longer recognizes "Acceptance Criteria"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/templates/issue-pack/child-issue.md"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

[ -s "$TEMPLATE" ] || fail "templates/issue-pack/child-issue.md is missing or empty"

REQUIRED_HEADINGS=(
  '## Task'
  '## Ownership Boundaries'
  '## Acceptance Criteria'
  '## Validation'
  '## Risks'
)

missing=()
for heading in "${REQUIRED_HEADINGS[@]}"; do
  # Match the heading as a full line; anchoring with ^...$ prevents a
  # heading rename like "## Task Plan" from masking a missing "## Task".
  if ! grep -Eq "^${heading}\$" "$TEMPLATE"; then
    missing+=("$heading")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  printf 'templates/issue-pack/child-issue.md is missing %d required heading(s):\n' \
    "${#missing[@]}" >&2
  for heading in "${missing[@]}"; do
    printf '  - %s\n' "$heading" >&2
  done
  printf '\nRestore the heading text exactly as listed, or coordinate the rename with\n' >&2
  printf 'scripts/dispatch_plan.sh --atomize and docs/issue-pack-handoff.md before changing the schema.\n' >&2
  exit 1
fi

# Parser-side cross-check. The atomization parser lives in
# lib/dispatch_plan_headers.sh (sourced by scripts/dispatch_plan.sh); its
# default allowlist must continue to name "acceptance criteria" so that
# checklist items under "## Acceptance Criteria" are treated as
# acceptance, not as new atomizable child tasks. lib/gh_body_helpers.sh
# is the body-write helper and does not parse sections; the ticket
# explicitly allows pivoting to "whichever helper is used by
# dispatch_plan.sh --atomize".
PARSER="$ROOT/lib/dispatch_plan_headers.sh"
if [ ! -s "$PARSER" ]; then
  fail "lib/dispatch_plan_headers.sh is missing or empty — atomization parser source not found"
fi

# Normalization in the parser lowercases and strips punctuation, so the
# allowlist literal is "acceptance criteria" (two words, no markdown).
if ! grep -Eq '^[[:space:]]*acceptance criteria[[:space:]]*$' "$PARSER"; then
  printf 'lib/dispatch_plan_headers.sh no longer lists "acceptance criteria" in its non-atomize allowlist.\n' >&2
  printf 'A rename on either side of the schema (template heading or parser allowlist) will silently\n' >&2
  printf 'break atomization output for the EPIC #249 standard handoff flow.\n' >&2
  exit 1
fi

printf 'ok - test_issue_pack_template_schema_drift (%d required headings present, parser allowlist intact)\n' \
  "${#REQUIRED_HEADINGS[@]}"
