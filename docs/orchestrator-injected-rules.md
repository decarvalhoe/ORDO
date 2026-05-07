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
   Full local repository validators are CI-delegated by default; `gh pr checks`
   or the orchestrator/PR CI gate is valid verification evidence. Local full
   validators require explicit `--require-local-validators` opt-in.
5. Continuation guard before stopping: before a final report or clean stop, run
   `continuation_guard.sh` for the active portfolio when available. If it
   returns `continue_required`, `dispatch_required`, or `rebalance_required`,
   continue dispatch, merge, unblock, or rebalance work instead of treating the
   batch as complete. Capacity with ready work requires one explicit outcome
   before stopping: dispatch the next ready issue, merge or unblock a
   higher-priority PR first, mark the ready issue blocked with a reason, or
   create an unblock/remediation task.
6. Context isolation: in multi-product mode, mutate only the confirmed target
   workdir. Stop on `context-mismatch`.
7. Metadata-first load policy: prefer git/GitHub/tmux metadata and state JSON
   before pane capture; avoid capture storms.
8. Continuous improvement capture: every operational finding becomes a tracked
   GH issue **at the moment of detection**, not at end-of-session. Chat-only
   findings are forbidden — they are lost when the session ends.

   Required actions on detection:

   a. **Audit log line** in the project's audit log (e.g., `/var/log/orch/<project>.log`):
      ```
      AUDIT LOG: <ts> FINDING source=<context-id> code=<short-kebab-id> severity=<low|medium|high> summary=<one-line>
      ```
      Use `audit "FINDING ..."` from `lib/audit_log.sh` when sourceable; fall
      back to a direct `>>` append otherwise.

   b. **GH issue** in the project repo (e.g., `RBOKproject/ORDO`) with:
      - title prefix `fix(<area>):`, `refactor(<area>):`, or `feat(<area>):`
        matching the finding nature;
      - labels `type:bug` / `type:investigation` / `parallel-safe` as applicable;
      - body sections: `## Source`, `## Symptom`, `## Impact`,
        `## Suggested remediation`, optional `## Workaround applied` if a
        same-wave patch was already issued.

   c. If the finding required an immediate workaround during the wave, file the
      issue anyway with the `## Workaround applied` section; the structural
      fix still needs tracking.

   d. Group findings from the same wave under a common `source=<wave-id>`
      audit field so traceability across multi-finding waves is preserved.

   The only exception is a finding fixed and validated within the same commit:
   in that case the commit message must reference the symptom + remediation,
   and no separate issue is required. Any finding that requires follow-up
   work (even minor) is filed as an issue.

## Opportunity Item Fields

Each durable ORDO opportunity should include:

- finding;
- impact;
- detection signal;
- safe remediation candidate;
- validation or POC plan;
- priority.
