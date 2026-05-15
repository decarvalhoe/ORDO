# ORDO Actionable Issue List - 2026-05-13

Source: read-only audit requested by user and produced from `fleet-000` orchestration findings.

Scope:
- RBOK active tranche: AI Safety + UX/UI.
- Refonte WordPress V2: hold after source gate `#642`.
- ORDO runtime state: manual supervision vs loop state.

Rules:
- Do not dispatch new work until active PR checks and review gates are resolved.
- Do not start WordPress `#603` while `#643`, `#644`, `#646`, and `#640/#619` are unresolved.
- Preserve dirty WordPress WIP in `realisons-wordpress-copilot`.
- No direct push to `main` or `develop`.

## ORD-ACT-001 - Unstick RBOK AI Safety PR gate `#3710`

Priority: P0 / High

Impacted:
- Repo: `RBOKproject/RBOK`
- Issue: `#3662`
- PR: `#3710`
- Slot: `fleet-002`
- Worktree: `/root/repos/RBOK-codex-2`

Evidence:
- AI Safety Gate, Backend, API v1 CSRF, Coverage, and Security checks were reported passing.
- PR still showed `mergeStateStatus=BLOCKED`.
- Finding points to a stale or pending `Frontend CI` from an older/superseded run.

Recommended owner:
- ORDO operator / maintainer, with `fleet-002` kept available for follow-up if the stale check masks a real issue.

Action:
- Verify current `gh pr checks 3710`.
- If `Frontend CI` is stale or superseded, rerun/cancel through normal GitHub workflow.
- If it is a real failure, return the failure log to `fleet-002`.
- Review and merge only after branch protection is clean.

Exit criteria:
- PR `#3710` is clean, reviewed, and mergeable.
- Issue `#3662` is reconciled after merge.
- Downstream `#3665` can proceed out of draft/hold.

## ORD-ACT-002 - Review and merge RBOK freeze workflow `#3713`

Priority: P0 / High

Impacted:
- Repo: `RBOKproject/RBOK`
- Issue: `#3660`
- PR: `#3713`
- Slot: `fleet-005`
- Worktree: `/root/repos/RBOK-gemini`

Evidence:
- PR `#3713` was reported `CLEAN`, non-draft, with passing or expected skipped checks.
- Issue `#3660` remains a P0 blocker.

Recommended owner:
- Maintainer review. Use `fleet-005` only for requested changes.

Action:
- Review PR diff and CI.
- Merge if the implementation meets the freeze workflow contract.
- Close or reconcile `#3660` after merge.

Exit criteria:
- PR `#3713` merged to `develop`.
- Issue `#3660` closed or explicitly updated with remaining scope.
- No conflicting AI Safety branch remains open for the same files.

## ORD-ACT-003 - Hold and sequence live deploy gate `#3712`

Priority: P1 / Medium

Impacted:
- Repo: `RBOKproject/RBOK`
- Issue: `#3665`
- PR: `#3712`
- Slot: `fleet-006`
- Worktree: `/root/repos/RBOK-gemini-2`

Evidence:
- PR `#3712` is draft.
- It depends logically on `#3662` / PR `#3710`.
- `Frontend CI` was still pending at audit time.

Recommended owner:
- ORDO operator for sequencing; `fleet-006` for follow-up after `#3710`.

Action:
- Keep draft until `#3710` lands.
- After `#3710` merges, refresh/rebase if needed.
- Rerun CI and validate deploy gate behavior.
- Promote from draft only when dependency and checks are clean.

Exit criteria:
- `#3710` merged.
- PR `#3712` rebased or confirmed current.
- Checks green and PR ready for review.

## ORD-ACT-004 - Resolve UX draft PRs before dispatching more UX

Priority: P1 / Medium

Impacted:
- Repo: `RBOKproject/RBOK`
- Parent: `#3675`
- Child issues: `#3676`, `#3677`
- PRs: `#3709`, `#3711`
- Slots: `fleet-009`, `fleet-008`
- Worktrees:
  - `/root/repos/RBOK-cursor-2`
  - `/root/repos/RBOK-copilot`

Evidence:
- PR `#3709` for `#3676` is draft but `mergeStateStatus=CLEAN`.
- PR `#3711` for `#3677` is draft with CI still pending at audit time.
- Parent `#3675` has many child UX issues, but no further UX tranche should start while current draft PRs are unsettled.

