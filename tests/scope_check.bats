#!/usr/bin/env bats
# tests/scope_check.bats — fleet scope posture coverage (#343).
#
# `lib/scope_check.sh` disambiguates "in scope / held / out of scope" by
# configured project KEY, never by repo path or naming inference. The
# fixture exercises the public functions against synthetic key lists and
# asserts:
#   - normalization (lowercase, no horizontal whitespace, sorted-uniq)
#     does not collapse the per-key newline split (regression guard for
#     the [:space:] vs [:blank:] subtlety);
#   - classification returns one of {in_scope, held, out_of_scope, unknown};
#   - validate_active passes for in_scope / held, refuses for out_of_scope,
#     and follows ORCH_SCOPE_STRICT for unknown;
#   - render_block carries the four mandatory dispatch context fields
#     (active project key, active repo, active branch, scope classification)
#     and never emits ambiguous "business repository" prose;
#   - the regression fixture from issue #343 — "rbok in scope while
#     wordpress is held/blocked" — classifies both correctly using
#     operator-supplied keys, with no inference from path or naming.

load './helpers.bash'

setup() {
  setup_orch_test
  # shellcheck disable=SC1090
  source "$TK/lib/scope_check.sh"
  # Clean any inherited scope env so each test sets its own posture.
  unset ORCH_SCOPE_IN_SCOPE_PROJECTS
  unset ORCH_SCOPE_HELD_PROJECTS
  unset ORCH_SCOPE_OUT_OF_SCOPE_PROJECTS
  unset ORCH_SCOPE_ACTIVE_KEY
  unset ORCH_SCOPE_STRICT
  unset ORCH_SCOPE_SECTION_TITLE
}

@test "normalize_list lowercases, strips horizontal whitespace, and dedupes (#343)" {
  result=$(ordo_scope_normalize_list "RBOK, ordo ,Nomos,praxis,RBOK,LUMEN")
  [ "$result" = "lumen,nomos,ordo,praxis,rbok" ]
}

@test "normalize_list does not collapse the comma split into one key (#343)" {
  # Regression: an earlier draft used [:space:] (which includes \n) and
  # collapsed every key into a single concatenated string. The fix uses
  # [:blank:] which only strips horizontal whitespace.
  result=$(ordo_scope_normalize_list "rbok, ordo, nomos")
  [ "$result" = "nomos,ordo,rbok" ]
  # Each key is its own field in the comma list, so cardinality is 3.
  # Use awk -F, NF rather than counting newlines (printf '%s' has no
  # trailing newline so wc -l reports one less than the true count).
  count=$(printf '%s' "$result" | awk -F, '{print NF}')
  [ "$count" = "3" ]
}

@test "classify returns in_scope when key is in the allowlist (#343)" {
  ORCH_SCOPE_IN_SCOPE_PROJECTS="rbok,ordo,nomos,praxis,lumen"
  ORCH_SCOPE_HELD_PROJECTS="wordpress"
  result=$(ordo_scope_classify rbok)
  [ "$result" = "in_scope" ]
  # Case-insensitive: classification matches regardless of input case.
  result=$(ordo_scope_classify RBOK)
  [ "$result" = "in_scope" ]
}

@test "classify returns held for the rbok-vs-wordpress regression fixture (#343)" {
  # The exact scope shape from issue #343 evidence: RBOK product is in
  # scope; realisons-wordpress (key: wordpress) is held/blocked.
  ORCH_SCOPE_IN_SCOPE_PROJECTS="rbok,ordo,nomos,praxis,lumen"
  ORCH_SCOPE_HELD_PROJECTS="wordpress"
  rbok_class=$(ordo_scope_classify rbok)
  wp_class=$(ordo_scope_classify wordpress)
  [ "$rbok_class" = "in_scope" ]
  [ "$wp_class" = "held" ]
}

