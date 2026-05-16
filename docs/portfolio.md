# Portfolio dispatch (#721)

`scripts/portfolio_dispatch.sh` unifies `dispatch_plan` across the
projects declared in a portfolio config, applies per-project capacity
caps, and either prints the resulting plan (default) or hands the
assembled matrix to `dispatch_wave` under a single wave id with
`--apply`.

```
scripts/portfolio_dispatch.sh <portfolio-config> <wave-id>
  [--apply]            Forward the matrix to dispatch_wave.
  [--dry-run]          Forwarded to dispatch_wave (no real submit).
  [--limit N]          Hard cap across all projects.
  [--matrix-out PATH]  Where to write the TSV matrix (default: tempfile).
  [--project NAME]     Constrain to one project for surgical dispatches.
  [--json]             Emit the plan as JSON.
```

## Portfolio-config fields consumed

- `PORTFOLIO_PROJECTS` (`project|config-path` rows) — the projects to
  walk. Already required by every other portfolio helper.
- `PORTFOLIO_MAX_CONCURRENT_DISPATCHES` *(optional)* — bash array of
  `project=N` entries; overrides per project. Same form as
  `PORTFOLIO_PRIORITIES`.
- `PORTFOLIO_DEFAULT_MAX_CONCURRENT_DISPATCHES` *(optional, default
  `1`)* — fallback when neither the portfolio override nor the project
  config set `MAX_CONCURRENT_DISPATCHES`.

The per-project config file may set `MAX_CONCURRENT_DISPATCHES=<n>` to
declare its own cap; the portfolio override (when present) wins.

## Capacity & filtering

Rows are dropped before they reach the matrix when any of the
following hold:

- `local_assigned: true` in `dispatch_plan`'s JSON output (another
  agent already holds the ticket — see issue #499).
- `conflict_with: [<ticket>...]` non-empty (the scope-claim ledger
  flags an active overlap — see [docs/dispatch.md](./dispatch.md)).
- No brief is staged at `/tmp/dispatch-<agent>-<ticket>.md`. The row
  appears in the preview as `status=brief_missing`, but is excluded
  from the matrix so `dispatch_wave` cannot try to submit an empty
  prompt. Override the staging dir via `ORCH_DISPATCH_STAGING_DIR`.

## Wave id

`<wave-id>` must match `[A-Za-z0-9._-]+` (same constraint as
`dispatch_wave.sh`). Every dispatched row in the wave lands in
`$ORCH_STATE_BASE/_waves/<wave-id>.json`, so one portfolio call
produces a single wave ledger that an integrator can consume with the
existing `dispatch_wave` tooling.

## Preview vs. apply

The default is preview-only: nothing is dispatched. The TSV matrix is
written to `--matrix-out` (or a tempfile whose path is printed on
stderr) so an operator can inspect the planned wave before opting in.
`--apply` invokes `dispatch_wave` against the matrix; combine with
`--dry-run` to forward the dry-run flag through to `dispatch_wave`
without touching agent panes.
