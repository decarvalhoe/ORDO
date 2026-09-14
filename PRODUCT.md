# ORDO

ORDO is the shell-first control plane for multi-agent software delivery.

It gives an operator a clear, auditable way to coordinate agent fleets across
issue queues, pull requests, checks, reviews, worktrees, portfolios, and release
gates without binding the product to a specific model provider, repository
name, or host layout.

## One-Liner

ORDO makes agent pools observable, dispatchable, recoverable, and safe to merge.

## Product Promise

Agent teams rarely fail only inside the editor. They stall because delivery
state becomes invisible:

- a PR is waiting on checks but no one is watching it;
- a branch drifted from the base and needs a rebase;
- an issue is too broad for one worker;
- two agents are about to touch the same files;
- an idle agent could help another product, but nobody knows the current repo
  is blocked on external gates;
- evidence exists in terminal scrollback but not in a reviewable artifact.

ORDO turns those conditions into explicit signals and repeatable operations.

## What It Is

ORDO is:

- **agent-neutral**: it coordinates terminal-driven agents by configured labels,
  panes, workdirs, branches, and evidence, not by model branding;
- **repo-neutral**: real repository identifiers and host paths live in external
  project profiles;
- **forge-neutral**: issue, PR, review, check and run data come through one
  provider adapter boundary with GitHub (`gh`), Forgejo/Gitea and GitLab
  (REST) backends and a fake for tests; the organisation runs on Forgejo,
  GitHub stays supported but is not privileged;
- **model-neutral and deterministic**: models may plan, classify and report;
  authorisation, persistence, scheduling and irreversible mutations belong to
  code;
- **portfolio-ready**: one physical fleet can serve several product repositories
  while preserving context boundaries;
- **audit-oriented**: mutating workflows leave operator-visible evidence and
  refuse unsafe states by default;
- **validation-aware**: ORDO can scaffold and reconcile CSV-style evidence, but
  it never invents approval, waiver, validated-use, or release decisions.

## Core Capabilities

### Fleet State

`agent_pool_status.sh` snapshots configured agents and reports branch, head,
upstream drift, dirty state, PR state, and readiness signals.

### Dispatch Planning

`dispatch_plan.sh` ranks issues and classifies them as ready, blocked,
assigned, or needing atomization before an operator sends work to a worker.

### Canonical Dispatch

`brief_agents.sh` and `dispatch_ticket.sh` build and send bounded prompts with
objective, allowed sources, boundaries, definition of done, and expected
evidence.

### PR Blocker Detection

`pr_block_signals.sh` surfaces stale branches, conflicts, failed or pending
checks, missing reviews, requested changes, auto-merge drift, CI-pass, and
merge-ready states.

### CI Autofix

`sixsigma_autoupgrade.sh` and `ci_autofix.sh` map failed checks back to the
owning agent branch and dispatch bounded remediation without merging.

### Portfolio Routing

`portfolio_session_start.sh`, `portfolio_status.sh`, and
`agent_product_switch.sh` help one fleet move clean capacity across products
when a repo is waiting on external gates.

### Evidence and Validation Support

`csv_dev_mode.sh` creates a neutral CSV/GAMP/CSA-style dossier scaffold for a
target system. It writes draft templates only when explicitly applied and
records that generated artifacts are not validation approval.

### Unified CLI

`ordo status | plan | dispatch | watch | resume | approve | cancel | recover |
merge` (`scripts/ordo.sh`) is one entry point over the scripts above, with
JSON and human output modes, structured error objects and stable exit codes.
It routes verbatim; direct script invocation keeps working.

### Durable Run Model

Typed contracts (run, task, attempt, lease, event, approval, artifact,
policy decision, blocker), an append-only SQLite event journal with pure
projections and a compatibility export of the legacy state files, and a
scheduler with exclusive leases, heartbeats, retries with backoff, timeouts,
cancellation, crash recovery and per-run budgets (turns, tool calls,
wall-clock, tokens, cost, retries, fan-out). Human waits hold no worker slot.

### Approval-Safe Mutations and Traces

An external mutation is granted once by a human for one run, one action, one
principal, one policy version and one expiry; deterministic code re-authorises
it immediately before execution, executes it with an idempotency key the
provider ledger deduplicates on, and journals the receipt. A model never
grants, denies or executes. Every step leaves OpenTelemetry-compatible spans
with credentials redacted before they are written.

### Trajectory Evaluation

