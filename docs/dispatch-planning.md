# Dispatch Planning

`dispatch_plan.sh` is the pre-dispatch planner for a configured issue-provider
agent pool. In the current shell adapter, GitHub-backed projects use `gh`. The
planner turns open issues into a ranked queue with explicit dependency and
atomization signals before an orchestrator sends work to agents.

## Command

```bash
bash scripts/dispatch_plan.sh <project> [--tsv|--json] [--ready-only] [--active-backlog]
bash scripts/dispatch_plan.sh <project> --ci-overlap [--tsv|--json]
bash scripts/dispatch_plan.sh <project> --priority-set <list> [--priority-set-override]
bash scripts/dispatch_plan.sh <project> --priority-set <list> --strict-priority-set
bash scripts/dispatch_plan.sh <project> --atomize [--dry-run|--apply] [--max-children-per-cycle <N>]
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
- `active-backlog`: an explicit issue marker or planner mode says the open
  issue is still active backlog even when historical shipped evidence exists.
- `shipped-advisory`: shipped/stale evidence was detected but did not change
  the issue's dispatch status because active-backlog mode applies.
- `explicit-shipped-label`: a maintainer label such as `status:shipped` marked
  the open issue as shipped, so it is not dispatchable by active-backlog mode.

### Ready-Only Collision Graph

`--ready-only --json` includes a compatibility `conflict_with` array plus a
`dispatch_collision` object for each ready row. The object replaces the older
`["unknown"]` abstention with an explicit file/surface decision:

| `dispatch_collision.decision` | Meaning |
| --- | --- |
| `blocked_by_file` | The issue's declared or inferred files overlap an active scope claim. |
| `blocked_by_pr` | The issue's declared or inferred files overlap an open PR's changed files. |
| `blocked_by_parent_policy` | The issue is an ambiguous code child with no file scope, and another in-flight claim shares the same parent. |
| `dispatchable` | No file, PR-file, or parent-policy collision is proven. |

The graph reads issue `Scope files`/`Allowed files` declarations, path-like
tokens in the title/body, issue labels and surface words such as
documentation/proof/comment, parent links, active scope claims, and open PR
file lists. Non-code proof/comment/doc children without file scope are
classified as `dispatchable` instead of being held behind same-parent code
children. Ambiguous code children without file scope still get
`blocked_by_parent_policy` when a sibling claim is already in flight, so the
planner avoids double-dispatching code work on an unproven shared parent.

## CI-Pending File Overlap Planning

When one or more PRs are waiting on checks, the whole fleet does not have to
idle. Use `--ci-overlap` to separate global CI wait from actual file collision
risk:

```bash
bash scripts/dispatch_plan.sh <project> --ci-overlap --tsv
bash scripts/dispatch_plan.sh <project> --ci-overlap --json
```

The mode reads open PRs targeting `DEFAULT_BRANCH`, keeps PRs with pending,
queued, in-progress, waiting, requested, or expected checks, fetches their
changed files, and compares them with ready issue scope declarations. It emits:

| Column | Meaning |
| --- | --- |
| `classification` | `parallel_safe`, `blocked_by_files`, `blocked_by_ci_dependency`, or `needs_human_decision`. |
| `parallel_safe` | `true` only when the issue is ready, has declared scope files, and avoids CI-pending PR files. |
| `scope_files` | Candidate-owned files or glob/prefix patterns parsed from the issue body. |
| `overlap_prs` / `overlap_files` | Pending PRs and files that collide with the issue scope. |
| `blocked_reason` | Machine-readable reason, such as `pending_pr_file_overlap` or `missing_scope_files`. |
| `suggested_next_action` | Operator action for the row. |
| `brief_note` | Text that can be injected into the dispatch prompt. Safe rows forbid files already touched by pending PRs. |

Issue bodies should declare file ownership before dispatch during a CI-pending
wave:

```markdown
Scope files:
- frontend/profile/page.tsx
- frontend/profile/*.test.tsx
- docs/profile.md
```

Accepted heading aliases include `Scope files:`, `Ownership files:`, `Allowed
files:`, `Files touched:`, and `File scope:`. Exact file paths, directory
prefixes, and shell-style globs are compared against pending PR files. If the
issue has no scope declaration, `--ci-overlap` returns
`needs_human_decision` instead of treating the work as safe.

For a `parallel_safe` row, copy the `brief_note` into the dispatch prompt. It
must travel with the agent brief so the agent avoids pending PR files while CI
settles.

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

After the branch is pushed, use a bounded CI snapshot as the validation proof:
`bash scripts/pr_block_signals.sh <project-config> --json` for the project
rollup, or a single `gh pr checks <pr> --repo <repo> --json name,state,link`
snapshot for manual inspection. Supervisor flows must not block on long-running
watch commands while unrelated safe work could still be planned. If CI turns
red, inspect the failed step log and fix the same branch instead of re-running
every heavy validator locally by default.

## Validation Sufficiency Gate (#724)

`brief_agents.sh` invokes a per-class sufficiency check against every
`dispatch-provided` brief. The gate compares the language classes
present in `scope_files` to the tokens present in the rendered
`validation_command` and fires when a class is uncovered:

| Scope class | Required token (any) |
| --- | --- |
| `*.sh`, `*.bash` | `shellcheck`, `run_shellcheck.sh` |
| `*.py` | `pytest`, `py_compile` |
| `*.ts`, `*.tsx` | `tsc`, `jest` |
| `*.mjs`, `*.cjs`, `*.js`, `*.jsx` | `eslint`, `jest`, `node --check` |
| `*.php` | `php -l`, `phpunit` |

The gate originated from the 2026-05-16 ORDO dispatch wave: PRs #719
and #722 each accumulated 1–3 lint follow-up commits *after push*
because the worker's `validation_command` was `bash -n <file>` plus
one targeted shell test. `bash -n` is parser-only — it does not flag
the SC2034 / SC2128 / SC2178 warnings that `scripts/run_shellcheck.sh`
would have caught locally before push. The token-match rules above
encode the same "right tool per scope class" reasoning for every
supported language so the same regression cannot reappear class-by-class.

### Modes

- `ORCH_BRIEF_VALIDATION_SUFFICIENCY=auto-augment` (default) — the
  gate prepends the canonical class invocation (`shellcheck $(git ls-files
  "*.sh" "*.bash")` for `sh`, `python3 -m py_compile ...` for `py`,
  `npx --yes tsc --noEmit` for `ts`, `node --check ...` for `js`,
  `find ... -print0 | xargs -0 -n1 php -l` for `php`) onto the front of
  `validation_command`. Each augment line is annotated with
  `# brief_agents: auto-augmented for scope class <class>` so the
  worker can see what was inserted, and one
  `BRIEF VALIDATION_AUTO_AUGMENTED scope_class=<class> added=<cmd>`
  audit row is emitted per added class.
- `ORCH_BRIEF_VALIDATION_SUFFICIENCY=enforce` — the gate refuses the
  brief with exit 88, surfaces a `BRIEF_VALIDATION_INSUFFICIENT`
  stderr blocker naming the missing classes, and emits a matching
  `BRIEF VALIDATION_INSUFFICIENT` audit row. Use this once a project's
  auto-augment audit rows show no false positives.
- `ORCH_BRIEF_VALIDATION_SUFFICIENCY=off` — full opt-out. Tests that
  pin an exact `validation_command` shape (for example the Node 22
  preflight injection test) pass this flag to keep the gate out of
  their blast radius.

Each mode is also reachable via the per-dispatch flag
`--validation-sufficiency=<mode>` so an operator can override the
default for a single brief without exporting the env var.

### Exception path

Briefs whose source body declares
`- validation-policy-exception: <reason>` bypass the gate in every
mode and emit a `BRIEF VALIDATION_POLICY_EXCEPTION` audit row that
records `reason=source_body_declaration`. The waiver follows the same
shape as the `- external-pr-mutations: <scopes>` and
`- require-local-validators: <yes|no>` declarations and is intentional
operator territory — use it for third-party shell files, generated
fixtures, or any scope where the canonical invocation would produce
noise instead of signal.

### Migration plan

1. Land in `auto-augment` mode so existing dispatchers keep working
   and the missing invocations land transparently. Audit rows surface
   any deltas worth reviewing.
2. After 1–2 weeks of `BRIEF VALIDATION_AUTO_AUGMENTED` rows with no
   false positives, flip the default to `enforce` so future briefs
   that omit shellcheck/tsc/pytest get refused with a clear
   remediation hint (mirroring how #538 refuses empty scope today).
3. The gate composes with #538 (empty scope refusal), the #483 audit
   evidence preflight, and the closeout final-base guard — each guard
   protects a distinct dispatch junction.

## Docs-Impact PR Trailer Instruction (#779)

`brief_agents.sh` renders a `## PR body trailer — Docs-Impact (#779)`
section in every implementation brief so the worker emits a
docs-impact-gate-passing PR on first submission instead of relying on
the operator (or auto-merge daemon) to patch the body and push an
empty commit to retrigger the gate.

The section instructs the worker to end its PR body, and/or its final
commit message, with:

```
Docs-Impact: <docs-updated|no-docs-needed|follow-up|blocked>
Docs-Impact-Note: <one line>
```

A suggested outcome is pre-computed from `scope_files`:

| `scope_files` content | Suggested outcome |
| --- | --- |
| any entry under `docs/` or `*/docs/` | `docs-updated` |
| any non-test top-level `.md` entry | `docs-updated` |
| only `tests/` entries (including `tests/*.md`) | `no-docs-needed` |
| any other shell / lib / scripts paths | `no-docs-needed` |

The suggestion is surfaced verbatim as
`Suggested: Docs-Impact: <computed>. Adjust if your change's doc
impact differs ...`. The worker is told explicitly to override the
suggestion when the real documentation impact differs from the
heuristic (e.g. a script change that quietly invalidates a runbook).

The gate that actually parses the trailer lives in
`lib/docs_impact_gate.sh` (#260 / #316) and accepts the four outcomes
listed above. A `BRIEF DOCS_IMPACT_TRAILER_SUGGESTED ticket=#<n>
agent=<a> project=<p> outcome=<computed>` audit row is emitted on
every render so downstream tooling can correlate suggested outcomes
with actual PR-body trailers once the worker submits.

The trailer instruction is independent of `## Docs-Impact Gate For
Multi-Agent Templates` further down this file: that section guards a
multi-agent-template checklist; the #779 trailer is the project-wide
gate-passing declaration emitted by every dispatched worker.

## Closeout Final Base Guard

Validation can pass and still leave stale base evidence if `origin/main advances while validation runs`.
Dispatch briefs therefore require a final base recheck after validation and
immediately before the final report or PR handoff:

1. Record the initial base SHA before implementation.
2. Run the configured validation exactly as reported.
3. Run `git fetch <base-remote>` and `git rev-parse <base-ref>` again at closeout.
4. Compare the final base SHA with the initial base SHA.
5. If the base advanced and the branch does not contain the final base, report
   `stale-base` with both SHAs. Rebase or refresh only when the dispatch
   explicitly authorizes a non-destructive path; otherwise leave the branch
   untouched and let the orchestrator decide the next handoff.

Documented POC: a worker records `origin/main`, validation runs, another merge
updates `origin/main`, and the worker fetches again during closeout. When the
final `origin/main` differs and is not an ancestor of `HEAD`, the final report
marks `stale-base` instead of presenting the initial base as current. The
focused regression in `tests/test_dispatch_closeout.sh` simulates that
concurrent advance and guards the canonical prompt language.

When dispatch refuses (78 for heavy-local-validators-without-opt-in,
77 for not-ready, 79 for not-consumed, 76 for context-mismatch, or
75 for degraded host or tmux), the numeric exit code maps to a
remediation step in [`docs/exit-codes.md`](exit-codes.md). Operators
inspecting a non-zero dispatch result should land on that manifest
first instead of guessing the meaning from the value.

## Mirror-Preserves-Mode-Bits Regression Class

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

## Wave Dispatch Resilience

Multi-agent wave dispatch MUST run through `scripts/dispatch_wave.sh` rather
than being modeled as parallel interactive Bash tool calls (#327). The host
(LLM tool harness, terminal multiplexer, etc.) can deny or cancel one
parallel call and silently cancel the unrelated siblings — leaving the wave
undispatched while the operator believes it is running. ORDO must own the
fanout transaction.

```bash
bash scripts/dispatch_wave.sh <wave-id> <matrix-file> \
  [--resume] [--dry-run] [--all-must-succeed] [--child-timeout-sec N]
```

Matrix file is TSV with these columns (extra column 5 forwards flags
verbatim to `dispatch_ticket.sh`):

```text
agent\tticket\tprompt-file\tproject-config[\textra-flags]
```

Per-entry guarantees:

- Each `dispatch_ticket.sh` invocation runs in process isolation; one
  entry's denial or failure CANNOT cancel sibling entries.
- Outcomes (`dispatched`, `denied`, `failed`, `skipped`, `dry_run`) are
  appended to `state/_waves/<wave-id>.json` with exit code, stderr tail,
  and timestamps.
- Policy-style denials (exit 77 / 78 / 79) are recorded as `denied`,
  distinct from generic `failed`, so the operator can distinguish
  "brief never landed" from "execution error".
- `--resume` skips entries already recorded as `dispatched`; denials /
  failures are NOT auto-skipped.

This is the codified version of the wave-dispatch resilience rule in
`docs/orchestrator-injected-rules.md`.

## Submit policy per CLI

Terminal-agent CLIs disagree on what "submit this brief" means after a
paste-buffer. The dispatcher encodes the per-CLI gesture in
`lib/worktree_helpers.sh::agent_submit_policy` so the same code path can
drive any CLI without false-negative dispatch failures.

| CLI                 | Policy         | Trailing keystroke after paste                    |
|---------------------|----------------|---------------------------------------------------|
| `codex`             | `single-enter` | one `Enter` (terminates paste + submits)          |
| `claude`            | `double-enter` | one `Enter` (terminates paste), brief pause, one more `Enter` (submits) |
| `copilot`, `gemini` | `single-enter` | one `Enter` (operator-tunable as the CLIs evolve) |
| unknown             | `single-enter` | one `Enter` (preserve legacy behavior)            |

### Why claude needs two Enters (#758)

Live evidence from the 2026-05-19 → 2026-05-20 ORDO dispatch wave
showed that `tmux send-keys -t <pane> "<brief>" Enter` against a healthy
claude pane left the brief staged at the `❯ <brief…>` input line. The
trailing `Enter` ends the paste editor's multi-line input — it does NOT
submit the turn. Without a second `Enter` the agent never receives the
brief; the dispatcher's `PROMPT_EXECUTION_PROOF` detector classifies
the pane as `submission-still-visible` and either fails the dispatch
(false negative) or absorbs a manual `tmux-verified-active`
reclassification (ledger entropy).

Codex CLI does not have this behavior: a single trailing `Enter` after
a pasted brief submits.

### Pipeline

1. `scripts/dispatch_ticket.sh` resolves the active CLI from the
   per-agent launch command (`exec claude …`, `exec codex …`) and
   exports `ORCH_DISPATCH_SUBMIT_CLI` before calling
   `terminal_dispatch_submit`.
2. `terminal_dispatch_submit_once` (wrapped in `worktree_helpers.sh`)
   calls `send_to_pane` (which always sends ONE `Enter` after the
   paste), then `agent_submit_policy_apply` to issue any trailing
   gesture the resolved CLI needs.
3. For `double-enter`, the wrapper sleeps
   `ORCH_CLAUDE_SUBMIT_SECOND_ENTER_MS` (default 200 ms, set to 0 to
   fire immediately) and emits the second `Enter`.
4. The existing `terminal_dispatch_submit` retry budget remains in
   place: if `PROMPT_EXECUTION_PROOF` still reports
   `submission-still-visible`, the dispatcher attempts one more
   staged-Enter recovery before declaring `NOT_CONSUMED`.

### Configuration knobs

- `ORCH_DISPATCH_SUBMIT_CLI` — explicit operator/test override. Skips
  the launch-command parse.
- `ORCH_CLAUDE_SUBMIT_SECOND_ENTER_MS` — delay between the first and
  second `Enter` for `double-enter` CLIs. Default `200`. Tests use `0`
  to avoid sleeping the suite.

### Default to single-enter

Adding a CLI to `agent_submit_policy` with `single-enter` semantics is
the safe default. Operators choosing `double-enter` should pair the
policy entry with a regression test in
`tests/test_dispatch_ticket_submit_policy.sh` so the gesture count is
locked against future paste-handler changes.

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

### Active Backlog Mode

Historical merged PRs and comments can mark an open issue as
`shipped_suspect` or `stale_parent`. That remains the default because it
protects normal queues from re-dispatching already-shipped work. During a
launch or UAT backlog, however, maintainers can declare open issues as
authoritative active backlog so shipped/stale evidence is advisory instead of
excluding the issue from `--ready-only`.

Enable this per planning run with either:

```bash
bash scripts/dispatch_plan.sh <project> --ready-only --active-backlog --json
DISPATCH_PLAN_ACTIVE_BACKLOG=1 bash scripts/dispatch_plan.sh <project> --ready-only --json
```

Or enable it per issue with one of:

- the label `dispatch:active-backlog`;
- the label `ordo:active-backlog`;
- the body marker `ORDO-ACTIVE-BACKLOG` (HTML comments are fine, e.g.
  `<!-- ORDO-ACTIVE-BACKLOG -->`).

When active-backlog mode applies, an otherwise ready open issue stays
`status=ready` and keeps `merged-pr:#N` or `shipped-comment:#N` in its signals
alongside `active-backlog` and `shipped-advisory`. Active-backlog mode does
not override normal dependency, assignee, or atomization states.

Maintainers can still make an open issue non-dispatchable by closing it or by
adding an explicit shipped label: `shipped`, `status:shipped`,
`resolution:shipped`, `dispatch:shipped`, or `ordo:shipped`. Those labels
produce `status=shipped_suspect` with `explicit-shipped-label`.

### Shipped Match Mode (`DISPATCH_PLAN_SHIPPED_MATCH_MODE`, #778)

The `shipped_pr_for_issue` lookup decides whether a merged PR actually
shipped an open issue. Before #778 it matched any reference to the issue
number anywhere in a merged PR's title, body, or branch name, which flagged
issues that a merged PR merely listed as a prerequisite, follow-up, or
see-also (e.g., #753/#754/#755 wrongly flagged because PR #743 listed them
under "Prerequisites:").

`DISPATCH_PLAN_SHIPPED_MATCH_MODE` selects how strictly the lookup attributes
ship credit to a merged PR:

| Mode | Match policy |
| --- | --- |
| `closing-keyword` (default) | The merged PR body uses a GitHub closing keyword (`close[sd]?`, `fix(e[sd])?`, `resolve[sd]?`) immediately before `#N`. A bare mention does **not** flag `shipped_suspect`. |
| `timeline-close` | The PR is listed under the issue's `closedByPullRequestsReferences` and is `MERGED`. Strict: requires GitHub to recognize the link, so a malformed closing keyword will not match. |
| `mention` | Legacy behavior: any mention of `#N` in the PR title, body, or branch name counts. Kept as an opt-in audit knob for verifying back-compat or for issues whose body intentionally references shipping work without using a closing keyword. |

```bash
# default — strict closing-keyword check
bash scripts/dispatch_plan.sh <project> --ready-only --json

# strictest — also requires GitHub to recognize the closing link
DISPATCH_PLAN_SHIPPED_MATCH_MODE=timeline-close \
  bash scripts/dispatch_plan.sh <project> --ready-only --json

# legacy — restores pre-#778 behavior (audit only; not for live dispatch)
DISPATCH_PLAN_SHIPPED_MATCH_MODE=mention \
  bash scripts/dispatch_plan.sh <project> --ready-only --json
```

PR authors should keep using `Closes #N` / `Fixes #N` / `Resolves #N` in PR
bodies — those are the canonical closing keywords. Bullet sections such as
`Prerequisites: #N`, `Follow-up: #N`, or `See also: #N` will no longer mark
those referenced issues as shipped.

### Resolved-Decision Marker

Issues whose body is **about** arbitration discipline (rather than asking for
a decision) used to trip the `arbitration:decision-required` text-blocker
because phrases like `pending arbitration`, `decision required`, or
`pending decision` matched anywhere in the body. To declare that no
decision is actually pending, add a marker line to the issue body:

```text
Decision status: RESOLVED — implement directly.
```

Recognized variants (case-insensitive): `Decision status: RESOLVED`,
`Decision status: cleared`, `Decision status: done`, `Decision: made`,
`Decision: resolved`, `Decision: cleared`, `Decision: done`.

When the marker is present, the planner suppresses the
`arbitration:decision-required` blocker and the `text-blocked` signal
contributed by it, even if the body quotes arbitration-policy prose. The
other text-blockers (`precondition:blocking-precondition`,
`design:figma-or-design-gate`, `multilingual:external-content-or-routing`)
are unaffected and continue to gate dispatch.

### Auto-Close shipped_suspect (queue resolver phase A, #762)

`continuation_guard.sh` raises `shipped-suspect-review-required` whenever the
ready queue is empty and the planner still carries `shipped_suspect` rows.
Those rows accumulate when a squash-merge `Closes #N` keyword silently
failed, or when the issue pre-dates the closure_acceptance gate landed by
PR #743 (#723). The supervisor cannot dispatch fresh work while they sit on
the backlog.

`scripts/auto_close_shipped_suspect.sh` resolves the queue by reusing the
same `closure_acceptance_gate` decision the post-merge cleaner already
applies on every PR merge:

```bash
# Inspect candidates without closing anything (default during rollout).
bash scripts/auto_close_shipped_suspect.sh <project> --dry-run --json

# Close the rows whose merging PR carries acceptance proof (or an
# operator-authorized override trailer).
ORCH_EXTERNAL_PR_MUTATIONS=issue_close \
  bash scripts/auto_close_shipped_suspect.sh <project> --apply --json
```

For each plan row classified as `shipped_suspect` (or `stale_parent`) the
script:

1. Reads the full plan via
   `dispatch_plan.sh <project> --include-shipped-suspect --json`.
2. Extracts the merging PR number from the row's `merged-pr:#N` signal.
3. Fetches the PR body and the source-issue body through `gh`.
4. Invokes `closure_acceptance_classify` (the same classifier wired into
   `post_merge_cleanup.sh::post_merge_reconcile_issues`).
5. Emits one `AUTO_CLOSE_CANDIDATE` audit row per shipped_suspect row,
   carrying the classifier outcome and refusal reason.
6. In `--apply` mode, closes the issue through
   `external_pr_mutation_run` so the `issue_close` authorisation scope
   (#268) still gates the mutation. Rows whose PR body lacks acceptance
   proof remain in `action=audit_only` and are surfaced for operator
   review — they are **never** auto-closed.

`ORCH_AUTO_CLOSE_MODE` controls the default mode (`off|dry-run|apply`,
default `off`). The CLI flags `--apply` and `--dry-run` override the
env so a one-shot supervisor pass cannot silently flip behavior on
hosts that pre-set the env. Even in `--apply` mode, `gh issue close`
requires `issue_close` (or `all`) in `ORCH_EXTERNAL_PR_MUTATIONS`; the
auto-close mode flag is intentionally not sufficient on its own.

Output columns (TSV/JSON):

| Column | Meaning |
| --- | --- |
| `project`, `issue`, `pr` | Identity. `pr=0` means no `merged-pr:#N` signal was attached to the row. |
| `outcome` | Raw `closure_acceptance_classify` outcome (`pass`, `operator-override`, `scaffold-declared:#M`, `refused`, or `no-merged-pr`). |
| `action` | `closed`, `would_close` (dry-run with pass outcome), `audit_only` (refused), `close_failed` (apply mode, mutation refused or `gh` exited non-zero), or `skip` (no PR signal). |
| `reason` | Stable token from `closure_acceptance_refusal_reason` plus the `issue_close_rc=<n>` failure code when applicable. |
| `mode` | Effective mode used for the run (`off`, `dry-run`, `apply`). |

Rollout sequence:

1. Run `--dry-run` first and review the `AUTO_CLOSE_CANDIDATE` audit rows
   per project to confirm the gate's verdict matches the operator's
   expectation.
2. Pin `ORCH_AUTO_CLOSE_MODE=dry-run` in the supervisor for one cycle to
   accumulate audit evidence without mutation.
3. Once the operator is comfortable with the gate's classification, flip
   to `ORCH_AUTO_CLOSE_MODE=apply` AND grant `issue_close` in
   `ORCH_EXTERNAL_PR_MUTATIONS`. Either lever alone is intentionally a
   no-op.
4. Rows the gate keeps refusing become the input for phases B/C/D of the
   queue resolver (stale evidence, non-acceptance, operator-review).

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

# Cap creation per invocation. --apply is a no-op alias for the default
# mutating behavior so orch_loop's auto-atomize step can pass it
# explicitly. 0 (the default) means unlimited.
bash scripts/dispatch_plan.sh <project-config> --atomize --apply --max-children-per-cycle 2
DISPATCH_PLAN_ATOMIZE_MAX_CHILDREN_PER_CYCLE=2 \
  bash scripts/dispatch_plan.sh <project-config> --atomize
```

When `--max-children-per-cycle` (or the env-fallback) is set, the script
stops creating children once the cap is reached, audits a
`DISPATCH_PLAN atomize cap-reached` row, and emits one stderr line per
parent that produced children:

```
AUTO_ATOMIZE_SUMMARY parent=<N> children=<a,b,...> project=<X> max_per_cycle=<K>
```

The summary line is the contract consumed by the Phase B orch_loop step
(see below). The ordinary stdout (TSV/JSON plan) is unchanged.

### Auto-Atomize when ready queue starves (queue resolver phase B, #763)

`continuation_guard.sh` raises `atomize-required` whenever the ready
queue is empty and the planner still carries needs-atomization parents.
Without a deterministic resolver, the supervisor's soft directive to
"run `dispatch_plan --atomize --dry-run` first" gets skipped and the
queue stays starved while atomize-eligible epics sit forever.

`scripts/orch_loop.sh` resolves this by invoking the cap-aware atomize
step once per cycle, after `sixsigma_autoupgrade` and before the
monitor heartbeat, when **all three** continuation_guard signals line up:

| Signal | Required value | Source |
| --- | --- | --- |
| `ready_count` | `== 0` | rows with `status == "ready"` |
| `shipped_suspect_count` | `== 0` | rows with `status == "shipped_suspect"` |
| `atomize_count` | `> 0` | rows with `status == "atomize"` or `"stale_parent"` |

The shipped_suspect gate is intentional: Phase A
(`auto_close_shipped_suspect.sh`) must clear the suspect rows first so
the auto-atomize step does not race the closure path on the same parent.

#### Rate limiting

Two independent caps apply to keep a runaway supervisor from
mass-creating issues:

- `ORCH_AUTO_ATOMIZE_MAX_PER_CYCLE` (default `2`) — hard upper bound per
  supervisor cycle. Passed directly to
  `dispatch_plan --max-children-per-cycle`.
- `ORCH_AUTO_ATOMIZE_MAX_PER_HOUR` (default `6`) — rolling-hour cap
  enforced from an on-disk ledger
  (`$(state_dir)/auto_atomize.ledger`). Each child creation appends
  `<unix_ts> <parent> <child> <cycle>`. Entries older than 3600s are
  ignored. The effective per-cycle budget is
  `min(ORCH_AUTO_ATOMIZE_MAX_PER_CYCLE, remaining-hour-budget)`; when
  the remaining budget hits 0 the step skips with audit row
  `AUTO_ATOMIZE skip cycle=K project=X reason=hourly-cap-exhausted cap=N`.

Operators that run an external atomizer can opt out entirely with
`ORCH_AUTO_ATOMIZE_DISABLED=1`.

#### Audit trail

Per cycle, the step emits one of these audit shapes per parent that
produced children:

```
AUTO_ATOMIZE parent=#<parent> children=[#<a>,#<b>,...] cycle=<K> \
  project=<X> mode=apply max_per_cycle=<budget> hourly_cap=<cap>
```

And these skip shapes when the conditions are not met:

```
AUTO_ATOMIZE skip cycle=<K> project=<X> reason=conditions-unmet \
  ready=<r> atomize=<a> shipped_suspect=<s>
AUTO_ATOMIZE skip cycle=<K> project=<X> reason=hourly-cap-exhausted cap=<N>
AUTO_ATOMIZE skip cycle=<K> project=<X> reason=plan-failed rc=<n>
```

The supervisor's main loop also honours the standard stop barrier
(`audit_blocked_dispatch auto-atomize <cycle>`), so a clean stop request
during the auto-atomize step is recorded and the step is skipped.

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
audited via `DISPATCH_MATRIX gate result=refused`). These are
pre-assignment matrix gate refusal outcomes: they happen before any tmux
send and before the optional GitHub assignee policy runs. Do not describe
them as `assignee_policy=refused`; that downstream outcome is reserved
for the GitHub assignment identity guard described in the assignment
policy section.

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

Before a hard-switch respawn, `dispatch_ticket.sh` checks the pane's live
`#{pane_current_path}` against active assignment workdirs under
`$ORCH_STATE_BASE/*/assignments.json`. If the pane is already inside an
assigned worktree, dispatch refuses before staging or respawning and surfaces
`pane-occupied:<project>#<issue>` in stderr/audit output. Operators should
wait for the active work to finish, recover the assignment, or explicitly
preempt it before redispatch.
`agent_pool_status.sh` emits the same signal when live pane cwd matches an
active assignment workdir, so planners can spot occupancy before dispatch.

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

