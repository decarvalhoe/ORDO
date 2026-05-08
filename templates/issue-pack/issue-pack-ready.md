# NEW ISSUE PACK READY Notification Template

Use this template when a local agent notifies the configured remote
orchestrator that a new issue pack has been filed and is ready for review.
See [`docs/issue-pack-handoff.md`](../../docs/issue-pack-handoff.md) for the
full local-handoff policy.

The notification target is configurable; do not hardcode it. Read it from the
operator-owned project profile:

```bash
# In the operator-owned project profile.
ORCH_NOTIFY_TARGET="rbok-orchestrator:0.0"   # example only; substitute per deployment
ORCH_NOTIFY_PROVIDER="tmux"                  # tmux | issue-comment | webhook | ...
```

`rbok-orchestrator:0.0` is shown only as an example pane label.

## Notification Payload

The notification carries the same fields regardless of provider:

| Field | Description |
| --- | --- |
| `event` | Always `NEW ISSUE PACK READY`. |
| `repo` | Configured repository identifier. |
| `epic` | Nuclear epic issue number. |
| `epic_url` | Full issue URL for the nuclear epic. |
| `children` | Comma-separated child issue numbers in dispatch order. |
| `audit_id` | Stable handoff ID matching the audit ledger entry. |
| `agent` | ORDO label of the local agent that built the pack. |
| `validation_grade` | `normal-dev`, `gxp-grade-dev`, or `sixsigma-grade-dev`. |

## Provider-Specific Forms

### Provider: tmux

```bash
tmux send-keys -t "$ORCH_NOTIFY_TARGET" \
  "NEW ISSUE PACK READY: repo=$GH_REPO epic=#{{epic}} children=#{{c1}},#{{c2}},#{{c3}} audit_id={{handoff-id}} agent={{agent}} grade={{grade}}" Enter
```

### Provider: issue-comment

Post the notification as a comment on the nuclear epic so the orchestrator
sees it through the configured issue adapter:

```markdown
NEW ISSUE PACK READY

- repo: {{owner/repo}}
- epic: #{{epic}}
- children: #{{c1}}, #{{c2}}, #{{c3}}
- audit_id: `{{handoff-YYYYMMDDTHHMMZ-<epic>}}`
- agent: `{{agent}}`
- validation_grade: `{{normal-dev|gxp-grade-dev|sixsigma-grade-dev}}`
- next step: orchestrator review and accept/reject this pack before any
  child is dispatched.
```

### Provider: webhook

Send a JSON body that mirrors the audit ledger entry. The orchestrator
verifies the `audit_id` against the ledger before accepting the pack.

```json
{
  "event": "NEW ISSUE PACK READY",
  "repo": "{{owner/repo}}",
  "epic": {{epic}},
  "epic_url": "{{epic_url}}",
  "children": [{{c1}}, {{c2}}, {{c3}}],
  "audit_id": "{{handoff-YYYYMMDDTHHMMZ-<epic>}}",
  "agent": "{{agent}}",
  "validation_grade": "{{normal-dev|gxp-grade-dev|sixsigma-grade-dev}}"
}
```

## Pre-Send Checklist

- [ ] Nuclear epic exists on the configured provider and uses the
      [nuclear-epic template](nuclear-epic.md).
- [ ] All child issues exist, each one uses the
      [child-issue template](child-issue.md), and each declares
      `Parent epic: #{{epic}}` on the first line.
- [ ] Duplicate checks (open issues, open PRs, atomization fingerprints) are
      empty for the new scope.
- [ ] Audit ledger entry appended with the same `audit_id` used in this
      notification (see *Audit Ledger Format* in
      [`docs/issue-pack-handoff.md`](../../docs/issue-pack-handoff.md)).
- [ ] `ORCH_NOTIFY_TARGET` and `ORCH_NOTIFY_PROVIDER` resolved from the
      operator-owned project profile, not hardcoded in the local agent.

## After Sending

The local agent stops. It does not assign children, dispatch agents, or push
feature branches that touch child-issue scope until the orchestrator records
an `event=issue-pack-accept` (or `issue-pack-reject`) ledger entry quoting
the same `audit_id`.
