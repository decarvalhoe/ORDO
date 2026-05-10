# Issue #423 - GxP documentation layer audit

## Purpose

Issue #423 is a read-only investigation of how the project documentation
generator wires the optional GxP layer. The question under audit is whether a
downstream project that declares a GxP validation grade causes the controlled
document, validation/evidence, audit trail, deviation/CAPA, traceability, and
approval handoff templates under `templates/docs/gxp/` to be emitted.

No generator code, templates, or tests were changed for this issue.

## Entry points reviewed

| Entry point | GxP signal considered | Observed behavior |
| --- | --- | --- |
| `scripts/docs_generate.sh` | `--gxp-grade` CLI flag only | Initializes `GXP_GRADE=0`, sets it to `1` only when `--gxp-grade` is present, then passes that boolean to `docs_generate_files_json`, `docs_generate_layers_markdown`, rendering, and the manifest. |
| `lib/docs_generate.sh` | Positional `gxp` boolean passed by caller | Defines `gxp` as an optional layer, appends the `gxp` layer only when the received boolean is `1`, and discovers every `templates/docs/gxp/*.md.tpl` file as `gxp/<name>.md`. |
| `scripts/project_scaffold.sh` | none found | Selects a neutral scaffold archetype and baseline files. It does not call `scripts/docs_generate.sh`, does not parse validation grade, and does not emit documentation-pack layers. |
| `scripts/guided_onboarding.sh` | `--validation-mode <gxp|dev>` / `ORDO_ONBOARDING_VALIDATION_MODE` | Accepts and validates `validation_mode`, then records it under `onboarding_profile.project_metadata.validation_mode`. It does not call the docs generator. |
| `scripts/multi_project_onboarding.sh` | manifest `validation_mode` | Forwards manifest `validation_mode` to `guided_onboarding.sh` and records the resulting per-project profile. It does not call the docs generator. |
| `lib/config_resolver.sh` | none found for docs layer selection | Loads project config values for callers, but no `PROJECT_VALIDATION_GRADE`, `validation_mode`, or equivalent value is consumed by the docs generator to infer `--gxp-grade`. |

## Emit-path map

All six GxP templates have a concrete generator path when the docs generator is
called with `--gxp-grade`:

`scripts/docs_generate.sh --gxp-grade` sets `GXP_GRADE=1`, then
`docs_generate_files_json 1 0` asks `docs_generate_resolve_layers 1 0` for the
selected layers. `docs_generate_resolve_layers` appends `gxp`.
`docs_generate_layer_files gxp` maps `templates/docs/gxp/*.md.tpl` to
`gxp/*.md`, and the apply loop renders each mapped template under
`<target-dir>/docs/generated/`.

| Template | Expected generated path | Observed status | Evidence |
| --- | --- | --- | --- |
| `templates/docs/gxp/approval-handoff.md.tpl` | `docs/generated/gxp/approval-handoff.md` | emitted | Present in the `--gxp-grade` preview file plan as `gxp/approval-handoff.md`. |
| `templates/docs/gxp/audit-trail.md.tpl` | `docs/generated/gxp/audit-trail.md` | emitted | Present in the `--gxp-grade` preview file plan as `gxp/audit-trail.md`. |
| `templates/docs/gxp/controlled-document-policy.md.tpl` | `docs/generated/gxp/controlled-document-policy.md` | emitted | Present in the `--gxp-grade` preview file plan as `gxp/controlled-document-policy.md`. |
| `templates/docs/gxp/deviation-capa.md.tpl` | `docs/generated/gxp/deviation-capa.md` | emitted | Present in the `--gxp-grade` preview file plan as `gxp/deviation-capa.md`. |
| `templates/docs/gxp/traceability.md.tpl` | `docs/generated/gxp/traceability.md` | emitted | Present in the `--gxp-grade` preview file plan as `gxp/traceability.md`. |
| `templates/docs/gxp/validation-evidence.md.tpl` | `docs/generated/gxp/validation-evidence.md` | emitted | Present in the `--gxp-grade` preview file plan as `gxp/validation-evidence.md`. |

