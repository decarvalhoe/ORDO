# Mode: GxP-Grade ORDO Deployment

> Template — copy into the documentation tree of `{{project_name}}` and
> replace every `{{placeholder}}` before publishing. This mode is opt-in
> and never the default for normal-dev work.

This template documents an ORDO deployment whose target product is governed
by computer-system-validation (CSV/GAMP/CSA-style) requirements and must
preserve a validation dossier. It builds on
[`single-project.md`](single-project.md) (or
[`portfolio.md`](portfolio.md) for portfolios) and adds dossier
expectations consistent with `docs/validation/README.md`.

> **Boundary.** Selecting GxP-grade for a product MUST NOT bleed GxP-only
> rules into the normal-dev mode used by other products in the same
> portfolio. The Six Sigma option (see [`sixsigma.md`](sixsigma.md)) is
> independent and can be combined with GxP-grade or with normal-dev.

## Installation

- toolkit version: `{{ordo_release_tag}}` pinned for the validated baseline
- toolkit checkout: `{{absolute_path_to_ordo_checkout}}`
- project profile: `{{absolute_path_to_project_profile}}` (validated baseline
  reference recorded in the dossier)
- credentials: provider tokens loaded from `{{operator_credential_source}}`
  per `SECRETS.md`; rotation cadence per the dossier roles/training section
- prerequisites identical to single-project plus the dossier scaffolding
  produced by `scripts/csv_dev_mode.sh`

```bash
bash {{absolute_path_to_ordo_checkout}}/scripts/csv_dev_mode.sh \
  {{project_config}} \
  --target-dir {{absolute_path_to_target_checkout}} \
  --dossier-dir .ordo/validation \
  --json
```

`csv_dev_mode.sh` scaffolds a CSV/GAMP/CSA-style dossier in development mode.
**It does not validate, approve, waive, or release.** Final disposition
remains a human decision recorded in the dossier.

## Integration

- repo: `{{owner}}/{{repo}}`
- default branch: `{{default_branch}}`
- CI provider and check rollup: `{{ci_provider}}` / `{{check_context}}`
- review policy: `{{review_policy_summary}}` (CSV-aware reviewer roster
  recorded in the dossier roles/training section)
- agent pool roster: as in single-project mode, but the validation mode for
  each agent profile is `ci-delegated` unless the dossier authorizes
  otherwise
- dossier path inside the target product repo:
  `{{target_repo}}/.ordo/validation/`

GxP-grade mode requires:

- explicit pinning of the toolkit baseline used for IQ/OQ/PQ;
- recorded operator identities and training references;
- review-required PR gates that align with the dossier review policy;
- forbidden actions list at every agent includes `bypass-validation`,
  `merge-without-gate`, and `secret-write`.

## Usage

In addition to the single-project loop, GxP-grade mode adds:

| Step | Command |
| --- | --- |
| Scaffold dossier | `bash scripts/csv_dev_mode.sh <project-config> --target-dir <target> --dossier-dir .ordo/validation --json` |
| Apply dossier scaffold | `bash scripts/csv_dev_mode.sh <project-config> --target-dir <target> --dossier-dir .ordo/validation --apply` |
| Controlled operation plan/verify/record | `bash scripts/controlled_operation.sh <project-config> plan|verify|record ...` per `docs/controlled-operations.md` |

Direct dispatch and any other exception path go through the controlled
operation evidence file. The matrix gate from
`templates/agents/direct-dispatch-exception.md` is mandatory for any direct
tmux assignment.

## Troubleshooting

| Symptom | Diagnosis | Safe remediation |
| --- | --- | --- |
| Dossier section reports `NOT VALIDATED` | csv_dev_mode default disposition | leave as-is; only an accountable human review may change disposition |
| `controlled_operation verify` fails with exit code 10 | evidence file contains a prohibited secret-material key (`value`, `password`, `private_key`, `token_value`, `credential`) | scrub the evidence file, re-verify; never commit secret material to evidence |
| Reviewer notes deviation in IQ/OQ/PQ | open or unresolved deviation in the dossier | record `DEV-<phase>-<id>`, link CAPA per `docs/orchestrator-injected-rules.md`, do not auto-close |
| CI gate red on validated baseline | regression on a tracked control point | fix on the same branch; do not skip the gate, do not flip to normal-dev |

## Audit Evidence

- validation dossier: `{{target_repo}}/.ordo/validation/` with sections
  defined in `docs/validation/README.md`
- IQ/OQ/PQ reports: `csv-iq-*.md`, `csv-oq-*.md`, `csv-pq-*.md` and the
  `evidence/` subdirectories under `docs/validation/`
- final report: `csv-val-02-final-report.md`
- controlled-operation evidence: `{{controlled_operation_evidence_root}}`
- audit log file: `{{audit_log_file}}`
- ORDO state base: `{{orch_state_base}}`

Every IQ/OQ/PQ report that creates, closes, or relies on a CAPA item must
reference the durable item and the linked evidence used for disposition,
per `docs/orchestrator-injected-rules.md`.

## Known Limitations

- `csv_dev_mode.sh` scaffolds dossier templates only; it never validates,
  approves, waives, or releases anything;
- the current ORDO dossier disposition is `NOT RELEASED` and
  `NOT PRODUCTION READY`; see `docs/validation/csv-val-02-final-report.md`;
- agent reports, generated summaries, check signatures, and any other
  automated output **cannot** approve validated use, waive a deviation, or
  release a regulated deployment (the CSV boundary in
  `templates/orch_briefing.md`);
- GxP-grade mode does not lift any restriction in normal-dev mode, and
  GxP-only rules MUST NOT be applied silently to normal-dev products in
  the same portfolio.

## Update Policy

- the toolkit baseline used by IQ/OQ/PQ is pinned in the dossier; bumping
  the pin is a controlled change with its own dossier update;
- profile and identity updates flow through the dossier roles/training
  section before being applied to project configs;
- on credential rotation, capture the rotation in the operator audit trail
  and reference the dossier rotation log per `SECRETS.md`.

## Docs Impact

Refresh this docs pack whenever any of the following ship. Use the
checklist in [`docs-impact.md`](docs-impact.md):

- toolkit baseline pin change for the validated deployment;
- dossier section addition, deletion, or disposition change;
- operator identity or training record update;
- new controlled operation type added to the deployment;
- regulatory scope change (added system, retired system, scope reduction);
- CAPA opened, transferred, or closed against this product;
- Six Sigma option toggled on or off (DMAIC interactions are documented
  separately in [`sixsigma.md`](sixsigma.md)).
