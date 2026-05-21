# closure_acceptance_fixtures

Shared mock fixture bodies for the post_merge_cleanup test family, used to
exercise both modes of the closure_acceptance_gate (issue #723):

- default-off (`ORCH_CLOSURE_GATE_ENFORCE=0` / `ORCH_CLOSURE_GATE_MODE` unset)
- enforce-on (`ORCH_CLOSURE_GATE_ENFORCE=1` or `ORCH_CLOSURE_GATE_MODE=enforce`)

The fixtures pair a mock PR body with a mock source-issue body so the gate
classifier (`lib/closure_acceptance.sh`) can see realistic DoD bullets and
either a matching acceptance proof block (gate-pass) or no block at all
(CLOSURE_REFUSED).

Files:

- `pr_body_with_proof.md` — PR body carrying a `\`\`\`acceptance` block with
  artifact-bearing bullets that cover the mock issue's DoD. Used for the
  enforce-mode positive path: gate returns `pass` and the close proceeds.
- `pr_body_without_proof.md` — PR body that omits the acceptance block.
  Used for the enforce-mode negative path: gate returns `refused` and the
  close mutation must NOT fire (CLOSURE_REFUSED audit row).
- `issue_body_dod.md` — source-issue body with a `## Acceptance Criteria`
  section. Both PR bodies are scored against the bullets in this file.

The fixtures are intentionally tiny and self-contained so the post_merge
test family can embed them via `cat` without pulling in extra dependencies.
