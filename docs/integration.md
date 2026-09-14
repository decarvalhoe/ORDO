# Integration

This guide explains how to wire ORDO into a project. ORDO does not own a
project's source code, repository, or release pipeline; it observes,
coordinates, and dispatches work using configured profiles and provider
adapters.

Two starting points are supported:

- **Existing project**: a repository already exists; ORDO needs an external
  project profile, agent workdirs, and agent identities pointing at it.
- **Greenfield project**: the repository does not exist yet; ORDO scaffolds the
  baseline before agents start working.

The single-project shape is documented first. Multi-product portfolios extend
the same contract and are described later.

This guide is generic. Substitute placeholder names such as `<project>`,
`<owner>/<repository>`, and `<agent>` with values from your deployment.
`RBOKproject` is one possible operator and is never an ORDO default.

## At a Glance

| Step | Outcome | Mutating? |
| --- | --- | --- |
| 1 | Decide repo mode (existing or greenfield) | read-only |
| 2 | Confirm or plan the repository | read-only by default; mutating only on explicit `--apply` |
| 3 | Author the external project profile | mutating: operator writes one file outside the checkout |
| 4 | Provision agent workdirs and identities | mutating: clones, agent identities, panes |
| 5 | Wire portfolio profile (optional) | mutating: operator writes one portfolio file |
| 6 | Verify integration with read-only commands | read-only |

ORDO never mutates the target repository unless an explicit `--apply` is
passed to a documented script. Dry-run is the default for preflight,
scaffolds, and bind plans.

## 1. Decide Repo Mode

| Mode | When to use | Entry script |
| --- | --- | --- |
| `existing` | A repository already exists at the configured provider | [`repository_platform_readiness.sh`](../scripts/repository_platform_readiness.sh) |
| `greenfield` | A new repository must be created and primed | [`repository_bootstrap.sh`](../scripts/repository_bootstrap.sh) |

Both scripts are non-mutating by default. They print a structured ready
report that downstream scaffolds and onboarding scripts consume.

## 2. Confirm or Plan the Repository

### Existing repository (read-only by default)

```bash
# Read-only: confirm provider access, default branch, and protection state.
bash scripts/repository_platform_readiness.sh <project-config> --json
```

The output reports whether ORDO can read the repository, whether the
configured default branch matches `DEFAULT_BRANCH`, and whether protection
rules are present.

### Greenfield repository (plan first, apply only after review)

```bash
# Read-only: produce a bootstrap plan.
bash scripts/repository_bootstrap.sh <project-config> --json

# Mutating, after operator review: create the remote, init local, push baseline.
bash scripts/repository_bootstrap.sh <project-config> --apply --json
```

`--apply` is the only path that mutates remote state. `ORCH_DRY_RUN=1` and
`--dry-run` keep the apply preview-only even when `--apply` is supplied.

### Optional: project scaffold

Once the repository is ready, the project scaffold can write a neutral
baseline (README, gitignore, env example, validate stub, decision record):

```bash
# Read-only: preview the scaffold for the chosen archetype.
bash scripts/project_scaffold.sh <project-config> \
  --intent "Describe the product outcome in business terms" \
  --target-dir <target-checkout> \
  --repo-mode existing \
  --json

# Mutating, requires a ready report and explicit --apply.
bash scripts/project_scaffold.sh <project-config> \
  --intent "Describe the product outcome in business terms" \
  --target-dir <target-checkout> \
  --repo-mode existing \
  --readiness-report <ready-report.json> \
  --apply \
  --json
```

The scaffold contract, archetypes, and refusal rules are documented in
[project-scaffold.md](project-scaffold.md). The validation stub it generates
verifies only that the baseline exists; it is not a substitute for project
checks.

## 3. Author the External Project Profile

The project profile is the only place where live identifiers (repository name,
credential directory, agent panes, agent logins, audit log path) belong. It is
operator-owned, lives outside the ORDO checkout, and is never committed to
ORDO.

A complete profile shape:

