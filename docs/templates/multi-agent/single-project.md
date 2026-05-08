# Mode: Single-Project ORDO Deployment

> Template — copy into the documentation tree of `{{project_name}}` and
> replace every `{{placeholder}}` before publishing. Keep the section
> headings in this order so audit reviews stay predictable.

This template documents an ORDO deployment that coordinates one product
repository and one agent pool. It is the simplest multi-agent shape and a
good baseline before scaling to a portfolio (see [`portfolio.md`](portfolio.md)).

## Installation

- toolkit version: `{{ordo_release_tag}}` (or `main` at SHA `{{base_sha}}`)
- toolkit checkout: `{{absolute_path_to_ordo_checkout}}`
- project profile: `{{absolute_path_to_project_profile}}`
- credentials: provider tokens loaded from `{{operator_credential_source}}`
  per `SECRETS.md` (no values committed)
- prerequisites: `gh`, `jq`, `git`, `bash`, terminal multiplexer of choice

```bash
export ORDO_PROJECT_PROFILE={{absolute_path_to_project_profile}}
bash {{absolute_path_to_ordo_checkout}}/scripts/agent_pool_status.sh \
  examples/ordo.config.sh --tsv
```

## Integration

- repo: `{{owner}}/{{repo}}`
- default branch: `{{default_branch}}`
- CI provider: `{{ci_provider}}` with check rollup `{{check_context}}`
- review policy: `{{review_policy_summary}}`
- agent pool roster (label, role, runtime, GitHub identity):
  - `{{label_a}}` / `{{role_a}}` / `{{runtime_a}}` / `{{provider_account_a}}`
  - `{{label_b}}` / `{{role_b}}` / `{{runtime_b}}` / `{{provider_account_b}}`
- orchestrator agent: `{{orchestrator_label}}` (the only agent allowed to
  call `dispatch_ticket.sh` directly)

The integration follows the project profile contract documented in
`README.md` of the toolkit. The profile binds the agent pool, repo, default
branch, supervisor workdir, and audit log path.

## Usage

The standard daily loop for a single-project deployment:

| Step | Command |
| --- | --- |
| Preflight | `bash scripts/agent_pool_status.sh <project-config> --tsv` |
| Plan | `bash scripts/dispatch_plan.sh <project-config> --ready-only --json` |
| Dispatch | `bash scripts/dispatch_ticket.sh <project-config> <agent> <issue> <prompt.md>` |
| Smart poll | `bash scripts/smart_poll_agents.sh <project-config> <wave-id>` |
| PR signals | `bash scripts/pr_block_signals.sh <project-config> --tsv` |
| Integrate | `bash scripts/integrate_wave.sh <project-config>` |
| Gated merge | `bash lib/pr_merge.sh <project-config> <pr-number>` |

Local agents in this mode follow the issue-pack handoff default
(`templates/agents/local-skill-default.md`). Direct dispatch is reserved
for the orchestrator agent, with the matrix gate documented in
`templates/agents/direct-dispatch-exception.md`.

## Troubleshooting

| Symptom | Diagnosis | Safe remediation |
| --- | --- | --- |
| `dispatch_plan` shows queue empty but operator expects work | issues missing `priority:*` label or assigned to a closed milestone | label issues, then re-run; do not bypass with `--include-shipped-suspect` unless the merged PR proof was reviewed |
| Agent reports `context-mismatch` | pane cwd or git remote does not match the project profile | re-cd to the configured workdir, refresh `git remote -v`, and re-run preflight |
| `pr_merge` refuses with `pending checks` | configured CI rollup hasn't finished | wait or fix the failed step on the same branch — do not pass `--admin` to bypass |
| Agent loops on validators | `--require-local-validators` was set without operator authorization | revert validation mode to `ci-delegated` in the agent profile |

## Audit Evidence

- audit log file: `{{audit_log_file}}` (configured via `AUDIT_LOG_FILE`)
- ORDO state base: `{{orch_state_base}}` (set via `ORCH_STATE_BASE`)
- portfolio state: not used in this mode
- findings ledger: `{{findings_ledger_path}}` outside agent worktrees, per
  `docs/orchestrator-injected-rules.md`
- per-agent audit roots: declared in each agent profile per
  `templates/agents/agent-config.sh.tpl`

## Known Limitations

- single-project mode does not coordinate cross-product capacity; for that,
  switch to portfolio mode using [`portfolio.md`](portfolio.md);
- without the GxP option, the deployment does not scaffold or maintain a
  validation dossier (`docs/validation/...`);
- without the Six Sigma option, no DMAIC autoupgrade or CI autofix loops
  run; see [`sixsigma.md`](sixsigma.md);
- the orchestrator agent is the only authorized entry point for direct
  dispatch and remote tmux mutation.

## Update Policy

- pin the toolkit to a tagged release whenever possible;
- after pulling a new toolkit version, re-run the preflight commands
  (`agent_pool_status`, `dispatch_plan --ready-only`) before resuming
  dispatch;
- review `templates/agents/operator-policy.md` per agent on every toolkit
  upgrade so default prompt SHA, audit root, and validation mode stay
  current.

## Docs Impact

This docs pack must be refreshed whenever any of the following changes ship.
Use the checklist in [`docs-impact.md`](docs-impact.md) and record the
diff in the PR body.

- new ORDO feature changes the daily loop or adds an operator command;
- validation-grade changes (for example flipping to GxP or back to normal-dev);
- GxP option toggled on or off;
- Six Sigma option toggled on or off;
- agent pool roster changes (label, runtime, identity, audit root);
- credential rotation or operator-policy review.
