# Local Issue-Pack Handoff Policy

This document is the standard local-agent process for moving work into the
remote orchestrator without dispatching remote agents directly.

It exists because local terminal agents share the same provider credentials and
panes as the remote orchestrator. A local agent that dispatches remote work can
collide with the orchestrator's wave plan, double-assign tickets, or skip
ORDO's gate checks. The local-agent boundary is therefore: plan locally, file a
nuclear epic with atomized child issues, notify the configured orchestrator,
then stop.

The policy is intentionally provider-neutral. The current shell adapter uses
`gh` for GitHub-backed projects; equivalent provider commands replace it where
ORDO is configured against another adapter.

## Do Not Dispatch Remote Agents From A Local Session

Local agents must not dispatch remote agents by default. This is a hard
boundary, not a recommendation:

- Local sessions do not own the orchestrator's dispatch matrix, wave gating, or
  hot-spot collision checks. A direct dispatch from a local agent bypasses
  every one of those controls.
- Local sessions do not own the orchestrator's audit trail. Direct dispatch
  produces evidence that the orchestrator never sees, breaking continuity for
  IQ/OQ/PQ reconciliation and CAPA.
- Local sessions cannot guarantee that the target agent pane is free, idle, on
  the right repo, on the right base SHA, or trusted for that wave.

The only legitimate way for a local agent to move work to remote agents is to
build a bounded **issue pack** (one nuclear epic + atomized child issues) and
hand it to the configured remote orchestrator with a `NEW ISSUE PACK READY`
notification. The orchestrator then decides which child issue is ready, gates
it, and dispatches it through the canonical path
(`scripts/brief_agents.sh` + `scripts/dispatch_ticket.sh`).

