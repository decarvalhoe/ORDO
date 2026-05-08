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

11. External PR mutation authority gate: verifying a third-party-managed pull
    request and mutating it are different authority levels. The default policy
    is audit-only — capture local evidence and stop. Any external mutation
    requires an explicit per-action scope in `ORCH_EXTERNAL_PR_MUTATIONS` (or
    the equivalent dispatcher flag, `--external-pr-mutations`).

    The recognised scopes are repo-neutral and provider-neutral:

    - `audit_evidence` — local capture only; always authorized; never
      sufficient by itself for any external mutation.
    - `issue_pack_notify` — notify the orchestrator's own issue pack.
    - `pr_comment` — post a comment on an externally-managed PR.
    - `pr_state` — flip draft/ready/reopen/close on such a PR.
    - `pr_labels` — add or remove labels on such a PR.
    - `pr_assignees` — add or remove assignees on such a PR.
    - `pr_merge` — merge such a PR.

    Required behaviour:

    a. Default is audit-only. Without an explicit scope, capture evidence
       under the project state directory using `record_local_gate_evidence`
       (see `lib/audit_log.sh`) and stop. Do not post comments, change PR
       state, edit labels or assignees, or merge.

    b. A dispatch prompt that needs an external mutation must declare it on
       its own line, in the same family as `require-local-validators`:

       ```text
       - external-pr-mutations: pr_comment,pr_state
       ```

       `dispatch_ticket.sh` refuses the dispatch with exit code
       `ORCH_EXTERNAL_PR_MUTATION_REFUSED_EXIT_CODE` (default 80) when the
       prompt requests scopes that are not in the authorized set.

    c. Every dispatch records the resolved policy. When no declaration is
       present the audit line is `DISPATCH external_pr_mutations ...
       requested=<none> ... mode=audit-only`. When a declaration is present
       the line records the requested and authorized scopes.

    d. The rule is repo-neutral: scope names refer to the abstract action,
       not to any particular repository, organization, or provider.

    e. CAPA traceability: when an external mutation was performed under an
       authorized scope, the durable record of the action (audit entry plus
       any saved evidence path) is the linked evidence required by rule 9.

    f. Backfill for pre-policy projects: for active project state
       directories that predate this rule, run the one-time idempotent
       backfill so future incident review can reconcile whether a state
       directory predated the policy or attests to it:

       ```bash
       bash scripts/external_pr_policy_backfill.sh \
         --scan-state-base \
         --apply --json
       ```

       The backfill writes one stable
       `external_pr_policy_initialized.json` marker per project under
       `${ORCH_STATE_BASE:-${XDG_DATA_HOME:-$HOME/.local/share}/orch-state}/<project>/`.
       Re-running is safe; every previously initialized project is reported
       as `already-initialized` and no marker bytes change. The script never
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

12. External PR mutation authority gate: every external GitHub mutation —
    `gh pr merge`, `gh pr comment`, `gh pr review`, `gh pr ready`,
    `gh pr edit`, `gh pr close`, `gh pr reopen`, `gh pr create`,
    `gh issue create|comment|edit|close|reopen`, including the
    `--add-label` / `--remove-label` and `--add-assignee` / `--remove-assignee`
    variants of `gh ... edit` — must pass through `external_pr_mutation_assert`
    from `lib/external_mutation_gate.sh` before the mutation is invoked.
    Default policy is **audit-only**: with no `ORCH_EXTERNAL_PR_MUTATIONS`
    declared, every refusable scope is denied and the assertion exits with
    `ORCH_EXTERNAL_PR_MUTATION_EXIT_CODE` (default `80`). The
    `audit_evidence` scope is always allowed because it never leaves the
    host; orchestrators that need only verification capture should call
    `record_local_gate_evidence` and stop. Operators authorize per scope by
    setting `ORCH_EXTERNAL_PR_MUTATIONS` (comma-separated) or passing
    `--external-pr-mutations <list>` to `dispatch_ticket.sh`. Recognised
    scopes (repo-/provider-neutral): `audit_evidence`, `issue_pack_notify`,
    `pr_comment`, `pr_edit`, `pr_state`, `pr_labels`, `pr_assignees`,
    `pr_review`, `pr_ready`, `pr_merge`, `pr_close`, `pr_reopen`,
    `issue_create`, `issue_comment`, `issue_edit`, `issue_labels`,
    `issue_assignees`, `issue_close`, `issue_reopen`. Every gate decision
    emits an `EXTERNAL_PR_MUTATION action=<scope> mode=<allowed|refused|unknown>
    context=<context>` audit line via `audit_external_mutation` so dashboards
    can group bypass attempts without parsing free-form text. Future scripts
    that introduce a new mutation call site MUST go through the gate; raw
    `gh pr <mutation>` invocations without a preceding
    `external_pr_mutation_assert` are a Rule 12 violation regardless of
    whether the mutation succeeds.

