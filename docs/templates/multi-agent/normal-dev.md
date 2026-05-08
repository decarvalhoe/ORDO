# Mode: Normal-Dev ORDO Deployment

> Template — copy into the documentation tree of `{{project_name}}` and
> replace every `{{placeholder}}` before publishing. Normal-dev is the
> default mode and **never inherits GxP-grade rules implicitly**.

This template documents an ORDO deployment for unregulated everyday product
work. It is the simplest mode and the baseline for any product that does
not need a CSV/GAMP/CSA-style validation dossier. It builds on
[`single-project.md`](single-project.md) (or
[`portfolio.md`](portfolio.md) when the product is one of several) and
deliberately omits the GxP machinery.

> **Boundary.** GxP-only rules and Six Sigma DMAIC loops MUST NOT activate
> in normal-dev mode unless the operator explicitly enables them via the
> dedicated mode templates. Selecting GxP-grade for a sibling product in
> the same portfolio does not change normal-dev for any other product.

## Installation

- toolkit version: `{{ordo_release_tag}}` (or `main` at SHA `{{base_sha}}`)
- toolkit checkout: `{{absolute_path_to_ordo_checkout}}`
- project profile: `{{absolute_path_to_project_profile}}`
- credentials: provider tokens loaded from `{{operator_credential_source}}`
  per `SECRETS.md`
- prerequisites: `gh`, `jq`, `git`, `bash`, terminal multiplexer

```bash
export ORDO_PROJECT_PROFILE={{absolute_path_to_project_profile}}
bash {{absolute_path_to_ordo_checkout}}/scripts/agent_pool_status.sh \
  examples/ordo.config.sh --tsv
```

No dossier scaffolding is created in this mode. Do not run
`scripts/csv_dev_mode.sh` against a normal-dev product unless the operator
has decided to flip it to GxP-grade and recorded that decision.

## Integration

- repo: `{{owner}}/{{repo}}`
- default branch: `{{default_branch}}`
- CI provider and check rollup: `{{ci_provider}}` / `{{check_context}}`
- review policy: `{{review_policy_summary}}`
- agent pool roster: as in single-project mode; validation mode is
  `ci-delegated` for every agent profile by default
- forbidden actions list at every non-orchestrator agent must include
  `remote-dispatch`, `force-push`, `merge-without-gate`, `secret-write`,
  `bypass-validation`, and `cross-product-mutation`

Local agents follow the issue-pack handoff default
(`templates/agents/local-skill-default.md`). Direct dispatch is the
exception, gated by `templates/agents/direct-dispatch-exception.md`.

## Usage

The standard daily loop is identical to [`single-project.md`](single-project.md).
Normal-dev specifically allows:

- short-lived feature branches with no controlled-operation evidence;
- iterative fixes through normal PRs gated by the configured CI rollup;
- automated atomization through `scripts/dispatch_plan.sh --atomize`;
- normal use of dry-run and apply commands without dossier paperwork.

Normal-dev specifically forbids:

- claiming validated use for a regulated deployment based on green CI
  (the CSV boundary still applies even when the dossier is not in scope);
- enabling DMAIC autoupgrade silently — see [`sixsigma.md`](sixsigma.md).

## Troubleshooting

| Symptom | Diagnosis | Safe remediation |
| --- | --- | --- |
| Operator asks for a validation dossier | mode mismatch — the product needs GxP-grade | switch to [`gxp-grade.md`](gxp-grade.md), scaffold the dossier through `csv_dev_mode.sh`, do not retrofit ad-hoc validation lines into normal-dev |
| Six Sigma autoupgrade fires unexpectedly | the Six Sigma option was enabled in a sibling profile and bled into this one | review the project profile for `SIXSIGMA_AGENT_CAN_PUSH` etc., disable for this product, re-run the audit |
| GxP-style language appears in dispatch briefs | the brief generator is using the wrong template | verify `templates/dispatch-canonical.md.tpl` and the operator policy template select the normal-dev variant |
| Agent runs full repo validators on the host | `--require-local-validators` was set | revert validation mode to `ci-delegated`; CI rollup is the authoritative gate |

## Audit Evidence

- audit log file: `{{audit_log_file}}` (configured via `AUDIT_LOG_FILE`)
- ORDO state base: `{{orch_state_base}}` (set via `ORCH_STATE_BASE`)
- findings ledger: `{{findings_ledger_path}}` outside agent worktrees per
  `docs/orchestrator-injected-rules.md`
- per-agent audit roots: declared in each agent profile per
  `templates/agents/agent-config.sh.tpl`

Normal-dev evidence is operational, not regulatory. It is sufficient for
day-to-day operator review; it does not constitute validated-use proof.

## Known Limitations

- normal-dev mode does not produce or maintain a validation dossier;
- normal-dev mode does not enable DMAIC autoupgrade or CI autofix loops;
- automated outputs and CI signatures cannot release a regulated
  deployment (this rule applies to every mode);
- if a regulated capability is needed later, switch the product to
  GxP-grade explicitly — never flip silently.

## Update Policy

- toolkit upgrades follow the standard single-project policy;
- profile changes are reviewed with the per-agent operator policy template;
- if normal-dev work begins to interact with regulated artifacts, raise the
  question of mode change before continuing.

## Docs Impact

Refresh this docs pack whenever any of the following ship. Use the
checklist in [`docs-impact.md`](docs-impact.md):

- new ORDO feature changes the daily loop or adds an operator command;
- the product flips between normal-dev and GxP-grade (note: a flip in
  either direction is itself a documented event);
- the Six Sigma option is toggled on or off for this product;
- agent pool roster, identity, audit root, or validation mode change;
- review policy or CI check rollup change.