Emergency direct-dispatch is out of scope for this policy and is governed
separately by the dispatch matrix gate (epic #249, child #253). It always
requires an explicit, current authorization record - never an inferred one.

## Handoff Flow

The local agent runs the flow below. Each step has a single, verifiable
output. Skipping a step turns the handoff into an unauthorized dispatch.

1. **Plan locally.** Write the planning notes in the local checkout only. Do
   not push, comment, or dispatch yet. The plan should describe the outcome,
   the affected files or surfaces, the expected validation, and any required
   sequencing.
2. **Duplicate check.** Search the configured issue provider for any open or
   recently closed issue or PR that already covers the work. Skip creation if
   a usable record already exists; link to it instead. See *Duplicate Checks*
   below for the canonical commands.
3. **File a nuclear epic.** One umbrella issue describes the outcome,
   non-goals, anchors to extend, validation grade, and the list of child
   issues that will atomize the work. Use
   [`templates/issue-pack/nuclear-epic.md`](../templates/issue-pack/nuclear-epic.md).
4. **Atomize into child issues.** Each child is independently dispatchable: it
   names the parent epic, scopes a single deliverable, lists acceptance
   criteria, and states its validation. Use
   [`templates/issue-pack/child-issue.md`](../templates/issue-pack/child-issue.md).
   Mark the parent epic's checklist with the child issue numbers as they are
   created, and stamp each child with `Parent epic: #<n>`.
5. **Notify the configured remote orchestrator.** Send a `NEW ISSUE PACK
   READY` notification to the configured target. Use
   [`templates/issue-pack/issue-pack-ready.md`](../templates/issue-pack/issue-pack-ready.md).
   The notification target is configurable; do not hardcode it. See
   *Notification Target* below.
6. **Append the audit ledger entry.** Record the handoff in the configured
   audit ledger so the orchestrator and the validation owner have durable
   evidence the pack exists and was handed over. See *Audit Ledger Format*
   below.
7. **Stop.** Do not assign child issues, do not dispatch agents, do not push
   feature branches that touch child-issue scope until the orchestrator has
   accepted the pack.

## Notification Target

The notification target is configurable so the policy works across
deployments. It is exposed in the project profile, not hardcoded in product
docs:

```bash
# In the operator-owned project profile, alongside PROJECT, GH_REPO, etc.
ORCH_NOTIFY_TARGET="rbok-orchestrator:0.0"   # example only; replace per deployment
ORCH_NOTIFY_PROVIDER="tmux"                  # tmux | issue-comment | webhook | ...
```

`rbok-orchestrator:0.0` is shown only as an example pane label. Real
deployments substitute the configured orchestrator session, channel, or
endpoint. Keep live target names in operator-owned profiles, not in this repo.

When `ORCH_NOTIFY_PROVIDER=tmux`, a typical local-agent send looks like:

```bash
tmux send-keys -t "$ORCH_NOTIFY_TARGET" \
  "NEW ISSUE PACK READY: epic=#<n> repo=<gh_repo> children=<n1>,<n2>,<n3>" Enter
```

When `ORCH_NOTIFY_PROVIDER=issue-comment`, the local agent posts the
notification as a comment on the nuclear epic itself. When the provider is a
webhook, the payload follows the same schema (epic, repo, children, audit
reference).

The orchestrator's read side polls the configured target. It does not infer
the target from product branding.

## Duplicate Checks

Run all three checks before filing a new epic. Each must come back empty (or
with only closed records that do not overlap the new scope) before the local
agent creates anything new. The example commands use `gh`; substitute the
configured provider adapter for non-GitHub deployments.

```bash
# 1. Open and recently closed issues with overlapping titles or labels.
gh issue list  --repo "$GH_REPO" --state all  --search "<keywords>" --limit 30
gh issue list  --repo "$GH_REPO" --state open --label  "<label>"   --limit 30

# 2. Open and recently merged PRs that already implement the work.
gh pr list     --repo "$GH_REPO" --state all  --search "<keywords>" --limit 30

# 3. Cross-check ORDO atomization fingerprints so a re-handoff does not
#    duplicate child issues from a previous wave.
gh issue list  --repo "$GH_REPO" --state all \
  --search "ORDO-ATOMIZE:<fingerprint>" --limit 30
```

If any open issue, open PR, or atomization fingerprint already covers the
work, link to it from the local plan and stop. Do not file the epic. If a
closed record covers the same scope but the work must be redone, reference
that record explicitly in the new epic's body so the orchestrator can confirm
the re-handoff is intentional.

## Audit Ledger Format

Every issue-pack handoff produces one durable ledger entry. The ledger is
append-only and lives outside the active worktree by default; use
`scripts/findings_ledger.sh` (or the configured equivalent) so the entry is
not lost when the worktree is cleaned. The orchestrator reads the ledger to
confirm a pack was handed over before it dispatches any child.

The canonical entry is one JSON object per line (JSON Lines). Required fields:

| Field | Type | Description |
| --- | --- | --- |
| `ts` | RFC3339 string | UTC timestamp of the handoff. |
| `event` | string | `issue-pack-handoff`. |
| `agent` | string | ORDO label of the local agent that built the pack. |
| `repo` | string | Configured repository identifier (for example `owner/repo`). |
| `epic` | integer | Nuclear epic issue number. |
| `epic_url` | string | Full issue URL for the nuclear epic. |
| `children` | array of integers | Child issue numbers created in this pack. |
| `notify_target` | string | Resolved notification target (e.g. `rbok-orchestrator:0.0`). |
| `notify_provider` | string | `tmux`, `issue-comment`, `webhook`, etc. |
| `duplicate_checks` | object | Provider commands run and their result counts. |
| `plan_ref` | string | Path or commit reference to the local plan that produced the pack. |
| `audit_id` | string | Stable handoff ID; orchestrator quotes it on accept/reject. |

Example entry:

```jsonl
{"ts":"2026-05-08T09:30:00Z","event":"issue-pack-handoff","agent":"rbok-cursor","repo":"RBOKproject/ORDO","epic":249,"epic_url":"https://github.com/RBOKproject/ORDO/issues/249","children":[250,251,252,253,254,255,256],"notify_target":"rbok-orchestrator:0.0","notify_provider":"tmux","duplicate_checks":{"issues_open":0,"issues_all":0,"prs_all":0,"atomize_fingerprint":"none"},"plan_ref":".work/issue-pack-249.md","audit_id":"handoff-20260508T0930Z-249"}
```

A plain-text fallback is acceptable when JSONL tooling is unavailable, but it
must carry the same fields in `key=value` form on a single line and the
ledger file must remain append-only:

```text
2026-05-08T09:30:00Z event=issue-pack-handoff agent=rbok-cursor repo=RBOKproject/ORDO epic=249 children=250,251,252,253,254,255,256 notify_target=rbok-orchestrator:0.0 notify_provider=tmux audit_id=handoff-20260508T0930Z-249
```

Once the orchestrator accepts the pack, it appends a corresponding
`event=issue-pack-accept` (or `issue-pack-reject`) entry that quotes the same
`audit_id`, closing the loop for IQ/OQ/PQ traceability.

## When This Policy Does Not Apply

- The orchestrator's own dispatch path
  (`scripts/brief_agents.sh` + `scripts/dispatch_ticket.sh`) is not a local
  handoff. It is the orchestrator-owned mutation path and is governed by
  [`docs/orchestrator-injected-rules.md`](orchestrator-injected-rules.md) and
  [`docs/dispatch-planning.md`](dispatch-planning.md).
- A finding fixed and validated within the same commit does not need an issue
  pack; the commit message records the symptom and remediation. Any follow-up
  work still needs a tracked item per the production CAPA rule.
- Emergency direct dispatch is out of scope here and requires the dispatch
  matrix gate.

## See Also

- [`templates/issue-pack/nuclear-epic.md`](../templates/issue-pack/nuclear-epic.md)
- [`templates/issue-pack/child-issue.md`](../templates/issue-pack/child-issue.md)
- [`templates/issue-pack/issue-pack-ready.md`](../templates/issue-pack/issue-pack-ready.md)
- [`docs/orchestrator-injected-rules.md`](orchestrator-injected-rules.md)
- [`docs/dispatch-planning.md`](dispatch-planning.md)
- [`docs/opportunity-registry.md`](opportunity-registry.md)
