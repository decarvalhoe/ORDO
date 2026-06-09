# Usage

This guide walks through the daily ORDO operator loop after installation
([install.md](install.md)) and integration ([integration.md](integration.md))
are complete. It covers audit and status, dispatch planning, orchestrator
handoff, CI and PR monitoring, post-merge cleanup, and controlled operations.

ORDO follows the same operator loop whether one product or several products
share a fleet:

1. Preflight the configured project or portfolio.
2. Inspect fleet and backlog state.
3. Dispatch one bounded task per available agent.
4. Monitor work, PRs, and CI for blocker signals.
5. Remediate or route failures with evidence.
6. Merge only through the configured gated merge path.
7. Clean up matching worktrees after a merge.

This guide is generic. Substitute placeholder names such as `<project>`,
`<portfolio>`, `<agent>`, and issue numbers with values from your deployment.
`RBOKproject` is one possible operator and is never an ORDO default.

## Read-Only vs Mutating Commands

ORDO marks every documented script as either read-only or mutating, and
mutating workflows expose a `--dry-run` preview where supported. The default
posture is preview first, mutate only after operator review.

- **Read-only** scripts inspect provider state, git metadata, tmux metadata,
  and ORDO state. They never edit branches, panes, repositories, or
  per-project state.
- **Mutating** scripts can dispatch keys to a pane, write per-project state,
  push branches, merge a PR, fast-forward a clone, or write a generated
  artifact. They expose `--dry-run` (or the global `ORCH_DRY_RUN=1`) to keep
  the preview non-mutating.
- A handful of scripts are **conditionally mutating**: they observe by default
  but write under `--apply`. The relevant guides flag this explicitly.

If a script does not appear in this guide, treat it as mutating until you
confirm otherwise from `--help` or the script header.

## Quick Reference

| Workflow | Command | Posture |
| --- | --- | --- |
| Fleet snapshot | `bash scripts/agent_pool_status.sh <project-config> --tsv` | read-only |
| Audit snapshot (state file) | `bash scripts/audit_state.sh <project-config>` | read-only |
| Backlog plan | `bash scripts/dispatch_plan.sh <project-config> --ready-only --json` | read-only |
| Plan atomization | `bash scripts/dispatch_plan.sh <project-config> --atomize --dry-run` | dry-run preview |
| PR blocker signals | `bash scripts/pr_block_signals.sh <project-config> --tsv` | read-only |
| Portfolio preflight | `bash scripts/portfolio_session_start.sh <portfolio-config> --json` | read-only |
| Portfolio capacity | `bash scripts/portfolio_status.sh <portfolio-config> --tsv` | read-only |
| Dispatch (dry-run) | `bash scripts/dispatch_ticket.sh <project-config> <agent> <issue> <prompt-file> --dry-run` | dry-run preview |
| Dispatch (live) | `bash scripts/dispatch_ticket.sh <project-config> <agent> <issue> <prompt-file>` | mutating: pane keys, state |
| Smart poll | `bash scripts/smart_poll_agents.sh <project-config> <wave-id>` | read-only |
| CI autofix preview | `bash scripts/sixsigma_autoupgrade.sh <project-config> --dry-run` | dry-run preview |
| CI autofix dispatch | `bash scripts/sixsigma_autoupgrade.sh <project-config>` | mutating: dispatches remediation |
| Gated merge | `bash lib/pr_merge.sh <project-config> <pr>` | mutating: merges if CI passes |
| Post-merge cleanup | `bash scripts/post_merge_cleanup.sh <project-config> <pr> --dry-run` | dry-run preview |
| Post-merge cleanup | `bash scripts/post_merge_cleanup.sh <project-config> <pr>` | mutating: clean worktree only |
| Controlled operation | `bash scripts/controlled_operation.sh <project-config> plan ...` | read-only plan / mutating record |

## 1. Audit and Status

Begin every operator session with read-only state commands. The goal is to
align the operator's mental model with provider, git, and pane state before
any dispatch decision.

### Single project

```bash
export ORDO_PROJECT_PROFILE=/secure/operator/<project>.config.sh

# Read-only: configured fleet, branch, head, drift, dirty state, PR state.
bash scripts/agent_pool_status.sh examples/ordo.config.sh --tsv

# Read-only: snapshot of agents, branches, open PRs, and backlog count.
bash scripts/audit_state.sh examples/ordo.config.sh
```

`audit_state.sh` writes its summary to the configured audit log and to the
project state directory; it does not edit branches or panes.

### Portfolio

```bash
# Read-only: clone existence, default branch, dirty state, drift.
bash scripts/portfolio_session_start.sh <portfolio-config> --json

# Read-only: per-product capacity and rebalance signal.
bash scripts/portfolio_status.sh <portfolio-config> --tsv
```

