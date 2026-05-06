# ORDO

Public product positioning for `RBOKproject/ORDO`.

## One-Liner

ORDO is a shell-first control plane for coordinating any pool of coding agents
across GitHub issues, pull requests, CI, project context, and resilient delivery
workflows.

## What It Is

Modern agent teams do not fail only because an agent writes bad code. They fail
because the surrounding workflow silently loses state: a PR needs a rebase, CI
is queued forever, a branch drifts from the base, two agents collide on the same
files, a parent issue is too large for one worker, or every session re-reads the
same project documentation from scratch.

ORDO turns those hidden failure modes into explicit signals and repeatable
operations.

It is designed to be:

- model-agnostic: works with Claude, Codex, Gemini, Cursor, Copilot, or any
  terminal-driven agent;
- pool-agnostic: supports one agent, a fixed fleet, or multiple mixed fleets;
- GitHub-native: issues, PRs, checks, reviews, branch state, and audit logs are
  first-class inputs;
- shell-first: every capability is inspectable, scriptable, dry-runnable, and
  usable without a hosted SaaS dependency;
- resilience-oriented: every mutating path has gates, audit logs, and fallback
  behavior.

## Product Promise

Give an orchestrator a reliable operating system for multi-agent software
delivery:

- know which agents are free, busy, dirty, blocked, or behind;
- know which issues are ready, blocked by dependencies, already assigned, or too
  broad and need atomization;
- detect PR blockers before they stall delivery silently;
- redispatch failed CI to the owning agent with bounded retries;
- gate merges on real green CI, not on optimism or auto-merge drift;
- persist project understanding cheaply across sessions and refresh it only when
  documentation changes.

## Core Capabilities

### Agent Fleet State

`agent_pool_status.sh` snapshots a heterogeneous agent pool without heavy pane
captures. It reports branch, head, upstream drift, dirty state, PR state, and
signals such as `needs-rebase` or `behind-upstream`.

### Dispatch Planning

`dispatch_plan.sh` ranks open issues and classifies them as `ready`, `blocked`,
`assigned`, or `atomize`. It detects priority labels, dependency references,
parent issues, EPIC/META parent scope, and unchecked checklists that should be
split into child work.

### Project Memory

`project_meta_context.sh` builds a compact project memory from documentation
and root metadata. It stores a persistent Markdown context, a manifest, and a
signature. If docs did not change, the cached context is reused.

### PR Blocker Signals

`pr_block_signals.sh` surfaces states that otherwise hide behind GitHub's
generic `BLOCKED`, `UNSTABLE`, or `UNKNOWN` states:

- `needs-rebase`
- `pr-behind`
- `merge-conflict`
- `review-required`
- `changes-requested`
- `ci-failed`
- `ci-pending`
- `auto-merge-armed`
- `ci-pass`
- `merge-ready`

### Autofix And Autoupgrade

`sixsigma_autoupgrade.sh` observes the whole pool, maps failed PR checks to the
owning agent workdir, and redispatches bounded CI repair work. It never merges
and never bypasses CI.

### Merge Gating

`pr_merge.sh` performs immediate gated squash merges only after CI passes. It
refuses red, pending, cancelled, ambiguous, or conflicting states and disables
pre-existing auto-merge before refusal.

## Who It Is For

ORDO is for teams running more than one coding agent against the same repository
or product surface:

- solo operators coordinating several terminal agents;
- teams experimenting with mixed model pools;
- engineering groups that need auditable GitHub-first agent workflows;
- projects where CI, branch drift, issue dependencies, and documentation context
  are bigger risks than raw code generation.

## What It Is Not

ORDO is not:

- a model provider;
- a replacement for GitHub Actions;
- a hosted agent platform;
- a prompt library only;
- a blind auto-merge bot.

It is the control layer around agent work: observe, plan, dispatch, recover,
autofix, and merge only when the delivery state is actually safe.

## Positioning

| Category | Position |
| --- | --- |
| Product name | ORDO |
| Repository name | `RBOKproject/ORDO` |
| Category | Agent operations control plane |
| Primary interface | Shell scripts + GitHub CLI + tmux metadata |
| Primary buyer/user | Operator or lead engineer coordinating agent pools |
| Core outcome | Fewer silent stalls, safer merges, faster agent reuse |
| Differentiator | Universal model/pool support with explicit blocker signals and persistent project context |

## Naming Notes

`ORDO` is Latin for order, arrangement, rank, or system. It fits the product
because the core job is to turn a noisy pool of agents, issues, branches, and CI
signals into an ordered delivery flow.

The old phrase "Toolkit Poll" described only one capability: smart polling. The
official product name should not reduce the system to polling. Polling is a
module. The product is the control plane that decides what to observe, when to
dispatch, what to block, what to repair, and when a PR is genuinely mergeable.

Use:

- public product name: **ORDO**;
- category phrase: agent operations control plane;
- repository name: `RBOKproject/ORDO`;
- legacy/local directory name: `orchestrator-toolkit`;
- capability name: Smart Poll or `smart_poll_agents.sh`.

Avoid:

- "Toolkit Paul";
- "Toolkit Poll" as the product name;
- model-specific branding;
- implying automatic merge bypass.

## Public Tagline Options

Recommended:

> ORDO: the shell-first control plane for multi-agent software delivery.

Alternatives:

> Make agent pools observable, dispatchable, and safe to merge.

> GitHub-native operations for coding agent fleets.

## Current Maturity

ORDO is currently an operator-grade toolkit. It favors durable shell primitives,
auditability, and fast iteration over packaging polish. The next productization
steps are:

- stable CLI wrapper around the shell scripts;
- generated static documentation site;
- sample demo project with a fake agent fleet;
- packaged installer and upgrade path;
- richer dependency parsing from GitHub issue forms and linked issues;
- dashboard layer over the existing TSV/JSON outputs.
