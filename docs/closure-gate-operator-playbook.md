# Closure-gate operator playbook

The closure-acceptance gate (issue #723, wired into
`scripts/post_merge_cleanup.sh::post_merge_reconcile_issues` via
`lib/closure_acceptance.sh`) gates auto-close behind one of three accepted
proof forms in the PR body. This playbook tells operators which form to
use for which PR, which form **not** to abuse, and how to read the audit
rows the gate emits after the fact.

The conceptual contract is in [docs/post-merge.md](post-merge.md). This
playbook is the operational companion: it does not redefine the outcomes,
it tells you which outcome you should be steering each PR toward.

## The three accepted closure forms

### Form 1 — Acceptance block

A fenced ```` ```acceptance ```` block in the PR body. Each bullet
mirrors a `## Definition of Done` / `## Acceptance Criteria` bullet from
the source issue and carries at least one verifiable artifact marker
(`artifact:`, `evidence:`, `run-id:`, `sha:`, `hash:`, `path:`, an
`http(s)://` URL, or a recognised file extension).

Example PR body:

```text
Closes #842

Wires the queue-starvation surface into the operator runbook.

```acceptance
- queue_starvation_surface.sh emits QUEUE_STARVED_NO_RESOLUTION on stall — run-id: 18234119923 sha: 9c4f1a2
- operator-runbook.md links the surface under "queue starvation" — path: docs/operator-runbook.md
- unit test covers stall + recovery — artifact: tests/test_queue_starvation_surface.sh
```
```

Classifies as `pass`. Close proceeds. This is the default form for any
PR that ships behaviour with a DoD checklist.

### Form 2 — Operator-authorized trailer

A closing keyword annotated with an operator-authorized trailer:

```text
Closes #903 (operator-authorized: @op-handle dispatcher self-fix; DoD vocabulary does not apply)
```

