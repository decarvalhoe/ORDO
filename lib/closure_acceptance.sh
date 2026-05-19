#!/usr/bin/env bash
# closure_acceptance.sh - closure-side gate for issue #723.
#
# Decide whether a merged PR may auto-close the GitHub issue it references.
# Auto-close is allowed only when one of the following holds for the merged
# PR body, evaluated against the source issue body:
#
#   1. acceptance proof: a fenced ```acceptance ... ``` block whose bullets
#      cover the DoD bullets in the source issue and reference verifiable
#      artifacts (test-run id, evidence URL, screenshot path, file hash, ...).
#   2. operator override: `Closes #N (operator-authorized: <handle> <reason>)`
#      trailer on the matching closing keyword.
#   3. scaffold-declared retarget: the PR body declares
#      `Acceptance: scaffold-only; live-validation tracked in #M`. Closing
#      the PARENT issue with this trailer is refused; the operator must
#      retarget the dispatch from the parent to the follow-up #M.
#
# Source this library from scripts/post_merge_cleanup.sh (or any future
# closer) and call `closure_acceptance_classify <pr-body> <issue-body>
# <issue-number>`. Use `closure_acceptance_should_close <outcome>` to
# decide whether to propagate the close; use
# `closure_acceptance_refusal_reason <outcome>` for a stable audit-row
# reason token.
#
# Pure shell + awk + grep + wc: no network, no filesystem side effects.

closure_acceptance_extract_block() {
  local body=${1-}
  awk '
    BEGIN { in_block = 0 }
    /^[[:space:]]*```[[:space:]]*acceptance[[:space:]]*$/ {
      if (in_block) { in_block = 0; next }
      in_block = 1
      next
    }
    /^[[:space:]]*```[[:space:]]*$/ {
      if (in_block) { in_block = 0; next }
      next
    }
    { if (in_block) print }
  ' <<<"$body"
}

closure_acceptance_extract_dod() {
  local body=${1-}
  awk '
    BEGIN { in_section = 0 }
    /^##[[:space:]]+(Acceptance Criteria|Definition of Done|Acceptance criteria|Definition of done)[[:space:]]*$/ {
      in_section = 1
      next
    }
    /^##[[:space:]]/ { if (in_section) in_section = 0 }
    in_section && /^[[:space:]]*-[[:space:]]+\[[ xX]\][[:space:]]+/ {
      sub(/^[[:space:]]*-[[:space:]]+\[[ xX]\][[:space:]]+/, "")
      if (length($0) > 0) print
    }
  ' <<<"$body"
}

closure_acceptance_operator_override() {
  local body=${1-}
  local issue=${2:?usage: closure_acceptance_operator_override <body> <issue>}
  grep -Eqi "(closes|fixes|resolves)[[:space:]]+#${issue}[[:space:]]*\(operator-authorized:[[:space:]]+@?[A-Za-z0-9._-]+[[:space:]]+[^)]+\)" \
    <<<"$body"
}

# closure_acceptance_scaffold_declaration <body>
# Emit the follow-up issue number on stdout when the PR body declares a
# scaffold-only retarget. Return non-zero when no declaration is present.
closure_acceptance_scaffold_declaration() {
  local body=${1-}
  local match
  match=$(grep -Eoi 'acceptance:[[:space:]]+scaffold-only;[[:space:]]+live-validation[[:space:]]+tracked[[:space:]]+in[[:space:]]+#[0-9]+' \
    <<<"$body" | head -n 1) || return 1
  [[ -n "$match" ]] || return 1
  printf '%s' "$match" | grep -Eo '#[0-9]+' | head -n 1 | tr -d '#'
}

# closure_acceptance_block_covers_dod <block> <dod>
# Pragmatic coverage check: the acceptance block must contain at least one
# bullet per DoD bullet AND have at least as many artifact-bearing bullets
# as DoD bullets. Artifact markers are `artifact:`, `evidence:`, `run-id:`,
# `sha:`, `hash:`, `path:`, an http(s) URL, or a known file extension.
closure_acceptance_block_covers_dod() {
  local block=${1-}
  local dod=${2-}
  [[ -n "$block" ]] || return 1
  [[ -n "$dod" ]] || return 1

  local dod_count
  local artifact_count
  dod_count=$(printf '%s\n' "$dod" | awk 'NF{c++} END{print c+0}')
  artifact_count=$(printf '%s\n' "$block" \
    | grep -E '^[[:space:]]*-[[:space:]]+' \
    | grep -Eci '(artifact:|evidence:|run-id:|sha:|hash:|path:|https?://|\.png|\.jpg|\.html|\.json|\.md|\.php|\.sh|\.js|\.css)' \
    || true)
  [[ "${dod_count:-0}" -gt 0 ]] || return 1
  [[ "${artifact_count:-0}" -ge "${dod_count}" ]]
}

closure_acceptance_classify() {
  local pr_body=${1-}
  local issue_body=${2-}
  local issue_number=${3:?usage: closure_acceptance_classify <pr-body> <issue-body> <issue-number>}

  if closure_acceptance_operator_override "$pr_body" "$issue_number"; then
    printf 'operator-override\n'
    return 0
  fi

  local scaffold_target
  scaffold_target=$(closure_acceptance_scaffold_declaration "$pr_body" 2>/dev/null || true)
  if [[ -n "$scaffold_target" ]]; then
    printf 'scaffold-declared:#%s\n' "$scaffold_target"
    return 0
  fi

  local dod
  dod=$(closure_acceptance_extract_dod "$issue_body")
  if [[ -z "$dod" ]]; then
    printf 'pass\n'
    return 0
  fi

  local block
  block=$(closure_acceptance_extract_block "$pr_body")
  if [[ -z "$block" ]]; then
    printf 'refused\n'
    return 0
  fi

  if closure_acceptance_block_covers_dod "$block" "$dod"; then
    printf 'pass\n'
  else
    printf 'refused\n'
  fi
}

closure_acceptance_should_close() {
  local outcome=${1-}
  case "$outcome" in
    pass|operator-override) return 0 ;;
    *) return 1 ;;
  esac
}

closure_acceptance_refusal_reason() {
  local outcome=${1-}
  case "$outcome" in
    pass) printf 'pass' ;;
    operator-override) printf 'operator-override' ;;
    scaffold-declared:*)
      printf 'scaffold-declared follow_up=%s' "${outcome#scaffold-declared:}"
      ;;
    scaffold-declared) printf 'scaffold-declared' ;;
    refused) printf 'missing-acceptance-proof' ;;
    *) printf 'unknown-outcome' ;;
  esac
}
