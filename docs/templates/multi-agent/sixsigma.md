# Mode: Six Sigma-Enabled ORDO Deployment

> Template — copy into the documentation tree of `{{project_name}}` and
> replace every `{{placeholder}}` before publishing. The Six Sigma option
> is opt-in. It is independent of the GxP-grade option and never the
> default.

This template documents an ORDO deployment that turns on the Six Sigma
DMAIC autoupgrade and CI autofix loops described in
`docs/sixsigma-autoupgrade.md`. It can stack on top of normal-dev or
GxP-grade; in the latter case the GxP boundaries from
[`gxp-grade.md`](gxp-grade.md) still apply.

> **Boundary.** Enabling Six Sigma for one product MUST NOT silently enable
> it elsewhere. Each project profile is an explicit opt-in via the
> `SIXSIGMA_*` and `CI_AUTOFIX_*` variables. Disabling Six Sigma reverts the
> product to its underlying mode (normal-dev or GxP-grade).

## Installation

- toolkit version: `{{ordo_release_tag}}`
- toolkit checkout: `{{absolute_path_to_ordo_checkout}}`
- project profile: `{{absolute_path_to_project_profile}}`
- credentials: provider tokens loaded from `{{operator_credential_source}}`
  per `SECRETS.md`; if push automation is enabled, the per-agent token
  must be present
- prerequisites: identical to single-project plus the autoupgrade scripts
  (`sixsigma_autoupgrade.sh`, `ci_autofix.sh`)

```bash
export ORDO_PROJECT_PROFILE={{absolute_path_to_project_profile}}
bash {{absolute_path_to_ordo_checkout}}/scripts/sixsigma_autoupgrade.sh \
  {{project_config}} --dry-run
```

Always begin in `--dry-run`. Promote to live runs only after operator
review.

## Integration

- repo: `{{owner}}/{{repo}}`
- default branch: `{{default_branch}}`
- CI provider and check rollup: `{{ci_provider}}` / `{{check_context}}`
- DMAIC scope: `{{dmaic_scope}}` (define which CI failures are in scope for
  autoupgrade and which require human triage)
- per-agent autopush: `SIXSIGMA_AGENT_CAN_PUSH` and
  `CI_AUTOFIX_AGENT_CAN_PUSH` declared explicitly in the project profile
- watcher cadence: `CI_WATCHER_INTERVAL_SEC`, `CI_WATCHER_LOOKBACK`
- maximum autofix dispatches per cycle: `SIXSIGMA_MAX_AUTOFIX_DISPATCHES`

The Six Sigma option does not bypass the configured CI rollup or branch
protection. It expands the operator's ability to react to red checks
quickly while keeping the gated merge contract intact.

## Usage

| Step | Command |
| --- | --- |
| Audit autoupgrade plan | `bash scripts/sixsigma_autoupgrade.sh <project-config> --dry-run` |
| Apply autoupgrade | `bash scripts/sixsigma_autoupgrade.sh <project-config>` |
| CI autofix | `bash scripts/ci_autofix.sh <project-config> <pr#> <agent>` |
| Workflow audit | `bash scripts/gh_actions_optimize.sh <project-config> --audit` |
| Watch checks | `bash scripts/ci_watcher.sh <project-config>` |

The autofix loop never bypasses CI: it generates a remediation prompt and
re-dispatches the original agent, which fixes the failing step on the same
branch. The gated merge path remains the only release surface.

## Troubleshooting

| Symptom | Diagnosis | Safe remediation |
| --- | --- | --- |
| Autofix dispatches loop on the same agent | the failing step is structurally broken (not a transient flake) | stop the watcher, fix the underlying step manually, re-enable Six Sigma after one clean pass |
| `SIXSIGMA_MAX_AUTOFIX_DISPATCHES` reached | the cycle limit fired | review the failing step; do not raise the limit silently |
| Six Sigma changes appear in normal-dev briefs | DMAIC vocabulary leaked into the wrong template | verify the dispatch template selection per project; adjust `templates/dispatch-canonical.md.tpl` only through the documented update policy |
| Per-agent push fails with auth error | per-agent token missing or expired | rotate per `SECRETS.md`; never paste tokens into briefs or comments |

## Audit Evidence

- autoupgrade audit log: appended via `audit "SIXSIGMA ..."` and
  `audit "CI_AUTOFIX ..."` lines in the configured audit log file
- watcher state: `{{orch_state_base}}/{{project_name}}/ci_watcher.json`
- autofix dispatches: durable issue/PR comments and the same audit log
- findings ledger: opportunities and CAPA candidates discovered while in
  the loop go through `scripts/findings_ledger.sh` per
  `docs/orchestrator-injected-rules.md`

## Known Limitations

- Six Sigma mode does not change the validation grade; if the product is
  GxP-grade, dossier rules still bind every change;
- autoupgrade and autofix never approve a release; the gated merge through
  `lib/pr_merge.sh` remains the only release surface;
- watcher and autofix loops require operator-owned credentials; they will
  not run if `CI_AUTOFIX_AGENT_CAN_PUSH=0` or the per-agent token is
  missing;
- DMAIC vocabulary is documentation-only — the toolkit does not enforce a
  particular DMAIC phase model.

## Update Policy

- toggle the Six Sigma option only in writing through the operator policy
  template;
- adjust `SIXSIGMA_MAX_AUTOFIX_DISPATCHES` and watcher cadences only after
  reviewing the audit log of the previous cycle;
- whenever a watcher or autofix script is upgraded, re-run a `--dry-run`
  pass before resuming live cycles.

## Docs Impact

Refresh this docs pack whenever any of the following ship. Use the
checklist in [`docs-impact.md`](docs-impact.md):

- the Six Sigma option is toggled on or off for this product;
- DMAIC scope changes (added or removed CI categories);
- watcher cadence, autofix limit, or per-agent push policy change;
- new autoupgrade or autofix script lands in the toolkit;
- a coverage gap is found through the autofix loop and gets a CAPA
  follow-up.
