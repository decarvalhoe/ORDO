# Dispatch Planning

`dispatch_plan.sh` is the pre-dispatch planner for a configured issue-provider
agent pool. In the current shell adapter, GitHub-backed projects use `gh`. The
planner turns open issues into a ranked queue with explicit dependency and
atomization signals before an orchestrator sends work to agents.

## Command

```bash
bash scripts/dispatch_plan.sh <project> [--tsv|--json] [--ready-only]
bash scripts/dispatch_plan.sh <project> --priority-set <list> [--priority-set-override]
bash scripts/dispatch_plan.sh <project> --priority-set <list> --strict-priority-set
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

## External PR Mutation Authority

Verification on a third-party-managed PR and mutation of that PR are different
authority levels. ORDO defaults to audit-only: capture local evidence and stop.
External mutations require an explicit per-action authorization. The rule is
repo-neutral and provider-neutral; scope names describe the abstract action.

Scopes (recognised by `lib/audit_log.sh` and `scripts/dispatch_ticket.sh`):

| Scope | What it authorizes |
| --- | --- |
| `audit_evidence` | local capture only; always authorized; never sufficient by itself for any external mutation. |
| `issue_pack_notify` | notify the orchestrator's own issue pack. |
| `pr_comment` | post a comment on an externally-managed PR. |
| `pr_state` | flip draft/ready/reopen/close on such a PR. |
| `pr_labels` | add or remove labels on such a PR. |
| `pr_assignees` | add or remove assignees on such a PR. |
| `pr_merge` | merge such a PR. |

A dispatch prompt that needs an external mutation must declare the scopes on
its own line, in the same family as `require-local-validators`:

```text
- external-pr-mutations: pr_comment,pr_state
```

The orchestrator authorizes the dispatch through either the env var or the
dispatcher flag (one wins; both forms are equivalent):

```bash
ORCH_EXTERNAL_PR_MUTATIONS=pr_comment,pr_state \
  bash scripts/dispatch_ticket.sh <project-config> reviewer 268 /tmp/dispatch-reviewer-268.md

bash scripts/dispatch_ticket.sh <project-config> reviewer 268 /tmp/dispatch-reviewer-268.md \
  --external-pr-mutations pr_comment,pr_state
```

Without authorization the dispatcher refuses the prompt with exit code
`ORCH_EXTERNAL_PR_MUTATION_REFUSED_EXIT_CODE` (default 80). Audit-only prompts
that make no declaration always pass and are recorded as `mode=audit-only` in
the audit log.

Inside an agent run, the helper API in `lib/audit_log.sh` enforces the same
gate at the call site:

```bash
external_pr_mutation_assert pr_comment "PR-3175 readiness recommendation" \
  || exit $?
# authorized -> safe to perform the external mutation here.

# audit-only fallback: always allowed.
record_local_gate_evidence "pr-3175-readiness" "$(cat <<'NOTE'
recommendation: ready-for-review
gate verdict: MET
NOTE
)"
```

`record_local_gate_evidence` writes under `state_dir`/gate-evidence/, audit-logs
the path, and never mutates anything externally — audit-only mode keeps
working.

For active project state directories that predate this policy, run the
one-time idempotent backfill so future incident review can reconcile whether
a state directory predated the policy or attests to it:

```bash
bash scripts/external_pr_policy_backfill.sh \
  --scan-state-base \
  --apply --json
```

The backfill writes one stable `external_pr_policy_initialized.json` marker
per project under
`${ORCH_STATE_BASE:-${XDG_DATA_HOME:-$HOME/.local/share}/orch-state}/<project>/`.
Re-running is safe; every previously initialized project is reported as
`already-initialized` and no marker bytes change.

## Dependency Detection

The planner scans issue bodies for lines like:

```text
Blocked by: #123, #124
Depends on: #200
Requires: #300
Parent: #42
```

Open or unknown dependencies block dispatch. Closed dependencies do not.

## Text-Based Blockers

In addition to the explicit dependency lines, the planner scans issue title
and body for narrow phrases that signal a blocker. These checks are
deliberately conservative so that issues which only mention design tooling or
external assets in passing remain dispatchable.

| Blocker reason | Triggering language (examples) |
| --- | --- |
| `precondition:blocking-precondition` | `precondition bloquante`, `blocking precondition`, `blocked until`, `bloqué jusqu'à`, `requires validation before implementation` |
| `design:figma-or-design-gate` | `figma-first`, `figma first`, `design validation required`, `requires design validation`, `requires validation from design`, `validation design requise`, `code connect access required`, `developer seat required`, `blocked on figma`, `waiting on figma sign-off`, `pending the design handoff`, `figma handoff/preflight/asset/spec/design/export/file required`, `figma required before implementation` |
| `arbitration:decision-required` | `à arbitrer`, `pending arbitration`, `arbitration required`, `agency inputs`, `hosting decision`, `placement decision`, `external asset required`, `pending decision` |
| `multilingual:external-content-or-routing` | `traductions manquantes`, `translations required`, `plugin retenu`, `choix du plugin`, `structure d'URL`, `url strategy`, `hreflang`, `source content model`, `multilingual dependency` |

