# Multi-Product Portfolios

ORDO can coordinate one physical agent pool across several product repos. This
is useful when one project is waiting on external gates such as CI, deploy
health checks, reviews, or GitHub merge state, while clean agents could produce
useful work on another product.

The feature is product-neutral. RBOK, NOMOS, PRAXIS, LUMEN, WordPress, and ORDO
itself are just project configs in a portfolio.

## Portfolio Config

Create a config that references independent project configs:

```bash
PORTFOLIO_NAME="company-products"
PORTFOLIO_PROJECTS=(
  "rbok|/path/to/rbok.config.sh"
  "nomos|/path/to/nomos.config.sh"
  "praxis|/path/to/praxis.config.sh"
  "lumen|/path/to/lumen.config.sh"
  "wordpress|/path/to/realisons-wp.config.sh"
)

PORTFOLIO_PRIORITIES=(
  "rbok=100"
  "ordo=90"
  "realisons-wordpress=70"
  "nomos=60"
  "praxis=50"
)

# Optional: enforce that every physical agent has a clone for every product.
PORTFOLIO_ENSURE_AGENT_MATRIX=1
PORTFOLIO_FLEET_AGENTS=(
  "claude|claude:0.0"
  "codex|codex:0.0"
  "copilot|copilot:0.0"
)
```

The right side can be any config accepted by ORDO: alias under `examples/`, a
relative path, or an absolute path.

Priorities are explicit by default. ORDO refuses portfolio status and
readiness commands when `PORTFOLIO_PRIORITIES` is missing or does not cover
every project, because silent project ordering can waste agent capacity on the
wrong product. If the operator wants to delegate the choice, rerun with
`--yolo-priority`; ORDO then derives priorities from the order of
`PORTFOLIO_PROJECTS`.

## Repo Binding Discovery

When product repo names are custom, bind them explicitly before preflight:

```bash
PORTFOLIO_REPO_CANDIDATES=(
  "lumen|RBOKproject/custom-lumen-core|main|/root/repos/lumen-%s"
)
```

If the user does not know the repo list, ORDO can perform a holistic GitHub
search over one or more owners and produce a non-mutating bind plan:

```bash
bash scripts/portfolio_repo_bind_plan.sh examples/portfolio.config.sh \
  --discover-owner RBOKproject \
  --json
```

The bind plan never edits configs, creates clones, moves panes, or dispatches
work. Candidate rows are marked `confirmation_required=true`; the operator must
confirm the project -> repo -> agent-workdir binding by updating the project
config or portfolio candidate list before `portfolio_session_start.sh --apply`
can clone anything.

## Capacity Status

```bash
bash scripts/portfolio_status.sh examples/portfolio.config.sh --tsv
bash scripts/portfolio_status.sh examples/portfolio.config.sh --json
bash scripts/portfolio_status.sh examples/portfolio.config.sh --yolo-priority --tsv
```

For each product, ORDO reports:

- `dispatchable`: no PR gate is blocking the product;
- `external_wait`: open PRs are waiting on checks or external merge gates;
- `merge_ready`: at least one PR is green and mergeable;
- `action_required`: CI failure, rebase, conflict, or requested changes;
- free agents: clean, on default branch, no open PR;
- parkable agents: clean, non-default branch already represented by an open PR;
- unsafe agents: dirty, behind, conflict, or rebase-required state.

When a project is `external_wait` and has free or parkable agents,
`rebalance_signal` becomes `rebalance_recommended`. `auto_rebalance.sh`
turns the conservative subset of those signals into an `AUTO_REBALANCE`
suggestion or applied switch-and-dispatch action, recording the source PR,
target project, target issue, and rollback/release action.

## Session Start Readiness

At the beginning of an orchestration session, audit every configured workdir:

```bash
bash scripts/portfolio_session_start.sh examples/portfolio.config.sh --tsv
bash scripts/portfolio_session_start.sh examples/portfolio.config.sh --json
```

The audit verifies clone existence, git repository shape, default branch,
dirty state, remote default availability, and ahead/behind drift. It fetches
`origin/<default>` by default so drift detection is current; use `--no-fetch`
for a purely local read.

