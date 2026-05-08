# Dispatch Planning

`dispatch_plan.sh` is the pre-dispatch planner for a configured issue-provider
agent pool. In the current shell adapter, GitHub-backed projects use `gh`. The
planner turns open issues into a ranked queue with explicit dependency and
atomization signals before an orchestrator sends work to agents.

## Command

```bash
bash scripts/dispatch_plan.sh <project> [--tsv|--json] [--ready-only]
bash scripts/dispatch_plan.sh <project> --atomize [--dry-run]
```

## Signals

- `ready`: unassigned issue with no open dependency blockers.
- `blocked`: one or more referenced dependency issues are still open or
  unknown.
- `assigned`: the issue already has an assignee.
- `atomize`: the issue is too large for direct dispatch and should become
  child issues first.
- `priority:P0` through `priority:P4`: inferred from priority labels.
- `has-deps`, `parent:#N`, and `unassigned`: extra scheduling context.

## Validation Placement

ORDO treats GitHub Actions as the default validation runner for full
repository checks. Dispatch briefs are CI-delegated unless generated with
`--require-local-validators`.

| Category | Examples | Default location |
| --- | --- | --- |
| syntax | `bash -n` or `shellcheck` on changed shell files only | local, foreground, strict timeout |
| focused smoke | one targeted script tied to changed files | local only when cheap |
| full unit/integration | repository shell suites and bats suites | CI by default |
| heavy/e2e | browser, API, or multi-service suites | CI only |

Local validation is still allowed when explicitly requested:

```bash
bash scripts/brief_agents.sh <project-config> builder 123 --require-local-validators
bash scripts/dispatch_ticket.sh <project-config> builder 123 /tmp/dispatch-builder-123.md --require-local-validators
```

Without that opt-in, prompts containing full local validators are refused so a
multi-agent wave cannot accidentally duplicate the CI `validate` job on the
shared host.

After the branch is pushed, `gh pr checks <pr> --watch` or the CI rollup is the
full validation proof. If CI turns red, inspect the failed step log and fix the
same branch instead of re-running every heavy validator locally by default.

## Dependency Detection

The planner scans issue bodies for lines like:

```text
Blocked by: #123, #124
Depends on: #200
Requires: #300
Parent: #42
```

Open or unknown dependencies block dispatch. Closed dependencies do not.

## Atomization

Issues are marked `atomize` when they have `size:xl`, `needs:atomize`, an
`EPIC` or `META` title/label, consolidation wording, or at least
`DISPATCH_PLAN_ATOMIZE_MIN_TASKS` unchecked checklist items.

### Acceptance Criteria vs. Atomization Tasks

The planner distinguishes **acceptance criteria** (bounded review checklist
for one PR) from **atomization tasks** (independent sub-deliverables that
should each become a child issue). It does so by inspecting the markdown
header that precedes each unchecked `- [ ]` item:

| Header (case-insensitive) | Treated as |
| --- | --- |
| `Acceptance Criteria`, `Acceptance`, `Criteria` | bounded review checklist (skipped) |
| `Definition of Done`, `Done` | bounded review checklist (skipped) |
| `Validation`, `Validations`, `Validation Strategy` | bounded review checklist (skipped) |
| `Preuves attendues`, `Preuves`, `Evidence` | bounded review checklist (skipped) |
| `Review Checklist`, `Checklist` | bounded review checklist (skipped) |
| `Risks`, `Risk` | non-atomization (skipped) |
| `Notes`, `Note` | non-atomization (skipped) |
| Anything else (including no header) | true subtask (counted) |

So an issue body like:

```markdown
## Task
Add the new export endpoint.

## Acceptance Criteria
- [ ] returns 200 with the new payload
- [ ] integration test covers the new code path
- [ ] docs page lists the endpoint
- [ ] release note added
```

stays `ready` with `atomize_tasks=0` even though it has four unchecked items,
because each item sits under `Acceptance Criteria`.

A body that mixes both — for example acceptance criteria and a separate
`## Subtasks` section — counts only the items under task-style headers
toward atomization. If the resulting count is still below
`DISPATCH_PLAN_ATOMIZE_MIN_TASKS`, the issue stays `ready`.

### Marking an Issue as a Single-PR Parent

Issue authors can force the planner to treat any checklist as bounded, even
when the section header looks task-like, by using one of:

- the body marker `ORDO-DISPATCHABLE-PARENT` (anywhere in the issue body —
  HTML comments are fine, e.g. `<!-- ORDO-DISPATCHABLE-PARENT -->`);
- the label `dispatch:single-pr`;
- the label `ordo:dispatchable-parent`.

Issues marked this way report `atomize_tasks=0`, never become `atomize`, and
carry a `dispatchable-parent` signal in the planner's signal column for
auditability.

Use these markers sparingly — they should describe a genuinely single-PR
deliverable. True multi-PR work should remain atomizable.

### Atomization Output

With `--atomize`, each remaining unchecked checklist item (after the rules
above) becomes a child issue that carries:

- parent issue number, URL, and title;
- a machine-readable `ORDO-ATOMIZE:<fingerprint>` marker;
- child objective;
- clipped parent body as inherited scope;
- constraints to keep child work inside parent requirements.
- best-effort labels from `DISPATCH_PLAN_ATOMIZE_LABELS`
  (`ordo:atomized,ordo:child` by default);
- a parent issue comment linking the child back to the source issue.

The fingerprint is computed from repository, parent issue number, and task
text. Before creating a child, ORDO searches GitHub issues for the same
`ORDO-ATOMIZE:<fingerprint>` marker across open and closed issues. If it finds
one, it skips creation and logs the existing child. This makes atomization
repeatable during autonomous cycles without producing duplicate GitHub issues.

Always dry-run first:

```bash
bash scripts/dispatch_plan.sh <project-config> --atomize --dry-run
```

Useful controls:

```bash
# Require more checklist tasks before marking an issue for atomization.
DISPATCH_PLAN_ATOMIZE_MIN_TASKS=5 bash scripts/dispatch_plan.sh <project-config> --tsv

# Disable best-effort labels, or set labels that already exist in the repo.
DISPATCH_PLAN_ATOMIZE_LABELS= bash scripts/dispatch_plan.sh <project-config> --atomize
DISPATCH_PLAN_ATOMIZE_LABELS="type:task,ordo:child" bash scripts/dispatch_plan.sh <project-config> --atomize
```