When `portfolio_session_start.sh` reports unsafe states (dirty worktrees,
behind clones, missing remotes), they become explicit unblock tasks. Do not
run `--apply` until the unblock list is empty or each item has an operator
disposition.

## 2. Dispatch Planning

`dispatch_plan.sh` ranks the issue backlog and labels it with explicit
signals: `ready`, `blocked`, `assigned`, `atomize`, `shipped_suspect`,
`active-backlog`, and `shipped-advisory`. It is read-only.

```bash
# Read-only: dispatch-ready issues only.
bash scripts/dispatch_plan.sh <project-config> --ready-only --json

# Read-only: launch/UAT backlog where open issues remain authoritative even
# when historical shipped evidence exists.
bash scripts/dispatch_plan.sh <project-config> --ready-only --active-backlog --json

# Read-only: full backlog with classification (TSV).
bash scripts/dispatch_plan.sh <project-config> --tsv
```

Atomization is a preview-only path until `--apply` is requested. Always
dry-run first because atomization creates child issues.

```bash
# Dry-run preview: what children would be created.
bash scripts/dispatch_plan.sh <project-config> --atomize --dry-run

# Mutating: actually create child issues. Operator-reviewed only.
bash scripts/dispatch_plan.sh <project-config> --atomize
```

The full classifier contract, dependency parsing, fingerprinting, and
shipped-suspect / active-backlog detection are documented in
[dispatch-planning.md](dispatch-planning.md).

### Dispatching one bounded task

Once a ready issue is selected and a dispatch markdown is prepared, the
dispatch is mutating because it sends keys to the agent pane:

```bash
# Dry-run preview: dispatcher prints target label, pane, workdir.
bash scripts/dispatch_ticket.sh <project-config> <agent> <issue> \
  /tmp/dispatch-<agent>-<issue>.md --dry-run

# Mutating: pastes the prompt into the configured pane.
bash scripts/dispatch_ticket.sh <project-config> <agent> <issue> \
  /tmp/dispatch-<agent>-<issue>.md
```

From Windows operator sessions that SSH into a Linux tmux host, send remote
bash snippets through the CRLF-safe wrapper so supported flags are not polluted
by trailing carriage returns:

```bash
bash scripts/windows_ssh_dispatch.sh \
  --host <ssh-target> \
  --file ./remote-dispatch.sh
```

The equivalent raw SSH pattern is
`ssh <ssh-target> "tr -d '\r' | bash -s" < ./remote-dispatch.sh`. If a remote
log combines `unknown arg: --<flag>` with CRLF evidence such as `\r`, `^M`, or
`$'...\r'`, classify it as `windows-crlf-argv-contamination` before assuming
the ORDO runtime is stale.

Dispatch briefs default to CI-delegated validation. Local validators are an
explicit opt-in:

```bash
# Mutating opt-in: brief includes full local validators.
bash scripts/dispatch_ticket.sh <project-config> <agent> <issue> \
  /tmp/dispatch-<agent>-<issue>.md --require-local-validators
```

Without that flag, prompts containing full local validators are refused so a
multi-agent wave cannot duplicate the CI `validate` job on the shared host.
Rendered briefs make the validation mode explicit with machine-readable fields:
`validation_policy=ci-delegated`, `validation_command=none`, and an
`allowed_focused_checks` list for cheap, changed-file-specific smoke checks.
When local validators are explicitly enabled, `validation_command` contains the
bounded validator command line the agent should run and report.

## 3. Orchestrator Handoff

ORDO supports two orchestration modes: a manual operator loop and a
long-running supervisor session.

### Manual session

Drive the loop interactively from your own terminal. Read-only status,
read-only planning, and operator-reviewed dispatches stay under direct
control.

### Supervisor session (`orch_loop.sh`)

`orch_loop.sh` is a long-running bash supervisor that calls a configured
agent CLI on each cycle. It is mutating because it can dispatch new work,
poll waves, autofix CI, and clean up after merges.

```bash
# Mutating: starts the supervisor loop in the current shell.
ORCH_DAEMON_CONFIRM="$USER" bash scripts/orch_loop.sh <project-config>
```

For operator panes that must remain strictly interactive, start through a
foreground wrapper modeled on `examples/start-ordo-loop.sh`. That wrapper
refuses partial agent selectors and validates the full fleet before entering
the loop. Profiles can set `ORCH_SUPERVISOR_INTERACTIVE_ONLY=1` so watchdogs
emit a recovery plan instead of respawning ORDO in another shell.

Signals control a running loop without restart:

