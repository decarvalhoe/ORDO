# ORDO

**ORDO is the shell-first control plane for multi-agent software delivery.**

It coordinates heterogeneous coding-agent fleets across GitHub issues, pull
requests, CI, dispatch planning, project context, portfolio routing, autofix,
recovery, and gated merge workflows. ORDO is model-neutral and repo-neutral:
use it with Claude, Codex, Gemini, Cursor, Copilot, custom terminal agents, or
any mixed pool that can work in a git checkout.

The product goal is simple: keep agent work observable, dispatchable, safe to
merge, and continuously improvable.

See [PRODUCT.md](PRODUCT.md) for the public positioning note.

## Why ORDO

Agent delivery usually stalls outside the editor: a PR needs a rebase, CI is
pending forever, two agents touch the same files, a branch has local work but
no PR, a parent issue is too broad, or a project is blocked while idle agents
could help another product.

ORDO turns those hidden states into explicit signals and repeatable operations:

- know which agents are free, dirty, parked, blocked, behind, or already
  represented by PRs;
- rank issues by priority, assignee, dependency, and atomization need;
- dispatch bounded work with context isolation and evidence requirements;
- detect silent PR blockers such as rebase drift, missing checks, review gates,
  conflicts, pending CI, and green merge-ready states;
- route clean capacity across product portfolios when one repo is waiting on
  external gates;
- capture every operational finding as either an immediate fix or a durable
  ORDO improvement opportunity.

## Core Workflows

| Workflow | Command |
| --- | --- |
| Fleet status | `bash scripts/agent_pool_status.sh <project> --tsv` |
| Session preflight | `bash scripts/portfolio_session_start.sh <portfolio> --json` |
| Issue planning | `bash scripts/dispatch_plan.sh <project> --ready-only --json` |
| Dispatch | `bash scripts/dispatch_ticket.sh <project> <agent> <issue> <prompt.md>` |
| Smart poll | `bash scripts/smart_poll_agents.sh <project> <wave-id>` |
| Integrate wave | `bash scripts/integrate_wave.sh <project>` |
| PR blockers | `bash scripts/pr_block_signals.sh <project> --tsv` |
| CI autofix | `bash scripts/sixsigma_autoupgrade.sh <project> --dry-run` |
| GitHub Actions audit | `bash scripts/gh_actions_optimize.sh <project> --audit` |
| Portfolio routing | `bash scripts/portfolio_status.sh <portfolio> --tsv` |
| Gated merge | `bash lib/pr_merge.sh <project> <pr-number>` |

Every mutating workflow supports dry-run mode where practical, audit logging,
and explicit refusal on unsafe states.

## Quick Start

```bash
git clone https://github.com/RBOKproject/ORDO.git
cd ORDO

# Inspect or adapt an example project config.
cp examples/ordo.config.sh examples/my-project.config.sh

# Validate shell entrypoints and regression tests.
bash scripts/run_shellcheck.sh
bash scripts/run_shell_tests.sh

# Start with read-only signals.
bash scripts/agent_pool_status.sh examples/my-project.config.sh --tsv
bash scripts/dispatch_plan.sh examples/my-project.config.sh --ready-only --json
bash scripts/pr_block_signals.sh examples/my-project.config.sh --tsv
```

Minimal project config:

```bash
PROJECT="my-project"
GH_REPO="owner/repo"
DEFAULT_BRANCH="develop"
GH_CONFIG_DIR="${GH_CONFIG_DIR:-$HOME/.config/gh}"

AGENT_PANES=(
  "writer|writer:0.0|/root/repos/my-project-writer"
  "reviewer|reviewer:0.0|/root/repos/my-project-reviewer"
)

SUPERVISOR_REPO="/root/repos/my-project-orch"
AGENT_REPO_PREFIX="/root/repos/my-project-"
export AGENT_WORKDIR_TEMPLATE="/root/repos/my-project-%s"
```

## Product Principles

- **Model-agnostic**: ORDO coordinates terminal agents by pane, workdir, git
  state, and GitHub signals instead of provider-specific APIs.
- **GitHub-native**: issues, PRs, checks, reviews, merge state, and Actions
  workflows are first-class inputs.
- **Portfolio-ready**: one physical agent pool can serve several product repos
  without losing context or crossing workdirs accidentally.
