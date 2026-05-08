# Multi-Agent Multi-Config Documentation Templates

This directory contains documentation templates for the deployment modes
ORDO supports. Each template is provider-neutral: agent labels, repo names,
host paths, and CLI runtimes are placeholders. Operators copy a template
into their own docs tree (outside this repository), replace placeholders,
and check the result into the documentation repo for the target deployment.

These templates implement the docs side of epic #257 (multi-agent,
multi-config, multi-project ORDO documentation) and align with the
onboarding/handoff anchors from epic #249.

## Modes

| Mode | When to use | Template |
| --- | --- | --- |
| Single-project | one product repo, one or several agents, one orchestrator | [`single-project.md`](single-project.md) |
| Portfolio / multi-project | one physical agent pool routed across two or more product repos | [`portfolio.md`](portfolio.md) |
| GxP-grade | regulated deployment with CSV/IQ/OQ/PQ dossier expectations | [`gxp-grade.md`](gxp-grade.md) |
| Normal-dev | unregulated everyday product work; no validation dossier obligation | [`normal-dev.md`](normal-dev.md) |
| Six Sigma-enabled | DMAIC autoupgrade and CI autofix loops are turned on | [`sixsigma.md`](sixsigma.md) |
| External-agent handoff | local agent prepares an issue pack for a remote orchestrator instead of dispatching | [`external-agent-handoff.md`](external-agent-handoff.md) |

## Required Sections in Every Mode

Every template carries the same eight section headings so the docs pack stays
predictable across products, modes, and audit reviews:

1. **Installation** — how to obtain the toolkit, project profiles, and
   credentials needed for the mode.
2. **Integration** — how the toolkit plugs into the project's repo, CI,
   provider account, and (where applicable) validation dossier.
3. **Usage** — the day-to-day operator loop with the commands relevant to
   the mode.
4. **Troubleshooting** — symptom → diagnosis → safe remediation table for
   common failure states.
5. **Audit Evidence** — what records the mode produces, where they live, and
   how reviewers consume them.
6. **Known Limitations** — capabilities the mode intentionally does not
   ship and dependencies that block expansion.
7. **Update Policy** — how operators refresh the toolkit, profiles, and
   docs when upstream changes land.
8. **Docs Impact** — when this docs pack must be refreshed; tied to feature,
   validation-grade, GxP option, and Six Sigma option changes (see
   [`docs-impact.md`](docs-impact.md)).

The "Docs Impact" section points at a shared docs-freshness checklist that
the operator runs whenever a tracked change is shipped.

## Provider Neutrality

These templates name agents only by role labels (`planner`, `builder`,
`reviewer`, `external-orchestrator`) and runtimes only by capability
(`terminal-driven`, `IDE-driven`, `chat-driven`, `headless`). They never
hardcode RBOK-only repository names, tmux session IDs, or host paths as
defaults. Vendor names appear only when explaining how a generic CLI field
maps to a specific runtime.

For the underlying agent skill/config doctrine see
`docs/external-agent-skills.md` and the templates under `templates/agents/`.

## Secrets

No template includes secret values, credential directories, or per-account
tokens. All secret-bearing names follow `SECRETS.md` and remain placeholders
until the operator binds them in the operator-controlled credential store.
