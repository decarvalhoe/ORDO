# ORDO Operator Runbook

This runbook is the entry point an operator follows when the ORDO
supervisor stops making forward progress on its own. It is generic —
keep live project names, repo URLs, and provider credentials in the
operator profile that invokes ORDO, not in this file.

The autonomy resolver (queue-starvation cluster) tries to recover
from common dead ends before paging a human:

- `#762` auto-close shipped-suspect issues via `closure_acceptance_gate`.
- `#763` auto-atomize epics flagged `needs-atomization` when the ready
  queue starves.
- `#764` reclaim soft-blocked agents idle behind dead briefs.
- `#765` (this surface) escalate explicitly when A/B/C cannot unblock.

When A/B/C all run and the ready queue is still empty, this runbook is
how the operator decides what to do next.

## Queue Starvation Surface (Phase D)

`scripts/queue_starvation_surface.sh` consumes the JSON output of
`scripts/continuation_guard.sh` for the current cycle and decides
whether the supervisor is "starved":

- decision is `continue_required` (the loop refuses to stop), AND
- at least one reason is `atomize-required`,
  `shipped-suspect-review-required`, `unblock-required`, or
  `idle-with-p0-p1-backlog` (all four describe an empty ready queue
  with spare capacity).

Other decisions (`stop_ok`, `dispatch_required`, `merge_required`,
`rebalance_required`, `scan_in_progress`) are not starvation — they
either close the loop cleanly or carry their own forward action.

### Standalone invocation

```bash
timeout 30 bash scripts/continuation_guard.sh <portfolio-config> --json \
  > /tmp/cg-output.json || true

timeout 30 bash scripts/queue_starvation_surface.sh ordo \
  --cycle 200 \
  --continuation-guard-json /tmp/cg-output.json \
  --dry-run --json
```

`--dry-run` (default) prints the decision but writes no state. Add
`--apply` once the operator wants the counter and intervention queue
to update.

### State tracked

`state_dir/queue_starvation_cycles.json` carries the rolling counter:

```json
{
  "consecutive_starved": 5,
  "last_cycle": 200,
  "first_starved_cycle": 196,
  "last_alert_cycle": 200,
  "last_state": "starved",
  "last_decision": "continue_required",
  "last_backlog_breakdown": {
    "atomize_required": 2,
    "shipped_suspect_review": 1,
    "unblock_required": 0,
    "idle_with_p0_p1_backlog": 2
  }
}
```

The counter increments only when `--cycle` advances. A non-starved
cycle resets `consecutive_starved` to `0` and clears
`first_starved_cycle` / `last_alert_cycle`.

### Alert threshold

Once `consecutive_starved` reaches
`ORCH_QUEUE_STARVATION_ALERT_CYCLES` (default `5`), the script emits:

- audit row `QUEUE_STARVED_NO_RESOLUTION cycles=N cycle=N backlog_breakdown=... last_autoresolver_actions=...`
- one new entry in `state_dir/intervention_queue.md`.

Lower the threshold for noisier projects with
`ORCH_QUEUE_STARVATION_ALERT_CYCLES=2 scripts/queue_starvation_surface.sh ...`.

## Reading `intervention_queue.md`

Each entry starts with an ISO-8601 UTC timestamp and the cycle that
crossed the threshold:

```
## 2026-05-20T23:50:09Z — QUEUE_STARVED_NO_RESOLUTION (cycle 200)

- project: ordo
- consecutive starved cycles: 5 (threshold=5)
- first starved cycle: 196
- continuation_guard decision: continue_required
- backlog breakdown: atomize_required=2,shipped_suspect_review=1,unblock_required=0,idle_with_p0_p1_backlog=2
- last autoresolver action items: atomize-required=2,shipped-suspect-review-required=1,idle-with-p0-p1-backlog=2
- recommended operator actions:
  - review docs/operator-runbook.md (queue starvation section)
  - run dispatch_plan --atomize --dry-run if atomize_required>0
  - review shipped_suspect rows if shipped_suspect_review>0
  - unblock or record explicit blockers if unblock_required>0
  - add fresh P0/P1 requirements if idle_with_p0_p1_backlog>0
  - if the autoresolvers cannot make progress, pause the loop
```

Work the entry top-to-bottom. Each recommended action maps to a
specific counter in the backlog breakdown so the operator only has to
follow the lines whose count is `> 0`.

### Decide the next operator action

Use the backlog breakdown to pick the smallest unblocking step. Stop
once the loop reports a non-starved cycle.

| Counter `> 0`                 | Operator action                                                                                  |
| ----------------------------- | ------------------------------------------------------------------------------------------------ |
| `atomize_required`            | `bash scripts/dispatch_plan.sh <cfg> --atomize --dry-run` then `--apply` once the plan is sane.  |
| `shipped_suspect_review`      | Inspect the merging PR's acceptance evidence; close manually or backfill `acceptance` proof.     |
| `unblock_required`            | Record the explicit blocker on the issue, or dispatch unblock work via `scripts/dispatch_ticket.sh`. |
| `idle_with_p0_p1_backlog`     | Add fresh P0/P1 requirements (the backlog has no atomized leaves left to dispatch).              |

If every recommended action has been tried and the next cycle still
reports starvation:

1. Pause the supervisor loop (operator-specific stop command).
2. Capture evidence: `state_dir/queue_starvation_cycles.json` plus
   the last continuation_guard JSON snapshot.
3. File a follow-up issue referencing the latest `QUEUE_STARVED_NO_RESOLUTION`
   audit row so the autonomy cluster can be extended (a new
   autoresolver, or a new ready-queue source).

## Stop Conditions

Pause the supervisor before doing anything destructive when:

- repository readiness preflight is failing;
- product intent for the starved project is ambiguous (no operator
  knows which P0/P1 ticket should land next);
- a recommended action would require committing secrets or running
  outside the dispatch-evidence path;
- the autonomy cluster keeps re-alerting on the same backlog row
  cycle after cycle — that means the resolver is missing a category
  and a code change is required, not another operator nudge.
