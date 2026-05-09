# Classifier outage runbook (#410)

## Why this runbook exists

The Claude CLI's auto-mode classifier — the small policy-decision call
that decides whether a tool use is auto-approved — fails closed during
Anthropic API outages (429 storms or 5xx bursts). When it gives up,
the agent silently downgrades to "ask user". On a headless tmux pane
that is the same as **stalling indefinitely**: nothing prints to the
pane, no main-turn error fires, and the next tool use stays pending
until an operator prods the pane.

ORDO has no native signal for this because the fail-closed line only
appears in the per-session Claude debug log
(`~/.claude/debug/<session>.log`), never in the pane capture.

This runbook describes how to detect and recover from those outages
using the helpers added under issue #410.

## When to use

Open this runbook when **any** of the following fires:

- A pane appears alive (process is running, prompt is rendered) but is
  not advancing through queued work.
- The orchestrator's hourly status sweep
  (`scripts/portfolio_status.sh --json`) reports a non-zero
  `counts.classifier_fallback_count` for any project.
- A live debug-log scan reports recent fail-closed events:
  ```bash
  bash -c '
    source lib/classifier_outage.sh
    classifier_outage_summary_json
  ' | jq '.total'
  ```

## How detection works

`lib/classifier_outage.sh` is a pure read-only scanner:

| Function | What it does |
| --- | --- |
| `classifier_outage_log_dirs` | Print configured debug log directories. Default: `$HOME/.claude/debug`. Override with `ORCH_CLASSIFIER_OUTAGE_LOG_DIRS` (colon-separated). |
| `classifier_outage_default_patterns` | Print the default ERE pattern set. Override with `ORCH_CLASSIFIER_OUTAGE_PATTERNS_FILE`. |
| `classifier_outage_scan_file <log>` | Count fail-closed lines in one log file. Always emits an integer. |
| `classifier_outage_scan_per_session` | Emit `<session>\|<count>\|<file>` rows for every log file in every configured dir. |
| `classifier_outage_summary_json` | Aggregated JSON: `{total, scanned_files, by_session, files, log_dirs, patterns_source}`. |
| `classifier_outage_total` | Print only the fleet-wide total. |
| `classifier_outage_count_for_sessions <sess>...` | Sum counts for the named sessions only (used by `portfolio_status.sh` to attribute counts to projects via their `AGENT_PANES`). |

`scripts/portfolio_status.sh` calls `classifier_outage_summary_json`
once per sweep, then attributes the per-session counts back to each
project using the project's `AGENT_PANES` session names. Each project
row carries the resulting count under
`counts.classifier_fallback_count` (JSON) and as the
`classifier_fallback_count` column of the TSV variant.

## Diagnosis

1. **Confirm the count from the hourly sweep.** Pin the offending
   project alias and the session-by-session breakdown:
   ```bash
   bash scripts/portfolio_status.sh "$PORTFOLIO_CONFIG" --json \
     | jq '.[] | select(.counts.classifier_fallback_count > 0)
                | {alias, count: .counts.classifier_fallback_count}'

   bash -c '
     source lib/classifier_outage.sh
     classifier_outage_summary_json
   ' | jq '.by_session'
   ```

2. **Open the relevant debug log** to confirm the fail-closed line is
   recent (and not a stale event from a previous incident the operator
   has already resolved):
   ```bash
   tail -n 200 "$HOME/.claude/debug/<session>.log" \
     | grep -E 'classifier: giving up|classifier_fallback'
   ```

3. **Check the pane state.** A genuine classifier-outage stall leaves
   the pane at the prompt with no new lines being printed. Use the
   existing `pane_context_proof` helper to confirm the pane is alive
   and idle, not crashed:
   ```bash
   bash -c '
     source lib/tmux_helpers.sh
     pane_context_proof "<session>:<window>.<pane>" "<workdir>"
   '
   ```

## Remediation

- **Single stalled pane:** prod the pane. The simplest is sending a
  blank `Enter` or a one-line continuation directive via `tmux
  send-keys`, which kicks the agent into asking again — by which point
  the classifier has typically recovered. Capture audit evidence with
  `lib/audit_log.sh`'s `audit` helper.

- **Multiple panes affected (Anthropic outage in progress):** wait for
  the upstream incident to clear. Before resuming dispatch, run the
  usual portfolio preflight refresh
  (`scripts/portfolio_session_start.sh --ensure-fresh`) so the readiness
  matrix reflects the current state.

- **Recurring outages on the same session:** the per-session debug log
  is the canonical evidence trail. Attach the trimmed
  `classifier: giving up`-window to the Anthropic support ticket
  alongside the session's pane capture.

## Forward-compatibility hints

The original finding (#410) lists optional concrete actions that live
inside the Claude CLI itself (deterministic local fallback policy,
`ORDO_CLASSIFIER_FALLBACK` env knob, visible banner). Those are not
implemented in ORDO — ORDO does not own the agent CLI. When the Claude
CLI grows native fallback support, update the default patterns in
`classifier_outage_default_patterns()` so the detector continues to
recognise the new fail-closed signature.

## Related

- `lib/classifier_outage.sh` — the detector (#410).
- `scripts/portfolio_status.sh` — the hourly sweep that surfaces
  `classifier_fallback_count` (#410).
- `lib/prompt_detector.sh` — orthogonal universal interactive-prompt
  detector (#349); it catches *visible* "ask user" prompts, but not
  the silent classifier-fallback case this runbook addresses.
- `docs/runbooks/fleet-preparation.md` — generic fleet recovery
  procedures.
