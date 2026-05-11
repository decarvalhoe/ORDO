# Installation

This guide installs ORDO on an operator-controlled host and runs the first
verification command. ORDO is a shell toolkit, not a hosted service: the
operator owns the checkout, the credentials, and the terminal sessions that
agents run in.

This guide is generic. It uses placeholder names such as `<owner>/<repository>`
and `<project>`; substitute values from your own deployment. `RBOKproject` may
appear elsewhere in this repository as an example operator and is not an ORDO
default.

## At a Glance

| Step | Outcome | Mutating? |
| --- | --- | --- |
| 1 | Confirm prerequisites | read-only |
| 2 | Clone or refresh the ORDO checkout | read-only on host, writes one directory |
| 3 | Run `install.sh` | mutating: chmods scripts, creates state dirs |
| 4 | Configure provider credentials and tokens | mutating: writes operator-owned files |
| 5 | Define an external project profile | mutating: writes one operator-owned file |
| 6 | Provision tmux/agent sessions | mutating: starts sessions on the host |
| 7 | Run the first verification command | read-only |

Mutating steps in this guide do not edit the ORDO checkout itself beyond
permissions and per-project state directories. Live topology, secrets, and
tokens stay outside the repository.

## 1. Prerequisites

Before installation, the host must provide:

- a POSIX-compatible shell (`bash` 5.x is the supported baseline);
- `git` 2.30 or later;
- `tmux` 3.0 or later, used for agent panes and orchestrator sessions;
- a provider CLI matching the configured adapter — for the GitHub adapter this
  is `gh` 2.40 or later, authenticated separately for each agent identity;
- core text utilities (`awk`, `sed`, `grep`, `jq` for JSON paths);
- `shellcheck` and `bats` if you intend to run validators locally; CI is the
  default location for full validators.

ORDO does not require root. Privileged operations are limited to:

- creating `/var/log/orch` (or the configured `ORCH_LOG_DIR`);
- writing per-project state under `${XDG_DATA_HOME:-$HOME/.local/share}/orch-state/`.

If the operator cannot create `/var/log/orch`, override `ORCH_LOG_DIR` to a
writable path before running `install.sh`.

### Verify prerequisites (read-only)

```bash
bash --version
git --version
tmux -V
gh --version
jq --version
```

The `gh` CLI is only needed when ORDO is configured against the current
GitHub-backed adapter. Other provider adapters declare their own CLI
dependencies.

## 2. Clone or Refresh the ORDO Checkout

ORDO has no installer to fetch the source itself; the operator chooses where
the checkout lives. Use the source location your organization already trusts.

```bash
# Read-only: pick a host directory under operator control.
mkdir -p ~/orch
cd ~/orch

# Mutating: clone or pull the toolkit.
git clone <owner>/<ordo-repository>.git ordo
# or update an existing checkout
cd ordo && git fetch --all --prune && git checkout main && git pull --ff-only
```

Keep the checkout outside short-lived agent worktrees. The checkout is the
control plane; agent-specific repository clones live in their own workdirs.

## 3. Run `install.sh`

`install.sh` is idempotent and safe to re-run. It performs only host-local
mutations:

- marks `scripts/*.sh` and `install.sh` as executable;
- creates `ORCH_LOG_DIR` (default `/var/log/orch`);
- creates a per-project state directory for each `examples/*.config.sh`;
- prints the next-step summary.

```bash
cd ~/orch/ordo
bash install.sh
```

The installer writes a per-project state path of the form:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/orch-state/<project>/
```

The example configs published in the repository are loaders: they refuse to
run until an external project profile is provided (see step 5). The state
directories are created so that the first dry-run can persist evidence
without surprising the operator.

If `~/.config/ordo-tokens.env` does not exist, the installer prints a copy
template. Token files belong outside the checkout and must be `chmod 600`.

## 4. Configure Provider Credentials and Tokens

ORDO never reads provider credentials from the repository. Each agent identity
keeps its own provider state, and privileged tokens stay in operator-owned
files.

### Per-agent provider profiles

For the GitHub adapter, each agent label maps to a `GH_CONFIG_DIR` containing
a `gh` authentication state. A common shape is:

```bash
# Mutating: one-time login per agent identity, performed by the operator
GH_CONFIG_DIR=/operator/credential/profiles/<agent>-gh gh auth login
```

The agent label, the GitHub login, and the credential directory stay in the
external project profile (step 5). ORDO never edits an agent's `gh` config.

### Privileged tokens

Privileged operations such as admin-fallback merges, branch-protection edits,
or controlled operations require a separate token file. Copy the template,
fill it in, and lock the file mode.

```bash
# Mutating: create the operator-owned token file
cp examples/orch-tokens.env.example ~/.config/ordo-tokens.env
chmod 600 ~/.config/ordo-tokens.env
$EDITOR ~/.config/ordo-tokens.env
```

The token file MUST stay outside the ORDO checkout. The installer warns when
the file mode is not `600`.

Detailed token expectations (scopes, rotation, leak response) live in
[../SECRETS.md](../SECRETS.md).

## 5. Define an External Project Profile

`examples/ordo.config.sh` is a loader that requires
`ORDO_PROJECT_PROFILE` to point at a profile the operator owns. The profile is
the only place where live identifiers belong.

A minimal profile defines:

```bash
# Operator-owned file, e.g. /secure/operator/<project>.config.sh
PROJECT="<project>"
DEFAULT_BRANCH="main"