When the operator is launching that command from a Windows session over SSH,
wrap the remote bash snippet with the CRLF-safe helper:

```bash
bash scripts/windows_ssh_dispatch.sh \
  --host <ssh-target> \
  --file ./remote-dispatch.sh
```

or use the raw equivalent:

```bash
ssh <ssh-target> "tr -d '\r' | bash -s" < ./remote-dispatch.sh
```

If the failed remote output includes `unknown arg: --<flag>` and CRLF evidence
such as `\r`, `^M`, or bash xtrace `$'...\r'`, classify the incident as
`windows-crlf-argv-contamination` and retry through the normalized path before
treating the flag as unsupported.

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

Successful assignment records also persist the declared route and context
proof (`route_mode`, `context_proof_route`, and
`context_proof_live_workdir`). `agent_pool_status.sh` only reports a cwd
mismatch as `soft_routed_active` when that metadata, the current pane cwd, and
the staged prompt's absolute workdir contract agree. If any part of that proof
is missing, stale, or inconsistent, the pane stays a normal
`live_cwd_mismatch`/`switch_required` candidate until the operator hard-switches
or redispatches it.

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

## Idle / Soft-Block Rebalance (#757)

A real ORDO wave on 2026-05-20 left `agent-004` occupied on a single ticket
for ~2 hours after the agent had already declared an out-of-scope blocker
in its pane ("Recommendation for the dispatcher: …needs to be resolved on
main…"). The supervisor's per-cycle loop ran 30+ times without releasing
the agent or surfacing the blocker, while ten other agents sat idle. The
loop treated the populated `assignments.json` row as opaque busy capacity
and never inspected pane state, so the doctrine-mandated rebalance never
fired.

`lib/agent_softblock.sh` adds a pane-state classifier and a per-cycle
rebalance step that the orchestrator runs after every supervisor turn:

- `classify_agent_pane <pane>` returns one of `working`, `idle`, or
  `soft_blocked`. The argument is either a tmux pane target (captured
  via `tmux capture-pane -p -S -<N>`) or a file path holding a
  pre-captured pane dump — fixtures and tests use the file form.
- A pane classifies as `soft_blocked` when its body matches any
  configured operator-handoff phrase. The default vocabulary ships with
  the library (`Recommendation for the dispatcher`, `out of scope`,
  `blocker:`, `waiting on`, `cannot resume`, `needs another dispatch`,
  …) and is replaceable via `ORCH_SOFTBLOCK_PATTERNS` (newline- or
  pipe-separated extended-regex fragments). When the soft-block
  vocabulary does not match, `working` is detected from recent git
  activity (`[branch sha] …`, `git commit`, `git push`, `To
  https://…`, "Wrote", "modified", …) configurable via
  `ORCH_SOFTBLOCK_WORKING_PATTERNS`. Everything else falls through to
  `idle`. Soft-block vocabulary always wins over a stale working line
  earlier in the same pane.

The orchestrator entry point is
`agent_softblock_run_rebalance_step <project> <state_dir>`. It is invoked
once per cycle from `scripts/orch_loop.sh` (gated by the standard stop
barrier; opt out with `ORCH_SOFTBLOCK_DISABLED=1`). The step:

1. Walks `agent_inventory_entries`, captures each pane, and classifies it.
2. Records a structured `ORCH_LOOP_SOFTBLOCK_SCAN` audit row regardless
   of outcome (`decision=no_softblock`, `decision=no_idle_capacity`,
   or — when both groups are present — the rebalance action).
3. Emits a single `ORCH_LOOP_REBALANCE_REQUIRED` audit row when
   `idle_count > 0 AND soft_blocked_count > 0`. The row carries
   `idle_agents=<csv>`, `soft_blocked=<agent#ticket,…>`, and
   `reason=soft_blocked_capacity_waste`.
4. Appends one row per soft-blocked agent to
   `<state_dir>/intervention_queue.md`. The row layout is:

   ```text
   | timestamp | agent | ticket | blocker_excerpt | recommended_action |
   ```

   The recommended action enumerates the live idle pool so the operator
   can redispatch the blocker fix to any of them, or release the
   soft-blocked assignment. The queue file is markdown so it renders
   with `glow` and grep-search works without a JSON tool. Operator
   action drains the row; orch_loop will re-add the row on the next
   cycle if the soft-block persists — that is by design.
5. Also emits one `ORCH_LOOP_OPERATOR_INTERVENTION_REQUIRED` audit row
   per soft-blocked agent so downstream dashboards see a per-agent
   signal alongside the aggregate `REBALANCE_REQUIRED` event.

Tuning hooks (all optional):

| Env knob | Default | Effect |
| --- | --- | --- |
| `ORCH_SOFTBLOCK_PATTERNS` | `agent_softblock_default_patterns` | Replace the soft-block vocabulary. Newline- or pipe-separated. |
| `ORCH_SOFTBLOCK_WORKING_PATTERNS` | `agent_softblock_default_working_patterns` | Replace the "working" indicators. |
| `ORCH_SOFTBLOCK_PANE_LINES` | `200` | Tail line count captured per pane. |
| `ORCH_SOFTBLOCK_DISABLED` | `0` | When `1`, the rebalance step no-ops. |

Coverage: `tests/test_agent_softblock.sh` exercises the classifier and
the intervention-queue writer in isolation;
`tests/test_orch_loop_softblock_rebalance.sh` runs the cycle-level step
against a three-agent fixture (one soft-blocked + two idle) and asserts
exactly one `REBALANCE_REQUIRED` row + one queue entry per cycle, as
well as the three negative paths (no soft-block, no idle capacity,
`ORCH_SOFTBLOCK_DISABLED=1`).

## Delegated PR Follow-Up Capacity

`scripts/dispatch_pr_ops.sh` treats both `available` and `switch_required`
agent capacity classes as delegation capacity for rebase, stale-base, PR
readiness, and CI follow-up work. A PR owner that is already `dispatched`,
dirty, or doing local work is not enough to keep the task with the
orchestrator; the dispatcher falls back to the first clean/switchable fleet
slot and records that agent's capacity class in the JSON result.

Stale-base signals (`needs-rebase`, `pr-behind`, and
`remote-rebased-local-stale`) are delegated as `resolve_conflict` tasks, with
the merge/ready authority remaining outside the delegated brief. When no
clean/switchable capacity exists, the blocker is
`no-clean-or-switchable-agent`.

Every PR-ops wave emits a counted audit summary:

```text
PR_OPS WAVE summary ... configured=<n> dispatched=<n> refused=<n> no_action=<n> no_delegation_reason=<reason> blockers=<csv>
```

Use that line as the durable evidence for "delegated" or "not delegated and
why" findings, rather than a chat narrative or a local manual execution note.

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
## Aggregate vs Isolated Bats Runs
Several documentation-system bats suites under `tests/` exercise the
ORDO documentation system (the docs architecture in #258, the install /
integration / usage guides in #259, the docs impact gate in #260, and
the docs generator in #261). Those suites have to behave correctly under
two different invocation paths, and the difference is large enough that
operators must read the test output with it in mind.
| Path | How it runs | What is reachable |
| Isolated | `bats tests/docs_*.bats` directly from the checkout | The full repository tree: `README.md`, `PRODUCT.md`, every file under `docs/`, plus the standard mirror dirs (`config/`, `examples/`, `lib/`, `scripts/`, `templates/`, `tests/`). Tests can grep tracked docs and assert on link targets. |
| Aggregate | `bash scripts/run_bats.sh` (or `tests/test_run_bats.sh`) | A sanitized mirror in `$TEST_TMP/toolkit/` that copies only `config/`, `examples/`, `lib/`, `scripts/`, `templates/`, `tests/`, plus `install.sh`. `README.md`, `PRODUCT.md`, and the `docs/` tree are intentionally not mirrored. |
The mirror exists so the bats suites cannot accidentally depend on a
non-toolkit file under the operator's working tree. As a consequence, a
test that wants to assert against `README.md` or `docs/<x>.md` must
detect the sanitized-mirror context and `skip` rather than fail. The
canonical helper is `detect_real_repo_root` in `tests/helpers.bash`, used
as:
@test "every README documentation map link resolves to a real file" {
  local repo
  repo=$(detect_real_repo_root) \
    || skip "running in sanitized mirror; README.md not reachable"
  ...
}
Aggregate-vs-isolated parity is the contract that test files in this
group respect:
- Every assertion that requires `README.md`, `PRODUCT.md`, or any path
  under `docs/` runs only in isolated mode, with a documented `skip`
  reason in aggregate mode.
- Every assertion that requires only mirrored sources (`scripts/`,
  `lib/`, `templates/`, `examples/`, `tests/`, `config/`,
  `install.sh`) runs identically in both modes.
## Deferred Docs-system Skip Reporting
Docs-system suites also use a "skip when absent" pattern for assertions
that depend on a feature whose owning ticket has not yet landed (#258
docs architecture, #259 install/integration/usage, #260 docs impact
gate, #261 docs generator). When the underlying file is missing the
test logs a `skip` line such as:
```text
ok 7 docs generator produces deterministic output when present (#261) # skip docs generator (#261) not yet present at this base
That is intentional: the suite stays green on the orch baseline, and
each deferred check activates by itself the moment its owning PR
merges. The trade-off is that an operator scanning a green CI run may
not realize how much of the docs-system coverage is still gated.
When triaging or signing off a docs-system wave, treat the bats output
as having two coverage counts:
| Count | Meaning |
| Active | bats lines that read `ok N <description>` with no `# skip` annotation. |
| Deferred | bats lines that read `ok N <description> # skip <reason>` — the assertion did not run because its owning ticket has not landed. |
Quick recipes:
# Count active vs deferred docs-system assertions in a bats log.
grep -c '^ok '            ci-bats.log
grep -c ' # skip '         ci-bats.log
grep -E '^ok .*# skip '   ci-bats.log    # the deferred lines themselves
# When promoting a docs-system PR, expect the deferred count to drop.
# After #260 lands, the docs_freshness_outcomes.bats skips disappear.
# After #261 lands, the docs_generator_smoke.bats and
# docs_layers_optionality.bats generator skips disappear.
The active and deferred counts together form the running coverage
ledger for the documentation system. Operators reviewing a docs-system
sign-off should record both counts in the wave's evidence so the
trend is visible across PRs without re-reading every bats log.
## File Hotspot Agent Attribution
ORDO is a general multi-agent toolkit, so file-hotspot detection
(`lib/file_hotspots.sh`) MUST NOT infer agent ownership from any single
hardcoded author-login convention. Deployments without RBOKCLI-style users
would otherwise misclassify multi-agent hotspots as single-owner rows and
miss real conflict risk (#292).
`file_hotspots_pr_agent <author> <labels-csv>` resolves a PR's effective
agent label using these sources, in this order:
1. **`agent:<name>` PR label** (case-insensitive). Wins immediately. The
   name keeps its original case. A bare `agent:` label (no name) is skipped
   so resolution continues.
2. **Explicit author -> agent map** via `ORDO_FILE_HOTSPOT_AUTHOR_AGENT_MAP`
   (bash array of `login=agent` entries; whitespace around `=` is tolerated).
3. **First matching configured prefix** from
   `ORDO_FILE_HOTSPOT_LOGIN_PREFIXES` (bash array, multi-prefix). The
   declared order matters — put longer / more specific prefixes first. The
   matched prefix is stripped from the author login. A single
   `ORDO_FILE_HOTSPOT_LOGIN_PREFIX` is retained for transitional
   compatibility and behaves as a one-element prefix list.
4. **Raw author login**, returned as-is when no prior rule matches. There is
   **no implicit `RBOKCLI` fallback** — operators that want RBOKCLI
   stripping must declare it via the configuration above.
5. **`unknown`** sentinel when both author and labels are empty.
### Configuration examples
# Multi-prefix deployment: declare every CLI bot identity that should be
# stripped down to its agent label.
ORDO_FILE_HOTSPOT_LOGIN_PREFIXES=("RBOKCLI" "MyOrgCLI-")
# Transitional single-prefix form (still supported).
ORDO_FILE_HOTSPOT_LOGIN_PREFIX="RBOKCLI"
# Explicit author -> agent map for accounts that don't follow any prefix
# convention (e.g. shared bot accounts, third-party tools).
ORDO_FILE_HOTSPOT_AUTHOR_AGENT_MAP=(
  "renovate-bot=renovate"
  "dependabot[bot]=dependabot"
)
When several agents share a single GitHub author (typical for shared bot
accounts), each PR should carry an `agent:<name>` label so the hotspot
matrix can disambiguate ownership without relying on author parsing at all.
## Docs-Impact Gate For Multi-Agent Templates
`scripts/docs_impact_gate.sh` is a small CI/contributor gate that refuses (or
warns) when a PR changes a multi-agent template under
`docs/templates/multi-agent/` without rendering the docs-impact checklist in
the PR body. It exists because the template itself only ships a checklist
that is otherwise enforced by review attention; the gate makes the
enforcement traceable.
### Behavior
The gate reads two inputs:
- a list of changed paths (typically `git diff --name-only origin/main...HEAD`);
- the PR body (text from `gh pr view --json body --jq .body`, or from a
  contributor's local PR-template draft).
It filters changed paths against `DOCS_IMPACT_GUARDED_PATHS` (default
`docs/templates/multi-agent/`). When at least one guarded path was changed,
it scans the PR body for a markdown header that matches
`DOCS_IMPACT_BLOCK_HEADERS` (default `Docs Impact|Documentation Impact|Impact docs|Impact documentation`)
followed by at least one `- [ ]` or `- [x]` checklist item.
| Outcome | Status | Exit |
| no guarded paths changed | `ok`    | 0 |
| guarded paths changed AND block present | `ok`    | 0 |
| guarded paths changed AND block missing | `block` | 4 |
| guarded paths changed AND block missing AND `--warn-only` | `warn`  | 0 |
| guarded paths changed AND block missing AND `DOCS_IMPACT_GATE_MODE=warn` | `warn`  | 0 |
### Local usage
# Capture changed paths and PR body (interactive review):
git diff --name-only origin/main...HEAD > /tmp/changed-paths.txt
gh pr view <number> --json body --jq .body > /tmp/pr-body.md
# Default: refuse when block is missing.
bash scripts/docs_impact_gate.sh \
  --diff /tmp/changed-paths.txt \
  --pr-body /tmp/pr-body.md
# Warn-only mode for the contributor's pre-push smoke check.
bash scripts/docs_impact_gate.sh \
  --diff /tmp/changed-paths.txt \
  --pr-body /tmp/pr-body.md \
  --warn-only
# Pipe stdin for either input (one at a time, not both).
git diff --name-only origin/main...HEAD \
  | bash scripts/docs_impact_gate.sh \
      --diff - \
      --pr-body /tmp/pr-body.md \
      --json
### CI wiring (suggested)
Add a step to the PR-validation workflow that fetches the PR body and the
diff, then runs the gate. The exact YAML lives in the project's
`.github/workflows/` and is intentionally not added by the toolkit, so each
project can wire it into its own existing validation job.
```yaml
- name: docs-impact gate
  if: github.event_name == 'pull_request'
  run: |
    gh pr diff "${{ github.event.pull_request.number }}" \
      --repo "${{ github.repository }}" \
      --name-only > /tmp/changed-paths.txt
    gh pr view "${{ github.event.pull_request.number }}" \
      --repo "${{ github.repository }}" \
      --json body --jq .body > /tmp/pr-body.md
    bash scripts/docs_impact_gate.sh \
      --diff /tmp/changed-paths.txt \
      --pr-body /tmp/pr-body.md
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
Projects with their own template directories can extend the guarded list
without code changes. Entries can be path prefixes (with or without a
trailing slash) or shell globs.
# Newline-delimited:
DOCS_IMPACT_GUARDED_PATHS=$'docs/templates/multi-agent/\nconfig/agent-roster/' \
  bash scripts/docs_impact_gate.sh --diff ... --pr-body ...
# Comma + semicolon separators:
DOCS_IMPACT_GUARDED_PATHS='docs/runbooks/,examples/profiles/;config/agent-roster/' \
  bash scripts/docs_impact_gate.sh --diff ... --pr-body ...
# Glob:
DOCS_IMPACT_GUARDED_PATHS='config/profiles/*/agents.yaml' \
  bash scripts/docs_impact_gate.sh --diff ... --pr-body ...
Custom entries are added to the defaults, not substituted for them, so
projects that opt-in keep the canonical multi-agent-template coverage.
### Localized headers
The default header allowlist already accepts the English variants
`Docs Impact`, `Documentation Impact`, `Impact docs` and the French
`Impact documentation`. To add a project-specific header (for example a
team's bilingual block), append a regex alternation to
`DOCS_IMPACT_BLOCK_HEADERS`:
DOCS_IMPACT_BLOCK_HEADERS="Docs Impact|Documentation Impact|Impact docs|Impact documentation|Repercussions docs" \
  bash scripts/docs_impact_gate.sh --diff ... --pr-body ...
### Rationale
`docs/templates/multi-agent/docs-impact.md` defines the checklist that PR
authors should render whenever a multi-agent template changes. Without the
gate, the only enforcement is review attention; template behavior and the
downstream onboarding docs that depend on it can drift quietly. The gate
turns the missing-checklist case into a traceable signal — failing the PR
in `block` mode, or warning in `warn` mode for projects that prefer a
softer enforcement during the rollout window.