Classifies as `operator-override`. Close proceeds. The audit row
captures the authorising handle and reason so a reviewer can find the
authority later. Use only for the PR archetypes listed under
[When to use form 2](#when-to-use-form-2-operator-authorized) — never as
a shortcut around a real DoD.

### Form 3 — Scaffold-only retarget

A single declaration in the PR body:

```text
Acceptance: scaffold-only; live-validation tracked in #911
```

Classifies as `scaffold-declared:#911`. The close of the **parent** is
refused on purpose; the operator's next step is to retarget the dispatch
from the parent to the follow-up issue so the live evidence lands
against the right ticket.

Example PR body:

```text
Locks the upgrade contract for the new ingest pipeline. No live runs in
this PR — the pipeline run, golden-file diff, and operator validation
all happen in #911.

Acceptance: scaffold-only; live-validation tracked in #911
```

## Decision matrix

Map each PR to the form before opening it. If the row you would pick is
not in the matrix, default to Form 1 and link the closest archetype in
your PR body.

| # | PR archetype | Example | Form |
| - | --- | --- | --- |
| 1 | Feature/behaviour change with a DoD checklist on the source issue | New CLI subcommand; new surface script; new gate; new runbook addition with verifiable artifact | **Form 1** (acceptance block) |
| 2 | Bug fix on a production module with user-visible behaviour | Auto-close mis-closing live UAT tickets; dispatch_plan picking a held project | **Form 1** (acceptance block — fix evidence + regression test path) |
| 3 | Shellcheck-only / lint-only / formatter sweep, no behaviour change | `shellcheck` fixes across `scripts/`; `black` reformat; `prettier` cleanup | **Form 2** (operator-authorized) |
| 4 | Dispatcher / orchestrator self-fix where the WP V2 DoD vocabulary does not apply | `brief_agents` prompt-fidelity tweak; `orch_loop` cycle ordering fix; rendering bug in the dispatch template | **Form 2** (operator-authorized) |
| 5 | Infra reset / housekeeping with no functional payload | Bumping a pinned base SHA; rotating a CI cache key; refreshing a state-dir layout doc | **Form 2** (operator-authorized) |
| 6 | Single-file doc typo / single-file comment fix | Fixing a broken markdown link in `docs/INDEX.md`; correcting a typo in a runbook | **Form 2** (operator-authorized) |
| 7 | Contract lock / scaffold PR with no runnable behaviour yet | Locking a schema; landing a stub interface; checking in a fixture set whose live run is tracked separately | **Form 3** (scaffold-only retarget) |
| 8 | UAT-gate PR that ships user-facing behaviour requiring sign-off | Anything visible to the end user; anything that changes a validated path under `docs/validation/` | **Form 1** (acceptance block — UAT artifact mandatory) |
| 9 | P0 hotfix on a production module under live incident | Reverting a broken migration; patching a crashing handler | **Form 1** (acceptance block — incident link + post-fix verification) |

## When to use form 2 (operator-authorized)

Form 2 is the operator escape hatch when the PR genuinely cannot or
should not carry a full acceptance block. Use it for:

- Shellcheck-only fixes, `shfmt`/`prettier`/`black` reformats, or other
  pure lint sweeps that touch many files but change zero behaviour.
- Single-file lint cleanups, comment-only edits, or one-line typo fixes.
- Infra reset PRs (pin bumps, cache key rotations, state-dir refreshes)
  that have no functional payload an operator could attach an artifact
  to.
- Dispatcher / orchestrator self-fixes where the source issue does not
  have a meaningful DoD checklist because the WP V2 DoD vocabulary does
  not apply to the dispatcher itself.
- Stale-issue closures the dispatcher already de-flagged (e.g.
  shipped-suspect false positives, deduplicated issue pairs) where the
  proof is in the dedup audit, not in the PR.

The trailer must name a real handle and a short, specific reason. A
generic `(operator-authorized: bot)` defeats the whole point of the
gate.

## When NOT to use form 2

Do not use form 2 for any of the following. Use Form 1 (acceptance
block) or Form 3 (scaffold-only) instead.

- **P0 hotfixes touching a production module**: the incident record
  belongs in the acceptance block (`run-id:`, post-fix verification
  link), not behind an `operator-authorized` trailer.
- **UAT-gated work**: anything routed through `docs/validation/` or any
  issue with a validation reviewer in the chain — the gate is the only
  enforced surface that asks "where is the proof?".
- **User-facing behaviour**: anything visible to the end user (UI
  changes, public CLI surface changes, API shape changes); these always
  carry a screenshot, run-id, or deploy URL that belongs in an
  acceptance block.
- **Contract locks / scaffold PRs**: these are exactly what Form 3
  exists for. Closing the parent with Form 2 hides the retarget.
- **Bulk auto-close of stale issues**: cleanup of many tickets at once
  needs the audit trail of *why* each ticket was closed; do this through
  the dedup ledger / orch_stale_close path that records the reason per
  ticket, not by stamping `operator-authorized` on a sweep PR.

If you find yourself wanting Form 2 because writing the acceptance block
is *tedious* (not because the DoD vocabulary genuinely does not apply),
that is a signal to use Form 1 anyway. The bullets do not need to be
long; they need to carry artifacts.

## Audit guidance — reading the gate's audit rows

Every closure-gate decision lands in the orchestrator audit log. The
rows are emitted by `scripts/post_merge_cleanup.sh` and follow a stable
schema you can grep on.

### `POST_MERGE_CLEANUP CLOSURE_GATE pass`

```text
POST_MERGE_CLEANUP CLOSURE_GATE pass issue=#842 pr=#1024 outcome=<outcome> base=feat/issue-842 repo_default=main mode=<mode>
```

- `outcome` is one of `pass`, `operator-override`, `scaffold-declared:#M`,
  or `no-dod` (issue had no DoD checklist; gate treated as routine).
- `pass` here means **the gate allowed the close**, not that the
  acceptance block was perfect. To audit *which* form was used, read
  `outcome`:
  - `pass` → Form 1 (acceptance block).
  - `operator-override` → Form 2 (operator-authorized trailer). Cross-check
    the PR body for the named handle and reason.
  - `scaffold-declared:#M` → Form 3 (this row is only emitted when the
    target was the follow-up, not the parent).
  - `no-dod` → routine issue, gate did not apply.
- `mode` is the gate mode the run was under (`warn`, `enforce`, or empty
  for legacy / unset). Pair this with the `CLOSURE_WARN` and
  `CLOSURE_REFUSED` rows below to understand what the gate *would* have
  done versus what it *did*.

### `POST_MERGE_CLEANUP CLOSURE_REFUSED`

```text
POST_MERGE_CLEANUP CLOSURE_REFUSED issue=#842 pr=#1024 outcome=refused reason=<reason> base=feat/issue-842 repo_default=main mode=enforce
```

- Only emitted under `mode=enforce`. The close was blocked, the issue
  remains open, and `issue_reconcile blocked closure_refused` appears in
  the cleanup output.
- `reason` is the human-readable verdict from `closure_acceptance.sh`
  (typically a missing-artifact message or a "no proof block, no
  override, no scaffold" verdict).
- Operator next steps:
  1. Read the PR body. If the DoD bullets were genuinely covered but the
     artifact markers were missing, land a follow-up PR that adds the
     acceptance block and references the original PR.
  2. If the PR was truly an operator self-fix and qualifies under
     [When to use form 2](#when-to-use-form-2-operator-authorized), edit
     the PR body to add the operator-authorized trailer (the gate
     re-runs on the next cleanup cycle).
  3. If the PR shipped only a scaffold, edit the PR body to add the
     `Acceptance: scaffold-only; live-validation tracked in #M`
     declaration and retarget the dispatch to `#M`.

### `POST_MERGE_CLEANUP CLOSURE_WARN`

```text
POST_MERGE_CLEANUP CLOSURE_WARN issue=#842 pr=#1024 outcome=refused reason=<reason> base=feat/issue-842 repo_default=main mode=warn would_refuse=1
```

- Emitted under `mode=warn`. The close **proceeded** (warn is observe-only),
  but the row tells you the gate would have refused under `enforce`.
- Treat these as the pre-flight signal before flipping
  `ORCH_CLOSURE_GATE_MODE=enforce` for the deployment. Aim for zero
  `CLOSURE_WARN ... would_refuse=1` rows over a representative window
  before enforcing.

### Quick recipes

```bash
# All gate decisions for a PR.
grep "POST_MERGE_CLEANUP CLOSURE" "$AUDIT_LOG" | grep "pr=#1024"

# Every refusal in the last cleanup cycle.
grep "POST_MERGE_CLEANUP CLOSURE_REFUSED" "$AUDIT_LOG"

# Distribution of outcomes (which form was used how often).
grep "POST_MERGE_CLEANUP CLOSURE_GATE pass" "$AUDIT_LOG" \
  | sed -n 's/.*outcome=\([^ ]*\).*/\1/p' \
  | sort | uniq -c | sort -rn

# Are we ready to flip enforce? — count warn-mode would-refuse rows.
grep "POST_MERGE_CLEANUP CLOSURE_WARN" "$AUDIT_LOG" | grep -c "would_refuse=1"
```

## Related

- [docs/post-merge.md](post-merge.md) — the gate contract: outcomes,
  acceptance-block template, operator-override trailer, scaffold
  declaration.
- `lib/closure_acceptance.sh` — gate library (pure shell + awk + grep +
  jq; no network).
- `scripts/post_merge_cleanup.sh::post_merge_reconcile_issues` — wiring
  point that runs the gate before `gh issue close`.
- `tests/test_closure_acceptance.sh`,
  `tests/test_post_merge_cleanup_closure_gate.sh` — outcome and
  integration coverage.
