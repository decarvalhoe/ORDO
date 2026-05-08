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
   Operational refusals from the toolkit surface as documented exit codes
   (the 75–79 ORDO refusal band, plus 124/137 for timeouts). The full
   mapping of code to meaning to remediation lives in
   [`docs/exit-codes.md`](exit-codes.md); orchestrator agents inspecting
   a non-zero dispatch result must treat that manifest as the canonical
   reference rather than guessing from the numeric value.
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
   before stopping: dispatch every ready issue that fits available free
   capacity, rebalance parkable capacity when needed, merge or unblock a
   higher-priority PR first, or record an explicit blocker for each idle ready agent
   that cannot receive work. If ready-only planning is empty but full planning
   still reports atomization candidates, shipped-suspect review, or blocked
   work, treat that as continuation work rather than idle capacity.
6. Post-merge cleanup: after a successful gated merge, run the safe cleanup
   path for the merged branch. Clean matching worktrees may be fetched, switched
   to the configured default branch, fast-forwarded, and have stale assignment
   state cleared. Dirty or mismatched worktrees must be left untouched and
   recorded as blockers.
7. Context isolation: in multi-product mode, mutate only the confirmed target
   workdir. Stop on `context-mismatch`.
8. Metadata-first load policy: prefer version-control metadata, issue or
   change-request metadata, terminal multiplexer metadata, and state JSON
   before terminal capture; avoid capture storms.
9. Production CAPA and self-improvement capture: every operational finding
   becomes a tracked improvement opportunity **at the moment of detection**,
   not at end of run. Use a tracked work item directly, or capture it first
   in a live ledger for curation. Chat-only findings are forbidden because they
   are lost when the run ends. Live findings ledgers must be kept outside
   active agent worktrees by default. Use `scripts/findings_ledger.sh <project>
   append ...` for operator-run ledgers, then curate durable items instead of
   leaving untracked report files in a checkout.

   Required actions on detection:

   a. **Linked audit evidence** in the configured audit trail:
      ```
      AUDIT LOG: <ts> FINDING source=<context-id> code=<short-kebab-id> severity=<low|medium|high> summary=<one-line>
      ```
      Use `audit "FINDING ..."` from `lib/audit_log.sh` when sourceable; fall
      back to the configured append-only audit trail otherwise.

   b. **Tracked work item or change request** in the configured project
      repository with:
      - title prefix `fix(<area>):`, `refactor(<area>):`, or `feat(<area>):`
        matching the finding nature;
      - labels `type:bug` / `type:investigation` / `parallel-safe` as applicable;
      - body sections for `finding`, `impact`, `detection signal`, `safe
        remediation candidate`, `validation/POC plan`, `priority`, and `linked
        audit evidence`;
      - optional `workaround applied` section if a same-wave patch was already
        issued.

   c. If the finding required an immediate workaround during the wave, file the
      durable record anyway with the workaround section; the structural fix
      still needs tracking unless it was fixed and validated in the same
      commit.

   d. Group findings from the same wave under a common `source=<wave-id>`
      audit field so traceability across multi-finding waves is preserved.

   The only exception is a finding fixed and validated within the same commit:
   in that case the commit message must reference the symptom + remediation,
   and no separate issue is required. Any finding that requires follow-up
   work (even minor) must be filed as a tracked item.

10. IQ/OQ/PQ CAPA references: any IQ, OQ, or PQ report that creates, closes, or
    relies on a CAPA or self-improvement item must reference the durable item
    and the linked evidence used for disposition.

11. External-PR-mutation default: external pull-request mutations
    (PR comments, draft/ready toggles, label changes, assignee changes,
    review requests, merge actions) default to **audit-only** or **refused**
    unless the dispatch brief explicitly authorizes the specific scope.
    Verification evidence may always be captured locally without external
    mutation.

    For active project state directories that predate this policy, run the
    one-time idempotent backfill so future incident review can reconcile
    whether a state directory predated the policy or attests to it:

    ```bash
    bash scripts/external_pr_policy_backfill.sh \
      --scan-state-base \
      --apply --json
    ```

    The backfill writes one stable
    `external_pr_policy_initialized.json` marker per project under
    `${ORCH_STATE_BASE:-${XDG_DATA_HOME:-$HOME/.local/share}/orch-state}/<project>/`.
    Re-running is safe; every previously initialized project is reported as
    `already-initialized` and no marker bytes change. The script never
    writes inside any git working directory.

