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

## Direct Dispatch Matrix Gate (Emergency)

Direct dispatch is the **authorized urgent exception** to the standard ORDO
flow `plan -> nuclear epic -> atomized issues -> notify remote orchestrator
-> stop`. Direct dispatch is the only path that writes a brief into an
agent pane without first crossing the local issue-pack handoff. It is
permitted only when the operator has explicit authorization for a named
target and a named scope; all other emergencies must still go through the
remote orchestrator.

The matrix gate exists so an emergency direct dispatch leaves the same
auditable trace as a normal dispatch, and so a hurried operator cannot
write into a pane that is already busy, dirty, in conflict with another
agent, or owned by an issue that is not actually unblocked.

### Procedure

1. **Read or create the matrix.** Run
   `bash scripts/dispatch_matrix.sh <project-config> print` first. If no
   matrix exists, build one from ORDO read-only status plus GitHub
   issue/PR data with
   `bash scripts/dispatch_matrix.sh <project-config> build`.
2. **Add or refresh the row** for the named target and scope:
   `bash scripts/dispatch_matrix.sh <project-config> add <issue> \
   target_agent=<agent> tmux_target=<session:0.0> \
   owned_paths=<comma-list> forbidden_paths=<comma-list> \
   readiness=ready notes="<authorization>"`.
3. **Run the gate** before any tmux send:
   `bash scripts/dispatch_matrix.sh <project-config> gate <issue>`. The
   gate exits non-zero unless the row is `ready`.
4. **Dispatch only after the gate passes** by re-running the normal
   `bash scripts/brief_agents.sh` then `bash scripts/dispatch_ticket.sh
   --require-matrix-gate <project> <agent> <issue> <prompt>` so the
   ticket script re-checks the matrix immediately before the tmux send.

### Columns

The matrix is a TSV with the following columns, in order:

| Column | Meaning |
| --- | --- |
| `repo` | GitHub repo (e.g. `RBOKproject/ORDO`). |
| `issue` | Issue number (no `#`). |
| `priority` | `P0`-`P4` from labels. |
| `validation_mode` | `ci-delegated` (default) or `local-validators`. |
| `target_agent` | Agent label this row authorizes (e.g. `copilot`). |
| `tmux_target` | Session/window/pane the brief is written to. |
| `base_branch` | Base branch the agent must branch from. |
| `owned_paths` | Comma-separated list of paths/globs the agent may modify. |
| `forbidden_paths` | Comma-separated list of paths/globs the agent must NOT touch. |
| `readiness` | `ready`, `blocked`, `dirty`, `conflicting`, or `owned`. |
| `blockers` | Free text describing blockers. Non-empty implies not ready. |
| `notes` | Free text — capture the authorization, scope, and PR expectations here. |

### Rules enforced by the gate

- **One active issue per agent.** If `assignments.json` shows the named
  agent is already busy on a different ticket, the gate refuses with
  `owned`.
- **Clean worktree.** If the agent's resolved workdir is a git checkout
  with uncommitted or staged changes, the gate refuses with `dirty`.
- **No conflicting hot spots.** If another row in the matrix names a
  different `target_agent` and an `owned_paths` entry overlaps this
  row, the gate refuses with `conflict`.
- **Explicit branch.** The `base_branch` column is required; the gate
  refuses with `malformed` if the row is missing it (or any other
  required column).
- **Explicit PR expectations.** The `notes` column is the operator's
  contract for what PR the agent will open against `base_branch`. The
  gate does not enforce content here, but the dispatch brief MUST
  cite the matrix row notes verbatim so the agent inherits the same
  expectations.
- **Blocker handling.** Any of `readiness=blocked`, `readiness=dirty`,
  `readiness=conflicting`, `readiness=owned`, or a non-empty `blockers`
  cell with no `readiness` set, refuses dispatch.

### Forbidden states

The gate refuses with one of these one-token reasons (printed on stderr,
audited via `DISPATCH_MATRIX gate result=refused`):

| Reason | Exit code | Meaning |
| --- | --- | --- |
| `blocked:<why>` | 80 | Row marked blocked or `blockers` non-empty. |
| `dirty:<workdir>` | 81 | Agent workdir has uncommitted/staged changes. |
| `conflict:hot-spot-shared-with=<agent>` | 82 | `owned_paths` overlaps another agent's row. |
| `owned:agent=<a> busy with #<N>` | 83 | `assignments.json` shows the agent is busy. |
| `missing:matrix-file` / `missing:row-not-found` | 84 | No matrix or no row for this issue. |
| `malformed:missing-required-column` | 85 | Row is missing `repo`, `issue`, `target_agent`, or `base_branch`. |

Exit codes 80-85 are intentionally outside the 75-79 range used by
`dispatch_ticket.sh` for tmux/pane lifecycle failures so callers can
disambiguate gate refusal from later dispatch failures.

### Opt-in only

The matrix gate is off by default; the standard local issue-pack policy
remains the recommended path. To opt in for one direct dispatch, pass
`--require-matrix-gate` to `dispatch_ticket.sh`, or set
`ORCH_REQUIRE_DISPATCH_MATRIX_GATE=1` in the operator's environment for
that emergency window. Override the matrix path with `--matrix <path>`
or `ORCH_DISPATCH_MATRIX_FILE`.

The default matrix path is the per-project state dir
(`$ORCH_STATE_BASE/<PROJECT>/dispatch_matrix.tsv`) so portfolios stay
isolated from each other.

### Template

A canonical operator template lives at `templates/dispatch-matrix.md.tpl`.
It captures the authorization narrative, the TSV header, and the
expected sequence of `init`, `add`, `gate`, `dispatch_ticket`.
