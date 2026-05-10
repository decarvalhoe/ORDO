# External-Operator Handoff Drill Audit

- Parent: #249
- Child: #434
- Date: 2026-05-10
- Scope: external-operator handoff only; intra-fleet operator transitions are excluded.
- Method: desktop audit of the in-repo handoff, onboarding, agent-template, and deployment-mode artifacts from the perspective of a fresh external operator persona with no chat-history context.

## Summary

The external-operator handoff path is complete in the repository artifacts reviewed. The flow can be followed from a fresh setup through issue-pack notification and orchestrator receipt without relying on chat-only context. Live values such as repository names, tmux targets, credential locations, audit roots, and notification endpoints are intentionally externalized into operator-owned profiles; each such external value is named in an in-repo artifact with a template or schema.

No follow-up issues were filed because no uncovered procedural gap was found. Potential gaps are listed below with explicit `closes-the-gap` notes and citations.

## Handoff Step Audit

| Step | Drill action for a fresh external operator | Supporting in-repo artifact | Gap disposition |
| --- | --- | --- | --- |
| 1 | Select the external-agent handoff deployment mode instead of direct remote dispatch. | `docs/templates/multi-agent/README.md:15-22`; `docs/templates/multi-agent/external-agent-handoff.md:6-17` | closes-the-gap: the mode and boundary are explicit. |
| 2 | Confirm host prerequisites and that the operator owns checkout, credentials, and terminal sessions. | `docs/install.md:1-6`; `docs/install.md:29-40` | closes-the-gap: prerequisites are documented without assuming prior conversation. |
| 3 | Clone or refresh the ORDO control-plane checkout outside short-lived agent worktrees. | `docs/install.md:64-81` | closes-the-gap: checkout ownership and placement are documented. |
| 4 | Run the installer and keep state/token files outside the checkout. | `docs/install.md:83-110`; `docs/install.md:131-145` | closes-the-gap: install effects and token-file boundaries are explicit. |
| 5 | Configure per-agent provider credentials in operator-owned locations. | `docs/install.md:112-129`; `docs/integration.md:180-189`; `docs/external-agent-skills.md:155-171` | closes-the-gap: identity and credential storage are documented as profile-backed inputs. |
| 6 | Define the external project profile with live repo, branch, pane, workdir, login, and audit-log values. | `docs/install.md:150-204`; `docs/integration.md:101-162`; `docs/universal-fleet-manual.md:39-85` | closes-the-gap: live topology is intentionally not committed, but the required profile shape is present. |
| 7 | Provision agent workdirs, identities, and tmux panes matching `AGENT_PANES`. | `docs/install.md:206-224`; `docs/integration.md:164-203`; `docs/universal-fleet-manual.md:245-270` | closes-the-gap: provisioning and mismatch remediation are documented. |
| 8 | For multi-project onboarding, record project alias, branch, validation mode, operator class, runtime root, and agent labels. | `docs/onboarding-multi-project.md:25-57`; `docs/onboarding-multi-project.md:58-91`; `examples/multi-project.portfolio.template.config.sh:35-73` | closes-the-gap: the portfolio manifest/profile data needed by a fresh external operator is templated. |
| 9 | Mark external contributors as `operator_class=external`, verify their own CLI credentials, and default them to normal-dev validation unless explicitly granted GxP scope. | `docs/onboarding-multi-project.md:134-152`; `examples/multi-project.portfolio.template.config.sh:63-73` | closes-the-gap: external-vs-internal operator expectations are explicit. |
| 10 | Configure each local agent with the default prompt, allowed control plane, forbidden actions, audit root, identity, and validation mode. | `docs/external-agent-skills.md:67-88`; `templates/agents/agent-config.sh.tpl:14-65`; `templates/agents/agent-config.sh.tpl:107-113`; `templates/agents/README.md:16-27` | closes-the-gap: the local-agent configuration surface is template-backed. |
| 11 | Review per-agent policy and keep `remote-dispatch` forbidden for non-orchestrator agents. | `templates/agents/operator-policy.md:30-64`; `templates/agents/operator-policy.md:91-101`; `templates/agents/multi-agent-roster.md:58-75` | closes-the-gap: review controls and roster refusal rules are documented. |
| 12 | Verify integration before handoff with read-only fleet/status/planning commands. | `docs/install.md:226-234`; `docs/integration.md:252-267`; `docs/usage.md:63-82` | closes-the-gap: the read-only verification path is documented. |
| 13 | Start the external-agent loop by reading the request, planning locally, and avoiding remote dispatch. | `docs/external-agent-skills.md:22-44`; `templates/agents/local-skill-default.md:44-61`; `docs/issue-pack-handoff.md:17-40`; `docs/issue-pack-handoff.md:47-50` | closes-the-gap: local planning and the no-dispatch boundary are explicit. |
| 14 | Run duplicate checks before creating a new pack. | `docs/issue-pack-handoff.md:51-54`; `docs/issue-pack-handoff.md:109-134` | closes-the-gap: provider-neutral duplicate checks and stop rules are present. |
| 15 | File the nuclear epic with outcome, non-goals, anchors, validation grade, child list, and handoff audit fields. | `docs/issue-pack-handoff.md:55-58`; `templates/issue-pack/nuclear-epic.md:1-12`; `templates/issue-pack/nuclear-epic.md:28-49`; `templates/issue-pack/nuclear-epic.md:56-90` | closes-the-gap: the epic body and filing checklist are templated. |
| 16 | Atomize independently dispatchable child issues with parent links, ownership boundaries, acceptance criteria, validation, risks, and handoff audit fields. | `docs/issue-pack-handoff.md:59-64`; `templates/issue-pack/child-issue.md:1-12`; `templates/issue-pack/child-issue.md:23-42`; `templates/issue-pack/child-issue.md:49-68`; `docs/dispatch-planning.md:405-423` | closes-the-gap: child issue schema and atomization fingerprinting are documented. |
| 17 | Notify the configured remote orchestrator with a `NEW ISSUE PACK READY` payload using the configured provider and target. | `docs/issue-pack-handoff.md:65-69`; `docs/issue-pack-handoff.md:78-107`; `templates/issue-pack/issue-pack-ready.md:1-33`; `templates/issue-pack/issue-pack-ready.md:34-77`; `templates/issue-pack/issue-pack-ready.md:79-92` | closes-the-gap: notification fields and provider-specific forms are documented; target values are profile-owned by design. |
| 18 | Append the durable issue-pack handoff audit ledger entry. | `docs/issue-pack-handoff.md:70-73`; `docs/issue-pack-handoff.md:136-177`; `docs/templates/multi-agent/external-agent-handoff.md:96-105`; `templates/issue-pack/issue-pack-ready.md:86-90` | closes-the-gap: required ledger fields and evidence locations are documented. |
| 19 | Stop after notification; do not assign children, dispatch agents, or push child-scope work until orchestrator acceptance. | `docs/issue-pack-handoff.md:74-76`; `templates/issue-pack/issue-pack-ready.md:94-99`; `docs/templates/multi-agent/external-agent-handoff.md:61-85` | closes-the-gap: the local stop condition and orchestrator-side receipt path are explicit. |
| 20 | Use direct dispatch only as an emergency exception with explicit authorization and a matrix gate. | `docs/external-agent-skills.md:45-65`; `docs/dispatch-planning.md:442-455`; `docs/dispatch-planning.md:536-543`; `templates/agents/direct-dispatch-exception.md:10-24`; `templates/agents/direct-dispatch-exception.md:26-65` | closes-the-gap: exception handling is documented separately and is not needed for the default handoff. |

