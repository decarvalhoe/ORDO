# Dispatch Planning

`dispatch_plan.sh` is the pre-dispatch planner for any GitHub-backed agent
pool. It turns open issues into a ranked queue with explicit dependency and
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
- child objective;
- clipped parent body as inherited scope;
- constraints to keep child work inside parent requirements.

Always dry-run first:

```bash
bash scripts/dispatch_plan.sh rbok --atomize --dry-run
```