```bash
# /secure/operator/<project>.config.sh
PROJECT="<project>"
DEFAULT_BRANCH="main"

# Provider adapter (current shell adapter is GitHub-backed).
GH_REPO="<owner>/<repository>"
GH_CONFIG_DIR="/operator/credential/profiles/<agent>-gh"

# Universal fleet inventory: label|session:window.pane|absolute-workdir.
AGENT_PANES=(
  "planner|<session-a>:0.0|/workspace/<project>-planner"
  "builder|<session-b>:0.0|/workspace/<project>-builder"
  "reviewer|<session-c>:0.0|/workspace/<project>-reviewer"
)

# Map ORDO labels to provider accounts for issue assignment.
AGENT_GH_LOGINS=(
  "planner=<planner-login>"
  "builder=<builder-login>"
  "reviewer=<reviewer-login>"
)

# Optional alias map for portfolio or matrix labels.
AGENT_GH_LABEL_ALIASES=(
  "<portfolio>-builder=builder"
)

# Per-agent repository workdirs. ORDO never derives these from project name.
PROJECT_REPO_ROOT="/workspace/<project>-supervisor"
SUPERVISOR_REPO="$PROJECT_REPO_ROOT"
AGENT_REPO_PREFIX="/workspace/<project>-"
export AGENT_WORKDIR_TEMPLATE="/workspace/<project>-%s"

# Optional audit trail location.
AUDIT_LOG_FILE="/var/log/ordo/${PROJECT}.log"
```

Required values for `examples/ordo.config.sh` to load the profile:

| Variable | Purpose |
| --- | --- |
| `PROJECT` | Stable short name used for state directories and logs |
| `GH_REPO` | Provider repository identifier for the GitHub adapter |
| `DEFAULT_BRANCH` | Branch ORDO treats as the merge target |
| `GH_CONFIG_DIR` | Path to a `gh` config directory authenticated for an agent |
| `AGENT_REPO_PREFIX` | Path prefix used to derive agent workdirs |
| `AGENT_WORKDIR_TEMPLATE` | Format string for agent workdirs |
| `AGENT_PANES` | Universal fleet inventory |

The fleet inventory contract, migration from legacy `AGENTS` arrays, and
common failure modes are documented in
[universal-fleet-manual.md](universal-fleet-manual.md).

## 4. Provision Agent Workdirs and Identities

Each entry in `AGENT_PANES` resolves to a triple `(label, pane, workdir)`. The
operator owns the panes and the per-agent identity. ORDO never edits agent
shell rcs, never starts logins, and never switches identities at runtime.

### Per-agent workdir (mutating, operator-driven)

```bash
# Create a clone for each agent label.
git clone <owner>/<repository>.git /workspace/<project>-<agent>
```

Each agent's workdir is independent. Agents must not share a clone because
git state, branches, and dispatch assignments are tracked per workdir.

### Per-agent provider identity (mutating)

For the GitHub adapter (`ORDO_PROVIDER_ADAPTER=github`, the default), each
`GH_CONFIG_DIR` is authenticated once:

```bash
GH_CONFIG_DIR=/operator/credential/profiles/<agent>-gh gh auth login
```

For Forgejo/Gitea or GitLab (`ORDO_PROVIDER_ADAPTER=forgejo|gitlab`) the
identity is a token file: `ORDO_FORGE_TOKEN_FILE=/operator/credential/profiles/<agent>-token`
(mode 0600) together with `ORDO_FORGE_URL` and `ORDO_FORGE_REPO` — see
[architecture/providers.md](architecture/providers.md). Check either with
`ordo_provider auth_status`.

The credential directory is operator-owned and outside the ORDO checkout.
ORDO selects the right directory automatically based on the active label.

### Per-agent tmux pane (mutating)

The `AGENT_PANES` entry names the tmux target. Provision the matching session
and pane before dispatch:

```bash
tmux list-panes -a
# create or rename sessions/panes until they match the AGENT_PANES profile
```

If a pane is missing or mismapped, ORDO refuses to dispatch and prints the
expected target. See `tmux pane ... not found` in
[universal-fleet-manual.md](universal-fleet-manual.md).

## 5. Wire a Portfolio Profile (Optional)

When one fleet serves several products, add a portfolio config that
references each project profile:

```bash
# /secure/operator/<portfolio>.config.sh
PORTFOLIO_NAME="<portfolio>"
PORTFOLIO_PROJECTS=(
  "<project-a>|/secure/operator/<project-a>.config.sh"
  "<project-b>|/secure/operator/<project-b>.config.sh"
)

PORTFOLIO_PRIORITIES=(
  "<project-a>=100"
  "<project-b>=80"
)

PORTFOLIO_ENSURE_AGENT_MATRIX=1
PORTFOLIO_FLEET_AGENTS=(
  "planner|<session-a>:0.0"
  "builder|<session-b>:0.0"
  "reviewer|<session-c>:0.0"
)

# Optional: explicit repo bindings for unusual repository names.
PORTFOLIO_REPO_CANDIDATES=(
  "<project-c>|<owner>/<custom-repo-c>|main|/workspace/<project-c>-%s"
)
```