12. Capability lanes go through the central registry: every probe ORDO uses to
    decide whether a class of work is dispatchable (host_health, host_assessment,
    visual, network, auth, future checks) is a "lane". A lane must register
    itself in `lib/lane_registry.sh` (`lane_registry_register <id>
    <description> [env_prefix] [require_command]`) and emit its evidence
    inside the canonical envelope (`lane_registry_evidence_envelope`,
    `schema_version: "ordo.lane.v1"`). Required envelope keys:
    `schema_version`, `lane`, `lane_description`, `captured_at`, `host`,
    `status` (one of `ok`, `warning`, `critical`, `unknown`,
    `unavailable_optional`), `configured`, `available`, `details`. Lanes own
    only their `details` payload; consumers read the wrapper.

    Required behaviour:

    a. New lanes do not invent ad-hoc `ORCH_<LANE>_*` JSON shapes. The
       wrapping shape comes from `lane_registry_evidence_envelope`; lane
       authors only contribute `details`.

    b. Dispatchers and reports must not branch on lane internals. Read the
       envelope (`status`, `configured`, `available`) to decide. If a
       consumer needs lane-specific keys, they belong under `details`.

    c. The list of registered lanes is discoverable via
       `bash scripts/portfolio_status.sh <portfolio-config> --lanes`. New
       lanes appear there without changes to portfolio_status itself.

    d. Lane payloads received from external sources should be validated
       through `lane_registry_envelope_validate` before being trusted.