@test "classify returns out_of_scope when explicitly listed (#343)" {
  ORCH_SCOPE_IN_SCOPE_PROJECTS="rbok"
  ORCH_SCOPE_OUT_OF_SCOPE_PROJECTS="legacy-tool"
  result=$(ordo_scope_classify legacy-tool)
  [ "$result" = "out_of_scope" ]
}

@test "classify returns unknown when no list is configured (#343)" {
  result=$(ordo_scope_classify rbok)
  [ "$result" = "unknown" ]
}

@test "out_of_scope precedes held precedes in_scope when lists overlap (#343)" {
  # If an operator misconfigures overlap, the most restrictive ruling wins.
  ORCH_SCOPE_IN_SCOPE_PROJECTS="rbok"
  ORCH_SCOPE_HELD_PROJECTS="rbok"
  ORCH_SCOPE_OUT_OF_SCOPE_PROJECTS="rbok"
  result=$(ordo_scope_classify rbok)
  [ "$result" = "out_of_scope" ]
}

@test "validate_active passes for in_scope and held (#343)" {
  ORCH_SCOPE_IN_SCOPE_PROJECTS="rbok"
  ORCH_SCOPE_HELD_PROJECTS="wordpress"
  run ordo_scope_validate_active rbok
  [ "$status" -eq 0 ]
  run ordo_scope_validate_active wordpress
  [ "$status" -eq 0 ]
}

@test "validate_active refuses out_of_scope with structured stderr line (#343)" {
  ORCH_SCOPE_OUT_OF_SCOPE_PROJECTS="legacy-tool"
  run ordo_scope_validate_active legacy-tool
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"needs_scope_clarification"* ]] || \
    [[ "$output" == *"needs_scope_clarification"* ]]
  [[ "$stderr" == *"classification=out_of_scope"* ]] || \
    [[ "$output" == *"classification=out_of_scope"* ]]
}

@test "validate_active is permissive for unknown by default (#343)" {
  # Without ORCH_SCOPE_STRICT, an unknown classification still passes so
  # deployments that have not yet bound their keys can dispatch. The
  # rendered block still makes the omission obvious to the agent.
  run ordo_scope_validate_active not-yet-configured
  [ "$status" -eq 0 ]
}

@test "validate_active refuses unknown when ORCH_SCOPE_STRICT=1 (#343)" {
  ORCH_SCOPE_STRICT=1
  run ordo_scope_validate_active not-yet-configured
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"needs_scope_clarification"* ]] || \
    [[ "$output" == *"needs_scope_clarification"* ]]
  [[ "$stderr" == *"classification=unknown"* ]] || \
    [[ "$output" == *"classification=unknown"* ]]
}

@test "render_block carries the four mandatory dispatch context fields (#343)" {
  ORCH_SCOPE_IN_SCOPE_PROJECTS="rbok,ordo"
  ORCH_SCOPE_HELD_PROJECTS="wordpress"
  block=$(ordo_scope_render_block rbok "https://github.com/example/rbok" "main")
  [[ "$block" == *"active project key"* ]]
  [[ "$block" == *"\`rbok\`"* ]]
  [[ "$block" == *"active repo"* ]]
  [[ "$block" == *"https://github.com/example/rbok"* ]]
  [[ "$block" == *"active branch"* ]]
  [[ "$block" == *"\`main\`"* ]]
  [[ "$block" == *"scope classification"* ]]
  [[ "$block" == *"\`in_scope\`"* ]]
}

@test "render_block lists allowlist / held / out-of-scope keys verbatim (#343)" {
  ORCH_SCOPE_IN_SCOPE_PROJECTS="rbok,ordo,nomos"
  ORCH_SCOPE_HELD_PROJECTS="wordpress"
  ORCH_SCOPE_OUT_OF_SCOPE_PROJECTS="legacy-tool"
  block=$(ordo_scope_render_block rbok "https://github.com/example/rbok" "main")
  [[ "$block" == *"in-scope project keys"* ]]
  [[ "$block" == *"nomos,ordo,rbok"* ]]
  [[ "$block" == *"held project keys"* ]]
  [[ "$block" == *"wordpress"* ]]
  [[ "$block" == *"out-of-scope project keys"* ]]
  [[ "$block" == *"legacy-tool"* ]]
}

