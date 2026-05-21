#!/usr/bin/env bash
# brief_acceptance.sh — render the Acceptance proof scaffold section of a
# dispatch brief from the source issue's Definition-of-Done bullets.
#
# Closure-gate prerequisite for issue #723: the closure_acceptance gate
# refuses to auto-close an issue whose merged PR body lacks a fenced
# ```acceptance``` block covering each DoD bullet with verifiable artifact
# pointers. For the gate to be useful without per-merge operator
# intervention, every dispatch brief must already carry a pre-filled
# acceptance scaffold that the worker fills with artifact references
# during their validation run, before opening the PR.
#
# Public API:
#   brief_acceptance_extract_dod_bullets <issue-body>
#     Emit one cleaned bullet text per line, in source order. Recognized
#     section headers (case-insensitive, level 2 only): "Acceptance
#     Criteria", "Definition of Done". Recognized bullet forms inside the
#     section: `- [ ] text`, `- [x] text`, `- [X] text`, `- text`.
#
#   brief_acceptance_render_section <issue-body>
#     Emit the full `## Acceptance proof` section ready to be appended to
#     the rendered brief. When no DoD section is detected, emits the
#     fallback line `acceptance: no-DoD-section-found-in-issue-body`.
#
# Pure shell + awk: no network, no filesystem side effects.

if [[ -n "${BRIEF_ACCEPTANCE_LIB_LOADED:-}" ]]; then
  return 0
fi
BRIEF_ACCEPTANCE_LIB_LOADED=1

brief_acceptance_extract_dod_bullets() {
  local body=${1-}
  awk '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    /^##[[:space:]]+/ {
      header = $0
      sub(/^##[[:space:]]+/, "", header)
      header = trim(header)
      lc = tolower(header)
      if (lc == "acceptance criteria" || lc == "definition of done") {
        in_section = 1
      } else {
        in_section = 0
      }
      next
    }
    in_section {
      line = $0
      if (match(line, /^[[:space:]]*-[[:space:]]+\[[ xX]\][[:space:]]+/)) {
        text = substr(line, RSTART + RLENGTH)
        if (length(text) > 0) print text
        next
      }
      if (match(line, /^[[:space:]]*-[[:space:]]+/)) {
        text = substr(line, RSTART + RLENGTH)
        if (length(text) > 0) print text
        next
      }
    }
  ' <<<"$body"
}

brief_acceptance_render_section() {
  local body=${1-}
  local bullets
  bullets=$(brief_acceptance_extract_dod_bullets "$body")

  printf '\n\n## Acceptance proof\n\n'
  if [[ -z "$bullets" ]]; then
    printf 'acceptance: no-DoD-section-found-in-issue-body\n'
    return 0
  fi
  printf '```acceptance\n'
  printf 'Replace each placeholder with a verifiable artifact reference produced by your validation run.\n'
  while IFS= read -r bullet; do
    [[ -n "$bullet" ]] || continue
    printf -- '- %s — <artifact-reference>\n' "$bullet"
  done <<<"$bullets"
  printf '```\n'
}