# Provider adapter settings (current shell adapter is GitHub-backed).
GH_REPO="<owner>/<repository>"
GH_CONFIG_DIR="/operator/credential/profiles/<agent>-gh"

AGENT_PANES=(
  "planner|<session-a>:0.0|/workspace/<project>-planner"
  "builder|<session-b>:0.0|/workspace/<project>-builder"
  "reviewer|<session-c>:0.0|/workspace/<project>-reviewer"
)

AGENT_GH_LOGINS=(
  "planner=<planner-login>"
  "builder=<builder-login>"
  "reviewer=<reviewer-login>"
)

PROJECT_REPO_ROOT="/workspace/<project>-supervisor"
SUPERVISOR_REPO="$PROJECT_REPO_ROOT"
AGENT_REPO_PREFIX="/workspace/<project>-"
export AGENT_WORKDIR_TEMPLATE="/workspace/<project>-%s"
AUDIT_LOG_FILE="/var/log/ordo/${PROJECT}.log"
```

Profile rules:

- never commit secrets, real org names, or live host paths into ORDO;
- prefer the three-field `label|session:window.pane|workdir` form for
  `AGENT_PANES`;
- if the host policy requires pane-zero-only fleets, set every target to
  `:0.0`;
- keep the profile readable only by the operator account that runs ORDO.

The fleet contract and migration paths from legacy single-fleet configs are
documented in [universal-fleet-manual.md](universal-fleet-manual.md). The
portfolio variant is documented in
[multi-product-portfolio.md](multi-product-portfolio.md).

Then export the profile path before invoking ORDO commands:

```bash
export ORDO_PROJECT_PROFILE=/secure/operator/<project>.config.sh
```

## 6. Provision tmux and Agent Sessions

ORDO does not start agent terminals automatically. The operator provisions
tmux sessions, panes, and per-agent workdirs that match the
`AGENT_PANES` entries in the profile. Two patterns are common:

- one tmux session per agent label, all on `:0.0` for pane-zero policies;
- one shared session with one window per agent and pane indices that match the
  profile.

Verification of the running fleet (read-only):

```bash
tmux list-panes -a
```

Each `<session>:<window>.<pane>` declared in the profile must exist before
ORDO can dispatch work. If the session topology is missing, sessions or panes
need to be created (mutating, operator-driven) and then re-verified.

If the deployment uses a long-running orchestrator pane, add the supervisor
watchdog settings to the external profile before enabling recovery:

```bash
ORCH_SUPERVISOR_TARGET="<orchestrator-session>:0.0"
ORCH_SUPERVISOR_WORKDIR="$PROJECT_REPO_ROOT"
ORCH_SUPERVISOR_CLI_FLAGS="--model gpt-5.5 --reasoning-effort xhigh --debug --yolo --search"
```

Preview the relaunch command and recovery-plan logging without touching tmux:

```bash
bash scripts/ensure_alive.sh orch-supervisor examples/ordo.config.sh --once --dry-run
```

Only after the preview matches the operator profile should a service manager
or operator terminal run the continuous watchdog.

## 7. First Verification Command

The first verification call is read-only. It exercises the loader, the project
profile, and the provider adapter without dispatching work.

```bash
# Read-only: snapshot fleet, branch, dirty state, and PR status.
bash scripts/agent_pool_status.sh examples/ordo.config.sh --tsv
```

Expected outcome:

- the loader resolves `ORDO_PROJECT_PROFILE`;
- every configured agent label appears at most once;
- the provider adapter returns issue and PR data;
- the report prints in TSV without errors.

If the call fails, the most common causes are:

- `ORDO_PROJECT_PROFILE` is unset or points at a missing file;
- the profile is missing one of the required values
  (`PROJECT`, `GH_REPO`, `DEFAULT_BRANCH`, `GH_CONFIG_DIR`,
  `AGENT_REPO_PREFIX`, `AGENT_WORKDIR_TEMPLATE`, `AGENT_PANES`);
- the configured `gh` config directory is not authenticated;
- a tmux pane declared in `AGENT_PANES` does not exist on the host.

The full list of failure modes is documented in
[universal-fleet-manual.md](universal-fleet-manual.md).

### Optional: run the local validator suite

Local validators are CI-delegated by default. Run them directly only on an
operator-controlled host (not on a shared agent host) and only when the
toolkit is being modified:

```bash
# Read-only on the project profile; modifies nothing in the checkout.
bash scripts/run_shellcheck.sh
bash scripts/run_shell_tests.sh
bash scripts/run_bats.sh
```

If a runner reports validator pressure or exits with status `75`, the host is
under process pressure; do not retry full suites in a loop. Delegate
verification to CI and keep local checks focused.

## What Comes Next

- Add ORDO to an existing project or bootstrap a greenfield project: see
  [integration.md](integration.md).
- Run the daily operator loop: see [usage.md](usage.md).
- Configure the orchestrator supervisor session: see
  [universal-fleet-manual.md](universal-fleet-manual.md).
- Review the validation and release boundary: see
  [validation/README.md](validation/README.md).