Run a non-mutating bind plan when repository names are custom or unknown:

```bash
# Read-only: candidate rows for operator review.
bash scripts/portfolio_repo_bind_plan.sh <portfolio-config> \
  --discover-owner <owner> \
  --json
```

Bind plans never edit configs, never clone, and never dispatch. Operator
confirmation is required before `portfolio_session_start.sh --apply` can
clone anything.

The full portfolio contract, switch modes, and capacity status outputs are
documented in [multi-product-portfolio.md](multi-product-portfolio.md).

## 6. Verify Integration

### Single project (read-only)

```bash
export ORDO_PROJECT_PROFILE=/secure/operator/<project>.config.sh

# Read-only: full fleet snapshot.
bash scripts/agent_pool_status.sh examples/ordo.config.sh --tsv

# Read-only: ranked dispatch candidates.
bash scripts/dispatch_plan.sh examples/ordo.config.sh --ready-only --json

# Read-only: PR blocker signals.
bash scripts/pr_block_signals.sh examples/ordo.config.sh --tsv
```

### Portfolio (read-only by default)

```bash
# Read-only: clone, default branch, dirty state, drift.
bash scripts/portfolio_session_start.sh <portfolio-config> --json

# Read-only: capacity per product.
bash scripts/portfolio_status.sh <portfolio-config> --tsv
```

`portfolio_session_start.sh --apply` performs only deterministic safe actions:
clones a missing workdir when a confirmed remote binding exists, and
fast-forwards a clean default-branch clone. It never stashes, resets,
checks out over local work, rebases feature branches, or pushes.

### Smoke dispatch (dry-run, no mutation)

```bash
cat >/tmp/dispatch-builder-smoke.md <<'EOF'
# Dispatch smoke

## Objectif

Verify ORDO resolves the configured fleet target.

## Tools / sources autorises

- Shell read-only commands.

## Boundaries / interdictions

- No mutation.

## Definition of Done verifiable

- [ ] Dry-run output names the intended label and workdir.

## Preuves attendues

- Dry-run output.
EOF

# Read-only: dispatcher prints the target without sending keys.
bash scripts/dispatch_ticket.sh examples/ordo.config.sh builder 999 \
  /tmp/dispatch-builder-smoke.md --dry-run
```

## Operator-Owned Configuration Boundaries

ORDO depends on three kinds of files. Only one is committed; the other two are
operator-owned and stay outside the checkout.

| File class | Examples | Location | Owner |
| --- | --- | --- | --- |
| Toolkit examples | `examples/ordo.config.sh`, `examples/portfolio.config.sh` | inside the ORDO checkout | ORDO repository |
| Project / portfolio profiles | `<project>.config.sh`, `<portfolio>.config.sh` | operator-controlled path (e.g. `/secure/operator/`) | operator |
| Token files | `~/.config/ordo-tokens.env` | operator-controlled path, `chmod 600` | operator |

Toolkit examples never carry live identifiers. Profiles never carry secret
material. Tokens never live in the checkout. Refer to
[../SECRETS.md](../SECRETS.md) for token expectations and rotation.

## Optional: GxP and Six Sigma Documentation Layers

When a downstream project opts in to GxP-grade or Six Sigma documentation
layers, the generated docs include controlled-document expectations,
validation and evidence sections, audit-trail expectations, and DMAIC/CTQ
hooks. These layers are explicit, optional, and testable; they are not enabled
in normal-dev integrations and never leak into a project that did not select
them.

The CSV development mode that supports validation evidence is documented in
[validation/README.md](validation/README.md) and
[validation/csv-development-mode.md](validation/csv-development-mode.md).

## What Comes Next

- Run the daily operator loop and merge gate: see [usage.md](usage.md).
- Configure the orchestrator supervisor session: see
  [universal-fleet-manual.md](universal-fleet-manual.md).
- Review controlled-operation evidence requirements: see
  [controlled-operations.md](controlled-operations.md).
