# Mode: External-Agent Handoff ORDO Deployment

> Template — copy into the documentation tree of `{{project_name}}` and
> replace every `{{placeholder}}` before publishing.

This template documents the operating shape where a local agent (an
operator running an agent in their own terminal or IDE) prepares an
**issue pack** and hands it to a remote orchestrator instead of dispatching
work directly. It is the default doctrine documented in
`docs/external-agent-skills.md`. Use this docs pack when the team includes
external collaborators using their own runtime (Claude, Codex, Cursor,
Copilot, Gemini, or any generic CLI agent).

> **Boundary.** Local agents in this mode MUST NOT call
> `dispatch_ticket.sh`, `agent_product_switch.sh`, `cycle.sh`, or any
> other ORDO script that mutates remote agent state. The orchestrator owns
> remote dispatch.

## Installation

- toolkit version: `{{ordo_release_tag}}` for the orchestrator and any
  in-house agent; external agents may run any provider runtime
- toolkit checkout (orchestrator side): `{{absolute_path_to_ordo_checkout}}`
- project profile (orchestrator side): `{{absolute_path_to_project_profile}}`
- external-agent skill template: `templates/agents/local-skill-default.md`
- direct-dispatch exception template (orchestrator only):
  `templates/agents/direct-dispatch-exception.md`
- agent config template: `templates/agents/agent-config.sh.tpl`
- agent profile examples: `examples/agents/*.agent.example.sh`
- credentials: each agent loads its own provider tokens from the operator
  credential source per `SECRETS.md`

```bash
# Operator on the orchestrator side
export ORDO_PROJECT_PROFILE={{absolute_path_to_project_profile}}
bash {{absolute_path_to_ordo_checkout}}/scripts/agent_pool_status.sh \
  examples/ordo.config.sh --tsv
```

External agents do not run ORDO scripts. They only consume the local skill
template and produce issue packs.

## Integration

- repo: `{{owner}}/{{repo}}`
- default branch: `{{default_branch}}`
- orchestrator agent (in-house): `{{orchestrator_label}}`
- external agent roster (label, runtime, provider account):
  - `{{label_a}}` / `{{runtime_a}}` / `{{provider_account_a}}`
  - `{{label_b}}` / `{{runtime_b}}` / `{{provider_account_b}}`
- handoff destination: `{{notification_target}}` (for example a tmux pane,
  a chat channel, or a webhook — the local handoff policy referenced from
  `docs/dispatch-planning.md` defines the format)
- audit ledger location: `{{external_agent_handoff_ledger_path}}`

The agent config for every external worker uses
`templates/agents/agent-config.sh.tpl`. Forbidden actions list MUST include
`remote-dispatch` for every non-orchestrator agent; the only role allowed
to remove it is the orchestrator.

## Usage

External-agent loop:

1. external agent reads the assigned issue or operator request;
2. external agent plans locally (no remote dispatch, no force-push, no
   merge);
3. external agent prepares an issue pack: parent epic plus atomized child
   issues following the local handoff policy referenced from
   `docs/dispatch-planning.md`;
4. external agent emits the configured `NEW ISSUE PACK READY`-style
   notification to `{{notification_target}}`;
5. external agent stops.

Orchestrator loop:

1. orchestrator runs `portfolio_session_start.sh` (portfolio) or
   `agent_pool_status.sh` (single-project) preflight;
2. orchestrator picks up the new issue pack, validates against the
   dispatch matrix gate (issue #253), and dispatches per
   [`single-project.md`](single-project.md) or [`portfolio.md`](portfolio.md);
3. orchestrator records the dispatch and the eventual merge in the
   configured audit log;
4. on completion, orchestrator notifies the external agent through
   `{{notification_target}}` and updates the handoff ledger.

## Troubleshooting

| Symptom | Diagnosis | Safe remediation |
| --- | --- | --- |
| External agent attempted direct dispatch | external agent profile is missing `remote-dispatch` from forbidden actions | rebuild the profile from `templates/agents/agent-config.sh.tpl`, re-load default prompt from `templates/agents/local-skill-default.md` |
| Issue pack arrives without `NEW ISSUE PACK READY` notification | external agent skipped the handoff step | external agent must re-run the handoff step; orchestrator should not pick up packs that lack the standard notification |
| Orchestrator cannot find the matrix row for a direct dispatch | dispatch matrix is stale or missing | refresh the matrix per issue #253 before any direct tmux assignment; use `templates/agents/direct-dispatch-exception.md` |
| External agent uses a provider account that collides with the orchestrator | identity overlap | each agent profile sets a distinct `ORDO_AGENT_GITHUB_IDENTITY`; rotate per `SECRETS.md` |

## Audit Evidence

- external-agent handoff ledger: `{{external_agent_handoff_ledger_path}}`
  (one record per pack: source agent, issue list, scope, evidence pointer,
  timestamp, notification reference)
- per-agent audit roots: each agent profile sets `ORDO_AGENT_AUDIT_ROOT`
- orchestrator audit log: `{{audit_log_file}}`
- ORDO state base: `{{orch_state_base}}`
- controlled-operation evidence (only when a direct-dispatch exception is
  authorized): `{{controlled_operation_evidence_root}}`

## Known Limitations

- this mode does not by itself enforce a validation grade; combine with
  [`gxp-grade.md`](gxp-grade.md) when a regulated product is involved;
- external agents cannot observe orchestrator state directly; the audit
  ledger and notification surface are the contract;
- direct dispatch remains an exception, not an alternative path; multiple
  exceptions in the same wave are a smell that should drive process work
  rather than more matrix rows.

## Update Policy

- whenever a new external collaborator joins the deployment, copy the
  appropriate runtime example from `examples/agents/`, fill in the
  config, run the operator-policy review, and add the agent to the
  handoff ledger;
- whenever the local handoff policy changes, refresh
  `templates/agents/local-skill-default.md` and notify every external
  agent to reload its default prompt;
- on toolkit upgrades, verify the orchestrator briefing template
  (`templates/orch_briefing.md`) and the dispatch template
  (`templates/dispatch-canonical.md.tpl`) still match the operator policy.

## Docs Impact

Refresh this docs pack whenever any of the following ship. Use the
checklist in [`docs-impact.md`](docs-impact.md):

- external-agent roster change (added, removed, runtime change);
- handoff notification target change;
- local skill template revision;
- direct-dispatch exception template revision;
- audit ledger schema or location change;
- secrets policy change affecting external agents.