`ordo_eval.sh` replays scripted scenarios in a fake world (fake runtime, fake
forge, pinned clock) and scores completion, policy compliance, evidence
completeness, cost, latency and duplicate-side-effect resistance against a
committed baseline; six failure injections (process crash, network timeout,
provider outage, stale lease, duplicate delivery, approval expiry) prove the
recovery paths. It runs with zero credentials
([docs/architecture/demo.md](docs/architecture/demo.md)).

## What It Is Not

ORDO is not:

- a model provider;
- a hosted agent platform;
- a replacement for CI;
- a prompt library only;
- an auto-merge bypass bot;
- a regulated release approval system by itself.

It is the operating layer around agent work: observe, plan, dispatch, recover,
autofix, verify, and merge only when the configured delivery state is safe.

## Primary Users

ORDO is built for:

- solo operators supervising several terminal agents;
- engineering teams experimenting with mixed agent pools;
- leads who need issue, PR, CI, and branch state to stay coordinated;
- organizations that move one agent fleet across several repositories;
- teams that need evidence-oriented agent workflows before they scale.

## Documentation Entry Points

ORDO documentation is organised so each audience finds the right material in
one click.

- New readers and users start at [README.md](README.md) and this page.
- Operators continue to [docs/universal-fleet-manual.md](docs/universal-fleet-manual.md)
  and the runbooks under `docs/`.
- Integrators and developers use [docs/INDEX.md](docs/INDEX.md) to navigate
  the full set, grouped by category (installation, integration, usage,
  operator runbooks, developer docs, user docs, API/CLI references, generated
  downstream docs, validation evidence).
- Validation reviewers go directly to
  [docs/validation/README.md](docs/validation/README.md) for the controlling
  CSV dossier disposition.

The architecture page that explains how the categories fit together — and
which docs must be updated when ORDO changes — is
[docs/architecture/README.md](docs/architecture/README.md).

## Release Maturity

The current release is an operator-grade toolkit release. It is suitable for
configured development orchestration by users who understand their provider,
terminal, repository, and CI environment.

The current CSV validation dossier is not production released:

- release status: `NOT RELEASED`;
- production-readiness status: `NOT PRODUCTION READY`;
- final validation release was refused;
- `DEV-OQ-001` and `DEV-PQ-001` remain open;
- OQ is not released to PQ;
- PQ evidence is incomplete.

This distinction is deliberate: the software can be released as a toolkit while
the validation dossier truthfully blocks any regulated validated-use claim.

## Positioning

| Field | Position |
| --- | --- |
| Product name | ORDO |
| Category | Agent operations control plane |
| Primary interface | The `ordo` CLI and shell scripts; forge adapters (GitHub CLI, Forgejo/Gitea and GitLab REST); terminal metadata; git state; a local SQLite journal |
| Deployment model | Operator-controlled checkout and project profiles |
| Core outcome | Fewer silent stalls, safer merges, faster agent reuse |
| Differentiator | Universal fleet coordination with explicit blocker signals, dry-run-first operations, and validation-aware evidence controls |

## Naming Notes

`ORDO` is Latin for order, arrangement, rank, or system. The name fits because
the product turns noisy pools of agents, issues, branches, checks, and evidence
into an ordered delivery flow.

Use:

- public product name: **ORDO**;
- category phrase: agent operations control plane;
- capability names such as Smart Poll, Dispatch Planning, Portfolio Routing,
  CSV Development Mode, and Gated Merge.

Avoid:

- model-specific branding;
- live customer or repository names in public product docs;
- implying automatic merge bypass;
- implying validated release when the dossier is blocked.

## Tagline

Recommended:

> ORDO: the shell-first control plane for multi-agent software delivery.

Short alternatives:

> Make agent pools observable, dispatchable, and safe to merge.

> Keep agent work visible from issue to release gate.

## Product Roadmap

Shipped by the agentic control plane epic (#806; see
[docs/architecture/overview.md](docs/architecture/overview.md)):

- the unified `ordo` CLI over the shell scripts (#809);
- the provider abstraction with GitHub, Forgejo/Gitea and GitLab backends
  (#811, #815) and the routing of the existing `gh` call sites through it
  (#816);
- the demo with fake agent panes, a fake forge and no live topology
  (#813, #814; `bash scripts/ordo_eval.sh demo`);
- the documented upgrade and rollback path
  ([docs/architecture/migration.md](docs/architecture/migration.md)).

Still open:

- autonomous blocked-drain decisions in the supervisor loop (#788), which
  the scheduler substrate (#810) now supports but does not implement;
- generated static documentation site;
- packaged installer;
- richer dependency parsing from issue forms and linked issues;
- dashboard layer over TSV/JSON outputs and the journal;
- continued CSV dossier hardening until OQ/PQ can be truthfully completed.
