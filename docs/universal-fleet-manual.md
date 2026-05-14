# Universal Fleet Manual

This manual describes the portable ORDO fleet contract. It avoids live product
names, account names, host paths, and model-provider assumptions; operators keep
those values in external project profiles.

## Fleet Contract

The universal inventory form is `AGENT_PANES`:

```bash
AGENT_PANES=(
  "planner|terminal-a:0.0|/workspace/product-planner"
  "builder|terminal-b:0.0|/workspace/product-builder"
  "reviewer|terminal-c:0.0|/workspace/product-reviewer"
)
```

Each entry is:

```text
label|session:window.pane|absolute-workdir
```

The label is the stable ORDO identity. It does not need to match the terminal
session, model provider, account, or repository name.

Backward-compatible two-field entries still work:

```bash
AGENT_PANES=(
  "terminal-a:0.0|/workspace/product-planner"
)
```

In that form, ORDO derives the label from `basename(workdir)`. Prefer the
three-field form for long-lived fleets.

## Minimal External Profile

`examples/ordo.config.sh` intentionally contains no live topology. Point it at
an operator-owned profile:

```bash
export ORDO_PROJECT_PROFILE=/secure/operator/project.config.sh
bash scripts/orch_ctl.sh examples/ordo.config.sh status
```

The external profile should define:

```bash
PROJECT="target-system"
DEFAULT_BRANCH="main"

# Provider adapter settings. For GitHub-backed projects, the current shell
# adapter uses GH_REPO and GH_CONFIG_DIR.
GH_REPO="owner/repository"
GH_CONFIG_DIR="/operator/credential/profile"

AGENT_PANES=(
  "planner|terminal-a:0.0|/workspace/target-planner"
  "builder|terminal-b:0.0|/workspace/target-builder"
)

AGENT_GH_LOGINS=(
  "planner=planner-bot"
  "builder=builder-bot"
)

PROJECT_REPO_ROOT="/workspace/target-supervisor"
SUPERVISOR_REPO="$PROJECT_REPO_ROOT"
ORCH_CLI_BIN="agent-cli"
AGENT_REPO_PREFIX="/workspace/target-"
export AGENT_WORKDIR_TEMPLATE="/workspace/target-%s"
AUDIT_LOG_FILE="/var/log/ordo/${PROJECT}.log"
```

Profile rules:

- keep secrets out of committed files;
- use generic labels unless the profile is private to the deployment;
- keep pane targets explicit;
- if your operating policy requires pane-zero-only fleets, set every target to
  `:0.0`;
- keep legacy `AGENTS`, `AGENT_SESSION_PREFIX`, and
  `AGENT_WORKDIR_TEMPLATE` only for compatibility with older scripts or tests.

## Assignee Mapping

For provider-backed issue assignment, map ORDO labels to provider accounts in
the external profile:

```bash
AGENT_GH_LOGINS=(
  "planner=planner-bot"
  "builder=builder-bot"
)

AGENT_GH_LABEL_ALIASES=(
  "portfolio-a-builder=builder"
)
```

`AGENT_GH_LOGINS` wins for exact labels. `AGENT_GH_LABEL_ALIASES` lets a
portfolio or matrix label resolve to a canonical worker label before lookup.
When no mapping exists, ORDO falls back to the agent label or the configured
login template.

## Startup Checklist

Run this sequence before dispatching real work:

```bash
bash scripts/orch_ctl.sh <project-config> status
bash scripts/agent_pool_status.sh <project-config> --tsv
bash scripts/dispatch_plan.sh <project-config> --ready-only --json
bash scripts/pr_block_signals.sh <project-config> --tsv
```

Then smoke-test a non-mutating dispatch:

```bash
cat >/tmp/dispatch-builder-smoke.md <<'EOF'
# Dispatch smoke

## Objectif

Verify ORDO resolves the configured fleet target.

## Format de sortie attendu

- Short dry-run report.

## Tools / sources autorises

- Shell read-only commands.

## Boundaries / interdictions

- No mutation.

## Definition of Done verifiable

- [ ] Dry-run output names the intended label and workdir.

## Preuves attendues

- Dry-run output.
EOF

bash scripts/dispatch_ticket.sh <project-config> builder 100 \
  /tmp/dispatch-builder-smoke.md --dry-run
```

Expected result:

- the project config resolves;
- every configured label appears at most once;
- the target pane exists when tmux is available;
- the target workdir is a git checkout;
- dry-run output shows the intended dispatch without sending keys.

## Daily Commands

