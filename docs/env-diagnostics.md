# Environment Control & Deployment Diagnostics

`scripts/env_diagnostics.sh` is the operator preflight that aggregates
ORDO's read-only environment probes into one command. It is designed
for the operator on the orchestrator host, for external agents being
onboarded into a fleet, and for automated deployment pipelines that
need a single command to confirm the host can safely host a wave.

This guidance complements the existing host/process/runbook docs:

- `docs/host-health-runbook.md` — host log/session storm gates.
- `docs/orchestrator-injected-rules.md` — preflight before dispatch.
- `docs/multi-product-portfolio.md` — portfolio status & priorities.
- `docs/dispatch-planning.md` — pre-dispatch planner & matrix gate.

## Read-only by default

Every helper exposed by `lib/env_diagnostics.sh` and every subcommand of
`scripts/env_diagnostics.sh` is **read-only**. They list, probe, count,
and emit `KEY=value` lines; they never start, stop, send keys, kill, or
mutate state. When a mutating action is needed, use the dedicated ORDO
script and document it explicitly:

| Need | Use this | Mutating? |
| --- | --- | --- |
| Inspect tmux/pane/load/disk/Docker/GitHub/issues/PRs/dirty clones | `scripts/env_diagnostics.sh` | no |
| Refuse dispatch on host pressure | `lib/host_load_gate.sh` (sourced by dispatch_ticket) | no (refusal only) |
| Kill runaway processes | `scripts/process_safety_preflight.sh --kill` | yes (opt-in flag) |
| Create tmux topology | `scripts/portfolio_session_start.sh` | yes |
| Bootstrap a clone | `scripts/repository_bootstrap.sh` | yes |
| Refresh GitHub auth | `gh auth login` / `gh auth refresh` | yes |
| Authorize urgent direct dispatch | `scripts/dispatch_matrix.sh` + `--require-matrix-gate` | gates only |

`scripts/env_diagnostics.sh` does not have an `--apply` or `--mutate`
flag. Adding one in the future would require a separate, named script
so the read-only promise here stays intact.

## Preflight diagnostics

`bash scripts/env_diagnostics.sh preflight [--text|--json]` runs every
probe end-to-end. Each block emits one or more `KEY=value` lines:

| Probe | Keys emitted | Source |
| --- | --- | --- |
| **tmux shape** | `tmux.status`, `tmux.session.<n>.name`, `tmux.session.<n>.windows`, `tmux.session.<n>.attached`, `tmux.session.<n>.live_target`, `tmux.session.<n>.pane_current_path`, `tmux.session.count` | `tmux list-sessions` + `tmux display-message -t <name>:0.0` |
| **pane commands** | `pane.<target>.command`, `pane.<target>.path`, `pane.<target>.status` | `tmux display-message` |
| **server load** | `load.uptime`, `load.averages` | `uptime` |
| **memory** | `memory.total_mb`, `memory.available_mb` | `/proc/meminfo` |
| **disk** | `disk.<n>.path`, `disk.<n>.mount`, `disk.<n>.size_mb`, `disk.<n>.used_mb`, `disk.<n>.avail_mb`, `disk.<n>.used_pct`, `disk.count` | `df -P -k` |
| **Docker health** | `docker.status`, `docker.server_version`, `docker.running_containers` | `docker info`, `docker ps` |
| **API health** | `api.url`, `api.http_code`, `api.status` | bounded `curl` HEAD/GET |
| **GitHub auth** | `gh.status`, `gh.login`, `gh.host` | `gh auth status` |
| **Open issues/PRs** | `gh.repo`, `gh.default_branch`, `gh.issues_open`, `gh.prs_open_default_base`, `gh.prs_open_non_default_base` | `gh issue list`, `gh pr list`, `gh repo view` |
| **Dirty clones** | `dirty.root`, `dirty.<n>.workdir`, `dirty.<n>.branch`, `dirty.<n>.porcelain_lines`, `dirty.count` | `find … -name .git -prune` + `git status --porcelain` |

The probes that need an external arg (`--api`, `--repo`, `--clones-root`)
emit `KEY=not-requested` when omitted so the JSON shape stays stable.

```bash
# Full preflight against the operator's host
bash scripts/env_diagnostics.sh preflight \
  --repo RBOKproject/ORDO \
  --api https://api.github.com \
  --clones-root /root/rbokproject-fleet-20260508-clean/repos \
  --json

# Quick tmux shape only (cheap, no GH calls)
bash scripts/env_diagnostics.sh tmux

# Dirty-clones sweep with depth bound (default ORCH_ENV_DIAG_DIRTY_MAX_DEPTH=3)
ORCH_ENV_DIAG_DIRTY_MAX_DEPTH=4 \
  bash scripts/env_diagnostics.sh clones /root/rbokproject-fleet-20260508-clean/repos
```

## Audit artifact naming conventions

ORDO writes evidence into a small set of artifact kinds. The
`scripts/env_diagnostics.sh audit-name <kind> <id>` helper resolves the
canonical path for each kind so operators and dashboards do not have
to memorize the layout:

| Kind | Subdir | Extension | Typical content |
| --- | --- | --- | --- |
| `snapshot` | `snapshots/` | `.tsv` | Point-in-time capture of fleet/portfolio/agent state. One file per snapshot id; second column is the snapshot id when relevant. |
| `ledger` | `ledgers/` | `.jsonl` | Append-only event log (findings, opportunities, audit trails). One JSON object per line; rotation handled separately. |
| `matrix` | `matrices/` | `.tsv` | Tabular gates and pre-dispatch authorizations (e.g. `dispatch_matrix.tsv`, hot-spot maps, capability matrices). |
| `monitor` | `monitors/` | `.log` | Bounded stdout/stderr captures from background watchers (CI watchdog, smart-poll, recovery probes). |