- **Fail-closed**: no green CI means no merge; ambiguous blockers become
  explicit unblock tasks.
- **Dry-run first**: dangerous or broad operations can be previewed before
  mutation.
- **Continuous improvement by design**: orchestrators and worker prompts carry
  injected rules that turn workflow findings into tracked ORDO opportunities.

## Documentation

- [Product positioning](PRODUCT.md)
- [Universal fleet manual](docs/universal-fleet-manual.md)
- [Multi-product portfolios](docs/multi-product-portfolio.md)
- [Dispatch planning](docs/dispatch-planning.md)
- [Project meta context](docs/project-meta-context.md)
- [6sigma autofix/autoupgrade](docs/sixsigma-autoupgrade.md)
- [GitHub Actions optimization](docs/sixsigma-autoupgrade.md#github-actions-optimization)
- [Orchestrator injected rules](docs/orchestrator-injected-rules.md)
- [Fleet injected rules](docs/fleet-injected-rules.md)
- [CI autofix runbook](docs/ci-autofix.md)
- [Architecture notes](docs/architecture.md)
- [Worktree migration guide](docs/worktree-migration.md)
- [OTEL export guide](docs/otel-export.md)

## Operational Durability

ORDO was rebuilt on **2026-05-05** after an untracked local copy was deleted.
That incident is now treated as a product requirement: the toolkit must remain
git-tracked, auditable, and restorable.

Durability policy:

1. Every change goes through GitHub in `RBOKproject/ORDO`.
2. Local immutable snapshots can be kept as `.tar.gz` archives with `.sha256`
   sidecars under independent backup paths.
3. Long-running daemons should keep enough source and audit context available
   for last-resort recovery, but git remains the source of truth.

Snapshot example:

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
TK=/root/repos/RBOK-orchestrator/orchestrator-toolkit
SNAP=orchestrator-toolkit-$TS.tar.gz

cd "$(dirname "$TK")"
tar -czf "/tmp/$SNAP" "$(basename "$TK")/"

for dest in \
  /root/repos/RBOK-orchestrator/.local-backups \
  /root/.config/orch-toolkit-snapshots \
  /var/log/orch/orch-toolkit-snapshots; do
  mkdir -p "$dest"
  cp "/tmp/$SNAP" "$dest/"
  sha256sum "$dest/$SNAP" > "$dest/$SNAP.sha256"
  chmod 444 "$dest/$SNAP" "$dest/$SNAP.sha256"
done
rm "/tmp/$SNAP"
```

## Layout

```
orchestrator-toolkit/
├── lib/
│   ├── audit_log.sh          # audit() + audit_action() + state_dir() + die()
│   ├── portfolio_config.sh   # multi-product portfolio config resolver
│   ├── state_persist.sh      # state_file/persist/append/read/trim
│   ├── governance_check.sh   # branch protection / required checks / admin bypass policy
│   └── pr_merge.sh           # approve + squash merge with CI gate enforcement
├── examples/
│   ├── nomos.config.sh       # Nomos project (panes: claude/codex/copilot/cursor/gemini)
│   ├── portfolio.config.sh   # multi-product fleet routing example
│   ├── rbok.config.sh        # RBOK project (panes: rbok-claude/...)
│   ├── realisons-wp.config.sh
│   └── 42t.config.sh
├── scripts/
│   ├── ci_watcher_daemon.sh  # long-running CI poller (recovered from /proc)
│   ├── ci_autofix.sh         # build a failed-CI remediation prompt and re-dispatch
│   ├── audit_state.sh        # snapshot agents + branches + open PRs + backlog
│   ├── check_ci_health.sh    # default-branch CI gate
│   ├── portfolio_status.sh   # detect gate-bound products and free capacity
│   ├── continuation_guard.sh # final-stop guard when work remains
│   ├── agent_product_switch.sh # park/switch an agent pane across products
│   ├── smart_poll_agents.sh  # wait until trigger=4+4 or timeout=900s
│   ├── dispatch_plan.sh      # priority/dependency/atomization planning
│   ├── project_meta_context.sh # persistent doc-derived project context
│   ├── dispatch_ticket.sh    # tmux send-keys + paste-buffer to agent pane
│   ├── brief_agents.sh       # render dispatch md from template
│   ├── integrate_wave.sh     # fetch + rebase + sanity gates per agent branch
│   └── cycle.sh              # full pipeline wrapper (CI → dispatch → poll → integrate)
└── templates/
    ├── dispatch-canonical.md.tpl # canonical dispatch template
    ├── ticket_dispatch.md    # legacy dispatch template
    ├── agent_briefing.md     # per-agent identity + protocol
    └── orch_briefing.md      # per-project orchestrator briefing
```

## Architecture docs

- [Tiered CI strategy](docs/architecture.md)
- [CI autofix runbook](docs/ci-autofix.md)
- [6sigma autoupgrade loop](docs/sixsigma-autoupgrade.md)
- [Dispatch planning](docs/dispatch-planning.md)
- [Multi-product portfolios](docs/multi-product-portfolio.md)
- [Project meta context](docs/project-meta-context.md)
- [OTEL export guide](docs/otel-export.md)
- [Universal fleet manual](docs/universal-fleet-manual.md)
- [Worktree migration guide](docs/worktree-migration.md)

## Running tests

The repository ships its own test runners so local verification and GitHub
Actions execute the same commands:

```bash
# Lint tracked shell entrypoints on an LF-sanitized mirror.
bash scripts/run_shellcheck.sh

# Run the shell-based regression suite.
bash scripts/run_shell_tests.sh

# Run the bats suites on an LF-sanitized mirror.
bash scripts/run_bats.sh
```

`run_shellcheck.sh` excludes `SC1090` and `SC1091` because the toolkit sources
project configs and helper libraries through runtime-selected paths. Those
dynamic source statements are intentional and are covered by the shell and bats
tests.

## Bootstrap

```bash
TK=/root/repos/RBOK-orchestrator/orchestrator-toolkit
source $TK/examples/nomos.config.sh   # or rbok / realisons-wp / 42t
```

After sourcing the config, all `lib/*.sh` and `scripts/*.sh` can be invoked.

### Fleet config contract

The universal fleet form is `AGENT_PANES`, with one entry per agent:

```bash
AGENT_PANES=(
  "label|session:window.pane|/absolute/workdir"
  "reviewer|review:2.0|/root/repos/project-reviewer"
)
```

Backward-compatible two-field entries (`session:window.pane|/absolute/workdir`)
still work; in that case the label defaults to `basename(workdir)`.

Optional GitHub assignee mapping:

```bash
AGENT_GH_LOGINS=(
  "reviewer=RBOKCLIcursor"
  "writer|RBOKCLIclaude"
)
AGENT_GH_LOGIN_PREFIX="RBOKCLI"
```

`AGENT_GH_LOGINS` wins per label. `AGENT_GH_LOGIN_PREFIX` is the fallback for
labels that should map mechanically.

## Multi-Product Portfolios

ORDO can coordinate one physical agent pool across multiple product repos. A
portfolio config lists independent project configs; each project remains
model-agnostic and repo-agnostic.

```bash
PORTFOLIO_PROJECTS=(
  "rbok|rbok"
  "nomos|nomos"
  "realisons-wp|realisons-wp"
)

PORTFOLIO_PRIORITIES=(
  "rbok=100"
  "nomos=60"
  "realisons-wp=50"
)

# Optional: verify every physical agent has a per-product clone.
PORTFOLIO_FLEET_AGENTS=(
  "claude|claude:0.0"
  "codex|codex:0.0"
)
```

`portfolio_session_start.sh` audits every configured clone at the beginning of
a session. It detects missing repos, stale default branches, dirty worktrees,
local feature branches, and remote drift. Default mode proposes remediation;
`--apply` only runs safe deterministic fixes: clone a missing workdir or
fast-forward a clean default branch. When `PORTFOLIO_FLEET_AGENTS` is present,
the preflight expands the full agent/project matrix and proposes clone creation
for missing per-product workdirs.

For custom repo names or unknown portfolios, use a strict non-mutating bind
plan before cloning:

```bash
bash scripts/portfolio_repo_bind_plan.sh examples/portfolio.config.sh \
  --candidate "lumen|RBOKproject/custom-lumen-core|main|/root/repos/lumen-%s"

bash scripts/portfolio_repo_bind_plan.sh examples/portfolio.config.sh \
  --discover-owner RBOKproject \
  --json
```

Bind-plan candidates require explicit confirmation in project config before
`portfolio_session_start.sh --apply` can create clones.

Portfolio priority must be user-defined. If `PORTFOLIO_PRIORITIES` is missing
or incomplete, portfolio status/readiness commands refuse and print the
required config shape. Operators can explicitly delegate ordering to ORDO with
`--yolo-priority`; in that mode priorities are derived from portfolio order.

`portfolio_status.sh` then classifies each product as `dispatchable`,
`external_wait`, `merge_ready`, or `action_required`, and reports free or
parkable agents. `agent_product_switch.sh` can move a clean physical pane to
another configured product, or use `--soft` to route the current agent process
to a target workdir without respawning the pane:

```bash
# Check local portfolio readiness and proposed remediation.
bash scripts/portfolio_session_start.sh examples/portfolio.config.sh --tsv

# Run the reproducible local POC and write a markdown report.
bash scripts/portfolio_poc.sh examples/portfolio.config.sh --phase local

# Run read-only checks across every product in the portfolio, including
# dispatch atomization dry-runs with ORDO-ATOMIZE trace markers.
bash scripts/portfolio_poc.sh examples/portfolio.config.sh --phase fleet

# Apply only safe clone / fast-forward remediation.
bash scripts/portfolio_session_start.sh examples/portfolio.config.sh --apply --dry-run

# Carte blanche mode if the user explicitly delegates priority choice.
bash scripts/portfolio_status.sh examples/portfolio.config.sh --yolo-priority --tsv

# Detect a product that is waiting on CI/gates and has reusable capacity.
bash scripts/portfolio_status.sh examples/portfolio.config.sh --tsv

# Refuse a final stop while ready work or merge/remediation work remains.
bash scripts/continuation_guard.sh examples/portfolio.config.sh --tsv

# Preview a switch from one product context to another.
bash scripts/agent_product_switch.sh examples/portfolio.config.sh rbok RBOK-claude-2 nomos --target-agent claude --dry-run

# Preview a soft subrepo/workspace assignment with strict context guardrails.
bash scripts/agent_product_switch.sh examples/portfolio.config.sh rbok RBOK-claude-2 nomos --target-agent claude --soft --dry-run
```

Switches refuse dirty worktrees and non-default branches without open PRs unless
`--force` is supplied. Unsafe refusals create unblock entries in
`_portfolio/unblock_tasks.json` and `_portfolio/ORCH_TASKS.md`, so the
orchestrator can add remediation actions to its task list instead of losing the
signal in stderr. Successful switches record source project, branch, head, PR,
target project, target workdir, mode, and reason.

## Testing changes safely

Mutating scripts accept `--dry-run`, and the same mode can be enabled globally
with `ORCH_DRY_RUN=1`.

Covered scripts:

- `scripts/dispatch_ticket.sh`
- `scripts/sixsigma_autoupgrade.sh`
- `scripts/recover.sh`
- `scripts/portfolio_session_start.sh`
- `lib/pr_merge.sh`
- `scripts/pr_merge_wave.sh`
- `scripts/integrate_wave.sh`
- `scripts/cycle.sh`

In dry-run mode the toolkit validates inputs and keeps read-only checks, but it
does not execute mutating actions such as:

- `tmux send-keys`
- `tmux new-session`
- `gh pr merge`
- state file writes
- local integration rebases/checkouts

Each skipped action is echoed with a `DRY-RUN:` prefix so the calling shell or
CI job can confirm what would have happened.

Examples:

```bash
# One-shot preview with CLI flag
bash scripts/dispatch_ticket.sh rbok claude 1234 /tmp/dispatch-claude-1234.md --dry-run

# Full cycle preview with env toggle
ORCH_DRY_RUN=1 bash scripts/cycle.sh rbok DRY_TEST 9999:claude

# Sanity check: make sure multiple dry-run actions were reached
bash scripts/cycle.sh rbok DRY_TEST 9999:claude --dry-run 2>&1 | grep -c '^DRY-RUN:'
```

## Dispatch Planning

`scripts/dispatch_plan.sh` builds a ranked dispatch plan from open GitHub
issues. It detects priority labels, assignees, dependency blockers from issue
body lines such as `Blocked by: #123`, and large parent issues that need
atomization from `EPIC`, `META`, consolidation wording, `size:xl`,
`needs:atomize`, or unchecked checklist tasks.

```bash
# Full backlog with ready/blocked/assigned/atomize signals.
bash scripts/dispatch_plan.sh rbok --tsv

# Only issues that can be dispatched now.
bash scripts/dispatch_plan.sh rbok --ready-only --json

# Create child issues from parent checklists; dry-run first.
bash scripts/dispatch_plan.sh rbok --atomize --dry-run
```

Atomized children are real GitHub issues. Each child carries the parent issue
URL, title, objective, clipped parent body, a machine-readable
`ORDO-ATOMIZE:<fingerprint>` marker, and a parent comment linking the child
back to the source issue. Re-running atomization skips existing children with
the same fingerprint instead of creating duplicates.

## Persistent Project Meta Context

`scripts/project_meta_context.sh` creates a low-cost project memory from docs
and root metadata. It stores `project_meta_context.md`, a manifest, and a
signature under the project state directory. If the docs have not changed, the
script returns the cached file and logs `DOC_META unchanged`.

```bash
# Build or refresh only if docs changed.
bash scripts/project_meta_context.sh rbok

# Print the cached/generated context for an orchestrator or agent.
bash scripts/project_meta_context.sh rbok --print
```

Dispatch prompts include the context path when generated through
`brief_agents.sh`, so agents can recover global project constraints without
re-reading the full documentation every session.

## 6sigma Autofix / Autoupgrade

`scripts/sixsigma_autoupgrade.sh` is the explicit self-improvement loop for
any configured agent pool. It is model-agnostic and pool-agnostic: it reads
`AGENT_PANES` or legacy `AGENTS`, snapshots branches without pane captures,
maps failed PR checks back to the owning agent workdir, then delegates to
`ci_autofix.sh` under retry caps. It also audits GitHub Actions process
quality so CI latency, duplicate runs, missing permissions, and weak workflow
guardrails become first-class 6sigma signals.

ORDO also injects mandatory operating rules into orchestrator agents via
`templates/orch_briefing.md`; see
[`docs/orchestrator-injected-rules.md`](docs/orchestrator-injected-rules.md).
The key rule is that every operational finding must either be fixed and
validated immediately or captured as a durable ORDO opportunity with impact,
detection signal, safe remediation, validation/POC plan, and priority.
Worker-agent dispatch prompts also receive fleet rules through
`templates/dispatch-canonical.md.tpl`; see
[`docs/fleet-injected-rules.md`](docs/fleet-injected-rules.md). Agents must
verify repo context, stay isolated to the target workdir, report evidence, and
surface `opportunity_findings` for the orchestrator.

```bash
# Observe what would be dispatched, without mutating tmux, git, or GitHub.
bash scripts/sixsigma_autoupgrade.sh rbok --dry-run

# Surface silent blockers plus green states like ci-pass and merge-ready.
bash scripts/pr_block_signals.sh rbok --tsv

# Live mode: failed PRs are redispatched to their owning agents.
bash scripts/sixsigma_autoupgrade.sh rbok

# Audit GitHub Actions process quality directly.
bash scripts/gh_actions_optimize.sh rbok --audit

# Nascent project: scaffold a conservative baseline CI workflow.
bash scripts/gh_actions_optimize.sh my-project --scaffold
```

Key controls:

- `SIXSIGMA_MAX_AUTOFIX_DISPATCHES` caps dispatch volume per run.
- `SIXSIGMA_AGENT_CAN_PUSH=1` lets the autofix prompt authorize commit+push on
  the existing PR branch; set `0` for local-only correction loops.
- `SIXSIGMA_INCLUDE_DRAFTS=1` includes draft PRs; default skips them.
- `CI_AUTOFIX_MAX_RETRIES` remains the per-PR retry cap.
- `SIXSIGMA_RUN_GHA_OPTIMIZER=1` audits GitHub Actions process quality during
  the loop; set `0` to suppress those advisory signals.

`gh_actions_optimize.sh` emits workflow optimization signals such as:

- duplicate `pull_request` + feature/fix `push` runs;
- full pytest/coverage suites keyed to generic `push` instead of default-branch
  pushes;
- missing `actions: read` permissions for workflows that call the Actions API;
- missing `concurrency`, explicit `permissions`, path filters, dependency
  caching, or pytest xdist parallelization.

For new projects, scaffold mode creates `.github/workflows/ci.yml` with
explicit permissions, concurrency, path filters, pip/npm cache support, and
tiered PR/default-branch behavior. It refuses to overwrite an existing workflow
unless `GHA_OPT_OVERWRITE=1` is set.

`scripts/pr_block_signals.sh` is the low-level detector used by the loop. It
reports blockers that can otherwise hide behind a generic GitHub `BLOCKED` or
`UNKNOWN`: draft PRs, merge conflicts, base drift needing rebase, failed or
pending checks, required reviews, requested changes, missing checks, and
pre-existing auto-merge. It also emits positive workflow signals: `ci-pass`
when all visible checks are complete and successful, and `merge-ready` when
the PR is non-draft, mergeable, current, reviewed enough, and green.

Merge safety stays separate: the loop never merges, never enables auto-merge,
and `lib/pr_merge.sh` now uses immediate gated merge only. If CI is red or
pending, merge is refused and any pre-existing auto-merge is disabled before
the refusal is audit-logged.

## Canonical dispatch format

`brief_agents.sh` now renders `templates/dispatch-canonical.md.tpl` by default.
Every prompt dispatched through `dispatch_ticket.sh` must contain these six
sections:

- `## Objectif`
- `## Format de sortie attendu`
- `## Tools / sources autorises`
- `## Boundaries / interdictions`
- `## Definition of Done verifiable`
- `## Preuves attendues`

If any section is missing, `dispatch_ticket.sh` refuses to send the prompt and
prints `missing canonical sections: ...` to stderr. Emergency bypass is
available with `--no-validate`, and that path is always audit-logged.

## Security & Secrets

Secret names, storage expectations, rotation steps, and leak response
procedures are documented in [SECRETS.md](SECRETS.md). Do not commit secret
values to this repository.

## Auto-unblock safety

`lib/tmux_helpers.sh:auto_unblock` only auto-approves known permission prompts
after scanning the visible pane content for destructive command patterns. If a
pattern matches, it refuses to send the approve keys and writes an audit line:

```text
AUTO_UNBLOCK REFUSED pattern=<pattern> agent=<agent> pane=<pane>
```

The hardcoded denylist blocks destructive filesystem, forced-push, GitHub
delete, blanket-permission, `sudo`, and pipe-to-shell prompts. Projects can add
more deny patterns without editing the helper by setting:

```bash
export AUTO_UNBLOCK_BLACKLIST_FILE=/path/to/auto_unblock_blacklist.txt
```

When `TK` points at this toolkit root, `config/auto_unblock_blacklist.txt` is
loaded automatically if present. Invalid denylist regexes fail closed: the
prompt is refused rather than auto-approved.

## Smart poll submitted-branch filtering

`scripts/smart_poll_agents.sh` treats branches with open PRs as submitted
work, not newly committed work. In verbose logs those branches use the `p`
state marker and increment `submitted=...`; they no longer increment
`committed=...`, so a pool with many pending PR checks does not retrigger the
orchestrator loop every minute.

Useful controls:

```bash
export SMART_POLL_IGNORE_OPEN_PR_BRANCHES=1
export SMART_POLL_OPEN_PR_CACHE_SEC=60
export SMART_POLL_OPEN_PR_LIMIT=100
```

Set `SMART_POLL_IGNORE_OPEN_PR_BRANCHES=0` for older behavior where every
feature branch ahead of the default branch is counted as committed work.

## Quota cascade autodetect

`scripts/smart_poll_agents.sh` now scans each agent pane for quota and
rate-limit signatures before evaluating idle/commit progress. When a pattern
matches, it triggers `scripts/cli_swap.sh <project> <agent> auto`, which flips
between Claude and Codex based on the currently detected CLI.

Defaults:

- bundled patterns: `config/quota_patterns.txt`
- cooldown: `300` seconds between auto-swaps for the same agent

Overrides:

```bash
export QUOTA_PATTERNS_FILE=/path/to/custom-patterns.txt
export QUOTA_SWAP_COOLDOWN_SEC=600
```

Each detection is audit-logged, and repeated detections during the cooldown
window are suppressed rather than spamming pane restarts.

## State recovery

State rollback is handled by `scripts/state_rollback.sh`.

Examples:

```bash
# List available state archives for the current project
PROJECT=rbok ORCH_STATE_BASE=/root/.local/share/orch-state \
  bash scripts/state_rollback.sh --list

# Preview a rollback without mutating state
PROJECT=rbok ORCH_STATE_BASE=/root/.local/share/orch-state \
  bash scripts/state_rollback.sh --dry-run 20260505T091500Z

# Restore a verified archive, skipping the confirmation prompt
PROJECT=rbok ORCH_STATE_BASE=/root/.local/share/orch-state \
  bash scripts/state_rollback.sh --yes 20260505T091500Z
```

By default the script looks in `<state-parent>/snapshots`, but you can override
that with `STATE_ROLLBACK_SNAPSHOT_DIR=/path/to/snapshots`. Every restore
verifies the `.sha256` sidecar, moves the current state tree to
`<project>.bak.<epoch>`, and then extracts the chosen archive.

## OTEL export

`lib/audit_log.sh` can mirror each audit event to an OTLP HTTP endpoint.

Behavior:

- opt-in only: current behavior is unchanged until `ORCH_OTEL_ENDPOINT` is set
- best-effort: the text log remains authoritative, and export failures do not
  stop the caller
- async: the HTTP export runs in the background, so normal audit calls are not
  blocked on collector latency

Minimal setup:

```bash
export ORCH_OTEL_ENDPOINT="http://127.0.0.1:4318/v1/traces"
bash scripts/check_ci_health.sh rbok
```

Useful knobs:

- `ORCH_OTEL_ENDPOINT` - OTLP HTTP endpoint, for example
  `http://tempo:4318/v1/traces`
- `ORCH_OTEL_TIMEOUT_SEC` - per-export HTTP timeout, default `0.2`
- `ORCH_OTEL_SERVICE_NAME` - OTEL service name, default
  `ordo`
- `ORCH_OTEL_SCOPE_NAME` - OTEL instrumentation scope, default
  `ordo.audit`
- `ORCH_OTEL_PYTHON_BIN` - optional Python binary override

See [docs/otel-export.md](docs/otel-export.md) for a local Jaeger stack and
dashboard suggestions.

## Worktree isolation

Per-ticket worktree isolation is available behind `USE_WORKTREES=1`.

Behavior when enabled:

- `dispatch_ticket.sh` creates a branch-scoped worktree for the ticket
- the target tmux pane is respawned in that worktree before the prompt is sent
- assignment state records `issue`, `branch`, `workdir`, `repo_root`, and
  `prompt_file`
- `recover.sh` recreates missing panes in the recorded worktree
- `orch_loop.sh` prunes stale, unassigned worktrees on boot

Defaults:

- feature flag off unless `USE_WORKTREES=1`
- worktree root: `${ORCH_WORKTREES_DIR:-$(state_dir)/worktrees}`
- branch naming: `feat/issue-<ticket>`

See [docs/worktree-migration.md](docs/worktree-migration.md) for rollout and
rollback steps.

## Conventions

- **Audit log format**: `AUDIT LOG: <UTC ISO 8601> <event-keyword> <key1=value1> <key2=value2> ...`
- **Audit log destination**: `/var/log/orch/<project>.log`
- **State dir**: `~/.local/share/orch-state/<project>/` (override via `ORCH_STATE_BASE`)
- **Pane targeting**: `${AGENT_SESSION_PREFIX}<agent>` (Nomos prefix is empty, RBOK is `rbok-`)
- **Doctrine**: never `--admin` bypass on CI=`IN_PROGRESS`/`FAILURE`. Admin allowed ONLY on `BLOCKED`/`UNSTABLE` mergeStateStatus + CI=`success`.

## Doctrine cross-reference

The orchestrator's behavior signatures live in `/var/log/orch/<project>.log`. The PR merge policy was hardened during the RBOK-orchestrator AQ cycles after several `--admin` bypass incidents (see `2026-05-03T10:51:19Z AUDIT WARNING: PRs #2720 #2722 #2723 were merged via --admin bypass before checks completed. New rule: always wait for CI.`).