## Structured gaps

| Gap | Affected surface | Observed signal | Impact |
| --- | --- | --- | --- |
| Profile validation grade is not wired into docs generation | `scripts/docs_generate.sh`, `scripts/guided_onboarding.sh`, `scripts/multi_project_onboarding.sh` | `validation_mode=gxp`, `PROJECT_VALIDATION_GRADE=gxp`, `ORDO_ONBOARDING_VALIDATION_MODE=gxp`, and `DOCS_GENERATE_GXP_GRADE=1` did not select the `gxp` layer in preview mode unless `--gxp-grade` was also passed. | A downstream project can record GxP intent in onboarding/profile metadata without the docs generator emitting the controlled-document GxP pack. Operators must remember the separate CLI flag. |
| No manifest-level provenance links GxP layer selection to project profile metadata | `generated.manifest.json` schema emitted by `scripts/docs_generate.sh` | Manifest records `layers.gxp_grade`, but not the source of that decision. | If `--gxp-grade` is passed manually, reviewers cannot tell whether it came from a validated project profile, an operator override, or an ad-hoc command. |

## Probe evidence

Focused preview commands were run in plan mode with `timeout 20`; none wrote
generated files.

| Probe | Result |
| --- | --- |
| `bash scripts/docs_generate.sh ordo --target-dir . --intent "Issue 423 GxP docs layer audit preview" --operator-context-file /tmp/dispatch-RBOK-claude-423.md --gxp-grade --json` | `layers.gxp_grade=true`, selected layers include `gxp`, and the file plan includes all six `gxp/*.md` outputs. |
| `bash scripts/docs_generate.sh ordo --target-dir . --intent "Issue 423 profile-grade probe" --operator-context-file /tmp/dispatch-RBOK-claude-423.md --json` | `layers.gxp_grade=false`; no `gxp/*.md` outputs. |
| `PROJECT_VALIDATION_GRADE=gxp bash scripts/docs_generate.sh ordo --target-dir . --intent "Issue 423 profile-grade probe" --operator-context-file /tmp/dispatch-RBOK-claude-423.md --json` | `layers.gxp_grade=false`; no `gxp/*.md` outputs. |
| `ORDO_ONBOARDING_VALIDATION_MODE=gxp bash scripts/docs_generate.sh ordo --target-dir . --intent "Issue 423 profile-grade probe" --operator-context-file /tmp/dispatch-RBOK-claude-423.md --json` | `layers.gxp_grade=false`; no `gxp/*.md` outputs. |
| `DOCS_GENERATE_GXP_GRADE=1 bash scripts/docs_generate.sh ordo --target-dir . --intent "Issue 423 profile-grade probe" --operator-context-file /tmp/dispatch-RBOK-claude-423.md --json` | `layers.gxp_grade=false`; no `gxp/*.md` outputs. |

## Follow-up status

Issue #518 implements the generator bridge identified by this audit:
`PROJECT_VALIDATION_GRADE=gxp` and `ORDO_ONBOARDING_VALIDATION_MODE=gxp` now
select the GxP layer in docs generator preview/apply output, and
`generated.manifest.json` records the trigger under
`layers.gxp_grade_sources`. The `--gxp-grade` CLI override is retained and
recorded distinctly as `cli:--gxp-grade`.

Original follow-up captured by the audit:

1. File one bug to define and implement the canonical bridge from project
   profile validation metadata to docs generation. Candidate acceptance: when a
   supported project profile declares GxP, the docs generator selects the GxP
   layer without requiring a second, easy-to-miss operator flag; the manifest
   records the decision source.
2. Include a regression proving that a normal-dev profile still omits the GxP
   layer and that an explicit operator override, if retained, is recorded
   distinctly from profile-derived selection.

No per-template follow-up is required: every current `templates/docs/gxp/*.md.tpl`
has an emit path once the GxP layer is selected.