If `PORTFOLIO_FLEET_AGENTS` is defined, the audit also expands a full
agent/project matrix. Any missing clone is reported with `source=portfolio_matrix`,
`remediation_action=clone`, `safe_apply=1`, and a `remediation_command` when
the project config has a confirmed `GH_REPO`, `REPO_URL`, or `GIT_REMOTE_URL`.
If the repo binding is still unknown, ORDO reports `missing_clone_no_remote`
and requires a confirmed bind plan first.

The same matrix is also used as a dispatch target fallback. A project config can
list only its currently assigned panes while `agent_product_switch.sh` and
`dispatch_ticket.sh --portfolio <portfolio-config>` still resolve a physical
matrix agent to that project's workdir. Matrix dispatch is fail-closed: the
project config used for dispatch must match the project entry in the portfolio,
the matrix entry must include a pane, and the resolved target workdir must
already be a git clone.

By default the script only proposes remediation. With `--apply`, it performs
only deterministic safe actions:

- clone a missing workdir when the project config exposes `REPO_URL`,
  `GIT_REMOTE_URL`, or `GH_REPO`;
- fast-forward a clean default-branch clone that is behind
  `origin/<default>`.

It does not stash, reset, checkout over local work, rebase feature branches, or
push. Unsafe states are reported for operator or orchestrator action:
`dirty_worktree`, `local_work_branch`, `branch_needs_rebase`,
`ahead_default`, `diverged_default`, and `not_git_repo`.

```bash
# Preview automatic clone / fast-forward work.
bash scripts/portfolio_session_start.sh examples/portfolio.config.sh --apply --dry-run

# Apply only safe remediations and persist the latest report.
bash scripts/portfolio_session_start.sh examples/portfolio.config.sh --apply --json
```

The latest live report is written to `_portfolio/session_start.json` under the
ORDO state directory.

The same preflight also writes a clean plan before any dispatch should happen:

```text
<ORCH_STATE_BASE>/_portfolio/clean_plan.json
<ORCH_STATE_BASE>/_portfolio/PREFLIGHT_CLEAN_PLAN.md
<ORCH_STATE_BASE>/_portfolio/unblock_tasks.json
<ORCH_STATE_BASE>/_portfolio/ORCH_TASKS.md
```

Safe deterministic blockers, such as a clean default branch that is only behind
`origin/<default>`, are either proposed or applied with `--apply`. Non-safe
states such as `dirty_worktree`, `branch_needs_rebase`, `local_work_branch`,
or missing repo bindings are promoted to explicit orchestrator unblock tasks.
That is the required first-run flow: preflight, clean/apply what is safe,
produce unblock tasks for the rest, then dispatch only from ready clones.

For a complete local or fleet POC, use:

```bash
bash scripts/portfolio_poc.sh examples/portfolio.config.sh --phase local
bash scripts/portfolio_poc.sh examples/portfolio.config.sh --phase fleet
```

The fleet phase also runs `dispatch_plan --atomize --dry-run` per product, so
large-issue decomposition is validated without creating GitHub issues. The
dry-run output must carry the `ORDO-ATOMIZE:<fingerprint>` trace marker used by
real child issues. Dry-run skips per-child duplicate lookups by default to keep
portfolio checks cheap; set `DISPATCH_PLAN_DRY_RUN_VERIFY_EXISTING=1` for a
full duplicate audit.

The detailed rollout plan lives in
[`docs/portfolio-poc-plan.md`](portfolio-poc-plan.md).

## Product Switch Modes

ORDO supports two routing modes.

`hard` mode respawns the physical pane in the target workdir. Use it when the
agent process should become dedicated to the target product.

```bash
bash scripts/agent_product_switch.sh \
  examples/portfolio.config.sh \
  rbok RBOK-claude-2 nomos \
  --target-agent claude \
  --reason rbok-gate-wait \
  --dry-run
```

`soft` mode keeps the pane and current agent process stable, then sends a
workspace contract telling the agent to execute the next work in a target repo.
This matches an orchestrator that supervises one repo while inspecting or
editing another repo.

