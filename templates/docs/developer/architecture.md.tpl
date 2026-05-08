# Developer Architecture — ${DG_PROJECT_NAME}

- generated_at: `${DG_GENERATED_AT}`

## Audience

Engineers extending or reviewing this project.

## Generated Boundary

This document is generated from project metadata and operator-supplied context.
It does not select a framework, runtime, hosting target, repository platform,
CI provider, or vendor on behalf of the project. Replace generic placeholders
with the project's actual decisions before treating this document as binding.

## Architectural Boundaries Skeleton

| Boundary | Responsibility | Confirmed source |
| --- | --- | --- |
| Interface boundary | externally observable surface (CLI, API, UI, file format) | TODO confirm |
| Behavioral boundary | core domain rules and policies | TODO confirm |
| Data boundary | data created, changed, retained, or deleted | TODO confirm |
| Integration boundary | upstream and downstream systems | TODO confirm |
| Operational boundary | runtime, deployment, observability | TODO confirm |
| Security boundary | authentication, authorization, secrets | TODO confirm |

## Decisions To Capture

- Confirm the supported runtime and language version.
- Confirm the persistence model and retention expectations.
- Confirm the integration surface (transport, schema, authentication).
- Confirm operational ownership and oncall pathway.
- Confirm validation grade. The generated pack assumes normal-dev unless
  `--gxp-grade` was passed.

## Operator-Supplied Context

${DG_OPERATOR_CONTEXT}
