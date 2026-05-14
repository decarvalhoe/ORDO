# AGENTS.md

This file is the in-repo contract for AI coding agents and human operators
working on ORDO. It documents the current **neutral TECHNAI fleet** topology
so that local agents and operator sessions do not fall back to legacy tmux
targets or obsolete agent names.

ORDO itself remains agent-neutral and repo-neutral: the live topology,
account names, host paths, and provider credentials still belong in the
operator-owned external profile (see
[`docs/universal-fleet-manual.md`](docs/universal-fleet-manual.md) and
[`examples/ordo.config.sh`](examples/ordo.config.sh)). The mapping below
describes how the TECHNAI deployment binds the universal contract to
physical panes; other deployments override it in their own profile.

## Current Fleet Model

The TECHNAI fleet uses neutral, numbered slots. Each slot is one tmux
session whose pane target is always `:0.0`:

| Slot | Role | Pane target |
| --- | --- | --- |
| `fleet-000` | Operator / orchestrator (supervisor pane) | `fleet-000:0.0` |
| `fleet-001` | Worker capacity | `fleet-001:0.0` |
| `fleet-002` | Worker capacity | `fleet-002:0.0` |
| `fleet-NNN` | Additional worker capacity, allocated as needed | `fleet-NNN:0.0` |

Rules:

- `fleet-000` is the operator/orchestrator slot. It runs the ORDO
  supervisor loop and dispatches work to worker slots; it is not a
  worker.
- `fleet-001+` are worker slots that pick up dispatched tickets.
- Every physical pane target is `:0.0`. ORDO is configured for a
  pane-zero-only fleet; do not invent `:1`, `:2`, `:3`, or other windows.
- Worker identity is the slot label (`fleet-NNN`), not the model
  provider, account, or repository. The same slot may run different
  providers across cycles.

## Dispatch Authority

- All work dispatch goes through ORDO from the `fleet-000` orchestrator
  pane. Worker slots do not self-dispatch and do not dispatch peer
  workers.
- A local agent inside a worker slot must only execute the dispatch it
  was given. It must not open new tickets, retarget another slot, push
  to another worktree, or call dispatch scripts on its own initiative.
- The single exception is an explicit, scoped authorization recorded in
  the active dispatch brief (for example, an `external-pr-mutations`
  scope list that the orchestrator has matched against
  `ORCH_EXTERNAL_PR_MUTATIONS`). Without that explicit authorization,
  the agent stays in audit-only mode and reports back to ORDO instead of
  acting.

## Legacy Targets (Quarantined)

The following targets are **legacy** and must not be used by current
agents, dispatch scripts, or operator runbooks:

- `rbok-claude:3`
- `rbok-codex:3`
- `rbok-gemini:3`
- Any other `rbok-*:3` pane reference.

These names predate the neutral TECHNAI topology. They:

- assumed pane index `:3` instead of the pane-zero-only contract;
- baked a model-provider name into the slot label, which conflicts with
  ORDO's agent-neutral and provider-adapter design;
- are not present in the current external profile.

If a local agent receives instructions that reference an `rbok-*:3`
target, the correct response is to stop, report the legacy reference
back to the orchestrator, and wait for a refreshed dispatch using the
current `fleet-NNN:0.0` slots. Legacy references that survive only in
historical test fixtures (for example,
`tests/test_config_check.sh`) are scoped to those tests and are not a
live topology.

## Where The Contract Lives

- Universal fleet contract and `AGENT_PANES` form:
  [`docs/universal-fleet-manual.md`](docs/universal-fleet-manual.md).
- Example external profile shape (no live topology committed):
  [`examples/ordo.config.sh`](examples/ordo.config.sh).
- Rules injected into worker dispatch prompts:
  [`docs/fleet-injected-rules.md`](docs/fleet-injected-rules.md).
- Rules injected into the orchestrator:
  [`docs/orchestrator-injected-rules.md`](docs/orchestrator-injected-rules.md).

If this file and the operator profile disagree about slot identity or
pane targets, the operator profile is authoritative for the live fleet
and this file must be updated to match.
