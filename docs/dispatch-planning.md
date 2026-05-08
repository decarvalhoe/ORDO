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

When dispatch refuses (78 for heavy-local-validators-without-opt-in,
77 for not-ready, 79 for not-consumed, 76 for context-mismatch, or
75 for degraded host or tmux), the numeric exit code maps to a
remediation step in [`docs/exit-codes.md`](exit-codes.md). Operators
inspecting a non-zero dispatch result should land on that manifest
first instead of guessing the meaning from the value.

### Mirror-Preserves-Mode-Bits Regression Class

Local validators (`scripts/run_shellcheck.sh`, `scripts/run_shell_tests.sh`,
`scripts/run_bats.sh`) sanitize the toolkit into a temporary mirror tree
before exercising it. The mirror MUST preserve the source file's mode bits
(canonical pattern: `chmod --reference="$ROOT/$rel" "$dest" 2>/dev/null ||
{ [[ -x "$ROOT/$rel" ]] && chmod +x "$dest"; }`). Dropping the executable
bit produces a CI-only failure class (#325):

- isolated `bats tests/<one-file>.bats` passes because no mirroring happens;
- the aggregate runner mirrors the executable script as 0644 and bats
  hits rc=126 (`Permission denied / not executable`) when the test execs
  the mirrored script directly;
- autofix loops can churn on the symptom (`chmod +x` per failing test)
  without addressing the mirror itself.

When adding a new mirror-style validator, mirror the same `chmod
--reference` fallback pattern and add a fixture that asserts an executable
source keeps its executable bit in the sanitized tree.

### Mirror-Includes-Fixtures Regression Class

The same mirror-style validators must also copy non-source test artifacts
that bats and shell suites load at runtime — fixture data, golden output,
snapshots, sample inputs (#326). The previous implementation in
`scripts/run_bats.sh` filtered files by extension (`*.sh`, `*.bash`,
`*.bats`, `*.config.sh`, `*.md`, `*.txt`) and silently dropped TSV / JSON /
binary fixtures. That produced the same CI-only failure shape as #325:

- isolated `bats tests/<one-file>.bats` passes because no mirroring
  happens;
- the aggregate runner mirrors source code but not the fixture, so the
  bats suite fails reading a path that exists in the repo and is missing
  in the sanitized tree;
- autofix loops can churn on test-side workarounds (inlining the fixture,
  guarding with `[ -f ... ]`) without addressing the mirror itself.

When adding a new mirror-style validator, also mirror everything under
`tests/{fixtures,data,golden,snapshots}/**` regardless of extension and
add a fixture that asserts a non-source fixture file appears in the
sanitized tree with its content preserved.

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
`DISPATCH_PLAN_ATOMIZE_MIN_TASKS` unchecked checklist items _outside_ a
non-atomization section (see [Non-atomization headers](#non-atomization-headers)
below).

### Acceptance Criteria vs. Atomization Tasks

The planner distinguishes **acceptance criteria** (bounded review checklist
for one PR) from **atomization tasks** (independent sub-deliverables that
should each become a child issue). It does so by inspecting the markdown
header that precedes each unchecked `- [ ]` item, comparing the normalized
header against the canonical bilingual allowlist in
`lib/dispatch_plan_headers.sh`:

| Locale | Sample headers covered by the default allowlist |
| --- | --- |
| English | `Acceptance Criteria`, `Acceptance`, `Definition of Done`, `Definition of Ready`, `Done Criteria`, `DoD`, `Verification`, `Verification Criteria`, `Validation Criteria` |
| French  | `Critères d'acceptation`, `Critères d acceptation`, `Critères d'acceptabilité`, `Définition de fini`, `Définition de terminé`, `Définition de prêt`, `Critères de validation` |

Any other header (including the absence of a header above the checklist)
is treated as a true subtask zone and the items count. Projects that need
to extend the allowlist (for example to add `Validation Strategy`, `Evidence`,
`Review Checklist`, `Risks`, or `Notes` as bounded review sections) should
use the `DISPATCH_PLAN_NON_ATOMIZE_HEADERS` override documented in
[Project-level overrides](#project-level-overrides).

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

## File Hotspot Detection

`dispatch_plan.sh --hotspots` is a read-only preflight that scans open pull
requests for shared files and reports which coordination surfaces (README,
PRODUCT, docs index, package metadata, CI workflows, central scripts) are
already being modified in parallel. Use it before dispatching a multi-agent
documentation, packaging, or CI wave.

```bash
# Read-only preflight (TSV).
bash scripts/dispatch_plan.sh <project-config> --hotspots --tsv

# Same data as JSON for downstream tooling.
bash scripts/dispatch_plan.sh <project-config> --hotspots --json

# Read-only preflight that exits non-zero when a blocker remains. Pair with a
# pre-dispatch CI step or an orchestrator gate.
bash scripts/dispatch_plan.sh <project-config> --hotspots --tsv --refuse-on-blocker
```

### Coordination Surfaces

Defaults live in `lib/file_hotspots.sh` and currently include:

- `README.md`
- `PRODUCT.md`
- `docs/INDEX.md`, `docs/index.md`
- `package.json`, `package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`
- `pyproject.toml`, `poetry.lock`, `requirements.txt`
- `Cargo.toml`, `Cargo.lock`
- `go.mod`, `go.sum`
- `install.sh`
- `.github/workflows/*.yml`, `.github/workflows/*.yaml`

Patterns are bash-`case` globs, so `*` matches any sequence (including `/`).
Operators can replace or extend the defaults from a project profile:

```bash
# Replace the defaults entirely (operator owns the full list).
ORDO_FILE_HOTSPOT_PATTERNS=(
  README.md
  custom/index.md
  ops/release-notes.md
)

# Or keep the defaults and append project-specific extras.
ORDO_FILE_HOTSPOT_EXTRA=(
  scripts/release.sh
  config/feature-flags.yaml
)
```

### Output

| Column | Meaning |
| --- | --- |
| `hotspot` | The matched coordination surface |
| `pr_count` | Number of open PRs touching that path |
| `prs` | Comma-separated PR numbers, e.g. `#269,#270,#272` |
| `agents` | Unique agent labels resolved from PR labels and authors |
| `classification` | `single_owner`, `blocker`, or `accepted_risk` |
| `recommendation` | Short remediation tag (see below) |
| `suggested_order` | PR numbers ordered by `updatedAt` ascending — the recommended merge order |

Agent resolution prefers an explicit `agent:<name>` PR label, then falls back
to the PR author with `ORDO_FILE_HOTSPOT_LOGIN_PREFIX` (default `RBOKCLI`)
stripped, then to the raw author login.

Classifications and remediation tags:

| Classification | Trigger | Recommendation |
| --- | --- | --- |
| `single_owner` | One PR or one unique agent | `ok-single-owner` — keep central edits in this PR only |
| `blocker` | Multiple agents touching the same surface, no operator opt-in | `sequence-or-reassign` — sequence merges or reassign to one owner |
| `accepted_risk` | Multiple agents AND `--accept-risk <pattern>` was passed | `operator-accepted-sequence` — operator-accepted; record sequencing in PR body |

### Operator Workflow For Documentation Waves

1. Plan dispatch with `--ready-only --json`.
2. Run `--hotspots --tsv` immediately before or after dispatch to surface
   shared-file conflicts.
3. For every `blocker` row, choose one of:
   - **Single owner**: assign the central index update to one agent and route
     the others to leaf docs only.
   - **Sequenced merges**: keep all PRs but merge them in `suggested_order`
     (oldest `updatedAt` first); rebase later PRs after the leading one merges.
   - **Leaf-first then integration**: instruct agents to write leaf docs first
     and create a separate, final integration issue that wires the central
     index. The integration issue gets dispatched alone.
   - **Accepted risk**: pass `--accept-risk <hotspot>` to mark the row as
     `accepted_risk`. The recommendation is then to record the agreed merge
     order in each PR body so reviewers can confirm the decision was explicit.
4. Re-run `--hotspots --refuse-on-blocker` to confirm the wave is clear before
   live dispatch.

### Sequencing Central Docs/Index Updates

For large documentation waves, the safest default is leaf-first:

- Each agent writes its leaf documents (for example `docs/install.md`,
  `docs/integration.md`, `docs/usage.md`) and avoids touching `README.md`,
  `PRODUCT.md`, or `docs/INDEX.md`.
- A separate, final integration issue updates the central index after the leaf
  PRs are merged. That issue is dispatched alone, owns the central index
  surface, and rebases against the latest `main` to pick up the leaf
  documents.

If leaf-first is not possible (for example a release-notes wave that has to
edit `PRODUCT.md`), prefer sequenced merges in `suggested_order` and document
the chosen order in each PR body. `--refuse-on-blocker` can be wired into a
pre-dispatch CI job so the wave fails closed when the operator forgets to
sequence.

### Tuning

| Variable | Default | Effect |
| --- | --- | --- |
| `DISPATCH_PLAN_HOTSPOT_PR_LIMIT` | `50` | Max open PRs scanned per run |
| `DISPATCH_PLAN_HOTSPOT_REFUSE_EXIT_CODE` | `7` | Exit code used by `--refuse-on-blocker` |
| `ORDO_FILE_HOTSPOT_PATTERNS` | (defaults) | Full pattern override (bash array) |
| `ORDO_FILE_HOTSPOT_EXTRA` | (empty) | Patterns appended to the defaults |
| `ORDO_FILE_HOTSPOT_LOGIN_PREFIX` | `RBOKCLI` | Author-login prefix stripped during agent resolution |

## Non-atomization headers

The header allowlist that drives the
[Acceptance Criteria vs. Atomization Tasks](#acceptance-criteria-vs-atomization-tasks)
behavior lives in `lib/dispatch_plan_headers.sh`. Use this section when you
need to (a) understand exactly which headers are covered, (b) extend the
allowlist for a project with its own conventions, or (c) audit how a header
gets normalized.

The default allowlist is bilingual (English + French) and tolerant of common
variants (curly apostrophes, missing apostrophes, accented and unaccented
spellings, trailing colons, bold/italic markup):

| Locale | Sample headers covered by the default allowlist |
| --- | --- |
| English | `## Acceptance Criteria`, `## Acceptance`, `## Definition of Done`, `## Definition of Ready`, `## Done Criteria`, `## DoD`, `## Verification`, `## Verification Criteria`, `## Validation Criteria` |
| French  | `## Critères d'acceptation`, `## Critères d acceptation`, `## Critères d'acceptabilité`, `## Définition de fini`, `## Définition de terminé`, `## Définition de prêt`, `## Critères de validation` |

Match comparison normalizes both sides:

- leading `#` markers, asterisks, underscores, and whitespace are stripped;
- trailing colon, asterisks, underscores, and whitespace are stripped;
- common Latin-script diacritics fold to their ASCII base
  (`é è ê ë → e`, `à â ä → a`, `ç → c`, `î ï → i`, `ô ö → o`,
  `ù û ü → u`, `ÿ → y`, `ñ → n`);
- the result is lowercased; non-`[a-z0-9]` runs are replaced with a single
  space; whitespace is collapsed and trimmed.

After normalization, `Critères d'acceptation` and `Critères d acceptation` and
`Criteres d'acceptation` all match the same allowlist entry
`criteres d acceptation`.

Headers that are NOT on the allowlist (for example `## Tasks`,
`## Subtasks`, `## TODO`) end any open non-atomization section, so a
checklist that follows them is treated as atomization tasks again.

### Project-level overrides

Projects with their own conventions can extend the allowlist via
`DISPATCH_PLAN_NON_ATOMIZE_HEADERS`. Entries may be separated by newlines,
commas, or semicolons; each entry passes through the same normalization as
the body header.

```bash
# Newline-delimited, single project profile:
DISPATCH_PLAN_NON_ATOMIZE_HEADERS=$'Validation Steps\nGate Criteria\nProcès-verbal' \
  bash scripts/dispatch_plan.sh <project-config> --tsv

# Comma-delimited, ad-hoc:
DISPATCH_PLAN_NON_ATOMIZE_HEADERS='Validation Steps,Gate Criteria' \
  bash scripts/dispatch_plan.sh <project-config> --tsv
```

Custom entries are added to the defaults, not substituted for them, so a
project that adds `Validation Steps` still benefits from the bilingual
acceptance-criteria coverage.

### Why this matters

Bilingual repositories with French acceptance checklists were marked
`atomize` and accumulated false-positive child issues each cycle. The
planner now treats those sections the same as their English equivalents,
so `status=ready` with `atomize_tasks=0` is the expected result for an
acceptance-only checklist regardless of language.

## Dispatch Routing: Hard-Switched vs Soft-Routed

Multi-product fleets share physical tmux panes across products. Before a brief
reaches a pane, the orchestrator must decide whether the pane will be moved to
the target workdir (hard-switch) or whether the brief will be sent into the
pane as-is and the agent will navigate to the target workdir itself
(soft-route). The two paths have different safety guarantees.

### Hard-switched (default)

The pane is respawned in the target workdir before the brief is sent. After
dispatch, `pane_context_proof` runs in `strict` mode: the pane's live
`#{pane_current_path}` MUST equal the recorded `WORKDIR`, otherwise the
dispatch is refused with reason `live-cwd-mismatch` (exit code
`ORCH_CONTEXT_MISMATCH_EXIT_CODE`, default 76) and the audit log records both
the expected workdir and the live workdir.

When to hard-switch:

- The orchestrator owns the pane and can safely respawn it.
- The previous product's work has been parked or merged.
- The fleet policy is "one product per pane at any time".

How to hard-switch before dispatch:

```bash
bash scripts/agent_product_switch.sh \
  <portfolio-config> \
  <source-project> <agent-label> <target-project> \
  --target-agent <agent-label> \
  --reason <reason> \
  --dry-run

# Then re-run without --dry-run after operator review.
```

After a hard-switch, `dispatch_ticket.sh` runs without `--soft-route` and the
strict context proof guarantees the brief landed in the right product
workdir.

### Soft-routed (opt-in)

The pane stays where it is and the brief carries an absolute path. The agent
is expected to `cd` into the target workdir before any mutation. This is the
right choice for short, one-off dispatches that should not disturb the pane's
current process or shell history.

When to soft-route:

- The dispatch is a single bounded task, not a session-long work stream.
- The pane currently runs an interactive process (long-running shell, REPL,
  agent CLI) the operator does not want to respawn.
- The dispatch brief itself contains an explicit `cd <absolute-path>` step
  before any git/file/test command.

How to soft-route a dispatch:

```bash
bash scripts/dispatch_ticket.sh <project-config> <agent> <ticket> <prompt> \
  --portfolio <portfolio-config> --soft-route
```

Or equivalently via env:

```bash
ORCH_DISPATCH_SOFT_ROUTE=1 bash scripts/dispatch_ticket.sh ...
```

With soft-route enabled, `pane_context_proof` runs in `accept-soft-routed`
mode: a live cwd that does not equal the recorded workdir is accepted but
the audit line carries `route=soft-routed` and `live_workdir=<live-path>`
alongside the expected `workdir=<target-path>`. The orchestrator and operator
remain accountable for confirming the agent's brief includes the absolute-cd
contract.

### Audit signature differences

| Path | DISPATCH ROUTE line | Successful proof line |
| --- | --- | --- |
| Hard-switched | `DISPATCH ROUTE agent=<a> ticket=#<n> pane=<p> route=hard` | `... live_workdir=<workdir> ... route=hard status=ok` |
| Soft-routed (cwd matches anyway) | `DISPATCH ROUTE agent=<a> ticket=#<n> pane=<p> route=soft` | `... live_workdir=<workdir> ... route=hard status=ok` |
| Soft-routed (cwd differs) | `DISPATCH ROUTE agent=<a> ticket=#<n> pane=<p> route=soft` | `... live_workdir=<other-path> ... route=soft-routed status=ok` |
| Hard-switched, cwd wrong | `DISPATCH ROUTE agent=<a> ticket=#<n> pane=<p> route=hard` | `... live_workdir=<other-path> ... status=mismatch:live-cwd-mismatch` (refused) |

The `route=` field on the proof line records what the proof actually
observed; the `DISPATCH ROUTE` line records what the orchestrator declared.
A divergence (operator declared hard but proof saw soft-routed) is itself a
signal worth investigating.

### Degraded tmux servers

If the tmux server cannot return `#{pane_current_path}` (timeout, server
restart), strict mode treats the result as `live-cwd-unreadable` and refuses
the dispatch. Set `ORCH_CONTEXT_PROOF_REQUIRE_LIVE_CWD=0` to fall back to the
legacy server-side-only proof when the operator has separately confirmed the
pane is in the right product workdir. Use that knob sparingly — it is the
exact configuration that hid the issue #286 false positives.

## Capacity Accounting Before Dispatch

Pre-dispatch capacity decisions must read from the `capacity_report` block
emitted by `scripts/portfolio_status.sh ... --json` rather than from pane
captures or narrative summaries. The block is computed by
`lib/capacity_report.sh` from three structured inputs only: the agent pool
(`agent_pool_status.sh`), `state/<project>/assignments.json`, and explicit
profile metadata (`ORDO_RESERVED_AGENTS[_<ALIAS>]`,
`ORDO_SUPERVISOR_SESSIONS`).

Key gates:

- `capacity_report.busy_claim_valid` is the only signal that authorizes the
  orchestrator to narrate "all agents busy" — it is `true` only when
  `free_pane_ready`, `dispatch_parkable`, and `switchable` are all empty.
- Stale assignments where the live pool reports the agent as free or
  parkable surface under `switchable`. Resolve them (re-bind the agent or
  clear the record after merge) before counting them as busy.
- Open PRs without active work appear under `parkable_pr_owners` /
  `open_prs_no_active_work` and remain available for the next dispatch
  unless explicitly reserved.
- Supervisor / control panes are declared via `ORDO_SUPERVISOR_SESSIONS` and
  surface separately under `supervisor_sessions`; they are never counted as
  agent slots.
- The `orch` agent is FREE by default. Reservation requires explicit
  profile metadata (`ORDO_RESERVED_AGENTS_<ALIAS>` or `ORDO_RESERVED_AGENTS`).
- `capacity_report.evidence_sources` must be cited when capacity claims are
  recorded in audit trails.

This heuristic is the codified version of orchestrator-injected rule #12
(see `docs/orchestrator-injected-rules.md`).
## Batched PR File Retrieval
Hotspot preflights and any other multi-PR scan that needs the changed-file
list of every open PR scale linearly with the number of open PRs when the
default `gh pr view --json files` loop is used. On large or rate-limited
GitHub installations that loop becomes the slowest part of `dispatch_plan`.
`lib/gh_pr_files_batch.sh` ships an opt-in helper that replaces N
`gh pr view` calls with a single `gh api graphql` query, returning the
changed-file set for every requested PR in one round trip. The helper is
deliberately not wired into the planner by default so existing callers
keep their current code path; consumers opt in and fall back when the
batched call fails.
source lib/gh_pr_files_batch.sh
# Returns TSV `<pr#>\t<path>` lines, sorted by PR# then path.
gh_pr_files_batch_fetch "$GH_REPO" 17 18 19 20
# Compatibility fallback (issue #293, "retain current path as fallback"):
if files=$(gh_pr_files_batch_fetch "$GH_REPO" "${prs[@]}"); then
  printf '%s\n' "$files"
else
  for n in "${prs[@]}"; do
    gh pr view "$n" --repo "$GH_REPO" --json files \
      | jq -r --argjson n "$n" '.files[] | "\($n)\t\(.path)"'
  done
fi
Tunable via env, all optional:
| Env knob | Default | Effect |
| `GH_PR_FILES_BATCH_LIMIT` | `100` | Max files returned per PR (the GraphQL `first:` cap). |
| `GH_PR_FILES_BATCH_MAX_PRS` | `25` | Max PRs per GraphQL call; larger inputs auto-chunk into multiple calls. |
| `GH_PR_FILES_BATCH_TIMEOUT` | `15` | Seconds for each `gh api graphql` call; wrapped via `orch_run_timeout` when `lib/process_safety.sh` is sourced. |
Exit codes:
- `0` - success (including the empty-input no-op).
- `1` - GraphQL or `jq` failure; a single-line `gh_pr_files_batch: <error>`
  is printed to stderr so the caller can fall back to the per-PR loop.
- `2` - argument-validation error (missing slash in `<repo>`, non-numeric
  PR id).

## GitHub Assignment Policy

ORDO records dispatch ownership in two places:

1. **Local assignment ledger** — `assignments.json` under the project state
   directory (`scripts/dispatch_ticket.sh` writes one entry per active
   agent containing the ticket number, branch, workdir, repo root, prompt
   file, and dispatch timestamp). This is ORDO's source of truth.
2. **GitHub issue assignee** — only mutated when the operator explicitly
   opts in. Real dispatch waves recorded ownership locally without
   touching GitHub assignees in the past, leaving observers to treat
   active work as free backlog (issue #273).

`scripts/dispatch_ticket.sh` makes the policy explicit:

| Flag                    | Default | Behavior                                                |
| ----------------------- | ------- | ------------------------------------------------------- |
| (none)                  | yes     | Local ledger only; GitHub assignee untouched.           |
| `--assign`              | no      | Run `gh issue edit --add-assignee <login>` after the identity guard passes. |

Every dispatch emits exactly one `assignee_policy=...` audit line per
ticket, recording one of:

| Policy outcome | Triggered when                                                        |
| -------------- | --------------------------------------------------------------------- |
| `skipped`      | `--assign` not supplied (`reason=disabled-by-default`), the ticket number is non-numeric (`reason=non-numeric`), or the dispatch was a `--dry-run` (`reason=dry-run`). |
| `applied`      | `gh issue edit --add-assignee` returned exit 0.                       |
| `refused`      | The identity guard reported `expected != active` for the active `gh` login (`reason=identity-mismatch`). The assignment is not attempted. |
| `failed`       | `gh issue edit` returned non-zero (`reason=gh-error`, `gh_exit=<n>`). |

Every line includes `ledger=<assignments.json path>` so operators can
reconcile ORDO's local truth against the GitHub view, and `--assign`
outcomes additionally record `expected_login=<login>` (and
`active_login=<login>` on refusal). Audit consumers can therefore answer
"did ORDO mutate this issue's GitHub assignee, and why" without
inspecting tmux state.

The identity guard is the same `orch_github_identity_guard` used elsewhere
in the toolkit. It reads the expected login from
`ORCH_EXPECTED_GH_LOGIN`, `ORCH_GH_EXPECTED_LOGIN`, or
`resolve_agent_github_login <agent>`, compares it to `gh api user --jq
.login`, and refuses on mismatch with exit code
`ORCH_GITHUB_IDENTITY_MISMATCH_EXIT_CODE` (default 78). The dispatch
script captures that exit, audits the refusal, and continues with the
rest of the dispatch flow rather than aborting the entire run, so a
single agent's drift does not knock out the wave.

Operators can silence the stderr ledger pointer that the default
(skipped) outcome prints by exporting `ORCH_DISPATCH_QUIET_LEDGER=1`;
the audit line is always emitted regardless.
