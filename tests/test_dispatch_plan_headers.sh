#!/usr/bin/env bash
# tests/test_dispatch_plan_headers.sh — header-aware atomization extractor (#294).
#
# Covers:
#   - dispatch_plan_normalize_header_line: strips markdown markers, folds
#     diacritics, lowercases, collapses non-alphanumerics.
#   - dispatch_plan_is_non_atomize_header: matches English defaults, French
#     defaults, accent-stripped variants, missing-apostrophe variants, and
#     custom DISPATCH_PLAN_NON_ATOMIZE_HEADERS overrides.
#   - dispatch_plan_atomize_tasks: returns only items outside non-atomize
#     sections; English-only, French-only, bilingual, and pre-header
#     fixtures all yield the expected counts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/dispatch_plan_headers.sh
source "$ROOT/lib/dispatch_plan_headers.sh"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

count_lines() {
  local s=$1
  if [[ -z "$s" ]]; then
    printf '0\n'
    return
  fi
  printf '%s\n' "$s" | sed '/^$/d' | wc -l | tr -d ' '
}

# --- normalize_header_line ----------------------------------------------------

assert_normalize() {
  local input=$1 expected=$2 got
  got=$(dispatch_plan_normalize_header_line "$input")
  [[ "$got" == "$expected" ]] \
    || fail "normalize($input) -> '$got', expected '$expected'"
}

assert_normalize "## Acceptance Criteria"          "acceptance criteria"
assert_normalize "###Acceptance Criteria"          "acceptance criteria"
assert_normalize "## **Definition of Done**"       "definition of done"
assert_normalize "## Definition of done:"          "definition of done"
assert_normalize "## Critères d'acceptation"       "criteres d acceptation"
assert_normalize "### Critères d acceptation"      "criteres d acceptation"
assert_normalize "## Criteres d'acceptation"       "criteres d acceptation"
assert_normalize "## Définition de fini"           "definition de fini"
assert_normalize "## Definition de fini"           "definition de fini"
assert_normalize "## Critères de validation"       "criteres de validation"
assert_normalize "##  Acceptance  Criteria  "      "acceptance criteria"

# --- is_non_atomize_header ----------------------------------------------------

assert_skip() {
  local input=$1
  dispatch_plan_is_non_atomize_header "$input" \
    || fail "is_non_atomize_header('$input') should match"
}

assert_atomize() {
  local input=$1
  if dispatch_plan_is_non_atomize_header "$input"; then
    fail "is_non_atomize_header('$input') must NOT match"
  fi
}

# English defaults
assert_skip "## Acceptance Criteria"
assert_skip "### Acceptance"
assert_skip "## Definition of Done"
assert_skip "## Definition of done:"
assert_skip "## Definition of Ready"
assert_skip "## DoD"
assert_skip "## Done Criteria"
assert_skip "## Verification Criteria"
assert_skip "## Validation Criteria"

# French defaults — apostrophe variants and accent-stripped variants both work.
assert_skip "## Critères d'acceptation"
assert_skip "## Critères d'acceptation"   # curly apostrophe
assert_skip "## Critères d acceptation"
assert_skip "## Criteres d'acceptation"
assert_skip "## Criteres d acceptation"
assert_skip "## Définition de fini"
assert_skip "## Definition de fini"
assert_skip "## Définition de terminé"
assert_skip "## Définition de prêt"
assert_skip "## Critères de validation"
assert_skip "## Critères d'acceptabilité"

# Headers that should NOT be skipped — atomization-eligible.
assert_atomize "## Tasks"
assert_atomize "## Subtasks"
assert_atomize "## TODO"
assert_atomize "## Implementation Steps"
assert_atomize "## Travaux à faire"
assert_atomize "## Notes"

# Custom override extends the allowlist without losing defaults.
export DISPATCH_PLAN_NON_ATOMIZE_HEADERS=$'Validation Steps\nGate Criteria'
assert_skip "## Validation Steps"
assert_skip "## Gate Criteria"
assert_skip "## Acceptance Criteria"   # default still active
unset DISPATCH_PLAN_NON_ATOMIZE_HEADERS

# Override accepts comma and semicolon separators.
export DISPATCH_PLAN_NON_ATOMIZE_HEADERS='Procès-verbal,Étapes de validation; Critères qualité'
assert_skip "## Procès-verbal"
assert_skip "## Étapes de validation"
assert_skip "## Critères qualité"
unset DISPATCH_PLAN_NON_ATOMIZE_HEADERS

# --- atomize_tasks: end-to-end fixtures ---------------------------------------

# Pre-header items count as atomization tasks (no skip yet).
body_pre_header='Intro paragraph.

- [ ] Task one
- [ ] Task two
'
got=$(dispatch_plan_atomize_tasks "$body_pre_header")
[[ "$(count_lines "$got")" == "2" ]] \
  || fail "pre-header expected 2 tasks, got: $got"

# English-only acceptance section: items inside should not count.
body_english='## Acceptance Criteria
- [ ] Tests pass
- [ ] Docs updated
- [ ] Release notes added

## Tasks
- [ ] Implement feature
- [ ] Wire CLI flag
'
got=$(dispatch_plan_atomize_tasks "$body_english")
[[ "$(count_lines "$got")" == "2" ]] \
  || fail "english fixture expected 2 atomize tasks, got: $got"
[[ "$got" == *"Implement feature"* ]] \
  || fail "english fixture should keep Implement feature, got: $got"
[[ "$got" != *"Tests pass"* ]] \
  || fail "english fixture must not include acceptance items, got: $got"

