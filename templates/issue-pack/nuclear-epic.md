# Nuclear Epic Template

Use this template when a local agent files the umbrella epic for an issue
pack handoff. See
[`docs/issue-pack-handoff.md`](../../docs/issue-pack-handoff.md) for the full
local-handoff policy. Replace every `{{placeholder}}` with a concrete value
before filing.

> Title format: `EPIC: {{outcome in one line}}`
> Labels: `epic`, `priority:{{P0|P1|P2|P3}}`, `type:meta`, plus any
> domain labels the orchestrator expects.

```markdown
## Outcome

{{One-paragraph statement of the durable outcome this epic delivers.
State the user/operator-facing change, not the internals.}}

## Existing Baseline To Extend

This pack must remain coherent with the already shipped work, not create a
parallel track. Anchors to extend rather than duplicate:

- {{path/or/issue/anchor #1}}
- {{path/or/issue/anchor #2}}
- {{path/or/issue/anchor #3}}

## Scope

- In scope:
  - {{deliverable 1}}
  - {{deliverable 2}}
  - {{deliverable 3}}
- Out of scope:
  - {{explicit non-goal 1}}
  - {{explicit non-goal 2}}

## Validation Grade

{{normal-dev | gxp-grade-dev | sixsigma-grade-dev}}. State why this grade is
appropriate and which optional layers (GxP, Six Sigma) must remain optional
and excluded from the default mode.

## Preparation Findings To Preserve

{{Bullet list of prior findings or constraints that must be honored. Cite
durable evidence (audit IDs, ledger entries, prior PRs) rather than chat
memory.}}

## Child Issues

- [ ] #{{child1}} {{title}} - {{url}}
- [ ] #{{child2}} {{title}} - {{url}}
- [ ] #{{child3}} {{title}} - {{url}}

## Acceptance

- {{Outcome-level acceptance check 1}}
- {{Outcome-level acceptance check 2}}
- {{Outcome-level acceptance check 3}}

## Orchestrator Notes

- Priority: {{P0..P4}} because {{rationale tied to risk or deadline}}.
- Suggested sequencing: {{ordered list of child IDs or topics}}.
- Known conflicts: {{paths, hot-spots, or sibling epics that risk collision}}.
- Business scope: {{in | out}}. State out unless the epic explicitly delivers
  business-domain implementation.

## Handoff Audit

- audit_id: `{{handoff-YYYYMMDDTHHMMZ-<epic>}}`
- plan_ref: `{{path or commit ref of the local plan that produced this pack}}`
- duplicate_checks: open issues, open PRs, atomization fingerprints all
  empty. Cite the searches that were run.
- notify_target / notify_provider: filled when the `NEW ISSUE PACK READY`
  notification is sent (see issue-pack-ready template).
```

## Filing Checklist

- [ ] Local plan committed or saved under `.work/` and referenced by `plan_ref`.
- [ ] Duplicate checks (open issues, open PRs, atomization fingerprints) ran
      empty against the configured provider.
- [ ] Each child issue is independently dispatchable and uses the
      [child-issue template](child-issue.md).
- [ ] Each child links back here as `Parent epic: #{{this_epic}}`.
- [ ] Handoff audit ledger entry appended with the same `audit_id` used above.
- [ ] `NEW ISSUE PACK READY` notification not sent yet; it is the next step
      after this epic and its children exist on the provider.
