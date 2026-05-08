# Portfolio POC Plan

This plan validates ORDO portfolio features in two passes: local first, then
the whole fleet. Defaults are read-only so the POC can run during active
orchestration without moving panes or mutating the configured issue provider.

## Scope

Define a POC portfolio with generic product labels:

1. `product-a` - highest-priority product work.
2. `product-b` - toolkit dogfooding or internal product work.
3. `product-c` - website or content work.
4. `product-d` - data or intelligence work.
5. `product-e` - test or platform work.

The user must define `PORTFOLIO_PRIORITIES`. If priorities are missing, ORDO
stops and asks for them explicitly. Operators may pass `--yolo-priority` to
delegate the ordering to ORDO; in that mode the order of `PORTFOLIO_PROJECTS`
becomes the priority source.

## Phase 1: Local POC

Goal: prove the portfolio model and guardrails on local clones without sending
work to agents.

Command:

```bash
bash scripts/portfolio_poc.sh examples/portfolio.config.sh \
  --phase local \
  --switch product-a:planner:product-b:planner
```

Checks:

- portfolio status is sorted by priority;
- start-of-session readiness reports clone state, dirty state, branch drift,
  missing matrix clones, and safe remediation;
- optional repo bind plans require confirmation before any clone can be
  created for custom or discovered repo names;
- `--apply --dry-run` previews clone/fast-forward work without mutation;
- optional soft-switch dry-run exercises context guardrails and unblock task
  escalation.

Promotion gate:

- no unexpected script failures;
- unsafe clones are reported with explicit remediation;
- switch refusal creates an unblock signal in dry-run output when target context
  is not safe.

## Phase 2: Fleet POC

Goal: exercise all read-only orchestration surfaces across every configured
product.

Command:

```bash
bash scripts/portfolio_poc.sh examples/portfolio.config.sh --phase fleet
```

Checks per product:

- `agent_pool_status --json`;
- `pr_block_signals --json`;
- `dispatch_plan --ready-only --json`;
- `dispatch_plan --atomize --dry-run` so child-issue creation is traceable
  through `ORDO-ATOMIZE:<fingerprint>` without mutating the issue provider.
  Dry-run skips
  per-child duplicate lookups by default to stay low-cost; set
  `DISPATCH_PLAN_DRY_RUN_VERIFY_EXISTING=1` for a full duplicate audit;
- `gh_actions_optimize --audit`;
- `sixsigma_autoupgrade --dry-run`.

Promotion gate:

- no hidden provider blockers;
- no red CI merged or bypassed;
- dispatch and autofix remain dry-run;
- GitHub Actions optimization signals are captured for follow-up.

## Phase 3: Safe Remediation

Goal: apply only deterministic local cleanup after operator review.

Command:

```bash
bash scripts/portfolio_poc.sh examples/portfolio.config.sh \
  --phase local \
  --apply-safe
```

Allowed actions:

- clone missing workdirs when repo config has a clone URL;
- fast-forward clean default-branch clones.

Forbidden actions:

- reset, stash, checkout over local work;
- rebase feature branches;
- push to the configured remote;
- move or respawn panes.

## Phase 4: Fleet Execution Candidate

After the first three gates pass, the orchestrator can choose a project using:

1. highest explicit priority;
2. `gate_state` and `rebalance_signal`;
3. ready/free agents;
4. absence of dirty or branch-needs-rebase blockers.

Only then should ORDO dispatch work, move agents, or apply live portfolio
switches.