Neutral mentions of design tooling do **not** block dispatch. For example, an
issue titled "feat: add visual verification capability using the Figma MCP"
whose body explains that the Figma MCP is available in the environment is
treated as ready. The planner only blocks when the body or title carries an
explicit gating phrase such as "blocked on figma", "figma required before
implementation", or "requires validation from design".

### Writing An Explicit Design Gate

When you genuinely need to gate an issue on design output, use one of the
recognised phrases verbatim so the planner detects it:

```text
This issue is blocked on figma sign-off from the design lead.

Figma required before implementation: the spec is owned by the design team.

Figma asset required: we cannot start coding without the export from the
design team.

Code Connect access required before coding can start.
```

Otherwise, prefer the explicit `Blocked by:` / `Depends on:` / `Requires:`
lines or the `blocked` label so the gate is unambiguous and reviewable. The
text-based heuristic is a safety net for human-written issues, not the
canonical dependency model.

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

## Priority Sets

A priority set is an operator-supplied allowlist of ticket numbers. The
planner resolves every entry against the configured provider and writes a
`found/missing/state/assignee` table to stderr before it filters anything.

ORDO ships two distinct priority-set semantics. Use the one that matches the
operator's intent for the wave.

### Advisory priority set (default)

```bash
bash scripts/dispatch_plan.sh <project> --priority-set "10,12,14"
bash scripts/dispatch_plan.sh <project> --priority-set "10,12,14" --priority-set-override
```

The default `--priority-set` is **advisory**. It only filters the queue when
at least one allowlisted ticket is currently `ready`. If at least one is
ready, non-allowlisted tickets are dropped from the queue and the planner
prints `priority-set: refusing non-allowlisted dispatch (override with
--priority-set-override)`. If none of the allowlisted tickets is ready, the
planner leaves the rest of the queue intact and prints `priority-set: no
allowlisted ready tickets — queue unchanged (use --strict-priority-set to
filter to the allowlist anyway)`.

`--priority-set-override` lets the operator dispatch outside the allowlist
even when an allowlisted ready ticket exists. It is mutually exclusive with
`--strict-priority-set`.

### Strict priority set: operator-scoped wave (#266)

```bash
bash scripts/dispatch_plan.sh <project> --priority-set "249,250,251" --strict-priority-set
bash scripts/dispatch_plan.sh <project> --priority-set "249,250,251" --strict-priority-set --ready-only
```

`--strict-priority-set` is **operator-scoped**. It always filters the queue to
the allowlist, regardless of which allowlisted ticket is `ready`. Use it when
the wave is "work only on this issue pack" and an older ready sibling must
not leak into the dispatch candidates.

Behavior:

- The TSV/JSON output contains every allowlisted, open ticket with its
  current `status` (`ready`, `blocked`, `atomize`, `assigned`,
  `shipped_suspect`, `stale_parent`). Combine with `--ready-only` if the
  operator only wants the dispatchable subset.
- A per-ticket status summary is printed to stderr, e.g.
  `strict-priority-set: allowlist statuses: #249=atomize #250=ready #251=blocked`.
  This makes blocker and atomization reasons visible from the same call.
- If none of the allowlisted tickets is open in the configured repo, the
  queue is empty (instead of falling back to the older queue) and the
  summary line is `strict-priority-set: allowlist statuses: (no allowlisted
  tickets are open in this repo)`.
- `--strict-priority-set` requires `--priority-set` and is mutually
  exclusive with `--priority-set-override`. Either misuse fails fast with a
  non-zero exit and a clear stderr message.

Use the strict mode for compliance-sensitive or urgent waves where a stale
sibling would defeat the operator's scope. Keep the advisory default for
cooperative planning where the priority set is a hint, not a gate.