| Signal | Effect |
| --- | --- |
| `SIGTERM` | clean shutdown after the current cycle |
| `SIGUSR1` | pause; skip cycles until resumed |
| `SIGUSR2` | resume, or run a cycle now |

`scripts/orch_ctl.sh` exposes these as named commands (`status`, `pause`,
`resume`, `run-now`, `stop`, `tail`, `reset-cycles`, `reset-state`). `pause`
and `stop` are mutating control barriers: after sending the signal they wait
for acknowledgement before returning. `pause` returns after `orch.paused`
exists or the loop exits; `stop` returns after no matching loop process
remains. The default acknowledgement timeout is 30 seconds; set
`ORCH_CTL_WAIT_TIMEOUT=<seconds>` or `ORCH_CTL_WAIT_INTERVAL=<seconds>` only
when an operator runbook needs a different bound. `reset-state` clears
assignments and is mutating.

`status` also reports the heartbeat watchdog surface:
`supervised`, `restart_attempts`, `last_restart`, and `last_stop_reason`.
Those fields are written by `monitor_heartbeat.sh` when it observes a stopped
project loop with remaining work.

```bash
# Read-only: cycle count, last activity, paused state.
bash scripts/orch_ctl.sh <project-config> status

# Mutating barrier: pause and wait until the supervisor acknowledges it.
bash scripts/orch_ctl.sh <project-config> pause

# Mutating barrier: request clean shutdown and wait until the loop exits.
bash scripts/orch_ctl.sh <project-config> stop

# Read-only: tail the supervisor log.
bash scripts/orch_ctl.sh <project-config> tail

# Mutating: clears stored assignments and CI watcher seen-state.
bash scripts/orch_ctl.sh <project-config> reset-state
```

The full handoff contract for orchestrator agents, including preflight rules,
context isolation, and continuation guards, is documented in
[orchestrator-injected-rules.md](orchestrator-injected-rules.md).

### Orchestrator relaunch watchdog

Use `ensure_alive.sh orch-supervisor` when the operator wants ORDO to recover
the orchestrator pane itself. The watchdog reads the project profile, checks
the configured pane, writes a recovery plan, and relaunches the supervisor when
the pane is missing, stopped, or no longer shows the configured supervisor CLI.

Preview first:

```bash
bash scripts/ensure_alive.sh orch-supervisor <project-config> --once --dry-run
```

Run continuously only from an operator-owned service or terminal:

```bash
bash scripts/ensure_alive.sh orch-supervisor <project-config> --interval 60
```

The profile can set `ORCH_SUPERVISOR_TARGET`,
`ORCH_SUPERVISOR_WORKDIR`, `ORCH_SUPERVISOR_CLI_FLAGS`, and
`ORCH_SUPERVISOR_HEALTH_PATTERN`. Runtime flags stay in the profile so model,
reasoning effort, logging, yolo mode, and search settings survive relaunches.
Each relaunch is written to the project audit log with its target pane,
reason, recovery-plan id, workdir, and command.

`monitor_heartbeat.sh <project-config>` also performs a bounded project-loop
supervision check. When the loop is `NOT RUNNING`, the profile is not paused,
and queued work, assignments, or an explicit `dispatch_required` marker exists,
it invokes the audited `ensure_alive.sh orch-loop <project-config> --once`
path. If the profile is paused or no work remains, it records the no-restart
decision in the project audit log instead of relaunching. If the restart path
refuses or fails, the heartbeat writes an `OPERATOR_AUTHORIZATION_REQUIRED`
audit row and appends a recovery row to `<state_dir>/intervention_queue.md`.

## 4. CI and PR Monitoring

### Read-only signals

```bash
# Read-only: stale, conflict, failed, pending, missing-review states.
bash scripts/pr_block_signals.sh <project-config> --tsv

# Read-only: CI rollup health.
bash scripts/check_ci_health.sh <project-config>

# Read-only: poll a wave and report agent progress.
bash scripts/smart_poll_agents.sh <project-config> <wave-id>
```

### Autofix

`sixsigma_autoupgrade.sh` and `ci_autofix.sh` map failed checks back to the
owning agent branch and dispatch bounded remediation. They never merge.

```bash
# Dry-run preview: which agents would receive an autofix dispatch.
bash scripts/sixsigma_autoupgrade.sh <project-config> --dry-run

# Mutating: dispatches remediation prompts to matching agents.
bash scripts/sixsigma_autoupgrade.sh <project-config>
```

The autofix contract, escalation rules, and backoff behavior are documented
in [sixsigma-autoupgrade.md](sixsigma-autoupgrade.md).

### PR check snapshots

