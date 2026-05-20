# Post-merge cleanup and the closure-acceptance gate

`scripts/post_merge_cleanup.sh` parks an agent worktree after its PR is
merged: it switches back to the default branch, fast-forwards from origin,
and clears the dispatch assignment. When the merge lands on a non-default
branch and the host repo policy enables issue reconciliation (e.g.
`RBOKproject/realisons-wordpress`), the script also closes the referenced
GitHub issues so GitHub's "closes-by-keyword" gap does not leave UAT
tickets orphaned in `Open`.

Issue #723 (followup to the PR #775 lazy-validation audit) layers a
**closure-acceptance gate** between the merge and that close. The gate is
the closure-side counterpart to the dispatch-side scope-claim ledger
(#721): scope-claim prevents *dispatching* without coverage; the gate
prevents *closing* without proof.

## When the gate fires

For every issue the script is about to auto-close from a non-default-branch
merge, `post_merge_reconcile_issues` runs
`closure_acceptance_classify <pr-body> <issue-body> <issue-number>` from
`lib/closure_acceptance.sh`. The gate's behaviour depends on the issue
body: an issue with no `## Acceptance Criteria` / `## Definition of Done`
section is treated as routine, the gate emits `pass`, and the close
proceeds as before. Only UAT-style issues with explicit DoD checklists
trigger the proof requirement.

## Outcomes

| Outcome                 | Close proceeds? | Trigger                                                                                                 |
| ----------------------- | --------------- | ------------------------------------------------------------------------------------------------------- |
| `pass`                  | yes             | Fenced ```` ```acceptance ```` block in the PR body covers each DoD bullet with a verifiable artifact   |
| `operator-override`     | yes             | PR body has `Closes #N (operator-authorized: <handle> <reason>)` for the matching issue                 |
| `scaffold-declared:#M`  | no              | PR body declares `Acceptance: scaffold-only; live-validation tracked in #M` — operator must retarget    |
| `refused`               | no              | DoD bullets exist but no proof block, no override, and no scaffold declaration                          |

When the close is refused the script emits a `CLOSURE_REFUSED` audit row
and adds an `issue_reconcile blocked closure_refused` record to the
output. `gh issue close` is **not** invoked. Operators see the open
issue plus the audit trail and can either land an acceptance-block follow-up
PR, post an operator-authorized close, or retarget to the follow-up issue.

## Acceptance block template

Drop this block in the PR body before requesting review. Each bullet
mirrors a DoD checkbox from the source issue; each bullet must carry at
least one artifact marker. Recognized markers are: `artifact:`,
`evidence:`, `run-id:`, `sha:`, `hash:`, `path:`, an `http(s)://` URL, or
a known file extension (`.png`, `.jpg`, `.html`, `.json`, `.md`, `.php`,
`.sh`, `.js`, `.css`).

```text
Closes #<issue>

```acceptance
- <DoD bullet 1 summary> — artifact: <test-run id|screenshot path|DOM hash|deploy URL>
- <DoD bullet 2 summary> — evidence: <https://... or repo-relative path>
- <DoD bullet 3 summary> — run-id: <CI run id> sha: <commit sha>
```
```

The block is matched by an awk pass that walks fenced
```` ```acceptance ... ``` ```` regions, so the literal triple-backtick
fence is required. The block can appear anywhere in the PR body.

## Operator override

When a manual close is genuinely the right call (deploy window, vendor
gate, security embargo), append the override trailer to the closing
keyword:

```text
Closes #<issue> (operator-authorized: @<operator-handle> <short reason>)
```

The gate emits `operator-override`, the close proceeds, and the audit
row captures the override authority so reviewers can find it later.

## Scaffold-only declaration

Some PRs intentionally ship only a contract lock or scaffold with the
live work tracked in a follow-up issue. The gate refuses to close the
*parent* in that case, but the PR body should declare the retarget so
the audit row carries the follow-up pointer:

```text
Acceptance: scaffold-only; live-validation tracked in #<follow-up>
```

The operator's next step is to retarget the dispatch from the parent
issue to the follow-up so the live evidence lands against the right
ticket.

## Implementation pointers

- Gate library: `lib/closure_acceptance.sh` (pure shell + awk + grep + jq;
  no network).
- Wiring: `scripts/post_merge_cleanup.sh::post_merge_reconcile_issues`.
- Unit tests: `tests/test_closure_acceptance.sh` (four outcomes plus the
  no-DoD pass-through and the missing-artifact refusal).
- Integration test: `tests/test_post_merge_cleanup_closure_gate.sh` (lazy
  PR refused, proof-bearing PR closes, both audit lines emitted).