```bash
bash scripts/agent_product_switch.sh \
  examples/portfolio.config.sh \
  rbok RBOK-claude-2 nomos \
  --target-agent claude \
  --soft \
  --reason rbok-gate-wait \
  --dry-run
```

Hard mode is a physical-pane operation. The source and target project configs
must map the same tmux session pane, either with the same label or with
`--target-agent`. Soft mode can target a different configured workdir without
respawning the pane.

When the target project does not duplicate the physical pane in `AGENT_PANES`,
soft routing can use the portfolio matrix instead:

```bash
bash scripts/agent_product_switch.sh \
  examples/portfolio.config.sh \
  rbok RBOK-claude ordo \
  --target-agent rbok-claude \
  --soft \
  --no-brief \
  --dry-run
```

Direct ticket dispatch can use the same matrix fallback:

```bash
bash scripts/dispatch_ticket.sh \
  examples/ordo.config.sh rbok-claude 93 /tmp/dispatch-rbok-claude-93.md \
  --portfolio examples/portfolio.config.sh \
  --dry-run
```

ORDO refuses to switch by default when:

- the source worktree is dirty;
- the source branch is not the project default branch and has no open PR;
- the PR is behind or conflicting;
- hard mode maps source and target to different physical panes;
- the target workdir is not a git repository.

Use `--force` only for an operator-reviewed exception.

## Unblock Task Escalation

Every unsafe switch refusal is promoted to an orchestrator-visible unblock
task. ORDO writes both machine-readable JSON and a human task list:

```text
<ORCH_STATE_BASE>/_portfolio/unblock_tasks.json
<ORCH_STATE_BASE>/_portfolio/ORCH_TASKS.md
```

Signals include source dirty worktrees, source branches without PRs, PRs that
need rebase or conflict resolution, missing git repos, hard cross-pane mapping
errors, dirty soft targets, and soft targets already on non-default branches.
Each task includes source/target project, agent, pane, workdir, branch, reason,
and a recommended unblock action. IDs are deterministic, so repeated refusals
update the open task instead of creating a new class of blocker.

## Soft Workspace Guardrails

Soft routing has stricter context controls so agents do not confuse repos.

By default, soft mode refuses to run when:

- the target workdir is dirty;
- the target workdir is on a non-default branch;
- the target workdir is not declared in the target project config or resolved
  from the portfolio matrix.

The brief sent to the pane includes a workspace contract path and requires the
agent to verify:

```bash
pwd
git -C <target_workdir> status --short --branch
```

The brief also tells the agent to use `cd <target_workdir>` or
`git -C <target_workdir>` for every command and to avoid mutating the parked
source workdir. If the active repo does not match the contract, the agent must
stop and report `context-mismatch`.

Override options are explicit:

- `--allow-target-branch`: allow a clean target workdir already on a non-default
  branch;
- `--no-strict-context`: disable target branch/dirty checks;
- `--force`: bypass safety refusals after operator review.

## Context Coherence

A successful switch records a JSON entry under the portfolio state directory:

```json
{
  "pane": "claude:0.0",
  "mode": "soft",
  "brief_pane": "claude:0.0",
  "source_project": "rbok",
  "source_branch": "develop",
  "source_head": "abc12345",
  "source_pr": null,
  "target_project": "nomos",
  "target_workdir": "/root/repos/Nomos-claude",
  "target_branch": "main",
  "target_head": "def67890",
  "target_dirty": 0,
  "safe_state": "free",
  "reason": "rbok-gate-wait",
  "strict_context": true,
  "switched_at": "2026-05-06T11:16:46Z"
}
```

The pane receives a short context brief telling the agent which product and repo
it is now operating in, and which source project was parked.

## Operating Pattern

1. Run `portfolio_status.sh`.
2. Merge any `merge_ready` PRs through `pr_merge.sh`.
3. Fix any `action_required` blocker before moving agents.
4. If a product is `external_wait`, run `auto_rebalance.sh` to move parkable
   capacity to another configured product with ready work.
5. Switch them back when the original product has mergeable PRs or new ready
   issues.