12. Assigned workdir vs live pane cwd: structured-state reports
    (`agent_pool_status`, `portfolio_status`, `dispatch_ticket`'s
    `CONTEXT_PROOF_OK` audit line) describe the **assigned** workdir per
    project profile. They are not, by themselves, proof that the live tmux
    pane's `#{pane_current_path}` is equal to that workdir. Soft-routed
    dispatches and post-switch panes can diverge.

    Required behaviour:

    a. Treat any structured-state field named `workdir`, `target_workdir`,
       or equivalent as the **assigned** workdir. `agent_pool_status.sh`
       publishes the columns `assigned_workdir` and `live_pane_cwd`
       separately so the distinction is visible at the surface (#295). When
       only the assigned value is read, the report is structured-state
       evidence, not pane sanitation proof.

    b. Pane sanitation proof requires reading `#{pane_current_path}` (or
       `/proc/<pane-pid>/cwd`) and comparing against the assigned workdir.
       Use `lib/tmux_helpers.sh::pane_current_path` for the canonical read.

    c. When `live_cwd_mismatch` is reported by `agent_pool_status.sh`, do
       not claim the agent is in the assigned workdir without remediation.
       Either run `scripts/agent_product_switch.sh` to re-route the pane,
       or record the dispatch as soft-routed (`cd`-in-prompt mitigation
       only) and capture the divergence in the audit ledger.

    d. Capacity decisions ("agent X is free", "all agents busy") must not
       be derived from `agent_pool_status` alone when `live_cwd_mismatch`
       signals are present for the agents under consideration.

## Opportunity Item Fields

Each durable ORDO opportunity should include:

- finding;
- impact;
- detection signal;
- safe remediation candidate;
- validation or POC plan;
- priority;
- linked audit evidence.

When a finding is promoted to CAPA, the durable item also records the owner,
disposition, verification evidence, and closure or acceptance decision.

## Scope Posture by Project Key (#343)

Every dispatch brief MUST carry a structured Scope Posture block rendered
by `lib/scope_check.sh::ordo_scope_render_block`. The orchestrator MUST
NOT rely on prose like "business repository", "product app", or "company
website" to communicate scope to agents — those phrases are ambiguous
across products and across deployments.

The block carries four mandatory fields and three operator-configured
lists, all expressed by configured project KEY (not by repo path or
naming inference):

| Field | Purpose |
| --- | --- |
| active project key | the project the agent is dispatched to work on |
| active repo | the bound repo URL or path for that key |
| active branch | the target branch for the dispatch |
| scope classification | one of `in_scope` / `held` / `out_of_scope` / `unknown` |
| in-scope project keys | from `ORCH_SCOPE_IN_SCOPE_PROJECTS` |
| held project keys | from `ORCH_SCOPE_HELD_PROJECTS` |
| out-of-scope project keys | from `ORCH_SCOPE_OUT_OF_SCOPE_PROJECTS` |

Required orchestrator behavior:

- Source `lib/scope_check.sh` and inject the rendered block into the
  dispatch template through the `{{scope_posture_block}}` placeholder.
- Call `ordo_scope_validate_active` for the active project key before
  dispatching; refuse on non-zero exit.
- When the call refuses with the structured stderr line
  `needs_scope_clarification: active=<key> classification=<state> source=<reason>`,
  treat that line as the recovery handle: surface it on the operator's
  recovery surface (audit log, findings ledger, paged channel) and do
  not re-dispatch until the operator has either bound the missing key
  in `ORCH_SCOPE_*_PROJECTS` or recorded a per-action authorization in
  a controlled-operation evidence file (see
  `docs/controlled-operations.md`).
- `held` classification passes validation but does not authorize new
  dispatch on its own; the brief must explicitly mention the held state.
- `ORCH_SCOPE_STRICT=1` opt-in: treat `unknown` the same as
  `out_of_scope` for high-stakes deployments.

Required agent behavior (codified in `templates/agent_briefing.md`):

- Read the brief's Scope Posture block as the source of truth.
- Do NOT infer scope from path heuristics, repo naming, or
  free-text descriptions of "business" vs "product" vs "internal".
- If the active project key is `unknown` or `out_of_scope`, STOP and
  report `needs_scope_clarification` with the operator-supplied keys,
  the active project key, and the active repo URL. Do not attempt to
  proceed under any inferred interpretation.

The lib is universal: it never hardcodes vendor CLI names, specific
project names, or repo URLs. Operators bind the keys per deployment
through environment variables loaded from their operator-controlled
profile sources.