13. Evidence-path-outside-worktree guard (#313): operator-readable artifacts
    (screenshots, forensic dumps, capability JSON, runtime logs, dispatch
    briefs and any other runtime output) must NOT be written inside an active
    git worktree. The visual lane (#264) added a per-component check; this
    rule generalizes it.

    Required actions:

    a. Artifact-producing scripts must call
       `audit_assert_evidence_outside_worktree <path> [<context>]`
       (from `lib/audit_log.sh`) before opening or copying to the artifact
       path. The helper sources `lib/worktree_helpers.sh::worktree_path_is_inside`
       lazily and emits a structured audit line:
       ```
       AUDIT LOG: <ts> EVIDENCE PATH GUARD status={refused|warned|skipped} path=<p> context=<c> [mode=strict]
       ```

    b. The default mode is `strict` (refuse + return 1). Operators in
       migration may opt down to `warn` or `off` via `ORCH_EVIDENCE_PATH_GUARD`,
       but `off` is reserved for tests and one-off remediation runs — never
       the default in shipping configs.

    c. Dispatch briefs that ask agents to capture artifacts must specify an
       evidence path under `$HOME/`, `/tmp/`, `$XDG_DATA_HOME/`, or another
       location that the guard will accept. Briefs that omit the path leave
       it to the agent and inherit the helper's default of refusing
       in-worktree writes.

12. Autonomous PR operations mode: ORDO supports an opt-in, profile-gated
    autonomous PR ops mode that can evaluate, refuse, and (in live mode)
    merge eligible PRs without per-step manual confirmation. The mode is
    disabled by default. To opt in, the project profile sets
    `AUTO_PR_OPS_ENABLED=1`, picks one of `squash` / `rebase` / `merge`
    via `AUTO_PR_OPS_MERGE_STRATEGY`, declares `AUTO_PR_OPS_ALLOWED_BASES`,
    and (optionally) lists release-gate labels and business-scope path
    prefixes that exclude a PR from autonomy.

    Every evaluation runs the full gate set (`policy_enabled`,
    `not_kill_switched`, `merge_strategy_valid`,
    `target_branch_allowed`, `not_draft`, `mergeable_known_clean`,
    `required_checks_pass`, `required_reviews_satisfied`,
    `no_release_gate_label`, `no_business_scope_exclusion`); any failed
    or unknown gate refuses the PR. Live mode additionally requires
    `AUTO_PR_OPS_MODE=live` *and* the explicit `--apply` flag on
    `scripts/autonomous_pr_ops.sh apply` so a chat prompt cannot
    accidentally trigger a merge.

    The kill switch is a state-dir file
    (`auto_pr_ops_kill_switch.json`) that any operator can engage to
    refuse every subsequent live action across the wave:

    ```bash
    bash scripts/autonomous_pr_ops.sh <project> kill-switch \
        engage --reason "wave halted for incident review"
    bash scripts/autonomous_pr_ops.sh <project> kill-switch status
    bash scripts/autonomous_pr_ops.sh <project> kill-switch release
    ```

    Each evaluation emits a one-line audit summary
    (`AUTONOMOUS_PR_OPS evaluation: repo=… pr=… mode=… strategy=…
    eligible=…`) before any mutation, and a post-action audit line in
    live mode. The library is universal: nothing about the policy,
    strategy, or gate set is hardcoded to a project, agent, or model.
    See `lib/autonomous_pr_ops.sh` for the public helpers and
    `tests/autonomous_pr_ops.bats` for the negative-test matrix.

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

12. PR operations modes (epic #357, #359). When PRs are blocked by CI,
    conflicts, stale branches, or readiness cleanup, the orchestrator
    delegates remediation through `scripts/dispatch_pr_ops.sh` using one of
    four explicit modes. The mode is part of the project profile, not a chat
    option; the script refuses any non-`observe` mode that the profile has
    not authorized via `PR_OPS_MODE_ALLOWED`.

    | Mode | What it does | When to use |
    | --- | --- | --- |
    | `observe` | Classify open blocked PRs into `fix_ci`, `resolve_conflict`, `mark_ready_candidate`, or `none`; emit no tasks. Always allowed. | dry-read of the queue; default for new profiles. |
    | `centralized` | Render dispatch tasks for `fix_ci` and `resolve_conflict`; refuse `mark_ready_candidate` (operator owns ready-flips). | tighter operator control during release windows. |
    | `delegated` | Render and (with `--apply`) dispatch all three task kinds to fleet agents through `dispatch_ticket.sh`, with one PR per agent. | normal multi-agent waves. |
    | `autonomous` | Reserved for a future iteration. Currently refused with `ORCH_PR_OPS_REFUSED_EXIT_CODE` (default 80). | not yet available. |

    Required behaviour:

    a. **One PR per agent per wave.** The script tracks `AGENT_ASSIGNED` and
       refuses a second task for the same agent with
       `blocker:duplicate-assignment`. Operators must not bypass this with
       parallel `dispatch_ticket.sh` calls; doing so re-creates the original
       conflict-storm finding from epic #357.

    b. **Bounded mutation scope.** Each rendered task declares its
       `external-pr-mutations` scope explicitly: `audit_evidence` for
       `fix_ci` and `resolve_conflict`, `audit_evidence,pr_state` for
       `mark_ready_candidate`. Agents must never merge from a delegated
       PR-op task; merge authority is the operator's responsibility unless
       a future autonomous mode lands. The external-PR-mutation gate (rule
       11) enforces this at dispatch time; any prompt requesting a wider
       scope is refused before the brief reaches the pane.

    c. **Refuse on uncertainty.** Dirty agent clones, missing branch,
       unknown mergeability (`mergeable=UNKNOWN`), missing project policy
       (`PR_OPS_MODE_ALLOWED` unset for non-`observe` modes), and
       coordination-surface hotspot conflicts produce blockers, not
       assignments. The orchestrator must surface every blocker row before
       progressing to the next wave.

    d. **Universal templates.** The three task templates under
       `templates/pr_op_*.md.tpl` are agent-CLI-neutral and project-name
       neutral. Any project-specific or model-specific text in a rendered
       prompt is a finding under rule 9 (production CAPA) — file the
       finding and rerender from the canonical template.

    e. **Evidence chain.** Every render and dispatch emits an audit line
       prefixed `PR_OPS DISPATCH ...` or `PR_OPS REFUSED ...`. The wave
       summary line `PR_OPS WAVE summary ...` is the durable evidence of
       the queue state at that moment; the orchestrator's CAPA records
       must reference these lines instead of a chat narrative.

12. Capacity reporting from structured state: free / parkable / busy / switchable
    counts must be derived from `portfolio_status.sh ... --json` and the
    `state/<project>/assignments.json` records, not from anecdotal pane
    inspection. Each per-project summary embeds a `capacity_report` block
    (see `lib/capacity_report.sh`) with explicit `free_pane_ready`,
    `parkable_pr_owners`, `panes_with_work`, `switchable`, `reserved_agents`,
    `supervisor_sessions`, `active_assignments`, and an `evidence_sources`
    map. Required behavior:

    a. The orchestrator MUST NOT narrate "all agents busy" unless
       `capacity_report.busy_claim_valid` is `true` for every project in the
       wave, i.e. `free_pane_ready`, `dispatch_parkable`, and `switchable`
       are all empty.

    b. Open PRs (parkable agents) are NOT counted as physically busy. They
       belong in `parkable_pr_owners` / `open_prs_no_active_work` and remain
       available for the next dispatch unless an explicit reservation is
       configured.

    c. Stale `assignments.json` entries (records where the live pool reports
       the agent as free or parkable) surface in `switchable`, not as busy
       capacity. The structural fix is to re-bind the agent to the right
       product or to clear the stale record after merge.

    d. Supervisor / control panes (e.g. `rbok-orchestrator:0.0`) must be
       declared via `ORDO_SUPERVISOR_SESSIONS` so they appear under
       `supervisor_sessions` rather than being conflated with agent slots.

    e. The `orch` slot is a regular ORDO agent and is FREE by default.
       Reservation is allowed only through explicit profile metadata —
       `ORDO_RESERVED_AGENTS` (portfolio-wide) or
       `ORDO_RESERVED_AGENTS_<ALIAS>` (per-project) — never by name
       convention alone.

    f. Status output must surface `evidence_sources` (assignments path,
       portfolio_status script, agent inventory module) so any capacity
       claim can be traced back to its structured source during audit.
11. Monitor-loop heartbeat (#339): the orchestrator must not park at an
    interactive prompt with stale run-state when in-flight work has gone
    green and queued work is still waiting. After every cycle, run
    `scripts/monitor_heartbeat.sh <project>` (the `orch_loop.sh` daemon
    invokes it automatically; manual operators run it themselves).
    The heartbeat snapshots `(in_flight, in_flight_clean, in_flight_stale,
    queued)` against the previous snapshot at
    `$(state_dir)/orch.monitor_heartbeat.json` and emits a single audit
    line:
    AUDIT LOG: <ts> ORCH_MONITOR_HEARTBEAT classification=<state>
      decision=<action> in_flight=<n> in_flight_clean=<n>
      prev_in_flight_clean=<n> queued=<n>
    Required reactions:
    a. `decision=advance_queue` — set the run-now flag (or, if running
       manually, immediately re-enter the cycle). Triggered when the
       wave just went green or capacity is free with queue pressure.
    b. `decision=block_stale_at_prompt` — emit
       `ORCH_LOOP_STALE_AT_PROMPT` so the operator nudge (`SIGUSR2`,
       manual cycle) is not silent. Triggered when two consecutive
       snapshots match `cur == prev && all in-flight clean && queued > 0`.
    c. `decision=noop` — sleep as usual. The audit line still records
       the snapshot so `git blame`-style debugging across waves stays
       cheap.
    The heartbeat is opt-out via `ORCH_MONITOR_HEARTBEAT_DISABLED=1` for
    operators who run an external monitor; that escape hatch is a
    self-declared waiver and must be recorded in the project profile.

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

## PR Operations Queue (#358)

`scripts/pr_ops_queue.sh` (backed by `lib/pr_ops_queue.sh`) is a read-only
classifier that turns live PR / CI / portfolio state into an explicit
queue of PR operation candidates. It is the **detector half** of the PR
operations governance epic (#357); the future mode dispatcher (observe /
centralized / delegated / autonomous) will consume the queue without
recomputing classification.

The classifier never mutates a PR, never sends keys, and never grants
permissions. Producers, consumers, and operators all rely on the same
JSON schema, which makes the queue stable enough to share between
the orchestrator and downstream tooling.

### Candidate types

There are eight stable candidate types, listed here in dispatch
priority order (highest first):

| Candidate | Priority | When it fires | Action implied for #357 |
| --- | --- | --- | --- |
| `resolve_conflict` | 90 | `merge-conflict` signal observed (mergeable=CONFLICTING or merge_state=DIRTY). Beats every other type because it blocks every downstream action. | Merge conflict resolution. |
| `fix_ci` | 80 | `ci-failed` signal observed. | Investigate failing checks; rerun or push a fix. |
| `refresh_branch` | 70 | `needs-rebase`, `pr-behind`, or `remote-rebased-local-stale`. | Rebase or pull the branch; reapply local fix when the remote was rebased under us. |
| `mark_ready_candidate` | 60 | Draft PR with `ci-pass` and no other blockers. | Promote to ready; merge unblocks the dependent pack. |
| `review_required` | 50 | `review-required` or `changes-requested`. | Awaiting human review; cannot be auto-merged. |
| `merge_candidate` | 40 | `merge-ready` signal. | Eligible for the gated merge path. |
| `hold_unknown_state` | 20 | `mergeable-unknown`, `merge-state-unknown`, or `checks-missing`. | Refresh the PR or rerun checks; no safe automated path until the state is known. |
| `hold_policy_blocked` | 10 | `deploy-gate-external-wait`, `auto-merge-armed`, `merge-blocked`, or `ci-pending` alone. | Waiting on policy / external gate; the orchestrator surfaces it but does not act. |

When a PR matches several signal classes, the highest-priority match
wins. The losing signals stay visible in the candidate's `signals`
array so consumers can inspect them.

### Output schema (`ordo.pr_ops_queue.v1`)

Every classified PR produces one JSON object with these keys:

| Field | Description |
| --- | --- |
| `schema` | Always `"ordo.pr_ops_queue.v1"`. |
| `generated_at` | ISO-8601 UTC timestamp when the queue was built. |
| `alias`, `project`, `repo` | Project alias from the portfolio, the loaded `PROJECT` value, and the configured `GH_REPO`. |
| `pr` | PR number (numeric when parseable). |
| `branch`, `base_branch`, `head` | Head branch name, base branch name, short head SHA. |
| `agent` | Owner agent label inferred from local clones, or `null`. |
| `candidate` | One of the eight types above. |
| `priority` | Numeric priority used for sort order (higher first). |
| `mergeable`, `merge_state`, `review_decision` | Raw GitHub state strings carried through. |
| `ci_summary` | `{total, failed, pending, passed}` derived from the rollup. |
| `signals` | The full `pr_block_signals.sh` signals array for this PR. |
| `is_draft` | Boolean. |
| `updated_at`, `last_update_age_sec` | PR `updatedAt` and the derived age in seconds (or `null`). |
| `linked_issue` | First issue number found in `Closes/Fixes/Refs/Resolves #N` patterns in the PR body, or `null`. |
| `project_policy` | One of `observe` (default), `centralized`, `delegated`, `autonomous`. The classifier records the policy from the project profile but never enforces it. |
| `rationale` | Human-readable explanation of why this candidate type was chosen. |

### Input modes

- `--portfolio <portfolio-config>` — walk every project in the
  portfolio. For each, run `scripts/pr_block_signals.sh --json` and
  classify every PR.
- `--project <project-config>` — single-project mode.
- `--input <file|->` — offline mode reading a JSON snapshot. Two
  shapes are accepted: a flat array of `pr_block_signals` records (must
  be paired with `--project-meta` or `--project-meta-file`), or a
  portfolio-grouped array `[{"alias":...,"project_meta":{...},"prs":[...]}, ...]`.

### Stale-cache refusal

When `--input` is used, the snapshot file's mtime is compared against
`PR_OPS_QUEUE_MAX_AGE_SEC` (default `300`). A snapshot older than that
exits 4 with the canonical line `pr_ops_queue_stale: input=<path>
age_sec=<n> max_age_sec=<m>; pass --allow-stale or refresh the
snapshot`. Live modes (`--portfolio`, `--project`) read fresh data
from `gh` directly and do not trip the staleness refusal.

The `--allow-stale` flag downgrades the refusal to a warning printed
on stderr (`pr_ops_queue_stale_warn: ...`) so an operator can still
inspect an old snapshot deliberately.

### Project policy

A project profile can declare a PR operations policy by exporting
`PR_OPS_QUEUE_POLICY` from its config. Recognized values:

| Policy | Meaning (consumed by #357 mode dispatcher) |
| --- | --- |
| `observe` (default) | Surface candidates only. No agent or operator action implied. |
| `centralized` | Operator/orchestrator handles all PR mutations. Agents may prepare fixes but never push directly. |
| `delegated` | The orchestrator may dispatch fix/refresh/mark-ready candidates to fleet agents under one-bounded-task-per-agent. |
| `autonomous` | Profile-approved full-auto mode. Refused on uncertainty (`hold_unknown_state`, missing reviews, failing CI, etc.). |

The classifier in this PR records the policy in every candidate but
does not enforce it. Enforcement and dispatch sit in #357's mode
dispatcher.

### Universality

The classifier uses no project-name or agent-name hardcoding. Default
matchers, priority values, and the candidate-type list are derived
only from PR signals + mergeability + review state + draft flag.
Tests verify that the same PR fixture under different aliases produces
identical candidates.

### Health-summary obligation

A portfolio summary that lists "healthy progress" while one or more
projects have non-empty `resolve_conflict` / `fix_ci` /
`refresh_branch` queues is incomplete. The PR-ops queue is the
operator-facing source of truth for which PRs need work and in which
order; portfolio summaries SHOULD reference the queue's top entries
when describing progress.

## Workdir Readiness Diagnostics (#367)

`portfolio_assert_workdir_ready` (and the new `portfolio_workdir_readiness_status`
helper in `lib/portfolio_config.sh`) refuse to dispatch into a matrix
workdir that is not in a state to receive fresh work. The 2026-05-08
PRAXIS finding showed that the original implementation collapsed every
unready state into a single "matrix workdir has uncommitted change(s)"
message — even when porcelain proved the tree was clean. The fix
distinguishes ten readiness states and only requires destructive
recovery for the two that genuinely involve uncommitted content.

### Readiness states

| State | Meaning | Recovery action | Destructive? |
| --- | --- | --- | --- |
| `ready` | Clean, on default branch, in sync with `origin/<default>`. | `none` | no |
| `ready_feature_branch` | Clean, on a feature branch whose tip descends from `origin/<default>`. | `none` | no |
| `dirty` | Porcelain non-empty (modified or untracked files present). | `recovery_context_proof_required` | YES |
| `in_progress_op` | A git operation is mid-flight (`MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `rebase-merge/`, `rebase-apply/`, or `BISECT_LOG`). | `recovery_context_proof_required` | YES |
| `wrong_branch` | Clean tree, but on a non-default branch that does NOT descend from `origin/<default>` (typical stale assignment). | `git_checkout_default` | no |
| `behind_origin_default` | Clean, on default branch, behind `origin/<default>`. | `git_pull_ff` | no |
| `ahead_origin_default` | Clean, on default branch, ahead of `origin/<default>`. | `git_push_or_review` | no |
| `detached_head` | Clean, no current branch. | `git_checkout_named_branch` | no |
| `no_clone` | The path is not a git working tree. | `clone_required` | no |
| `no_origin_default` | The clone has no `origin/<default>` ref. | `fetch_origin` | no |

Only `dirty` and `in_progress_op` require destructive recovery
(`RECOVERY_CONTEXT_PROOF`); the other six unready states can be
auto-recovered by the orchestrator with a `git checkout` or
`git pull --ff-only` and a fresh dispatch.

### Audit log fields

When `dispatch_ticket.sh` refuses on `matrix_workdir_not_ready`, the
audit line now includes the porcelain-proven counts and the recovery
hint, so downstream parsers no longer claim "uncommitted changes"
unless porcelain agrees:

```text
DISPATCH REFUSED reason=matrix_workdir_not_ready state=<state>
  branch=<branch> upstream=<upstream-tracking-name>
  ahead=<n> behind=<n>
  dirty=<total> dirty_modified=<n> dirty_untracked=<n>
  in_progress=<marker-or-empty>
  recovery_action=<token> destructive=<0|1>
  agent=<label> project=<alias> workdir=<path>
```

### Side-channel variables

Callers that want the structured state directly (without parsing the
log line) can read these variables after the helper returns:

| Variable | Description |
| --- | --- |
| `PORTFOLIO_WORKDIR_READINESS_STATE` | One of the ten states above. |
| `PORTFOLIO_WORKDIR_READINESS_BRANCH` | Current branch name (empty on detached HEAD). |
| `PORTFOLIO_WORKDIR_READINESS_UPSTREAM` | Upstream tracking name (e.g., `origin/main`). |
| `PORTFOLIO_WORKDIR_READINESS_AHEAD` | Ahead count vs `origin/<default>` (only meaningful on the default branch). |
| `PORTFOLIO_WORKDIR_READINESS_BEHIND` | Behind count vs `origin/<default>`. |
| `PORTFOLIO_WORKDIR_READINESS_DIRTY` | Total porcelain entries. |
| `PORTFOLIO_WORKDIR_READINESS_DIRTY_MODIFIED` | Tracked-modified entries (M/D/A/R/T). |
| `PORTFOLIO_WORKDIR_READINESS_DIRTY_UNTRACKED` | Untracked entries (`??`). |
| `PORTFOLIO_WORKDIR_READINESS_IN_PROGRESS` | Marker name when a git operation is mid-flight. |
| `PORTFOLIO_WORKDIR_READINESS_RECOVERY_ACTION` | Token from the table above. |
| `PORTFOLIO_WORKDIR_READINESS_DESTRUCTIVE` | `1` for `dirty` / `in_progress_op`, `0` otherwise. |
| `PORTFOLIO_WORKDIR_READINESS_RECOVERY_COMMAND` | Suggested non-destructive shell command (empty for destructive states). |

### Orchestrator obligations

1. When refusing on `matrix_workdir_not_ready`, the orchestrator MUST
   surface the readiness `state` and the proposed `recovery_action` —
   not the generic "uncommitted changes" wording.
2. The orchestrator MUST NOT escalate a non-destructive state
   (`wrong_branch`, `behind_origin_default`, etc.) to the operator
   when the recovery_command can be run safely.
3. `RECOVERY_CONTEXT_PROOF` requirements stay intact for `dirty` and
   `in_progress_op`; the orchestrator MUST NOT skip them just because
   another agent's recovery proof exists for a different workdir.
## Interactive Prompt Signals (#349)
Live agent panes can stall on interactive permission prompts (Figma MCP,
Chrome DevTools / browser connectors, auto-mode denials, generic
allow/deny gates). The orchestrator must treat those panes as `blocked
external`, not as healthy busy work. The detector library
`lib/prompt_detector.sh` and the `scripts/prompt_detector_scan.sh`
read-only CLI emit a stable JSON signal the orchestrator and #350 consume.
### Signal schema (`ordo.prompt_detector.v1`)
Every detected prompt produces one JSON object on stdout (line-delimited)
and, with `--persist`, one appended line in the prompt-signals ledger.
| Field | Type | Description |
| --- | --- | --- |
| `schema` | string | Always `"ordo.prompt_detector.v1"`. |
| `detected_at` | string (ISO-8601 UTC) | When the scan ran. |
| `session` | string \| null | tmux session name passed by the caller. |
| `pane` | string \| null | `session:window.pane` form when the source was a pane. |
| `cwd` | string \| null | Effective workdir — explicit `--cwd` wins; else extracted inline from the prompt line if present. |
| `agent` | string \| null | ORDO agent label (e.g. `claude`, `cursor`). |
| `project` | string \| null | Active project / portfolio alias. |
| `ticket` | string \| null | Caller-supplied ticket identifier. |
| `tool` | string | Tool family. Stable values today: `mcp`, `browser-connector`, `auto-mode`, `generic`. |
| `provider` | string \| null | Concrete provider (e.g. `claude.ai-figma`, `chrome-devtools`). |
| `command` | string \| null | Tool subcommand parsed from the prompt (e.g. `get_metadata`). |
| `prompt_class` | string | Routing class. Stable values: `allow-deny-confirmation`, `browser-connector-confirmation`, `auto-mode-denial`, `generic-confirmation`. |
| `matcher_id` | string | The matcher entry id that won (e.g. `figma-mcp-confirm`). |
| `matched_text` | string | The exact pane line that matched. |
| `suggested_option_hint` | string | `review-required` plus a class-aware tip; never an instruction to grant. |
| `prompt_age_sec` | number \| null | Caller-supplied age. The lib does not measure age itself. |
| `linked_issue` | number \| string \| null | Caller-supplied. Numeric when parseable. |
| `linked_pr` | number \| string \| null | Caller-supplied. |
The detector is **read-only**. `suggested_option_hint` is advisory, never
prescriptive; the consumer (#350) decides whether the operator's policy
allows an automatic response or whether to escalate.
### Default matcher catalog
| matcher_id | tool | provider | class | priority | What it matches |
| --- | --- | --- | --- | --- | --- |
| `figma-mcp-confirm` | mcp | claude.ai-figma | allow-deny-confirmation | 110 | `Do you want to proceed?` followed by `claude.ai Figma` on the same line. Highest precedence among MCP allow-deny patterns. |
| `chrome-devtools-connect` | browser-connector | chrome-devtools | browser-connector-confirmation | 105 | `Allow connection ... chrome[-]devtools` on a single line. |
| `auto-mode-denial` | auto-mode | (none) | auto-mode-denial | 100 | `auto-mode (denied|disabled|requires confirmation)`. |
| `browser-connector-confirm` | browser-connector | (none) | browser-connector-confirmation | 95 | Generic `Allow connection (to|from) (browser|chromium|firefox|webkit)` line. |
| `mcp-allow-deny-confirm` | mcp | (none) | allow-deny-confirmation | 90 | Generic `Do you want to proceed? 1.Yes 2.Yes-don't-ask-again` lacking a Figma marker. |
| `generic-confirmation` | generic | (none) | generic-confirmation | 10 | Bare `[y/n]`, `Allow ... Deny ...`, or `Confirm (y/n)` lines. Lowest precedence. |
When several matchers fire on the same line, the highest priority wins.
The detector deduplicates `(matcher_id, matched_line)` so a stuck pane
that loops the same prompt does not produce N copies of the same alert.
### Operator-supplied matchers
Projects can extend the catalog without code changes by setting
`ORCH_PROMPT_MATCHERS_FILE` to a file with one matcher per non-blank,
non-comment line. The format mirrors the default catalog:
matcher_id|tool|provider|class|priority|regex
Example (custom Vault grant prompt):
custom-vault-grant|secrets-manager|hashicorp-vault|allow-deny-confirmation|120|grant access to vault path
User-supplied entries are appended to the defaults; tied priorities
fall back to the most recent declaration order. No matcher is
silently overridden.
### Persistence and ledger location
Records appended via `--persist` go to:
${ORCH_PROMPT_DETECTOR_LEDGER:-${ORCH_STATE_BASE:-${XDG_DATA_HOME:-/root/.local/share}/orch-state}/_prompt_signals/signals.jsonl}
The ledger is JSON-Lines so consumers can `jq -c '.'` it, group by
`pane`, dedupe by `matcher_id`, or fold by `prompt_class`. The path is
intentionally outside any product worktree so a per-product clean
operation cannot wipe fleet evidence.
### CLI entry points
```bash
# Scan a captured pane snapshot or stdin:
bash scripts/prompt_detector_scan.sh --capture <file> \
  --session <name> --pane-id <session:window.pane> \
  --agent <label> --project <alias> --ticket <id> \
  --json --persist --summary
# Scan one or more live tmux panes:
bash scripts/prompt_detector_scan.sh \
  --pane terminal-a:0.0 --pane terminal-b:0.0 \
  --project <alias> --persist
# Scan every pane listed in a file:
bash scripts/prompt_detector_scan.sh --pane-list /tmp/active-panes.txt \
  --project <alias> --persist --summary
The CLI never sends keys, never grants, never resumes a pane. Consumers
that need to act on a signal (e.g. mark the pane `blocked_external` in
portfolio status, file a permission-grant request, or escalate to the
operator) sit on top of the JSON the detector emits.
When the detector reports one or more records for an active pane:
1. The pane MUST NOT count as `busy` in capacity claims for that
   product. Treat it as `blocked_external` until the matched prompt
   class is resolved.
2. The matched record MUST be referenced (by `matcher_id` and
   truncated `matched_text`) in any operator-action list the
   orchestrator surfaces.
3. The orchestrator MUST NOT auto-grant a prompt unless a per-profile
   unblock policy explicitly allows the matched class for the matched
   provider. Even then, the action must be logged separately from the
   detection record. The detector lib never performs the action.
4. Records with the same `(pane, matcher_id, matched_text)` signature
   inside the dedupe window MUST be rate-limited by the consumer; the
   detector emits one record per scan, but consecutive scans against a
   stuck pane will reproduce it.
