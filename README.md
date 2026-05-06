# ORDO

Shell-first control plane for multi-agent software delivery.

Repository name: `ORDO`.

Legacy/local install path used by existing operators:
`/root/repos/RBOK-orchestrator/orchestrator-toolkit`.

ORDO coordinates heterogeneous coding-agent pools across GitHub issues, pull
requests, CI, project context, dispatch planning, recovery, autofix, and gated
merge workflows. See [PRODUCT.md](PRODUCT.md) for the public product
positioning.

## Status

Rebuilt **2026-05-05** after the original copy at this same path was deleted (untracked, no git history). The recovery was partial: only `scripts/ci_watcher_daemon.sh` survived intact in process memory (`/proc/<pid>/fd/255`); the rest of the toolkit was reconstructed from:

- The recovered `ci_watcher_daemon.sh` source (variable list + sourcing chain)
- Audit log signatures preserved in `/var/log/orch/{nomos,rbok}.log` (event format, kvargs schema)
- State directory layout in `~/.local/share/orch-state/{nomos,rbok}/`
- The two surviving daemons (PID 4073362 rbok + 4073488 nomos) running via deleted file descriptor
- Direct hand-roll experience from the FSQ + NGW orchestration cycles (18 PRs shipped without the toolkit)

## Persistence policy — never lose this again

This toolkit MUST be preserved across:

1. **Git tracking** — committed to <https://github.com/RBOKproject/ORDO> (this repo). Every change goes through a PR / commit. Never `rm -rf` an untracked sibling here.
2. **Local immutable snapshots** — read-only `.tar.gz` archives at three independent paths:
   - `/root/repos/RBOK-orchestrator/.local-backups/orchestrator-toolkit-<utc-ts>.tar.gz`
   - `/root/.config/orch-toolkit-snapshots/<utc-ts>.tar.gz`
   - `/var/log/orch/orch-toolkit-snapshots/<utc-ts>.tar.gz`
   Each archive is paired with a `.sha256` sidecar. Mode `0444` so `rm -f` requires explicit force.
3. **Live process safety** — the running `ci_watcher_daemon.sh` keeps the original (or current) script open via `fd 255`. Recovery via `cat /proc/<pid>/fd/255` is always possible while at least one daemon is alive.

### Snapshot recipe

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
TK=/root/repos/RBOK-orchestrator/orchestrator-toolkit
SNAP=orchestrator-toolkit-$TS.tar.gz

cd /root/repos/RBOK-orchestrator
tar -czf "/tmp/$SNAP" orchestrator-toolkit/

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

### Recovery from snapshot

```bash
# Pick any of the three paths; verify sha matches first
sha256sum -c /var/log/orch/orch-toolkit-snapshots/<file>.sha256

# Restore in place
mkdir -p /root/repos/RBOK-orchestrator
tar -xzf /var/log/orch/orch-toolkit-snapshots/<file>.tar.gz \
  -C /root/repos/RBOK-orchestrator/

# Or: clone fresh from GitHub
git clone https://github.com/RBOKproject/ORDO.git \
  /root/repos/RBOK-orchestrator/orchestrator-toolkit
```

### Recovery from a running daemon (last resort)

```bash
# Find the daemon
pgrep -af ci_watcher_daemon.sh

# Pull the script from /proc (works while the daemon is alive)
cat /proc/<PID>/fd/255 > /tmp/recovered-ci_watcher_daemon.sh
```

This works ONLY for `ci_watcher_daemon.sh`. The other scripts are not held open by any process — git + snapshots are the only durable backups.

## Layout

```
orchestrator-toolkit/
├── lib/
│   ├── audit_log.sh          # audit() + audit_action() + state_dir() + die()
│   ├── state_persist.sh      # state_file/persist/append/read/trim
│   ├── governance_check.sh   # branch protection / required checks / admin bypass policy
│   └── pr_merge.sh           # approve + squash merge with CI gate enforcement
├── examples/
│   ├── nomos.config.sh       # Nomos project (panes: claude/codex/copilot/cursor/gemini)
│   ├── rbok.config.sh        # RBOK project (panes: rbok-claude/...)
│   ├── realisons-wp.config.sh
│   └── 42t.config.sh
├── scripts/
│   ├── ci_watcher_daemon.sh  # long-running CI poller (recovered from /proc)
│   ├── ci_autofix.sh         # build a failed-CI remediation prompt and re-dispatch
│   ├── audit_state.sh        # snapshot agents + branches + open PRs + backlog
│   ├── check_ci_health.sh    # default-branch CI gate
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

## Testing changes safely

Mutating scripts accept `--dry-run`, and the same mode can be enabled globally
with `ORCH_DRY_RUN=1`.

Covered scripts:

- `scripts/dispatch_ticket.sh`
- `scripts/sixsigma_autoupgrade.sh`
- `scripts/recover.sh`
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

Atomized children carry the parent issue URL, title, objective, and clipped
parent body so child work stays inside parent scope and requirements.

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
