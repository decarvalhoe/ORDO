# Orchestrator Injected Rules

ORDO injects these rules into orchestrator agents through
`templates/orch_briefing.md`. They apply to any model and any agent pool.

## Required Rules

1. Preflight before dispatch: run the relevant readiness preflight at session
   start, after remediation, and before assigning work. For portfolios, use
   `portfolio_session_start.sh`.
   `dispatch_plan --ready-only` must be treated as an automatic dispatch input:
   issues classified as `shipped_suspect` are excluded unless the operator
   explicitly passes `--include-shipped-suspect` after reviewing the merged PR
   proof.
2. Strict repo binding: if a product repo is custom or unknown, run
   `portfolio_repo_bind_plan.sh`; require explicit project -> repo ->
   agent-workdir confirmation before clone or dispatch.
3. No silent blockers: rebase-required, merge-conflict, review-required,
   missing checks, pending CI, red CI, draft PRs, auth failures, quota limits,
   and deploy gates must become explicit states and unblock actions.
4. Post-apply verification: after any `--apply`, clone, fast-forward, auto-fix,
   or product switch, run a non-mutating verification pass before dispatch.
5. Continuation guard before stopping: before a final report or clean stop, run
   `continuation_guard.sh` for the active portfolio when available. If it
   returns `continue_required`, continue dispatch, merge, unblock, or rebalance
   work instead of treating the batch as complete.
6. Context isolation: in multi-product mode, mutate only the confirmed target
   workdir. Stop on `context-mismatch`.
7. Metadata-first load policy: prefer git/GitHub/tmux metadata and state JSON
   before pane capture; avoid capture storms.
8. Continuous improvement capture: every operational finding becomes an ORDO
   opportunity item unless it is fixed immediately and validated.

## Opportunity Item Fields

Each durable ORDO opportunity should include:

- finding;
- impact;
- detection signal;
- safe remediation candidate;
- validation or POC plan;
- priority.
