# Maintenance and Update Policy

This pack is regenerated, not hand-edited in place. Operator-owned content can
be merged into a separate `<output>/manual/` tree and linked from `index.md`,
but the templates and generated sections must be refreshed by re-running the
generator with updated inputs.

## Refresh Cadence

- Refresh on every functional change that affects user-visible behavior,
  integration contracts, operator workflow, or validation grade.
- Refresh on every change to the documentation generator templates.
- Refresh on every change to project intent or operator-supplied context.
- Refresh at least once per release cycle even if no other trigger fires.

## Ownership

| Section | Default owner | Replacement note |
| --- | --- | --- |
| Developer | engineering lead | Replace with the named role on the project. |
| User | product or support lead | Replace with the named role on the project. |
| Operator | operations or oncall lead | Replace with the named role on the project. |
| Integration | integrations or platform lead | Replace with the named role on the project. |
| Validation | validation or quality lead | Replace with the named role; required if gxp-grade layer is enabled. |
| Maintenance | documentation lead | Owns the refresh cadence and template updates. |
| GxP-grade layer | validation owner + quality reviewer | Required only when gxp-grade layer is enabled. |
| Six Sigma layer | improvement owner | Required only when six-sigma layer is enabled. |

## Generator Inputs Recorded

The generator records inputs and produced files in `generated.manifest.json`.
That file is the canonical record of what was generated and what context was
supplied. It includes:

- project name and intent;
- target and output directories;
- operator-supplied context reference;
- repository metadata signature;
- layers selected;
- generated files;
- follow-up gaps detected at generation time.

## Follow-up Gaps Policy

Each generation surfaces follow-up gaps that the documentation pack cannot
resolve from inputs alone (for example, missing product intent or missing
operator context). Treat these gaps as backlog items. They must be closed by
human edits in operator-owned content or by re-running the generator with
better inputs.

## Safe Defaults

- The generator does not infer business claims from project metadata.
- The generator does not assume a regulated grade unless `--gxp-grade` is
  passed.
- The generator does not assume Six Sigma controls unless `--sixsigma` is
  passed.
- The generator does not write outside the configured output directory.
