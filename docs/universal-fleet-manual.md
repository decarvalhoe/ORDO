# Universal Fleet Manual

Practical operator guide for running `orchestrator-toolkit` with any number of
named agents.

## 1. What changed

The toolkit no longer needs a single implicit fleet such as:

```bash
AGENTS=(claude codex copilot cursor gemini)
AGENT_SESSION_PREFIX="rbok-"
AGENT_REPO_PREFIX="/root/repos/RBOK-"
```

That legacy form still works, but the recommended contract is now:

```bash
AGENT_PANES=(
  "label|session:window.pane|/absolute/workdir"
)
```

This lets you run:

- 2 agents or 20 agents
- mixed naming (`writer`, `reviewer`, `orch`, `rbok-cursor-2`)
- multiple fleets inside one project
- agent labels that do not match the tmux session name
- per-agent GitHub assignee mapping

## 2. Minimal config

Create a project config in `examples/<project>.config.sh` or outside the repo.

Example:

```bash
#!/usr/bin/env bash

PROJECT="demo"
GH_REPO="RBOKproject/orchestrator-toolkit"
GH_CONFIG_DIR="/root/.config/gh-orchestrator"
DEFAULT_BRANCH="main"

AGENT_PANES=(
  "writer|writer:0.0|/root/repos/demo-writer"
  "reviewer|reviewer:0.0|/root/repos/demo-reviewer"
  "orch|orch:0.0|/root/repos/demo-orch"
)

AGENT_GH_LOGINS=(
  "writer=DemoWriterBot"
  "reviewer=DemoReviewerBot"
)
AGENT_GH_LOGIN_PREFIX="Demo"

SUPERVISOR_REPO="/root/repos/demo-orch"
AGENT_REPO_PREFIX="/root/repos/demo-"
export AGENT_WORKDIR_TEMPLATE="/root/repos/demo-%s"
```

Notes:

- `AGENT_PANES` is the source of truth.
- `AGENT_REPO_PREFIX` and `AGENT_WORKDIR_TEMPLATE` are still required for
  compatibility and tests.
- `AGENT_GH_LOGINS` is optional. If omitted, `AGENT_GH_LOGIN_PREFIX` is used.
- If both are omitted, the fallback remains `RBOKCLI<label>`.

## 3. Accepted `AGENT_PANES` formats

Recommended:

```bash
AGENT_PANES=(
  "writer|writer:0.0|/root/repos/demo-writer"
  "reviewer|review:2.0|/root/repos/demo-reviewer"
)
```

Backward-compatible:

```bash
AGENT_PANES=(
  "writer:0.0|/root/repos/demo-writer"
  "review:2.0|/root/repos/demo-reviewer"
)
```

In the two-field form, the label becomes `basename(workdir)`. Use the
three-field form whenever you want stable logical names.

## 4. Concrete startup checklist

### 4.1 Validate config resolution

```bash
bash scripts/orch_ctl.sh /root/repos/demo-orch/examples/demo.config.sh status
```

Or with an alias if your config is stored under `examples/`:

```bash
bash scripts/orch_ctl.sh demo status
```

Expected result:

- the project resolves
- state dir is printed
- no `config not found` error

### 4.2 Validate fleet resolution

Check each pane exists:

```bash
tmux has-session -t writer
tmux has-session -t reviewer
tmux has-session -t orch
```

Check each workdir exists:

```bash
test -d /root/repos/demo-writer/.git
test -d /root/repos/demo-reviewer/.git
test -d /root/repos/demo-orch/.git
```

### 4.3 Dry-run a dispatch

```bash
cat >/tmp/dispatch-writer-123.md <<'EOF'
# Dispatch test

## Objectif

Tester la resolution universelle.

## Format de sortie attendu

- Rapport final standard

## Tools / sources autorises

- bash

## Boundaries / interdictions

- pas de mutation

## Definition of Done verifiable

- [ ] dry-run observe

## Preuves attendues

- logs dry-run
EOF

bash scripts/dispatch_ticket.sh /root/repos/demo-orch/examples/demo.config.sh writer 123 /tmp/dispatch-writer-123.md --dry-run
```

Expected result:

- `DRY-RUN:` lines
- no `tmux pane not found`
- no `config not found`

### 4.4 Dry-run a recover

```bash
bash scripts/recover.sh /root/repos/demo-orch/examples/demo.config.sh writer --reset-state --dry-run
```

