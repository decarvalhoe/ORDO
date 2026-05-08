# ORDO Documentation Generator

`scripts/docs_generate.sh` produces a reusable documentation pack for a
downstream project from project metadata, repository structure signals,
existing docs, and operator-supplied context. It is a generalizable module: it
does not hardcode a downstream product, a framework, a runtime, or a vendor.

The generator complements `scripts/project_scaffold.sh` and
`scripts/project_meta_context.sh`. Project scaffold creates a minimum repo
baseline. Project meta context maintains a low-cost cached project map. Docs
generate produces an extended documentation pack on top of either, and is
re-runnable as inputs evolve.

## Audience Layers

The pack distinguishes audiences:

- developer — engineers extending the project (overview, architecture,
  contribution flow);
- user — end users of the project (user guide skeleton);
- operator — operators running the project (runbook with stop conditions);
- integration — integrators connecting upstream or downstream systems;
- validation — minimal evidence index for normal-dev, expanded under
  `--gxp-grade`;
- maintenance — refresh cadence, ownership, and follow-up gap policy.

## Optional Layers

Two layers are optional and emitted only when explicitly selected. They never
leak into a default pack.

- `--gxp-grade` adds a `gxp/` folder with controlled-document policy,
  validation evidence index, audit trail expectations, deviation and CAPA
  hooks, traceability template, and approval handoff.
- `--sixsigma` adds a `sixsigma/` folder with DMAIC skeleton, CTQ tree, metric
  evidence ledger, control plan, and improvement backlog.

The selection is recorded in `generated.manifest.json` under `layers` and the
generated pages display the active grade in their headers.

## Safe Preview

Preview is the default:

```bash
bash scripts/docs_generate.sh <project> \
  --target-dir <downstream-project-dir> \
  --intent "Describe the product outcome in business terms" \
  --operator-context-file <path/to/context.md> \
  --json
```

Preview output reports:

- selected layers (with optional gxp-grade and six-sigma flags);
- file plan (path and layer for each file the generator would write);
- repo metadata signature (used to detect whether inputs changed);
- follow-up gaps detected before writing;
- blockers and apply blockers.

## Apply

Writes require `--apply`:

```bash
bash scripts/docs_generate.sh <project> \
  --target-dir <downstream-project-dir> \
  --intent "..." \
  --operator-context-file <path/to/context.md> \
  --apply --json
```

`--dry-run` or `ORCH_DRY_RUN=1` keeps the command non-mutating even when
`--apply` is supplied. Existing generated files cause refusal unless
`--overwrite` is passed.

To enable an optional layer, pass the flag explicitly:

```bash
bash scripts/docs_generate.sh <project> \
  --target-dir <downstream-project-dir> \
  --intent "..." \
  --gxp-grade --apply --json
```

```bash
bash scripts/docs_generate.sh <project> \
  --target-dir <downstream-project-dir> \
  --intent "..." \
  --sixsigma --apply --json
```

Both layers can be combined.

## Output Layout

The default output directory is `<target-dir>/docs/generated/`. Override with
`--output-dir`. The generator does not write outside this directory.

```
docs/generated/
  index.md
  maintenance.md
  developer/
    overview.md
    architecture.md
    contribution.md
  user/
    user-guide.md
  operator/
    operator-runbook.md
  integration/
    integration-notes.md
  validation/
    evidence-index.md
  generated.manifest.json
  [if --gxp-grade]
  gxp/
    controlled-document-policy.md
    validation-evidence.md
    audit-trail.md
    deviation-capa.md
    traceability.md
    approval-handoff.md
  [if --sixsigma]
  sixsigma/
    dmaic.md
    ctq.md
    metric-evidence-ledger.md
    control-plan.md
    improvement-backlog.md
```

## Manifest

`generated.manifest.json` records:

- generation timestamp;
- inputs (project name, intent, target directory, output directory, operator
  context file, repo metadata signature);
- selected layers and the GxP-grade / Six Sigma flags;
- list of generated files with their layer;
- follow-up gaps detected at generation time;
- `defaults_safe` boolean (true when neither optional layer is selected).

The manifest is the canonical record of what was generated. Operators use it
to confirm a regeneration covered the expected scope and to drive the
follow-up gap backlog.

## Templates

Templates live in `templates/docs/` and use `${TOKEN}` placeholders. The
supported tokens are documented in `lib/docs_generate.sh`. Editing a template
changes the next generation run; templates are not versioned per downstream
project.

## Defaults Are Neutral

- The generator does not infer a regulated grade. The default pack states
  explicitly that it is not validation evidence.
- The generator does not infer Six Sigma controls.
- The generator does not infer business claims from project metadata.
- The generator stops when intent or target directory are missing rather than
  fabricating content.

## Re-running After Changes

Refresh the pack on every change that affects user-visible behavior,
integration contracts, operator workflow, validation grade, or generator
templates. Re-running the generator with the same inputs is idempotent only
when `--overwrite` is passed; the default refusal protects operator-edited
files in the output directory.
