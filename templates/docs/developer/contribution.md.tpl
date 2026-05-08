# Contribution Guide — ${DG_PROJECT_NAME}

- generated_at: `${DG_GENERATED_AT}`

## Audience

Engineers landing changes in this project.

## Branching Model

Confirm the active branching model. The generator does not assume `main` vs
`develop`, fork vs branch, or trunk-based vs release-train. Capture the
project's actual model here.

## Pull Request Expectations

- One change per pull request, scoped to a single concern.
- Tests added or updated to cover the change.
- Linter and formatter clean before requesting review.
- Documentation regenerated when changes affect user-visible behavior,
  integration contracts, operator workflow, or validation grade.

## Review Expectations

- At least one independent reviewer for every merged change.
- Reviewer must confirm tests run and pass against the proposed change.
- Reviewer must confirm documentation updates when the change qualifies.

## Documentation Refresh

The maintenance and update policy lives in `../maintenance.md`. Re-run the
documentation generator after merging changes that affect user-visible
behavior, integration contracts, operator workflow, or validation grade.
