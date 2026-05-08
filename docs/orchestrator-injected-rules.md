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

12. PR operations mode: every project profile MUST declare an explicit
    PR operations mode (`PR_OPS_MODE` config var or `ORDO_PR_OPS_MODE`
    env override). The default and least-privilege value is `observe`
    (read-only). Stricter portfolios opt into `centralized` so final
    PR mutations remain under operator control while agents continue
    to prepare evidence and patches. `delegated` and `autonomous`
    modes are reserved for the remaining children of #357 and are
    refused by `scripts/pr_ops_controller.sh` until those PRs land.
    Required behavior:

    a. Final PR mutations (`merge`, `ready-for-review`, `rerun`,
       `close`, `branch-delete`) MUST go through
       `scripts/pr_ops_controller.sh`, which returns a typed JSON
       decision and a policy exit code (90 unauthorized actor, 91
       missing required gate, 92 override disabled). The
       orchestrator MUST NOT invoke `gh pr merge` (or equivalent)
       without first obtaining an `allowed` decision for the
       current project + action + actor.

    b. Preparation actions (`prepare-fix`, `evidence-record`,
       `comment-audit-only`, `report-status`) are allowed in every
       mode, for every actor, so centralized mode can coexist with
       agent-side remediation work as required by #360 acceptance.

    c. Operator override is allowed ONLY when the project profile
       sets `ORDO_PR_OPS_OVERRIDE_ENABLED=1`. The override flag
       MUST carry a non-empty reason string (`--override <reason>`
       on the controller). The reason is recorded in both the
       audit log and the optional ledger so a later review can
       reconstruct who bypassed which gate and why.

    d. The actor identity is supplied via `ORDO_PR_OPS_ACTOR`
       (default `agent`). The operator pane sets it to `operator`
       explicitly; there is no implicit promotion. An agent never
       silently becomes the operator.

    e. Required gates per action are profile-driven via bash arrays
       (`ORDO_PR_OPS_REQUIRED_GATES_<ACTION>`). The orchestrator
       MUST verify the listed gates upstream and pass the result
       via `--gates <csv>`; the controller refuses with exit 91
       when any required gate is missing from the passed list.

    f. Every decision is durable evidence: `AUDIT LOG ...
       PR_OPS_CONTROLLER ...` for the audit trail, plus a ledger
       entry under `state/<project>/pr_ops_ledger.json` (or
       `--ledger <path>`) carrying the full augmented payload
       (action, mode, actor, required_gates, passed_gates,
       override_reason, decision, reason, pr, project,
       decided_at).

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