Recommended owner:
- ORDO operator for sequencing; maintainers for review; original slots for requested changes.

Action:
- Wait for `#3711` CI to settle.
- Decide whether `#3709` and `#3711` should become ready-for-review.
- Review for UX scope boundaries and file collisions before merging.
- Dispatch next UX child only after current pair is reviewed or blocked with a clear reason.

Exit criteria:
- `#3709` and `#3711` either ready/merged or explicitly blocked.
- Parent `#3675` updated or internally reconciled with completed children.
- Next UX dispatch has a non-overlapping file scope.

## ORD-ACT-005 - Decide ORDO supervision mode after active PRs settle

Priority: P2 / Medium

Impacted:
- ORDO profile: `rbok-live`
- State dir: `/root/.local/share/orch-state/rbok`
- Audit log: `/var/log/orch/rbok.log`
- Slot: `fleet-000`

Evidence:
- `orch_ctl rbok-live status` showed `loop: NOT RUNNING` and `paused=true`.
- Manual ledger contains adopted active assignments.
- `fleet-000` is supervising manually.

Recommended owner:
- ORDO operator.

Action:
- Keep manual supervision until current PR tranche settles.
- Then decide explicitly:
  - continue manual supervision, or
  - relaunch loop with `ORCH_DAEMON_CONFIRM=operator`.
- Do not relaunch loop while active PRs are still in review/CI unless the loop is configured not to redispatch over them.

Exit criteria:
- A single chosen supervision mode is documented.
- Ledger, panes, and loop status agree.
- No stale assignments remain in `assignments.json`.

## ORD-ACT-006 - Keep WordPress V2 in hold and protect dirty `#618` WIP

Priority: P1 / High

Impacted:
- Repo: `RBOKproject/realisons-wordpress`
- Issues: `#603`, `#618`, `#619`, `#643`, `#644`, `#646`
- PR: `#640`
- Slot: `fleet-011` was used for `#642`, now hold.
- Dirty worktree: `/root/repos/realisons-wordpress-copilot`

Evidence:
- `#642` is closed.
- `#643`, `#644`, `#646`, `#603`, `#618`, `#619` remain open.
- PR `#640` remains draft.
- `realisons-wordpress-copilot` contains dirty WIP files for `#618`, including secondary pages/parser/sync/test surfaces.

Recommended owner:
- ORDO operator for sequencing; WordPress-specific agents only after WIP preservation and collision audit.

Action:
- Do not start `#603`.
- Preserve or snapshot dirty `#618` WIP before any WordPress dispatch.
- Resolve the next WordPress gates in order:
  1. `#643` inventory alignment after source decision.
  2. `#644` staging mirror pages.
  3. `#646` / PR `#640` parity finalization.
  4. Only then consider `#603` rehearsal.
- Avoid assigning work that touches the dirty `#618` files unless it is the same owner or the WIP is safely committed/stashed.

Exit criteria:
- Dirty WIP is preserved and attributable.
- `#643/#644/#646/#640` are resolved or explicitly blocked with evidence.
- `#603` remains blocked until prerequisites are satisfied.

## ORD-ACT-007 - Normalize idle fleet slots before reuse

Priority: P3 / Low

Impacted:
- Slots: `fleet-001`, `fleet-003`, `fleet-004`, `fleet-007`, `fleet-010`

Evidence:
- Idle slots are sitting at Codex prompts.
- Some show stale placeholder prompts or MCP warnings.
- They are capacity, but not ready to receive work without context cleanup.

Recommended owner:
- ORDO operator.

Action:
- Before assigning any idle slot:
  - verify current workdir,
  - verify GitHub/Codex identity,
  - clear stale input/prompt state,
  - confirm no dirty or hidden work in the slot worktree.

Exit criteria:
- Slot status is `idle-clean-ready`.
- Workdir and identity match the intended task.
- No stale prompt will consume a dispatch accidentally.

## Recommended Order

1. `ORD-ACT-001` - unblock/merge `#3710`.
2. `ORD-ACT-002` - review/merge `#3713`.
3. `ORD-ACT-003` - update/promote `#3712` after `#3710`.
4. `ORD-ACT-004` - settle UX `#3709/#3711`.
5. `ORD-ACT-006` - preserve WordPress WIP and continue V2 gates.
6. `ORD-ACT-005` - choose manual vs loop supervision once tranche is stable.
7. `ORD-ACT-007` - normalize spare slots before next dispatch.