Expected result:

- assignment targeting works with config-path mode
- no mutation if `--dry-run`

### 4.5 Run a fleet snapshot

```bash
bash scripts/audit_state.sh /root/repos/demo-orch/examples/demo.config.sh
```

Expected result:

- every configured label appears once
- branch/workdir lines correspond to the intended clone
- pane activity lines come from the intended pane

## 5. Daily operator commands

### Dispatch one ticket

```bash
bash scripts/dispatch_ticket.sh demo writer 401 /tmp/dispatch-writer-401.md
```

### Recover one agent

```bash
bash scripts/recover.sh demo writer
```

### Clear one stuck assignment

```bash
bash scripts/recover.sh demo writer --reset-state
```

### Poll the whole fleet

```bash
bash scripts/smart_poll_agents.sh demo wave-1
```

### Integrate one subset

```bash
bash scripts/integrate_wave.sh demo wave-1 writer reviewer
```

### Merge one PR

```bash
bash lib/pr_merge.sh demo 88
```

### Merge a wave by branch regex

```bash
bash scripts/pr_merge_wave.sh demo wave-1 '^feat/demo-'
```

### Start the supervisor loop

```bash
bash scripts/orch_loop.sh demo
```

If the supervisor must use another CLI:

```bash
ORCH_CLI_BIN=codex bash scripts/orch_loop.sh demo
```

## 6. Migration from legacy configs

Legacy:

```bash
AGENTS=(claude codex copilot)
AGENT_SESSION_PREFIX="rbok-"
AGENT_WINDOW_INDEX="0"
AGENT_REPO_PREFIX="/root/repos/RBOK-"
export AGENT_WORKDIR_TEMPLATE="/root/repos/RBOK-%s"
```

Universal equivalent:

```bash
AGENT_PANES=(
  "claude|rbok-claude:0.0|/root/repos/RBOK-claude"
  "codex|rbok-codex:0.0|/root/repos/RBOK-codex"
  "copilot|rbok-copilot:0.0|/root/repos/RBOK-copilot"
)

AGENTS=(claude codex copilot)
AGENT_SESSION_PREFIX="rbok-"
AGENT_WINDOW_INDEX="0"
AGENT_REPO_PREFIX="/root/repos/RBOK-"
export AGENT_WORKDIR_TEMPLATE="/root/repos/RBOK-%s"
```

Recommended migration path:

1. Add `AGENT_PANES` first.
2. Keep legacy variables during transition.
3. Validate with `dispatch_ticket --dry-run`, `recover --dry-run`, `audit_state`.
4. Only then rely on non-legacy labels or multi-fleet naming.

## 7. Common failure modes

### `config not found`

Cause:

- alias does not map to a real file
- caller passed a project name that only exists outside `examples/`

Fix:

- pass the full config path
- or place the config under `examples/<name>.config.sh`

### `tmux pane ... not found`

Cause:

- wrong pane target in `AGENT_PANES`
- wrong session/window/pane index
- label/pane confusion

Fix:

- verify the `session:window.pane` tuple with `tmux list-panes -a`
- prefer the explicit `label|pane|workdir` form

### wrong repo used for an agent

Cause:

- two-field `AGENT_PANES` form inferred the label from `basename(workdir)`
- operator dispatched with another logical label

Fix:

- switch to `label|pane|workdir`

### wrong GitHub assignee

Cause:

- no explicit mapping for a non-standard label

Fix:

```bash
AGENT_GH_LOGINS=(
  "reviewer=custom-gh-user"
)
```

### orch loop says `claude` missing

Cause:

- the supervisor CLI binary is not `claude`

Fix:

```bash
ORCH_CLI_BIN=codex bash scripts/orch_loop.sh demo
```

## 8. Verification before production use

Run all three:

```bash
bash scripts/run_shellcheck.sh
bash scripts/run_shell_tests.sh
bash scripts/run_bats.sh
```

Then run the concrete smoke sequence:

```bash
bash scripts/orch_ctl.sh demo status
bash scripts/audit_state.sh demo
bash scripts/dispatch_ticket.sh demo writer 999 /tmp/dispatch-writer-999.md --dry-run
bash scripts/recover.sh demo writer --reset-state --dry-run
bash scripts/integrate_wave.sh demo smoke writer --dry-run
```

If those pass, the fleet contract is wired correctly.
