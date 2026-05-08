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

## External-PR-Mutation Default

External pull-request mutations (PR comments, draft/ready toggles, labels,
assignees, review requests, merge actions) default to audit-only or refused
unless the dispatch brief explicitly authorizes the specific scope. Local
verification evidence may always be captured without external mutation; see
`docs/orchestrator-injected-rules.md` rule 11 for the durable rule and
`scripts/external_pr_policy_backfill.sh` for the one-time idempotent backfill
that records the policy default in active project state directories created
before the policy existed.

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
`DISPATCH_PLAN_ATOMIZE_MIN_TASKS` unchecked checklist items. With `--atomize`,
each unchecked checklist item becomes a child issue that carries:

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