Supervisor and dispatch-planning flows use snapshot polling, not blocking
watch commands. Prefer the structured PR signal snapshot when deciding whether
other work can continue:

```bash
bash scripts/pr_block_signals.sh <project-config> --json
```

Each PR record includes `ci_status` (`pass`, `fail`, `pending`, or `unknown`),
`ci_pending`, and pending check URLs when GitHub exposes them. For one-off
manual inspection, take a single GitHub CLI snapshot with JSON fields such as
`name`, `state`, and `link`; keep any long-running watch in a separate
operator-owned terminal, outside the supervisor flow.

## 5. Gated Merge

`lib/pr_merge.sh` is the only documented merge entrypoint. It enforces the CI
gate and refuses unsafe states by default.

```bash
# Mutating: approve and squash-merge if CI passes the gate.
bash lib/pr_merge.sh <project-config> <pr>
```

Merge doctrine:

- Only merge when the CI rollup status is `pass`.
- If the PR is `BLOCKED` on review only and CI is green, the gated merge can
  fall back to `--admin` using `PR_MERGE_ADMIN_TOKEN`. This path remains
  refused while CI is `IN_PROGRESS` or `FAILURE`.
- Never bypass CI when it has not finished or when it has failed.
- Risk-based no-check policy is opt-in via `PR_MERGE_NO_CHECK_POLICY=1` and
  applies only to docs and workflow scopes that match the configured pattern.

`pr_merge_wave.sh` extends the same gate to a batch of PRs in one call. It
emits the same logs and refusals.

## 6. Post-Merge Cleanup

After a successful gated merge, the matching agent worktree should return to
the configured default branch.

```bash
# Dry-run preview: which workdirs match the merged PR.
bash scripts/post_merge_cleanup.sh <project-config> <pr> --dry-run

# Mutating but non-destructive: only touches clean matching worktrees.
bash scripts/post_merge_cleanup.sh <project-config> <pr>
```

Cleanup contract:

- Clean worktrees on the merged branch are switched back to the default
  branch and fast-forwarded from `origin/<default>`.
- Dispatch assignment state for the cleaned label is cleared.
- Dirty or mismatched worktrees are reported as blockers and left untouched.
- The script never stashes, resets, force-checks-out, rebases, or pushes.

## 7. Controlled Operations

Controlled operations are exceptional, evidence-gated workflows: temporary
admin access, emergency rollouts, manual cache invalidation. They are never
run as normal dispatches.

```bash
# Read-only: produce the evidence plan.
bash scripts/controlled_operation.sh <project-config> plan \
  --type emergency-admin \
  --id emergency-001 \
  --reason "temporary maintenance" \
  --json

# Operator performs the temporary operation through approved paths.

# Read-only: verify the evidence file.
bash scripts/controlled_operation.sh <project-config> verify \
  --evidence-file /tmp/emergency-001-evidence.json --json

# Mutating: append the operation record to per-project state.
bash scripts/controlled_operation.sh <project-config> record \
  --evidence-file /tmp/emergency-001-evidence.json --json
```

`record --dry-run` previews the state write. The full evidence schema, the
list of refused secret-material keys, and the state file location are
documented in [controlled-operations.md](controlled-operations.md).

## Optional: Local Validators

Full local validators are CI-delegated by default. Run them locally only on
an operator-controlled host (not on a shared agent host) and only when the
ORDO toolkit itself is being modified.

```bash
# Read-only on the project profile; modifies nothing in the checkout.
bash scripts/run_shellcheck.sh
bash scripts/run_shell_tests.sh
bash scripts/run_bats.sh
```

If a runner reports validator pressure or exits with status `75`, do not
retry the suite in a loop. Delegate verification to CI and keep local checks
focused on the changed files.

## Stop Conditions

Stop the operator loop and capture evidence when:

- a portfolio preflight reports unsafe states for which there is no operator
  disposition;
- a `dispatch_plan` indicates blocked or atomize-required issues with no path
  to ready work;
- a PR sits in `action_required` (CI red, conflict, requested changes) and the
  configured autofix path cannot remediate it;
- `pr_merge.sh` refuses to merge for any reason other than CI in progress;
- a controlled operation evidence file fails verification.

Each stop condition is an explicit signal. The fail-closed posture is
intentional: ORDO keeps refused states visible so the operator decides what
to do, rather than silently retrying.

## What Comes Next

- Configure host health and resource preflight: see
  [host-health-runbook.md](host-health-runbook.md).
- Capture findings as durable improvement records: see
  [opportunity-registry.md](opportunity-registry.md).
- Review the CSV validation dossier disposition before claiming validated
  use: see [validation/README.md](validation/README.md).
