# Child Issue Template

Use this template for each atomized child issue inside an issue pack. See
[`docs/issue-pack-handoff.md`](../../docs/issue-pack-handoff.md) for the full
local-handoff policy. Each child must be small enough that the orchestrator
can dispatch it as a single bounded ticket.

> Title format: `{{type}}: {{single-deliverable summary}}`
> Conventional types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`.
> Labels: at least one `type:*` label, `parallel-safe` when applicable, and
> any domain label the orchestrator expects. Add `ordo:atomized` and
> `ordo:child` when produced by `dispatch_plan.sh --atomize`.

```markdown
Parent epic: #{{epic}}

## Task

{{One-paragraph statement of the single deliverable. No multi-deliverable
phrasing. If the work would naturally split into more than one PR, file
separate child issues instead.}}

## Ownership Boundaries

- Own: {{paths or surfaces this child is allowed to modify}}.
- Do not touch: {{paths or surfaces explicitly out of scope}}.

## Acceptance Criteria

- [ ] {{Verifiable check 1}}
- [ ] {{Verifiable check 2}}
- [ ] {{Verifiable check 3}}

## Validation

- Command: `{{cheap, foreground command tied to changed files only,
  for example a grep, bash -n, or focused unit test}}`
- Expected: {{what passing output looks like}}
- Full validation: CI-delegated. The PR check rollup is the authoritative
  evidence. Do not run repository-wide validators on the shared agent host
  unless the dispatch explicitly opts in with `require-local-validators: yes`.

## Risks

- Conflict paths: {{hot-spot files this child may touch alongside siblings}}.
- Dependencies: {{`Blocked by: #N`, `Depends on: #N`, `Requires: #N` lines if
  the orchestrator must sequence this child after another}}.

## Handoff Audit

- audit_id: `{{handoff-YYYYMMDDTHHMMZ-<epic>}}` (same as the parent epic
  handoff entry)
- pack_role: `{{nuclear-epic-child}}`
- atomization_fingerprint: `{{ORDO-ATOMIZE:<fingerprint>}}` if the child was
  produced by `dispatch_plan.sh --atomize`; otherwise `n/a`.
```

## Filing Checklist

- [ ] Title uses a conventional type prefix matching the deliverable.
- [ ] Body declares `Parent epic: #{{epic}}` on the first line.
- [ ] Acceptance criteria are individually verifiable, not aspirational.
- [ ] Validation command is cheap, foreground, and tied to changed files.
- [ ] Ownership boundaries name explicit allowed and forbidden paths.
- [ ] Dependency lines (`Blocked by:`, `Depends on:`) are present when this
      child must wait on a sibling.
- [ ] Atomization fingerprint preserved when the child was produced by
      `dispatch_plan.sh --atomize` so re-handoffs do not duplicate it.