| Task | Command |
| --- | --- |
| Fleet snapshot | `bash scripts/agent_pool_status.sh <project-config> --tsv` |
| Backlog plan | `bash scripts/dispatch_plan.sh <project-config> --ready-only --json` |
| Dispatch one ticket | `bash scripts/dispatch_ticket.sh <project-config> builder 401 /tmp/dispatch-builder-401.md` |
| Recover one agent | `bash scripts/recover.sh <project-config> builder` |
| Clear one stuck assignment | `bash scripts/recover.sh <project-config> builder --reset-state` |
| Preempt one assignment | `bash scripts/preempt_assignment.sh <project-config> builder --reason "reprioritize" --preserve` |
| Poll a wave | `bash scripts/smart_poll_agents.sh <project-config> wave-1` |
| Integrate a subset | `bash scripts/integrate_wave.sh <project-config> wave-1 builder reviewer` |
| Merge one PR | `bash lib/pr_merge.sh <project-config> 88` |
| Start supervisor loop | `bash scripts/orch_loop.sh <project-config>` |

Use `--dry-run` where supported before live dispatch, recovery, merge, switch,
or generated-file operations.

## Supervisor CLI

ORDO core is not tied to a specific supervisor CLI. Configure the supervisor
binary externally:

```bash
ORCH_CLI_BIN=agent-cli bash scripts/orch_loop.sh <project-config>
```

New profiles should set `ORCH_CLI_BIN` explicitly. For legacy operator
profiles, `orch_loop.sh` also accepts `ORCH_AGENT_CLI` as the supervisor CLI
fallback when neither `ORCH_CLI_BIN` nor `SUPERVISOR_CLI_BIN` is set, so
existing `ordo` shorthand profiles remain loop-capable after clean starts.

If the supervisor binary is missing, `orch_loop.sh` fails preflight and points
operators to manual-session guidance instead of silently starting a broken
loop.

When `ORCH_CLI_BIN` resolves to `codex`, the loop starts the supervisor with
`codex exec --ephemeral -C <workdir>` instead of the interactive TUI. This keeps
live cycles usable from non-interactive operator contexts and avoids persistent
session database contention. The `<workdir>` defaults to the toolkit checkout
so cycle prompts that reference `$TK/scripts/...` run from the ORDO toolkit even
when `PROJECT_REPO_ROOT` points to an application checkout. Set
`ORCH_SUPERVISOR_WORKDIR` explicitly when a profile needs a different supervisor
working directory. Legacy `SUPERVISOR_REPO` and `PROJECT_REPO_ROOT` values are
only fallbacks if the toolkit checkout is unavailable. ORDO refuses that
resolved workdir when it is also one of the configured agent workdirs from
`AGENT_PANES` or the derived agent inventory; use a dedicated control-plane
checkout for the supervisor.

Each supervisor cycle is bounded by `ORCH_SUPERVISOR_CYCLE_TIMEOUT_SEC`
(default: `900`). On timeout, `orch_loop.sh` sends a follow-up kill after
`ORCH_SUPERVISOR_CYCLE_KILL_AFTER_SEC` seconds (default: `5`) and audits
`ORCH_LOOP_SUPERVISOR_TIMEOUT` before continuing the loop.

## Orchestrator Relaunch Watchdog

`ensure_alive.sh orch-supervisor` keeps the interactive orchestrator pane
available. It checks the configured pane, treats missing, stopped, or
non-supervisor panes as unhealthy, writes a recovery plan under the project
state directory, and relaunches the supervisor command from the supervisor
workdir.

Add the target and runtime flags to the external profile:

```bash
ORCH_SUPERVISOR_TARGET="terminal-orchestrator:0.0"
ORCH_SUPERVISOR_WORKDIR="/path/to/control-plane-checkout"
ORCH_SUPERVISOR_CLI_FLAGS="--model gpt-5.5 --reasoning-effort xhigh --debug --yolo --search"
```

Then verify the action in dry-run mode:

```bash
bash scripts/ensure_alive.sh orch-supervisor <project-config> --once --dry-run
```

Live mode is usually run by an operator-owned service manager:

```bash
bash scripts/ensure_alive.sh orch-supervisor <project-config> --interval 60
```

When `ORCH_SUPERVISOR_TARGET` is unset, the target defaults to
`${AGENT_SESSION_PREFIX}orchestrator:0.0`, or `${PROJECT}-orchestrator:0.0`.
The health probe looks for the configured supervisor CLI name in the pane
capture; override `ORCH_SUPERVISOR_HEALTH_PATTERN` if the displayed process
name differs. The audit log records the timestamp, target pane, relaunch
reason, recovery-plan id, workdir, and command.

## Migration From Legacy Profiles

Legacy profiles often derive panes and workdirs from a prefix:

