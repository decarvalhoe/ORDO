# Developer Overview — ${DG_PROJECT_NAME}

- generated_at: `${DG_GENERATED_AT}`

## Product Intent

${DG_PROJECT_INTENT}

## Audience

This section is for engineers extending or maintaining the project. It is not
a user manual; see `../user/user-guide.md` for that.

## What This Document Covers

- Where to find the source.
- How to set up a local development environment.
- How to run tests and verify changes.
- Where to look for ongoing engineering decisions.

## Source Layout (operator-confirmed)

The generator detects the presence of common manifest and metadata files but
does not infer a runtime. Confirm the actual source layout in this section by
hand or by linking to existing documentation in the project repository.

## Local Development Setup

Operator-supplied context, when provided, is appended below.

${DG_OPERATOR_CONTEXT}

## Verification Steps

- Run the project test suite as documented in the source repository.
- Run the project linter or formatter as documented in the source repository.
- Confirm that the documentation pack regeneration succeeds after material
  changes; see `../maintenance.md`.