# French-only acceptance section: zero atomization tasks expected.
body_french='## Critères d'\''acceptation
- [ ] Tests réussis
- [ ] Doc mise à jour
- [ ] Notes de version ajoutées
'
got=$(dispatch_plan_atomize_tasks "$body_french")
[[ "$(count_lines "$got")" == "0" ]] \
  || fail "french fixture expected 0 atomize tasks, got: $got"

# French Definition of Done variant.
body_dod_fr='## Définition de fini
- [ ] Compilation OK
- [ ] Tests OK
'
got=$(dispatch_plan_atomize_tasks "$body_dod_fr")
[[ "$(count_lines "$got")" == "0" ]] \
  || fail "french DoD fixture expected 0 tasks, got: $got"

# Accent-stripped French heading still skipped.
body_no_accents='## Criteres d acceptation
- [ ] Tests passent
- [ ] Doc OK
'
got=$(dispatch_plan_atomize_tasks "$body_no_accents")
[[ "$(count_lines "$got")" == "0" ]] \
  || fail "accent-stripped french fixture expected 0 tasks, got: $got"

# Bilingual fixture: English + French acceptance sections, plus a
# Travaux/Tasks atomize section.
body_bilingual='## Acceptance Criteria
- [ ] Tests pass
- [ ] Docs updated

## Critères d'\''acceptation
- [ ] Tests réussis
- [ ] Doc mise à jour

## Tasks / Travaux à faire
- [ ] Implement feature
- [ ] Wire CLI flag
- [ ] Backfill telemetry
'
got=$(dispatch_plan_atomize_tasks "$body_bilingual")
[[ "$(count_lines "$got")" == "3" ]] \
  || fail "bilingual fixture expected 3 atomize tasks, got: $got"
[[ "$got" == *"Implement feature"* ]] \
  || fail "bilingual fixture should keep Implement feature, got: $got"
[[ "$got" == *"Backfill telemetry"* ]] \
  || fail "bilingual fixture should keep Backfill telemetry, got: $got"
[[ "$got" != *"Tests pass"* ]] \
  || fail "bilingual fixture must not include English acceptance items"
[[ "$got" != *"Tests réussis"* ]] \
  || fail "bilingual fixture must not include French acceptance items"

# Custom override fixture: project defines extra non-atomize header.
export DISPATCH_PLAN_NON_ATOMIZE_HEADERS='Validation Steps'
body_custom='## Validation Steps
- [ ] Run smoke
- [ ] Inspect logs

## Tasks
- [ ] Implement feature
'
got=$(dispatch_plan_atomize_tasks "$body_custom")
[[ "$(count_lines "$got")" == "1" ]] \
  || fail "custom-override fixture expected 1 atomize task, got: $got"
[[ "$got" == *"Implement feature"* ]] \
  || fail "custom-override fixture should keep Implement feature, got: $got"
unset DISPATCH_PLAN_NON_ATOMIZE_HEADERS

# A non-skip header after a skip section re-opens atomization.
body_resume='## Acceptance Criteria
- [ ] Tests pass

## Tasks
- [ ] Implement feature
- [ ] Document feature

## Définition de fini
- [ ] CI green

## Notes
- [ ] Coordinate with team
'
got=$(dispatch_plan_atomize_tasks "$body_resume")
[[ "$(count_lines "$got")" == "3" ]] \
  || fail "resume fixture expected 3 atomize tasks, got: $got"
[[ "$got" == *"Implement feature"* ]] \
  || fail "resume fixture should keep Implement feature"
[[ "$got" == *"Document feature"* ]] \
  || fail "resume fixture should keep Document feature"
[[ "$got" == *"Coordinate with team"* ]] \
  || fail "resume fixture should keep Coordinate with team"
[[ "$got" != *"Tests pass"* ]] \
  || fail "resume fixture must not include acceptance items"
[[ "$got" != *"CI green"* ]] \
  || fail "resume fixture must not include DoD items"

# Empty body — no tasks, no error.
got=$(dispatch_plan_atomize_tasks "")
[[ "$(count_lines "$got")" == "0" ]] \
  || fail "empty body should yield 0 tasks"

# Body with no headers — every checkbox counts.
body_no_headers='Intro

- [ ] one
- [ ] two
- [ ] three
'
got=$(dispatch_plan_atomize_tasks "$body_no_headers")
[[ "$(count_lines "$got")" == "3" ]] \
  || fail "no-header fixture expected 3 tasks, got: $got"

# Regression: the normalized non-atomize allowlist is reused across header
# checks. Live dispatch planning can inspect many issue headers; rebuilding the
# default allowlist for every header turns ready-queue planning into a timeout.
counter_file=$(mktemp)
dispatch_plan_default_non_atomize_headers() {
  printf x >> "$counter_file"
  printf '%s\n' "acceptance criteria" "validation criteria"
}
dispatch_plan_clear_non_atomize_header_cache 2>/dev/null || true
dispatch_plan_is_non_atomize_header "## Acceptance Criteria" \
  || fail "cache fixture should match acceptance criteria"
dispatch_plan_is_non_atomize_header "## Validation Criteria" \
  || fail "cache fixture should match validation criteria"
default_builder_calls=$(wc -c < "$counter_file" | tr -d ' ')
rm -f "$counter_file"
[[ "$default_builder_calls" == "1" ]] \
  || fail "non-atomize header allowlist should be cached; builder calls=$default_builder_calls"

printf 'ok - dispatch_plan_headers tests passed\n'