```bash
AGENTS=(planner builder reviewer)
AGENT_SESSION_PREFIX="product-"
AGENT_WINDOW_INDEX="0"
AGENT_REPO_PREFIX="/workspace/product-"
export AGENT_WORKDIR_TEMPLATE="/workspace/product-%s"
```

Universal equivalent:

```bash
AGENT_PANES=(
  "planner|product-planner:0.0|/workspace/product-planner"
  "builder|product-builder:0.0|/workspace/product-builder"
  "reviewer|product-reviewer:0.0|/workspace/product-reviewer"
)
```

Migration path:

1. Add `AGENT_PANES`.
2. Keep legacy variables during transition.
3. Validate `dispatch_ticket --dry-run`, `recover --dry-run`, and
   `agent_pool_status`.
4. Remove deployment-specific assumptions from committed examples.

## Common Failure Modes

### `config not found`

Cause:

- the alias does not map to a file;
- the operator passed a profile name that exists only outside `examples/`.

Fix:

- pass the full config path;
- or point `ORDO_PROJECT_PROFILE` at the external profile and use
  `examples/ordo.config.sh`.

### `tmux pane ... not found`

Cause:

- wrong `session:window.pane`;
- wrong window or pane index;
- label and pane target were confused.

Fix:

```bash
tmux list-panes -a
```

Then update `AGENT_PANES` in the external profile.

### Wrong Workdir

Cause:

- two-field `AGENT_PANES` inferred a label from the workdir basename;
- the operator dispatched to a different logical label.

Fix:

- switch to explicit `label|pane|workdir` entries.

### Cross-project workdir refused (`workdir_origin_mismatch`)

Cause:

- the fleet slot's `AGENT_WORKDIR` is a clone of project X (e.g.
  `RBOKproject/ORDO`) but the dispatch targets project Y (e.g.
  `RBOKproject/RBOK`). `dispatch_ticket.sh` refuses with audit line
  `DISPATCH REFUSED reason=workdir_origin_mismatch agent=... ticket=...
  workdir=... origin=... canonical=...` and exits `4`.

Fix:

- provision a clone of the canonical URL at a project-specific path —
  the recommended layout is
  `/root/repos/fleet-worktrees/<project>/<agent>` — and re-point
  `AGENT_WORKDIR_TEMPLATE` (or the per-agent `AGENT_PANES` entry) for
  the affected profile;
- or dispatch from a slot whose `git remote get-url origin` already
  matches the project's canonical clone URL.

Roll-out: set `ORCH_DISPATCH_WORKDIR_ORIGIN_GUARD=warn` to audit
affected slots without refusing dispatches; flip to `enforce` (the
default) once every slot is provisioned. Set the variable to `off` only
for legacy callers / fixtures that intentionally test the cross-project
path. The `enforce`-mode exit code is configurable via
`ORCH_DISPATCH_WORKDIR_ORIGIN_MISMATCH_EXIT_CODE` (default `4`, shared
with the existing portfolio-matrix `duplicate_clone_remote_mismatch`
refusal so dashboards group both under one operator runbook).

### Wrong Provider Assignee

Cause:

- no explicit account mapping for a non-standard label.

Fix:

```bash
AGENT_GH_LOGINS=(
  "builder=builder-bot"
)
```

### Supervisor CLI Missing

Cause:

- `ORCH_CLI_BIN` points to a binary that is not installed on the host;
- no supervisor CLI is configured through `ORCH_CLI_BIN`,
  `SUPERVISOR_CLI_BIN`, or the legacy `ORCH_AGENT_CLI` fallback.

Fix:

```bash
ORCH_CLI_BIN=agent-cli bash scripts/orch_loop.sh <project-config>
```

## Verification Before Production Use

Run full repository validators only on an operator-controlled host or in CI:

```bash
bash scripts/run_shellcheck.sh
bash scripts/run_shell_tests.sh
bash scripts/run_bats.sh
```

If a runner reports validator degradation or exits `75`, the host is under
process pressure. Do not retry heavy suites in a loop; delegate full validation
to CI and keep local checks focused.

Before first live dispatch, run:

```bash
bash scripts/orch_ctl.sh <project-config> status
bash scripts/agent_pool_status.sh <project-config> --tsv
bash scripts/dispatch_ticket.sh <project-config> builder 999 \
  /tmp/dispatch-builder-smoke.md --dry-run
bash scripts/recover.sh <project-config> builder --reset-state --dry-run
bash scripts/integrate_wave.sh <project-config> smoke builder --dry-run
```

If these pass, the fleet contract is wired correctly. They do not validate a
regulated deployment or approve production use.