Resolution rules:

1. If `ORCH_ENV_DIAG_AUDIT_BASE` is set, the artifact path is
   `${ORCH_ENV_DIAG_AUDIT_BASE}/<subdir>/<id>.<ext>`.
2. Otherwise, if a project config has been sourced and `state_dir` is
   defined, the per-project state dir is used. This keeps portfolios
   isolated automatically.
3. Otherwise, `${TMPDIR:-/tmp}/ordo-audit/<subdir>/<id>.<ext>` is used.

```bash
$ ORCH_ENV_DIAG_AUDIT_BASE=/root/.local/share/orch-state/myproj \
    bash scripts/env_diagnostics.sh audit-name snapshot fleet-20260508T0850Z
/root/.local/share/orch-state/myproj/snapshots/fleet-20260508T0850Z.tsv

$ bash scripts/env_diagnostics.sh audit-name ledger findings
/tmp/ordo-audit/ledgers/findings.jsonl
```

## Drift tips

These are the recurring fleet-prep findings that have caused real
incidents on the orchestrator host. The diagnostics tooling exists to
make each of them visible without an operator needing to know which
command to type.

### Stale state

- ORDO portfolio state can bleed across portfolios when
  `ORCH_STATE_BASE` and `ORCH_LOG_DIR` default to a shared directory.
  Always set them explicitly per portfolio before running any dispatch
  or status command.
- Trust live target probing over stale window counts: a tmux session
  may report "1 windows" while the live `session:0.0` pane is the only
  one actually usable. The tmux shape probe re-checks `session:0.0`
  with `tmux display-message -t <name>:0.0` — use the same approach in
  any custom script.

### False scrollback signals

- A long pane scrollback can contain matches for runaway-process
  patterns even when the live process is gone. Treat scrollback hits
  as **suggestions**, not refusals; cross-check against
  `scripts/process_safety_preflight.sh` (which inspects live process
  state via `ps`, not scrollback) before acting.
- When scrollback must be cleared, capture it first
  (`tmux capture-pane -p -t <target> > snapshots/<id>.log`) and only
  then `tmux clear-history`. The captured file becomes a `monitor`
  artifact (see naming above).

### Hidden dirty worktrees

- Old workdirs may carry uncommitted fixes that look "abandoned" but
  are not. Onboarding and recovery flows MUST run
  `bash scripts/env_diagnostics.sh clones <root>` before any
  destructive cleanup so dirty checkouts are surfaced.
- Dirty checkouts on a non-default branch are doubly invisible: a
  generic "any branch is fine" probe misses them. The diagnostics
  tooling reports the branch alongside the porcelain count so the
  operator can decide whether to commit, stash, or audit-and-clean.

### Missing non-default-base PRs

- `gh pr list` defaults to PRs targeting the repo's default branch.
  Cross-repo migrations and release-train flows use feature branches
  that target a non-default base; portfolio status that only counts
  default-base PRs misses these and incorrectly classifies an agent
  as "free".
- The `gh-repo` probe reports `gh.prs_open_non_default_base` separately
  so dashboards and gates can refuse to mark an agent free unless both
  counts agree. Treat a non-zero non-default count as a signal to read
  the PRs explicitly with
  `gh pr list --repo <r> --state open --json number,baseRefName,headRefName`.

## Deployment & operator productivity tips

These tips optimize end-to-end orchestration without bypassing the
authority model. The orchestrator stays the only actor that dispatches
work; operators inspect with `env_diagnostics`, then act through the
dedicated mutating scripts when needed.

### Before each session

1. `bash scripts/env_diagnostics.sh preflight --repo <r> --clones-root <root>`
   — one-shot view of host pressure, tmux shape, GitHub auth, dirty
   clones, non-default-base PRs.
2. `bash scripts/process_safety_preflight.sh` — confirms no runaway
   scans/validators are pinning cores from a previous session.
3. `bash scripts/portfolio_status.sh <portfolio-config> --tsv` — agent
   readiness across the portfolio.

### Before each dispatch

1. Re-run `env_diagnostics.sh tmux` if the session has been idle long
   enough that the live target may have drifted.
2. `bash scripts/dispatch_matrix.sh <project-config> gate <issue>` for
   any direct dispatch (matrix gate; opt-in per `dispatch-planning.md`).
3. `bash scripts/dispatch_ticket.sh ...` only after the gate passes.

### After each merge / before each push

1. `env_diagnostics.sh clones <root>` to confirm no agent has
   uncommitted work on the merged branch.
2. `env_diagnostics.sh gh-repo <r>` to confirm the PR landed and no
   non-default-base PRs were left behind.
3. `bash scripts/post_merge_cleanup.sh <project-config>` to retire the
   feature branch (this is the mutating action).

### Authority model — non-negotiable

- `env_diagnostics.sh` cannot dispatch, merge, push, kill, or send
  keys. It is read-only by construction.
- A local agent reading `env_diagnostics.sh` output cannot promote
  itself to dispatcher. Direct dispatch still requires the matrix
  gate, and normal dispatch still flows through the remote
  orchestrator handoff documented in
  `docs/orchestrator-injected-rules.md`.

## Validation discoverability

The terms `preflight`, `diagnostics`, `tmux shape`, `dirty clones`,
`non-default-base PR`, and `read-only` are all present in this file
and in `scripts/env_diagnostics.sh` so the issue #255 validation grep
finds them:

```bash
grep -nE "preflight|diagnostics|tmux shape|dirty clones|non-default-base PR|read-only" \
  docs examples scripts
```