@test "render_block classification line does NOT use ambiguous prose (#343)" {
  # The classification line is the actionable signal an agent reads. It
  # MUST be one of the four classification tokens — never prose like
  # "business out of scope" or "product app". (The block's pedagogical
  # warning text legitimately mentions "business repository" as an
  # example of inference language to avoid; this test targets the
  # actionable classification line specifically.)
  ORCH_SCOPE_IN_SCOPE_PROJECTS="rbok"
  block=$(ordo_scope_render_block rbok "https://github.com/example/rbok" "main")
  classification_line=$(grep '^- scope classification:' <<< "$block")
  [[ -n "$classification_line" ]]
  [[ "$classification_line" == *"\`in_scope\`"* ]]
  ! grep -qi 'business' <<< "$classification_line"
  ! grep -qi 'product app' <<< "$classification_line"
  ! grep -qi 'company website' <<< "$classification_line"
}

@test "render_block carries the by-configured-key directive (#343)" {
  block=$(ordo_scope_render_block rbok "https://github.com/example/rbok" "main")
  [[ "$block" == *"by configured project key"* ]]
  # Substring is single-line so the heredoc word-wrap does not break the match.
  [[ "$block" == *"explicit keys"* ]]
  [[ "$block" == *"source of truth"* ]]
}

@test "render_block always includes the recovery path for the orchestrator (#343)" {
  block=$(ordo_scope_render_block rbok "" "")
  [[ "$block" == *"Recovery path for the orchestrator"* ]]
  [[ "$block" == *"ORCH_SCOPE_IN_SCOPE_PROJECTS"* ]]
  # Heredoc word-wrap can split "controlled operation evidence file" across
  # lines, so check the unique tokens individually rather than a single
  # substring.
  grep -qi 'controlled' <<< "$block"
  grep -qi 'evidence file' <<< "$block"
}

@test "rbok-vs-wordpress regression renders correctly side by side (#343)" {
  # Regression fixture per issue #343 acceptance criteria. RBOK product
  # work is in scope while realisons-wordpress (key: wordpress) is held.
  # Both renderings must classify by KEY, not by inference from path.
  ORCH_SCOPE_IN_SCOPE_PROJECTS="rbok,ordo,nomos,praxis,lumen"
  ORCH_SCOPE_HELD_PROJECTS="wordpress"

  rbok_block=$(ordo_scope_render_block rbok "https://github.com/example/rbok" "develop")
  wp_block=$(ordo_scope_render_block wordpress "https://github.com/example/realisons-wordpress" "main")

  [[ "$rbok_block" == *"\`in_scope\`"* ]]
  [[ "$rbok_block" == *"\`rbok\`"* ]]
  [[ "$wp_block" == *"\`held\`"* ]]
  [[ "$wp_block" == *"\`wordpress\`"* ]]

  # Each rendering's classification line is the actionable signal — it
  # must NOT carry inference prose like "business out of scope". Even
  # though the wordpress repo URL contains "wordpress", the classification
  # is computed from the configured KEY ("wordpress" in HELD list), not
  # from the URL or path.
  rbok_class_line=$(grep '^- scope classification:' <<< "$rbok_block")
  wp_class_line=$(grep '^- scope classification:' <<< "$wp_block")
  [[ "$rbok_class_line" == *"\`in_scope\`"* ]]
  [[ "$wp_class_line" == *"\`held\`"* ]]
  ! grep -qi 'business out of scope' <<< "$rbok_class_line"
  ! grep -qi 'business out of scope' <<< "$wp_class_line"
}
