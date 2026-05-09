# API Rate Limiting Runbook (#409)

This runbook documents how ORDO shapes outbound API call rate to keep the
12-pane fleet under per-org Anthropic limits and avoid 429 storms during a
full restart cycle. It pairs with `lib/api_rate_limiter.sh` and the
hooks installed in `scripts/dispatch_ticket.sh` and
`scripts/portfolio_session_start.sh`.

## Why this exists

Across the 12-pane fleet debug logs, the orchestrator and several worker
panes were repeatedly hitting Anthropic HTTP 429 on `/v1/messages` during
fan-out waves. A single ordo restart cycle accumulated ~293 distinct 429
events and ~875 retry attempts. Each storm correlated with:

1. A wave of `dispatch_ticket.sh` / `portfolio_session_start --apply`
   runs that fanned out to all panes inside the same ~50 ms window.
2. Orchestrator-side bookkeeping (status sweeps, planner rehydration)
   firing in tight succession.
3. Auto-mode classifier requests bursting in sync with main turn
   requests.

ORDO does not call `/v1/messages` itself — the agent CLIs (`claude`,
`codex`, `gemini`, …) inside each tmux pane do. ORDO controls the two
levers that actually matter for aggregate fleet QPS:

- **WHEN** each pane begins its first prompt after a fan-out.
- **WHEN** any future ORDO-direct API caller (orchestrator wrappers,
  bookkeeping scripts) is allowed to issue its request.

The first lever is staggered by per-pane jitter. The second is gated by
a token-bucket limiter. Both share a structured 429 audit sink so the
storm reduction is verifiable.

## Defaults

| Knob | Default | Rationale |
| --- | --- | --- |
| `ORDO_API_RATE_LIMIT_RPS` | `5` | Steady-state requests per second across ORDO-direct callers. Sits below the ~8–10 concurrent in-flight rate at which the per-org limit was observed to engage. |
| `ORDO_API_RATE_LIMIT_BURST` | `8` | Token-bucket capacity. Allows a short burst (e.g. orchestrator status sweep) without immediately bottle-necking. |
| `ORDO_API_RATE_LIMIT_JITTER_MIN_MS` | `50` | Lower jitter bound for per-pane fan-out staggering. |
| `ORDO_API_RATE_LIMIT_JITTER_MAX_MS` | `250` | Upper jitter bound. With 12 panes, spreads the burst across roughly 600 ms – 3 s. |
| `ORDO_API_RATE_LIMIT_LOG` | `$ORCH_LOG_DIR/api-rate-limit.log` | Where 429 events are recorded with timestamp, endpoint, retry-after, and originating session. |
| `ORDO_API_RATE_LIMIT_DISABLE` | `0` | Set to `1` to disable both jitter and bucket gating (tests, dry-runs, operator escape hatch). |

## Where the limiter is wired

| Surface | Hook | Effect |
| --- | --- | --- |
| `scripts/dispatch_ticket.sh` | `api_rate_limiter_jitter` immediately before `terminal_dispatch_submit` | Each dispatch waits 50–250 ms before pushing the brief into its target pane. Twelve back-to-back dispatches now spread their first-prompt ignition across ~600 ms – 3 s instead of arriving in lockstep. Honors `ORDO_API_RATE_LIMIT_DISABLE`. Skipped on `--dry-run`. |
| `scripts/portfolio_session_start.sh` (`--apply`) | `api_rate_limiter_jitter` at the top of `inspect_entry` when `APPLY=1` and not in dry-run | Per-agent clone/pull/identity-set mutations stagger so the subsequent agent-CLI startup wave does not arrive simultaneously. Diagnostic (`--tsv`, `--json` without `--apply`) runs are unaffected. |
| Any future ORDO-direct API caller | `api_rate_limiter_acquire <scope>` | Token-bucket gate; sleeps until a token is available, sharing state with sibling ORDO processes via `flock`. |
| 429 surfacing | `api_rate_limiter_record_429 <session> <endpoint> <retry_after>` | Append a structured key=value line to `$ORDO_API_RATE_LIMIT_LOG`. Fail-soft: log-write failures fall back to stderr. |

## Verifying the storm is gone

After the fix is live, run one full ordo restart cycle and inspect the
audit sink:

```bash
tail -F "$ORCH_LOG_DIR/api-rate-limit.log"
```

A typical line:

```
ts=2026-05-08T19:34:11Z event=anthropic_429 session=rbok-orchestrator endpoint=/v1/messages retry_after_sec=4
```

Acceptance for #409:

- During a full ordo restart cycle (`portfolio_session_start --apply` +
  first dispatch wave), aggregate 429 hits across all 12 panes stay
  below 5 within any 60s window.
- Orchestrator pause time attributable to 429 retries drops from the
  pre-fix ~30–90 s per storm to <5 s per storm.
- The new limiter is configurable via the environment variables listed
  above; no code changes are needed to retune.

## Tuning

Two scenarios most often need a knob change:

1. **Anthropic raises the per-org limit.** Bump `ORDO_API_RATE_LIMIT_RPS`
   (and `ORDO_API_RATE_LIMIT_BURST` proportionally — typically `RPS *
   1.5`). Re-run the restart cycle, watch the 429 log; back off if
   storms reappear.

2. **A pane fleet smaller than 12 (or far larger).** Adjust
   `ORDO_API_RATE_LIMIT_JITTER_MAX_MS` so the spread stays close to
   `n_panes * 50 ms` to `n_panes * 250 ms`. Smaller fleets can
   safely shrink the upper bound; very large fleets should grow it.

## Operator escape hatch

If the limiter itself ever causes a problem (e.g., a stuck bucket file
prevents dispatch), run:

```bash
ORDO_API_RATE_LIMIT_DISABLE=1 bash scripts/dispatch_ticket.sh ...
```

The bucket lib is fail-open after 120 sleep cycles even without that
override, so a stuck state file cannot deadlock the dispatch fan-out
indefinitely. Removing the bucket file under
`$ORCH_STATE_BASE/api_rate_limiter/<scope>.bucket` rebuilds the bucket
from scratch on the next acquire.

## Related work

- #327 — orchestrator stall investigation (the visible fleet stall
  symptom that 429 storms produce).
- #339 — dispatch fan-out timing (where the simultaneous-start pattern
  was first reported).
- #341 — API error surfacing (the audit-sink contract this runbook
  inherits).