## Potential Chat-History Dependency Checks

| Potential dependency | Audit result | Disposition |
| --- | --- | --- |
| Notification target might require someone to remember a tmux pane or channel from chat. | The target and provider are required to live in the operator-owned project profile and are read from `ORCH_NOTIFY_TARGET` / `ORCH_NOTIFY_PROVIDER`. | closes-the-gap: `docs/issue-pack-handoff.md:78-107`; `templates/issue-pack/issue-pack-ready.md:8-17`. |
| External operator identity might require private context. | The docs require each external agent to bring its own CLI credentials, map identity through profiles, and keep secrets outside the repo. | closes-the-gap: `docs/onboarding-multi-project.md:134-152`; `docs/install.md:112-129`; `docs/external-agent-skills.md:155-171`. |
| Agent prompt and forbidden-action posture might be known only from prior sessions. | The local skill template, agent config template, operator policy template, and roster template all preserve the no-remote-dispatch default. | closes-the-gap: `templates/agents/local-skill-default.md:1-12`; `templates/agents/agent-config.sh.tpl:29-58`; `templates/agents/operator-policy.md:41-64`; `templates/agents/multi-agent-roster.md:58-75`. |
| Multi-project external onboarding might require RBOK-specific examples. | The multi-project onboarding extension defines generic manifest/profile fields, and the template tells external agents to use their own credentials and normal-dev defaults unless granted more scope. | closes-the-gap: `docs/onboarding-multi-project.md:25-57`; `docs/onboarding-multi-project.md:134-152`; `examples/multi-project.portfolio.template.config.sh:10-17`. |
| Orchestrator receipt and acceptance might be implicit. | The handoff policy records an accept/reject ledger event using the same `audit_id`; the external-agent deployment template states that the orchestrator picks up the pack, dispatches through the normal mode docs, records dispatch/merge, notifies the external agent, and updates the ledger. | closes-the-gap: `docs/issue-pack-handoff.md:175-177`; `docs/templates/multi-agent/external-agent-handoff.md:75-85`. |
| Full local validators might be assumed from prior operator practice. | Validation is documented as CI-delegated by default, with only cheap foreground checks unless explicitly authorized. | closes-the-gap: `docs/dispatch-planning.md:74-90`; `templates/agents/local-skill-default.md:79-85`; `templates/issue-pack/child-issue.md:34-42`. |

## Judgment Calls

- Treated operator-owned live values as not-a-gap when the repo provides a schema, template, or explicit profile field and says the value must stay outside committed docs.
- Treated direct dispatch as out of the default handoff path because the repo documents it as an emergency exception with separate authorization and matrix-gate requirements.
- Did not file follow-up issues because the audit found no missing step that depends on chat-history context.

Verdict: complete
