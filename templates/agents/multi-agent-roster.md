# Multi-Agent Roster Template

> Template — copy into the documentation tree of `{{project_name}}` (or
> the portfolio's docs tree) and replace every `{{placeholder}}` before
> publishing. The roster is the operator-readable inventory of every agent
> that participates in this deployment.

The roster sits next to the agent profile files (one per agent, derived
from `templates/agents/agent-config.sh.tpl`) and the per-agent operator
policy notes (derived from `templates/agents/operator-policy.md`). It is
used during onboarding, audits, and credential rotation.

## Header

- project / portfolio: `{{project_or_portfolio_name}}`
- mode: `{{single-project | portfolio | gxp-grade | normal-dev | sixsigma | external-agent-handoff}}`
- toolkit version: `{{ordo_release_tag}}`
- last review: `{{iso8601_date}}` by `{{operator_label}}`
- next review due: `{{iso8601_date}}`

## Agent Inventory

Replace the rows below. Keep the column order and types so the roster is
machine-readable.

| Agent Label | Role | Runtime | Provider Account | Workdir | TMUX Target | Default Prompt File | Allowed Control Plane | Forbidden Actions | Audit Root | Validation Mode | Standing Direct-Dispatch Authorization |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `{{label_a}}` | `{{role_a}}` | `{{runtime_a}}` | `{{provider_account_a}}` | `{{workdir_a}}` | `{{tmux_target_a}}` | `{{default_prompt_file_a}}` | `{{allowed_control_plane_a}}` | `{{forbidden_actions_a}}` | `{{audit_root_a}}` | `{{validation_mode_a}}` | `{{none|controlled-operation-id}}` |
| `{{label_b}}` | `{{role_b}}` | `{{runtime_b}}` | `{{provider_account_b}}` | `{{workdir_b}}` | `{{tmux_target_b}}` | `{{default_prompt_file_b}}` | `{{allowed_control_plane_b}}` | `{{forbidden_actions_b}}` | `{{audit_root_b}}` | `{{validation_mode_b}}` | `{{none|controlled-operation-id}}` |
| `{{label_c}}` | `{{role_c}}` | `{{runtime_c}}` | `{{provider_account_c}}` | `{{workdir_c}}` | `{{tmux_target_c}}` | `{{default_prompt_file_c}}` | `{{allowed_control_plane_c}}` | `{{forbidden_actions_c}}` | `{{audit_root_c}}` | `{{validation_mode_c}}` | `{{none|controlled-operation-id}}` |

Roles are vendor-neutral and reused across the docs pack:

- `planner` — local agent that plans work and emits issue packs;
- `builder` — agent that implements bounded issues per dispatch briefs;
- `reviewer` — agent that reviews PRs against operator policy;
- `external-orchestrator` — remote orchestrator authorized for direct
  dispatch through the dispatch matrix gate;
- `visual-checker` — opt-in agent for the visual lane (see
  `examples/agents/visual-check.agent.example.sh`);
- `{{custom_role}}` — any additional role; document scope inline.

Runtimes are referenced by capability and provider. The runtime example set is
machine-readable and must stay in parity with `docs/external-agent-skills.md`;
none of these examples is an implied default:

- `examples/agents/claude.agent.example.sh`
- `examples/agents/codex.agent.example.sh`
- `examples/agents/cursor.agent.example.sh`
- `examples/agents/copilot.agent.example.sh`
- `examples/agents/gemini.agent.example.sh`
- `examples/agents/generic-cli.agent.example.sh`

The visual lane has a separate opt-in example,
`examples/agents/visual-check.agent.example.sh`, because it is role-specific
rather than part of the runtime parity set.

## Roster Rules

The orchestrator must refuse to operate against a roster that violates any
of the rules below.

- exactly one row per agent label; no duplicate labels in the same
  deployment;
- at most one row carries the `external-orchestrator` role; that row is
  the only one allowed to omit `remote-dispatch` from forbidden actions;
- every row's `Forbidden Actions` cell includes
  `merge-without-gate`, `secret-write`, `bypass-validation`, and
  `cross-product-mutation`;
- every row's `Validation Mode` cell is `ci-delegated` unless an operator
  policy note authorizes `require-local-validators`;
- every row's `Audit Root` cell points outside of the agent's worktree;
- standing direct-dispatch authorization is `none` for non-orchestrator
  agents unless a current controlled-operation evidence file references the
  authorization (see `docs/controlled-operations.md`).

## Linkage

- agent profile files: `{{absolute_path_to}}/profiles/agents/<label>.sh`
  (rendered from `templates/agents/agent-config.sh.tpl`);
- operator policy notes: `{{absolute_path_to}}/profiles/agents/<label>.policy.md`
  (rendered from `templates/agents/operator-policy.md`);
- skill templates: `templates/agents/local-skill-default.md` and
  `templates/agents/direct-dispatch-exception.md`;
- vendor-neutral runtime examples:
  `examples/agents/claude.agent.example.sh`,
  `examples/agents/codex.agent.example.sh`,
  `examples/agents/cursor.agent.example.sh`,
  `examples/agents/copilot.agent.example.sh`,
  `examples/agents/gemini.agent.example.sh`,
  `examples/agents/generic-cli.agent.example.sh`;
- opt-in visual-lane example:
  `examples/agents/visual-check.agent.example.sh`;
- mode-specific docs packs: `docs/templates/multi-agent/`.

## Review Checklist

- [ ] Every label is unique.
- [ ] Every non-orchestrator agent forbids `remote-dispatch`.
- [ ] Every audit root is operator-controlled and outside agent worktrees.
- [ ] Every validation mode entry matches the deployment mode default.
- [ ] Standing direct-dispatch authorizations have not expired.
- [ ] Provider accounts are distinct from the operator's personal account.
- [ ] Credential rotation cadence is current per `SECRETS.md`.
- [ ] Any `{{custom_role}}` entry has a documented scope and policy note.
