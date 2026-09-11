# Migration, compatibility, rollback and versioned upgrades

Audience: operator, integrator, developer. Category: integration / operator
docs (see [README.md → 2. Integration](README.md#2-integration)).

Epic [#806](https://github.com/decarvalhoe/ORDO/issues/806), child
[#814](https://github.com/decarvalhoe/ORDO/issues/814). This page is for the
operator of an existing ORDO deployment: what changed under the scripts you
already run, which knobs turn the new layers on, what an upgrade needs from
you, and how to roll each piece back. Everything here follows from one
design rule of the plan — *keep Bash adapters operational during migration;
compatibility wrappers are required until each surface has a replacement*.

## What changed, at a glance

| Surface | Before `c7231cc` | Now | Knob | Rollback |
| --- | --- | --- | --- | --- |
| Operator commands | `bash scripts/<x>.sh …` | Same, plus `ordo <cmd>` routing to them verbatim | none | keep calling the scripts |
| Forge access | ~100 direct `gh` calls in `lib/` and `scripts/` | `ordo_provider <op>`; the `github` backend issues the same `gh` invocations; `forgejo` / `gitlab` over REST; `fake` for tests | `ORDO_PROVIDER_ADAPTER` (default `github`) | default already reproduces the old behaviour |
| Forge mutations from scripts | gated per call site by `external_pr_mutation_run` | gated once, in the adapter, per scope; idempotency ledger; receipts | `ORCH_EXTERNAL_PR_MUTATIONS` (unchanged semantics, **more scopes needed**, see below) | unset → audit-only, as before |
| Run state | `assignments.json` and friends via `state_persist.sh` | Additionally: SQLite journal + projections; compat export re-emits the legacy files | none (the journal is created lazily by the first `ordo_*` call) | delete the journal files; legacy files stand |
| Scheduling | `orch_loop.sh` cycles | Same; optional scheduler tick per cycle | `ORDO_SCHEDULER_ENABLED=1` | unset |
| Approvals | none (gate only) | Typed approvals + re-authorising bridge on top of the gate | `ORDO_APPROVAL_PRINCIPALS`, `ORDO_POLICY_VERSION` | unset; the gate alone remains |
| Telemetry | audit log (+ optional OTLP mirror) | Same, plus span files under `traces/` and an explicit OTLP export | `ORDO_TRACE_ENABLED` (default on, local files only) | `ORDO_TRACE_ENABLED=0` |
| Tests | 431 Bats + shell suite | Same suites unchanged, plus the `ordo_*` suites and the eval harness | — | — |

No existing script changed its flags, output or exit codes; the routed
scripts' historical exit codes (the 75–92 refusal band) stay authoritative
([../exit-codes.md](../exit-codes.md)).

## Compatibility guarantees

1. **Direct script invocation keeps working.** `scripts/ordo.sh` is a
   facade ([cli.md → Migration plan](cli.md#migration-plan-route-incrementally));
   `tests/cli/ordo_cli.bats` contains a regression test that the routed
   scripts still run on their own.
2. **Status output is reproduced byte for byte.** The journal's
   compatibility projection writes the legacy files *through*
   `lib/state_persist.sh` with the exact key order and null/empty rules of
   `dispatch_assignment_payload` in `scripts/dispatch_ticket.sh`;
   `tests/ordo_journal.bats` extracts that function at run time and `cmp`s
   the two ledgers ([journal.md → Compatibility projection](journal.md#compatibility-projection-legacy-state-files)).
   Readers that keep working unchanged: `orch_ctl.sh status`, `orch_loop.sh`,
   `monitor_heartbeat.sh`, `recover.sh`, `preempt_assignment.sh`,
   `lib/worktree_helpers.sh`, `lib/agent_softblock.sh`,
   `lib/dispatch_capacity.sh`, `lib/capacity_report.sh`, `lib/recovery_context.sh`.
3. **The journal owns only what it wrote.** `ordo-journal-compat.json`
   lists the `assignments.json` rows the compat export manages; every other
   row is never touched.
4. **Same `gh` invocations on GitHub.** `tests/ordo_provider_adapter.bats`
   pins, op by op, the exact `gh` command lines the github backend issues —
   the ones the call sites used before #816. A deployment on GitHub with the
   default adapter sees the same requests, the same `GH_CONFIG_DIR`
   handling and the same `gh` retries.
5. **Enums are projected back.** Migrated scripts map the adapter's
   lowercase forge-neutral values onto the upper-case vocabulary their
   `jq`/`awk` consumers and audit lines already read
   ([providers.md → Migration status](providers.md#migration-status)).

## The `gh` → adapter migration: what an operator must do

### Add the mutation scopes your workflows use

The gate semantics did not change — audit-only by default, authorised per
scope through `ORCH_EXTERNAL_PR_MUTATIONS` (comma list or `all`) — but
mutations that used to slip through a raw `gh` call are now classified and
asserted **before** the forge is called. A refusal is exit 3
`policy_refused` from module `provider_adapter` with
`details.authorize_via="ORCH_EXTERNAL_PR_MUTATIONS"` and an audit line
`EXTERNAL_PR_MUTATION action=<scope> mode=refused …`. Add the scopes the
workflow needs, nothing more:

| Workflow / script | Scopes to authorise |
| --- | --- |
| `lib/pr_merge.sh` (also `pr_merge_wave.sh`, `portfolio_auto_merge.sh`) — merge, ready-for-review, admin approval, reconcile the linked issue | `pr_merge`, `pr_ready`, `pr_review`, `issue_comment`, `issue_close`, `issue_labels` (`pr_merge.sh` audits `MERGE REFUSED … reason=policy-refused` and exits 4 when one is missing) |
| `scripts/dispatch_plan.sh --atomize --apply` — create child issues, label and comment | `issue_create`, `issue_labels`, `issue_comment` |
| `scripts/dispatch_ticket.sh` — assign the issue to the agent; `scripts/reclaim_orphan_assignments.sh` — unassign | `issue_assignees` |
| `scripts/post_merge_cleanup.sh`, `scripts/auto_close_shipped_suspect.sh` — close the shipped issue | `issue_close` |
| `scripts/blocker_issue_registry.sh` — open / reopen / close / label blocker issues | `issue_create`, `issue_reopen`, `issue_close`, `issue_labels` |
| callers of `lib/gh_body_helpers.sh` — comments, reviews, new PRs and issues | `pr_comment`, `pr_review`, `issue_comment`, `issue_create`, `pr_state` |
| The approval bridge (`ordo approve` + `authorize-and-run`) | the scope of the approved action (`pr.merge` → `pr_merge`, …) — an approval never bypasses the gate |

Known scopes (`external_pr_mutation_known_scopes`): `audit_evidence
issue_pack_notify pr_comment pr_edit pr_state pr_labels pr_assignees
pr_review pr_ready pr_merge pr_close pr_reopen issue_create issue_comment
issue_edit issue_labels issue_assignees issue_close issue_reopen`. Set the
variable in the external profile (never in the repository) and keep it as
narrow as the workflow; a read-only profile leaves it empty.

### Know where the ledger lives

Every mutation now records a receipt in
`$(state_dir)/ordo-provider-idempotency.jsonl` keyed by a stable idempotency
key (`<context>:<action>:<subject>`, e.g. `pr_merge:<repo>#<n>:<head_sha>`).
A retry with the same key returns the receipt without calling the forge.
Include the file in state backups; deleting it only means the next retry
calls the forge again (forge-side idempotency — "already merged" →
`conflict` — still holds).

### Remaining GitHub-only paths

A few reads have no forge-neutral op yet and stay on `gh` **for the github
adapter only**, answering "unknown" or empty elsewhere: branch protection
(`lib/governance_check.sh`, `scripts/pr_block_signals.sh`), check-run
annotations (`lib/ci_external_blockers.sh`, `scripts/check_ci_health.sh`),
the batched GraphQL file listing (`lib/gh_pr_files_batch.sh`), `gh label
list` (`dispatch_plan.sh`), `gh repo list` (`portfolio_repo_bind_plan.sh`),
`gh workflow list`. Child [#818](https://github.com/decarvalhoe/ORDO/issues/818)
adds the missing ops so no call site survives; until then those signals
degrade to "no evidence" on Forgejo/GitLab, never to "ready".

## Per-forge setup

Select the forge in the external profile and nothing else changes for the
scripts ([providers.md → Configuration](providers.md#configuration) has the
full table and the token file rules):

```bash
# Forgejo / Gitea
ORDO_PROVIDER_ADAPTER=forgejo
ORDO_FORGE_URL=https://forge.example.org        # /api/v1 is appended
ORDO_FORGE_REPO=owner/repo                      # GH_REPO stays the legacy fallback
ORDO_FORGE_TOKEN_FILE=$HOME/.config/ordo/forge-token   # mode 0600, never the token itself
export ORDO_PROVIDER_ADAPTER ORDO_FORGE_URL ORDO_FORGE_REPO ORDO_FORGE_TOKEN_FILE

# GitLab: the same four variables with ORDO_PROVIDER_ADAPTER=gitlab and a
# project path (nested groups allowed) in ORDO_FORGE_REPO.
# GitHub: nothing to add; ORDO_FORGE_URL only for GitHub Enterprise hosts.
```

Verify without mutating anything:

```bash
( source examples/ordo.config.sh; source lib/ordo_provider_adapter.sh; ordo_provider auth_status )
```

`gh` is required only when `ORDO_PROVIDER_ADAPTER=github`; the REST
adapters need `curl`. `orch_loop.sh`'s preflight checks for the right one.
The commented block at the end of `examples/ordo.config.sh` lists every
adapter knob with its default.

## Turning the scheduler on

The scheduler is off until `ORDO_SCHEDULER_ENABLED=1` is set in the
profile; with it, `orch_loop.sh` runs one `ordo_scheduler.sh <project> tick
--json` per cycle (owner `orch-loop@<host>:<loop pid>`) and audits
`ORCH_LOOP SCHEDULER_TICK OK …` ([scheduler.md → Loop integration](scheduler.md#loop-integration-opt-in)).
Daemon startup still requires the explicit operator confirmation
(`ORCH_DAEMON_CONFIRM` / `--daemon-confirm`); the hook does not touch it.

Recommended progression:

1. Run ticks by hand first: `bash scripts/ordo_scheduler.sh <project> status --json`,
   `… enqueue …`, `… run-once`, and read the journal.
2. Set `ORDO_SCHED_MAX_FANOUT` to the number of worker slots you actually
   want leased at once (default 2) and the budgets you mean
   (`ORDO_SCHED_BUDGET_MAX_*`, `ORDO_SCHED_MAX_RETRIES`, `ORDO_SCHED_RUN_TIMEOUT_SEC`).
3. Enable the hook. Keep `ORDO_SCHED_REQUIRE_READINESS=0` until every run
   carries a readiness verdict, then flip it to `1` (fail-closed picks).

## Turning approvals on

Nothing mutates through the bridge until an operator scopes the gate
**and** names who may approve what:

```bash
export ORCH_EXTERNAL_PR_MUTATIONS="pr_merge"           # exactly the action
export ORDO_APPROVAL_PRINCIPALS="<operator>=pr.merge"   # who may grant it
export ORDO_POLICY_VERSION="policy-2026-09-11"          # optional: pin, so a deliberate policy edit does not void live approvals
```

Without `ORDO_POLICY_VERSION` the version is a hash of the gate
configuration, so *any* change to `ORCH_EXTERNAL_PR_MUTATIONS` or the
principals refuses grants and executions made under the previous
configuration — the safe default while you are still tuning. The full
runbook is [approvals.md → Enabling one scoped action](approvals.md#enabling-one-scoped-action-operator-runbook).

## Rollback

Every layer is additive and switched by environment, so rollback is
"unset and, if wanted, delete":

| To roll back | Do | Effect |
| --- | --- | --- |
| The scheduler hook | unset `ORDO_SCHEDULER_ENABLED` | `orch_loop.sh` behaves exactly as before; queued runs simply stop being picked (they stay in the journal). |
| Live approvals | unset `ORCH_EXTERNAL_PR_MUTATIONS` (and `ORDO_APPROVAL_PRINCIPALS`) | Granted approvals refuse at the gate (exit 3) without being consumed; nothing else changes. |
| A forge switch | set `ORDO_PROVIDER_ADAPTER=github` (or unset) | The github backend issues the pre-migration `gh` invocations. |
| The journal and its derived files | stop the loop, then delete `ordo-journal.sqlite`, `ordo-journal.sqlite-wal`, `ordo-journal.sqlite-shm`, `ordo-runs/`, `ordo-journal-compat.json` under `$(state_dir)` | Legacy state files are untouched, **except** the `assignments.json` rows listed in `ordo-journal-compat.json` (rows the compat export created for journal-dispatched runs): remove those rows if the runs are gone, keep them if the agent is still working. Back the three SQLite files up together first. |
| Mutation receipts | delete `ordo-provider-idempotency.jsonl` | The next retry of a mutation calls the forge again (forge-side idempotency still applies). |
| Traces | `ORDO_TRACE_ENABLED=0`; delete `traces/` | Span files stop being written; the audit log and its OTLP mirror are unaffected. |
| The code | `git checkout c7231cc` (the pre-epic `main`) | Scripts and state files are readable by that revision; the journal is ignored, not migrated back. |

The journal never rewrites an event, so a rollback never loses the history
of what mutated: keep the SQLite files even when you disable everything.

## Versioning

### Contracts

`schema_version` is `"1"` for every kind. Additive changes — a new optional
field, a new kind, a new event type, a *new* edge in a transition table —
stay in v1, and readers ignore unknown fields (`additionalProperties:
true`, enforced by the `compat/` fixtures). A breaking change — a removed
or renamed required field, a **removed** transition edge — creates
`contracts/v2/`, `schema_version: "2"`, new fixtures and a migration note in
[contracts.md](contracts.md); both majors stay readable while any journal
still holds v1 objects. `contracts/v1/emit.sh write-schemas <dir>`
materialises the JSON schemas for external tooling.

### Journal schema

The database carries `PRAGMA user_version` and a `schema_migrations(version,
applied_at)` table. `ordo_journal_init` prints the current version
(`{"db":…,"schema_version":1,"journal_mode":"wal",…}`) and every journal
command migrates lazily, so an upgrade needs no manual step: the first call
of the new library applies the pending migrations inside one transaction.
Projections are a cache (`ordo_journal_rebuild_all` recomputes them from
the events), so a migration that changes the projection shape bumps
`projection_version` and rebuilds; events are never rewritten. Before
upgrading, checkpoint and back up the three files together
([journal.md → WAL, locking and durability](journal.md#wal-locking-and-durability)).
An older library must not be pointed at a newer database: downgrade by
restoring the backup, not by editing the schema.

### CLI

`ordo version` prints the CLI version (`0.1.0`). The command set
(`status plan dispatch watch resume approve cancel recover merge`) and the
output modes are the public shape; a registry row may flip from `routed` to
`native` without changing that shape, and a new command or variant flag is
an additive registry row ([cli.md](cli.md)). The error object and the
exit-code table are shared by every `ordo_*` module and are part of the
contract ([../exit-codes.md](../exit-codes.md#agentic-control-plane-scriptsordosh-and-libordo_sh)).

### Provider adapters

The twenty ops and their normalised shapes are the contract every backend
must satisfy; the conformance suite (`tests/ordo_provider_conformance.bash`)
is parameterised by adapter name, so a new forge or a new op is proven the
same way ([adapters.md → How #815 added an adapter](adapters.md#how-815-added-an-adapter-recipe-for-the-next-forge)).
A new op is additive; changing a normalised field is breaking and must
update the fake fixtures and every migrated call site in the same change.

### Evaluation baseline

`tests/fixtures/eval/demo/baseline.json` is generated, never edited. An
intentional behaviour change (a new event type, a cheaper path) regenerates
it in the same pull request with `bash scripts/ordo_eval.sh baseline`;
`bash scripts/ordo_eval.sh check` fails on any regression
([evaluation.md → Baseline policy](evaluation.md#baseline-policy)).

## Upgrade checklist

Before pulling a new ORDO revision into a deployment:

1. **Stop the loop** (`orch_ctl.sh <project> stop`) or wait for a cycle
   boundary; a scheduler tick in flight holds a lease.
2. **Back up state**: `$(state_dir)` as a whole — the SQLite trio, the
   ledger, `traces/`, and the legacy files — after a checkpoint.
3. **Read the change history** sections of the module pages touched by the
   revision (each `docs/architecture/<module>.md` ends with one) and this
   page's "What changed" table.
4. **Pull, then run the local validators** on an operator host:
   `bash scripts/run_shellcheck.sh`, `bash scripts/run_bats.sh`,
   `bash scripts/run_shell_tests.sh`; and the zero-credential demo,
   `bash scripts/ordo_eval.sh demo`, which must report `0 regression(s)`.
5. **Check the profile**: new knobs appear in `examples/ordo.config.sh`
   (adapters, scheduler, approvals, traces); add the mutation scopes your
   workflows need; confirm `ordo_provider auth_status` on the configured
   forge.
6. **Migrate the journal** by running any read command — e.g.
   `bash scripts/ordo_scheduler.sh <project> status --json` — and read the
   `schema_version` it reports; then `bash scripts/ordo_scheduler.sh
   <project> recover` to rebuild projections and sweep stale leases.
7. **Reproduce the status output**: `ordo status <project>` and
   `orch_ctl.sh <project> status` must print what they printed before the
   upgrade (assignments count included).
8. **Restart the loop** with the daemon confirmation, and watch the first
   `SCHEDULER TICK` / `EXTERNAL_PR_MUTATION` audit lines.
9. If anything above disagrees with expectations, roll back with the table
   above — the knobs first, the code second, the state never.
