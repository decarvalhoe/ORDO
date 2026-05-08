# Documentation Change Triggers

This page tells a contributor which documentation must be updated when ORDO
changes. It is the long-form version of the table in
[docs/architecture/README.md](README.md#change-trigger-matrix).

It exists so the documentation impact gate planned by epic
[#257](https://github.com/RBOKproject/ORDO/issues/257) (specifically issue
[#260](https://github.com/RBOKproject/ORDO/issues/260)) has a stable contract
to read. Changes to the gate must update this page first.

## How to use this page

1. Identify the type of change (feature, CLI, config, workflow, validation,
   optional layer, generated artefact).
2. Apply every "always update" item in the matching section.
3. Apply each "update if affected" item that the change touches.
4. Run the smoke check the section recommends, where one is listed.
5. Record the touched documents in the PR body.

A documentation diff that does not match any section is a signal that this
page is incomplete. Add the missing trigger in the same PR.

## Trigger sections

### Trigger 1 — User-facing feature added, removed, or behaviour-changed

Symptoms:

- a new operator workflow appears (or an old one disappears);
- the public capability list in [PRODUCT.md](../../PRODUCT.md) is now
  inaccurate;
- a documented `--dry-run`, `--apply`, or refusal path changes meaning.

Always update:

- [README.md](../../README.md): What ORDO Does and the relevant feature
  paragraph;
- [PRODUCT.md](../../PRODUCT.md): Core Capabilities and Positioning;
- [docs/INDEX.md](../INDEX.md): the category that exposes the feature.

Update if affected:

- the feature's own doc under `docs/` (for example
  [docs/dispatch-planning.md](../dispatch-planning.md),
  [docs/sixsigma-autoupgrade.md](../sixsigma-autoupgrade.md),
  [docs/controlled-operations.md](../controlled-operations.md));
- [docs/architecture/README.md](README.md): if the feature changes which
  audience or category owns it;
- examples under `examples/`.

Smoke check: confirm the README and PRODUCT capability bullets still match
the feature's actual command surface.

### Trigger 2 — CLI script added, renamed, or flag changed

Symptoms:

- `scripts/*.sh` gains, loses, or renames a script;
- a flag is added, removed, renamed, or changes default;
- a usage banner refuses or accepts something it did not before.

Always update:

- [README.md → Common Commands](../../README.md#common-commands);
- [docs/universal-fleet-manual.md → Daily Commands](../universal-fleet-manual.md#daily-commands).

Update if affected:

- the per-feature doc that describes the script (for example
  [docs/sixsigma-autoupgrade.md](../sixsigma-autoupgrade.md) for the autofix
  script, [docs/controlled-operations.md](../controlled-operations.md) for the
  controlled-operation script, [docs/project-scaffold.md](../project-scaffold.md)
  for the scaffold);
- the script's own usage banner;
- tests under `tests/` and Bats fixtures;
- examples that demonstrate the flag.

Smoke check: `grep -n "<flag>" README.md docs/` to confirm the change
propagated everywhere the flag is mentioned.

### Trigger 3 — Project-profile config key added, renamed, or removed

Symptoms:

- a profile field such as `AGENT_PANES`, `GH_REPO`, `AGENT_GH_LOGINS`,
  `PROJECT_REPO_ROOT`, or `AGENT_WORKDIR_TEMPLATE` changes name, default, or
  semantics;
- a new config key is required to load a profile.

Always update:

- [docs/universal-fleet-manual.md](../universal-fleet-manual.md): Fleet
  Contract, Minimal External Profile, and Migration sections.

Update if affected:

- [README.md → Project Profile Contract](../../README.md#project-profile-contract);
- [examples/](../../examples) loaders and any documented example profiles.

Smoke check: load the example loader with the new key set and confirm
preflight either passes or refuses with a clear message.

### Trigger 4 — Orchestrator workflow added or changed

Symptoms:

- the integration / merge / wave flow changes;
- new orchestrator-injected rules apply to dispatched agents;
- the supervisor binding (`ORCH_CLI_BIN`) gets new expectations.

Always update:

- [docs/architecture.md](../architecture.md): tier-1/tier-2 description;
- [docs/orchestrator-injected-rules.md](../orchestrator-injected-rules.md);
- [docs/fleet-injected-rules.md](../fleet-injected-rules.md) when fleet-wide
  rules change.

Update if affected:

- [docs/dispatch-planning.md](../dispatch-planning.md);
- runbooks under `docs/` that describe recovery during the workflow;
- [docs/host-health-runbook.md](../host-health-runbook.md) when the workflow
  introduces new host pressure modes.

Smoke check: re-run the relevant `--dry-run` to confirm the workflow's
preflight still names the documented expectations.

### Trigger 5 — Validation grade or evidence flow changed

Symptoms:

- new evidence is required for IQ/OQ/PQ;
- a deviation, CAPA, or release rule changes;
- the controlled baseline or document index changes.

Always update:

- [docs/validation/README.md](../validation/README.md);
- [docs/validation/document-index.md](../validation/document-index.md);
- the affected CSV documents under `docs/validation/`.

Update if affected:

- [docs/validation/csv-08-traceability-template.md](../validation/csv-08-traceability-template.md)
  and [docs/validation/csv-val-01-final-traceability.md](../validation/csv-val-01-final-traceability.md);
- [docs/validation/csv-09-validation-strategy.md](../validation/csv-09-validation-strategy.md)
  and [docs/validation/csv-10-controlled-baseline.md](../validation/csv-10-controlled-baseline.md);
- evidence packs under `docs/validation/evidence/`.

Smoke check: the disposition statements in
[README.md → Current Release State](../../README.md#current-release-state),
[PRODUCT.md → Release Maturity](../../PRODUCT.md#release-maturity), and
[docs/validation/README.md → Current Disposition](../validation/README.md#current-disposition)
must agree.

### Trigger 6 — Optional GxP or Six Sigma layer changed

Symptoms:

- the GxP-grade documentation layer gains or loses required content;
- the Six Sigma layer DMAIC structure or evidence ledger changes;
- the gating that makes those layers optional changes.

Always update:

- [docs/architecture/README.md → Optional layers](README.md#optional-layers);
- [docs/INDEX.md](../INDEX.md) so the layer is discoverable when selected.

Update if affected:

- the reusable generator templates under `templates/` once they exist (epic
  #257, issues #261 and #262);
- [docs/sixsigma-autoupgrade.md](../sixsigma-autoupgrade.md) for Six Sigma
  layer linkage;
- the validation set under [docs/validation/](../validation/) for GxP linkage.

Mandatory rule: a change to either layer must include a test or rationale that
demonstrates the layer remains opt-in and absent from a normal-dev project. If
the change cannot demonstrate that, it is out of scope.

### Trigger 7 — Generated downstream artefact added or changed

Symptoms:

- the project scaffold or meta-context generator emits a new file;
- the generator changes a generated file's structure or required content;
- a new generator module is added.

Always update:

- [docs/project-scaffold.md](../project-scaffold.md) or the new generator
  module's doc;
- [docs/architecture/README.md → Generated downstream docs](README.md#8-generated-downstream-docs).

Update if affected:

- [docs/project-meta-context.md](../project-meta-context.md);
- examples under `examples/`;
- tests under `tests/` that assert generator output.

Smoke check: run the generator with `--dry-run` against a temporary directory
and confirm the documented file list matches the preview.

## Maintenance

This page is structured so that every section maps to one row in the matrix in
[docs/architecture/README.md](README.md#change-trigger-matrix). When the matrix
changes, this page changes in the same PR. When the planned documentation
impact gate (issue #260) ships, its parser must point at this file by path.
