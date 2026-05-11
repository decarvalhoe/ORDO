# Agent Status Declarations

ORDO agents can declare their current work state through a provider-neutral
local status contract. The declaration is advisory evidence for the
orchestrator: it complements pane, process, git, assignment, and PR signals
without replacing acceptance proof or handoff policy.

## Design Choice

The chosen path is an agent-written local JSONL ledger plus one atomic
latest-status file per agent:

- agents call `scripts/agent_status.sh declare ...`;
- ORDO writes under `$ORCH_STATE_BASE/<project>/agent-status/`;
- `agent_pool_status.sh` batch-reads latest files during its existing capacity
  pass and exposes declaration state separately from inferred capacity;
- `handoff_ready` and `done` declarations append a durable event row and touch
  `$ORCH_STATE_BASE/<project>/orch.run_now`; when a same-node `orch_loop.sh`
  process is visible, the helper also sends a local `SIGUSR2` nudge. This gives
  same-node orchestrators a no-SSH continuation signal with a durable fallback.

This is less intrusive than the alternatives:

| Alternative | Cost | Failure modes | Decision |
| --- | --- | --- | --- |
| Piggyback only on dispatch, audit, or capacity ticks | No extra write path, but agents cannot signal completion between scans | Completed work waits for broad scans; blocked agents may look healthy until the next audit | Reused for consumption, not declaration |
| Agent-written status files or JSONL rows | One local append plus one atomic write per declaration; batched local reads | Stale files, malformed JSON, or missing declarations need health signals | Selected |
| Explicit helper command from prompts | One foreground shell command, no provider API coupling | Agents may omit it; stale/missing declarations must remain visible | Selected entry point |
| Long-lived watcher | Fast event reaction | Extra process lifecycle, noisy failure surface, and risk of runaway monitors | Rejected for the base contract |
| Per-agent SSH or tmux polling | Familiar to existing operators | Remote round trips, pane coupling, and same-node overhead | Rejected except as existing fallback evidence |

## Status Vocabulary

Allowed `status` values are:

- `accepted`
- `working`
- `blocked`
- `waiting_for_operator`
- `validating`
- `finalizing`
- `done`
- `no_progress`
- `handoff_ready`

`blocked`, `waiting_for_operator`, `no_progress`, `handoff_ready`, and `done`
also surface explicit declaration signals in `agent_pool_status.sh`.

## Declaration Schema

Every declaration is JSON with `schema_version: 1`.

Required fields:

- `project`: project key such as `ordo`;
- `agent_id`: provider-neutral agent id or label;
- `target`: issue, PR, or handoff target, for example `issue:638`;
- `status`: one allowed state;
- `reason`: short human-readable reason;
- `timestamp`: UTC ISO timestamp.

When available, declarations include:

- `workspace.workdir` or `workspace.id`;
- `git.branch`, `git.head`, and `git.dirty`;
- `evidence`: path or URL to supporting evidence.

Optional advisory indicators live under `optional`:

- `phase`
- `last_activity_ts`
- `progress_note`
- `blocker_category`
- `required_operator_action`
- `validation_state`
- `handoff_url`
- `dependency`
- `permission_state`
- `retry_count`
- `next_action`

Missing optional indicators never invalidate the declaration. Stale or
contradictory indicators are health evidence for the operator, not hard
capacity facts.

## Helper Usage

Agents emit status with:

```bash
bash scripts/agent_status.sh declare \
  --project ordo \
  --agent RBOK-codex \
  --target issue:638 \
  --workdir "$PWD" \
  --status working \
  --reason "implementing scoped declaration contract" \
  --phase implementation \
  --validation-state pending \
  --next-action "run focused tests"
```

The helper auto-detects branch, HEAD, and dirty count when `--workdir` is a git
checkout. It writes:

- `agent-status/declarations.jsonl`: append-only declaration ledger;
- `agent-status/latest/<agent-key>.json`: atomic latest declaration;
- `agent-status/events.jsonl`: durable continuation queue for `done` and
  `handoff_ready`;
- `agent-status/wake.pending` and `orch.run_now`: local wake markers for
  same-node orchestrators.
- `agent-status/wake.signal`: last local loop signal attempt and count.

## Capacity Consumption

`scripts/agent_pool_status.sh <project> --json` includes a `declaration` object
per agent:

```json
{
  "state": "fresh",
  "status": "working",
  "reason": "implementing scoped declaration contract",
  "target": "issue:638",
  "timestamp": "2026-05-11T08:00:30Z",
  "age_sec": 30,
  "evidence": "",
  "optional": {"phase": "implementation"},
  "wake_pending": 0,
  "required_action": ""
}
```

The TSV view appends declaration columns after the existing `signals` column.
This keeps the inferred capacity columns stable while making declared status
operator-visible.

## Staleness And Missing Declarations

`AGENT_STATUS_STALE_AFTER_SEC` controls freshness. The default is 900 seconds.

- Fresh declaration: `declaration.state == "fresh"`.
- Stale declaration: `declaration.state == "stale"` and signal
  `agent-declaration-stale`.
- Missing declaration: `declaration.state == "missing"` and signal
  `agent-declaration-missing`.

These signals do not by themselves prove an agent is idle or busy. They are
actionable operator prompts: refresh the declaration, inspect the agent, or
recover the assignment if other signals agree.

## Same-Node Wake-Up

Same-node fleets do not need SSH to hand work back to the orchestrator. A
`handoff_ready` or `done` declaration appends an event row, touches the project
`orch.run_now` marker, and sends `SIGUSR2` to a same-node `orch_loop.sh
<project>` process when one is visible. If the orchestrator is busy or not
running, the event remains in `events.jsonl` and `wake_pending` stays visible in
capacity output until an operator or future consumer drains it. Remote-node
deployments may transport the same JSONL events in batches, but the base
contract does not require per-agent remote polling.
