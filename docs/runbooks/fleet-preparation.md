# Fleet Preparation Runbook

This runbook captures the durable ORDO procedure for preparing a multi-agent
fleet from a fresh operator workstation or a reused one. It is the
chat-history-free reference an operator follows when bringing up, auditing, or
debugging a fleet.

The runbook is generic. Live host names, account names, repository identifiers,
tmux session names, and provider-specific account labels stay in external
operator profiles. The examples below use placeholder values such as
`product-a`, `terminal-a:0.0`, and `owner/repository`.

This runbook complements existing ORDO documentation and does not replace it:

- [Universal fleet manual](../universal-fleet-manual.md) for the fleet contract,
  `AGENT_PANES`, and provider mapping.
- [Multi-product portfolio guide](../multi-product-portfolio.md) for portfolio
  config, capacity status, and product switching.
- [Host health runbook](../host-health-runbook.md) for log/session storms,
  evidence capture under load, and remediation order.
- [Controlled operations guide](../controlled-operations.md) for `ORCH_STATE_BASE`
  state-record locations.
- [Fleet injected rules](../fleet-injected-rules.md) for the dispatch-time rules
  delivered to worker agents.
- [Worktree migration](../worktree-migration.md) for isolating workdirs per
  agent without destructive cleanup.

## When To Use This Runbook

Use this procedure when any of the following is true:

- The operator is bringing up a fleet on a host where ORDO has not run before.
- The operator is reusing a host that previously ran a different fleet, project,
  or version of ORDO.
- The operator suspects fleet drift, stale topology references, or state bleed
  between products.
- The operator must produce evidence that a session was prepared safely
  (preflight, setup, verification, audit capture) before dispatch.

It is not a release procedure. Validation grade for the operator host is
operational; the regulated CSV release boundary is unchanged and remains
documented in [docs/validation/README.md](../validation/README.md).

## Conventions

- Every long-running command has a strict `timeout`. Do not background a
  preparation step and walk away.
- Every audit step writes evidence into a per-run directory under
  `evidence/fleet-prep-<timestamp>/`.
- Every example assumes the operator has already exported
  `ORDO_PROJECT_PROFILE` (for single-product) or has a portfolio config in
  hand. Live topology values are loaded from the external profile, not from
  the runbook.
- Examples use the universal `AGENT_PANES` form `label|session:window.pane|workdir`.

```bash
ts=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE_DIR="evidence/fleet-prep-$ts"
mkdir -p "$EVIDENCE_DIR"
```

## Reproducible Flow

The flow is four ordered phases. Each phase produces evidence and stops the
operator before the next phase if a refusal signal fires.

1. **Preflight** — verify host capacity, process safety, and provider/CLI
   reachability before touching topology.
2. **Setup** — point ORDO at an isolated runtime root, load the project or
   portfolio profile, and bind the universal fleet contract without mutating
   existing workdirs.
3. **Verification** — confirm panes, workdirs, identities, and PR/issue counts
   match the configured matrix using direct provider queries.
4. **Audit capture** — record evidence (preflight metrics, scrollback, audit
   snapshot, portfolio status, GitHub cross-check) into the per-run evidence
   directory.

Refuse to proceed past any phase whose refusal-mode command exits non-zero.
The runbook is fail-closed by design.

## Phase 1 — Preflight

### 1.1 Host capacity and storm signals

Run the bounded host-health preflight. Use the fail-closed `--refuse` form
when the operator wants to stop on critical signals (storm, log saturation,
session pressure).

```bash
timeout 10 bash scripts/host_health_preflight.sh \
  > "$EVIDENCE_DIR/host_health.txt"

timeout 10 bash scripts/host_health_preflight.sh --refuse \
  > "$EVIDENCE_DIR/host_health_refuse.txt"
```

If `--refuse` exits non-zero, follow the
[host health runbook](../host-health-runbook.md) order: capture evidence first,
stop the storm source, then remediate. Resume Phase 1 after the host returns
to nominal.

### 1.2 Process safety preflight

Run the process-safety preflight to refuse on runaway scans, validators, or
host forensic probes that historically pin cores during ORDO sessions.

```bash
timeout 15 bash scripts/process_safety_preflight.sh \
  > "$EVIDENCE_DIR/process_safety.txt"

timeout 15 bash scripts/process_safety_preflight.sh --refuse \
  > "$EVIDENCE_DIR/process_safety_refuse.txt"
```

Do not pass `--kill` from this runbook. Killing offending processes is a
controlled operation handled by an operator, not by an automated preparation
step.

### 1.3 Server, Docker, API, disk, memory, load, GitHub counts

Capture the durable preflight envelope. Each command is bounded; missing
binaries are tolerated.

```bash
{
  echo "# uname"
  uname -a
  echo
  echo "# uptime"
  uptime
  echo
  echo "# free"
  free -m 2>/dev/null || true
  echo
  echo "# disk"
  df -hT / "${ORCH_STATE_BASE:-${XDG_DATA_HOME:-$HOME/.local/share}/orch-state}" \
    "${ORCH_LOG_DIR:-/var/log/orch}" 2>/dev/null || true
  echo
  echo "# load"
  cat /proc/loadavg 2>/dev/null || true
} > "$EVIDENCE_DIR/host_envelope.txt" 2>&1

if command -v docker >/dev/null 2>&1; then
  timeout 5 docker info --format '{{.ServerVersion}} {{.OperatingSystem}}' \
    > "$EVIDENCE_DIR/docker_info.txt" 2>&1 || true
fi

if command -v gh >/dev/null 2>&1; then
  timeout 10 gh api rate_limit --jq '.resources.core' \
    > "$EVIDENCE_DIR/gh_rate_limit.json" 2>&1 || true
  timeout 10 gh api -H 'Accept: application/vnd.github+json' \
    /repos/owner/repository --jq '.full_name' \
    > "$EVIDENCE_DIR/gh_repo_probe.txt" 2>&1 || true
fi
```

Replace `owner/repository` with the configured `GH_REPO` from the project
profile. The probe is read-only and does not assume a specific organization.

### 1.4 GitHub issue and PR baseline counts

Capture provider counts directly. The orchestrator uses these to cross-check
ORDO portfolio status later (Phase 4).

```bash
if command -v gh >/dev/null 2>&1; then
  timeout 10 gh issue list --repo owner/repository --state open \
    --json number --jq 'length' \
    > "$EVIDENCE_DIR/gh_open_issues.txt" 2>&1 || true

  timeout 10 gh pr list --repo owner/repository --state open \
    --json number,isDraft,baseRefName \
    > "$EVIDENCE_DIR/gh_open_prs.json" 2>&1 || true
fi
```

Capturing draft PRs and `baseRefName` is intentional: portfolio status can
miss draft PRs or PRs targeting a non-default base. Phase 4 reconciles those
counts against ORDO state.

## Phase 2 — Setup

### 2.1 Isolate the runtime root

Avoid state bleed between products and between fleet runs. Point every ORDO
runtime path at an isolated, operator-owned root before loading any project
config.

```bash
RUNTIME_ROOT="/srv/ordo-runtime/<operator>/<fleet-name>"
export ORCH_STATE_BASE="$RUNTIME_ROOT/state"
export ORCH_LOG_DIR="$RUNTIME_ROOT/logs"
export ORDO_TOKENS_FILE="$RUNTIME_ROOT/tokens.env"

mkdir -p "$ORCH_STATE_BASE" "$ORCH_LOG_DIR"
chmod 700 "$RUNTIME_ROOT"

if [ -f "$ORDO_TOKENS_FILE" ]; then
  perms=$(stat -c '%a' "$ORDO_TOKENS_FILE")
  if [ "$perms" != "600" ]; then
    chmod 600 "$ORDO_TOKENS_FILE"
  fi
fi
```

`ORCH_STATE_BASE` and `ORCH_LOG_DIR` are scoped explicitly because they default
to user-wide paths (`$XDG_DATA_HOME/orch-state` and `/var/log/orch`). When two
products run on the same host without scoping, state for one bleeds into the
other under `<base>/<project>/`. Scoping per fleet is the durable fix.

Do **not** delete or move `$RUNTIME_ROOT` from a previous session. See
[§ Cleanup is forbidden by default](#cleanup-is-forbidden-by-default).

### 2.2 Load the project or portfolio profile

Load the operator-owned profile. Never inline live topology into committed
ORDO files.

```bash
export ORDO_PROJECT_PROFILE="/profiles/product-a.config.sh"

# Or, for portfolios:
PORTFOLIO_CONFIG="/profiles/product-suite.portfolio.config.sh"
```

Verify the profile resolves and reports the expected project identity.

```bash
timeout 10 bash scripts/orch_ctl.sh examples/ordo.config.sh status \
  > "$EVIDENCE_DIR/orch_ctl_status.txt" 2>&1
```

Before rendering a live dispatch brief, confirm the profile carries the fields
that make the dispatch auditable and route-safe:

- `ORCH_SCOPE_IN_SCOPE_PROJECTS`, `ORCH_SCOPE_HELD_PROJECTS`, or
  `ORCH_SCOPE_OUT_OF_SCOPE_PROJECTS` binds the active project key so
  `scope classification` is not `unknown`. If a one-off dispatch must proceed
  with `unknown`, record the per-dispatch authorization and render with
  `--allow-unknown-scope`.
- `SUPERVISOR_REPO` is a git remote name such as `origin`, not a filesystem
  checkout path. Filesystem roots belong in `PROJECT_REPO_ROOT`, `AGENT_PANES`,
  or other workdir fields. If a path is inherited, pass an explicit
  `base_remote=<remote> base_ref=<remote>/<branch>` only after verifying the
  remote points at the expected repository.
- `AGENT_GH_LOGINS` resolves the provider login used for issue assignment and
  other GitHub-backed operations.
- `AGENT_GIT_IDENTITIES` or both git identity templates
  (`AGENT_GIT_IDENTITY_NAME_TEMPLATE` and
  `AGENT_GIT_IDENTITY_EMAIL_TEMPLATE`) resolve the commit display identity for
  every dispatchable agent label.

### 2.3 Bind workdirs without mutation

For portfolios, run the session-start audit in non-mutating mode first. This
verifies clones, default branches, dirty state, and ahead/behind drift across
the agent/product matrix without checking out, stashing, or rebasing anything.

```bash
timeout 30 bash scripts/portfolio_session_start.sh "$PORTFOLIO_CONFIG" --json \
  > "$EVIDENCE_DIR/portfolio_session_start.json" 2>&1
```

Apply only deterministic safe actions when needed. The `--apply` mode is
documented to clone missing workdirs only when a confirmed remote binding
exists, and to fast-forward clean default-branch clones; it never stashes,
resets, or rebases existing work.

```bash
timeout 60 bash scripts/portfolio_session_start.sh "$PORTFOLIO_CONFIG" \
  --apply --dry-run \
  > "$EVIDENCE_DIR/portfolio_session_start_apply_preview.txt" 2>&1
```

Promote `--apply --dry-run` to `--apply` only after the operator reviews the
plan and confirms no existing workdir would be overwritten.

## Phase 3 — Verification

### 3.1 Live tmux targets and pane indexes

Stale documentation often says "1 window" when the live pane is actually
`session:0.0`. Verify against the live tmux server, not against the wording in
older briefs.

```bash
if command -v tmux >/dev/null 2>&1; then
  timeout 5 tmux list-sessions \
    -F '#{session_name} windows=#{session_windows} attached=#{session_attached}' \
    > "$EVIDENCE_DIR/tmux_sessions.txt" 2>&1 || true

  timeout 5 tmux list-panes -a \
    -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path}' \
    > "$EVIDENCE_DIR/tmux_panes.txt" 2>&1 || true
fi
```

Cross-check every entry in `AGENT_PANES`:

- The configured `session:window.pane` exists in `tmux_panes.txt`.
- `pane_current_path` matches the configured workdir or is a parent of it.
- The label in `AGENT_PANES` is unique across the file.

If a configured pane is missing, do **not** auto-create it from this runbook.
Open a session-start ticket or follow the operator's pane-bring-up procedure;
ORDO refuses dispatch when the pane is not resolvable, so the failure is
explicit upstream.

### 3.2 Workdir identity and dirty state

For each declared workdir, verify it is a git repository, on the expected
default branch, with no uncommitted changes that have not been audited.

```bash
while IFS='|' read -r label pane workdir; do
  [ -d "$workdir/.git" ] || { echo "MISSING_REPO label=$label workdir=$workdir"; continue; }
  branch=$(timeout 5 git -C "$workdir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
  dirty=$(timeout 5 git -C "$workdir" status --porcelain 2>/dev/null | head -1)
  echo "label=$label pane=$pane workdir=$workdir branch=$branch dirty=${dirty:+yes}"
done <<< "$(printf '%s\n' "${AGENT_PANES[@]}")" \
  > "$EVIDENCE_DIR/workdir_identity.txt"
```

If `dirty=yes`, audit the diff before doing anything else. See
[§ Cleanup is forbidden by default](#cleanup-is-forbidden-by-default).

### 3.3 Provider identity and account mapping

Verify the operator's provider login and the per-agent account mapping. The
provider adapter is configurable; the example below uses `gh` because the
current shell adapter uses GitHub.

```bash
if command -v gh >/dev/null 2>&1; then
  timeout 10 gh auth status 2>&1 \
    > "$EVIDENCE_DIR/gh_auth_status.txt" || true
  timeout 10 gh api user --jq '.login' \
    > "$EVIDENCE_DIR/gh_login.txt" 2>&1 || true
fi
```

For each `AGENT_GH_LOGINS` entry, check the configured login resolves and
matches the worker bot account (no operator humans inside the worker pool).

### 3.4 Model and mode acceptance

Worker agents arrive at first launch with model selection prompts and trust
prompts. Record acceptance in evidence rather than hoping the operator
remembers. The exact UX is vendor-specific; ORDO does not embed vendor copy.

For each pane, capture and store:

- The configured model identity (e.g. `claude-opus-4-7`, or the
  vendor-neutral string used in the operator's profile).
- The mode (e.g. `headless`, `interactive`, or the operator-defined mode).
- A timestamped acknowledgement that the trust prompt was answered.

```bash
{
  echo "# model_mode_acceptance"
  for entry in "${AGENT_PANES[@]}"; do
    IFS='|' read -r label pane workdir <<<"$entry"
    echo "label=$label pane=$pane workdir=$workdir model=<filled by operator> mode=<filled by operator> trust_accepted_at=<UTC>"
  done
} > "$EVIDENCE_DIR/model_mode_acceptance.txt"
```

The `<filled by operator>` markers stay in evidence so an auditor can see what
was confirmed at session start. ORDO does not auto-select model or mode.

### 3.5 Issue and PR cross-check

Cross-check ORDO portfolio status against direct GitHub queries from Phase 1.4.
Portfolio status can miss drafts or non-default-base PRs; the orchestrator
needs both views to detect drift.

```bash
timeout 30 bash scripts/portfolio_status.sh "$PORTFOLIO_CONFIG" --json \
  > "$EVIDENCE_DIR/portfolio_status.json" 2>&1 || true
```

Compare:

- The total open-PR count from `gh_open_prs.json` (Phase 1.4).
- The per-product PR counts from `portfolio_status.json` (Phase 3.5).
- The set difference. Investigate any PR present in `gh_open_prs.json` but
  absent from `portfolio_status.json`. Common causes are draft PRs or PRs
  targeting a non-default branch on a product whose profile is missing the
  alternate base.

If a delta exists and is not a known false positive, file an opportunity
finding in the final report under `opportunity_findings`. Do not silently
accept the divergence.

## Phase 4 — Audit Capture

### 4.1 ORDO audit snapshot

Run the audit script for the project. It records a snapshot of agents,
branches, open PRs, and backlog under `$ORCH_STATE_BASE/<project>/`.

```bash
timeout 60 bash scripts/audit_state.sh examples/ordo.config.sh \
  > "$EVIDENCE_DIR/audit_state.txt" 2>&1 || true
```

The script logs `AUDIT START project=<id>` and `AUDIT END project=<id>` lines
that can be used as durable signatures when reconciling against
`$ORCH_LOG_DIR/<project>.log`.

### 4.2 Capture tmux scrollback before clearing

Tmux scrollback can carry false risk signals (old refusals, stale model
chooser screens, error fragments from an unrelated previous session). Capture
the scrollback before any `clear` or `tmux clear-history`.

```bash
if command -v tmux >/dev/null 2>&1; then
  for entry in "${AGENT_PANES[@]}"; do
    IFS='|' read -r label pane workdir <<<"$entry"
    timeout 5 tmux capture-pane -t "$pane" -p -S -2000 \
      > "$EVIDENCE_DIR/scrollback.${label}.txt" 2>&1 || true
  done
fi
```

Only after each pane's scrollback file exists in `$EVIDENCE_DIR/` may the
operator clear scrollback. The evidence file proves what was cleared and is
the artifact referenced by the findings table when a false signal was
suppressed.

### 4.3 Detect and retire legacy sessions

Tmux sessions created by previous fleets, ad-hoc shells, or earlier
orchestration runs may sit outside the active matrix. They can confuse pane
indexing, hold open dirty workdirs, or own stale GitHub auth.

```bash
if command -v tmux >/dev/null 2>&1; then
  active_panes=$(printf '%s\n' "${AGENT_PANES[@]}" | awk -F'|' '{print $2}' | sort -u)
  all_panes=$(timeout 5 tmux list-panes -a \
    -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null | sort -u)

  comm -23 <(printf '%s\n' "$all_panes") <(printf '%s\n' "$active_panes") \
    > "$EVIDENCE_DIR/legacy_panes.txt"
fi
```

For each legacy pane:

1. Capture scrollback into `$EVIDENCE_DIR/legacy_scrollback.<pane>.txt` before
   anything else.
2. Check if the pane's `pane_current_path` is a workdir that contains
   uncommitted changes (`git status --short`). If yes, treat as a preserve
   case (see § Cleanup is forbidden by default).
3. Only then, if the operator confirms the pane is genuinely abandoned and
   contains no uncommitted work, kill it explicitly:

   ```bash
   tmux kill-pane -t '<pane>'   # operator-confirmed only
   ```

Never run `tmux kill-server`, `tmux kill-session`, or wildcard
`tmux kill-pane -a` from this runbook.

### 4.4 Final evidence index

Write an index file enumerating the artifacts produced. The index is the
single attachment the orchestrator can link from a PR or report.

```bash
{
  echo "# fleet-prep evidence"
  echo "timestamp_utc: $ts"
  echo "orch_state_base: $ORCH_STATE_BASE"
  echo "orch_log_dir: $ORCH_LOG_DIR"
  echo
  echo "## artifacts"
  ls -1 "$EVIDENCE_DIR"
} > "$EVIDENCE_DIR/INDEX.txt"
```

## Findings Table

Every row maps a recurring symptom to a durable ORDO procedure. The runbook
phase number tells the operator where to apply the procedure.

| Symptom | Risk | Durable ORDO procedure | Evidence artifact |
| --- | --- | --- | --- |
| Stale brief says "1 window" but the live pane is `session:0.0` | Dispatch sent to a non-existent window; commands appear to vanish | Phase 3.1 — verify against `tmux list-panes -a` and update `AGENT_PANES` to use explicit `:0.0` targets | `tmux_panes.txt` |
| Old workdir contains uncommitted fixes from a prior agent | Destructive cleanup loses unmerged work | Phase 3.2 — audit `git status` per workdir, treat as preserve case (§ Cleanup is forbidden by default) | `workdir_identity.txt` |
| Generated clones, profiles, logs, and audit files share a default root with another fleet | State bleed between products and runs | Phase 2.1 — set isolated `$RUNTIME_ROOT` and export scoped `ORCH_STATE_BASE`/`ORCH_LOG_DIR` | `host_envelope.txt`, `audit_state.txt` |
| `ORCH_STATE_BASE` defaulted to `~/.local/share/orch-state` | Two products write to the same `<base>/<project>/`, state collides | Phase 2.1 — scope `ORCH_STATE_BASE` per fleet | `host_envelope.txt` |
| `ORCH_LOG_DIR` defaulted to `/var/log/orch` | Audit logs from different fleets interleave under the same project key | Phase 2.1 — scope `ORCH_LOG_DIR` per fleet | `host_envelope.txt`, `$ORCH_LOG_DIR/<project>.log` |
| Portfolio status reports a lower PR count than direct provider query | Drafts or non-default-base PRs are invisible to ORDO routing | Phase 1.4 + Phase 3.5 — direct `gh pr list --json number,isDraft,baseRefName` and reconcile against `portfolio_status.json` | `gh_open_prs.json`, `portfolio_status.json` |
| Tmux scrollback shows an old refusal or model chooser fragment | Operator clears scrollback and loses signals an audit may need | Phase 4.2 — capture scrollback per pane before clearing | `scrollback.<label>.txt` |
| Worker agent first launch shows a model selection or trust prompt | Acceptance is implicit and unverifiable later | Phase 3.4 — record model, mode, and trust acceptance per pane | `model_mode_acceptance.txt` |
| Tmux server has sessions or panes outside the configured matrix | Pane indexing skew, dirty hidden workdirs, stale auth | Phase 4.3 — compute legacy-pane diff, capture scrollback, preserve dirty workdirs, kill only operator-confirmed | `legacy_panes.txt`, `legacy_scrollback.<pane>.txt` |
| Operator skips host capacity probe before dispatch | Storm conditions amplify under load and probes pin cores | Phase 1.1 + 1.2 + 1.3 — `host_health_preflight.sh --refuse`, `process_safety_preflight.sh --refuse`, capture envelope | `host_health_refuse.txt`, `process_safety_refuse.txt`, `host_envelope.txt` |
| Operator runs full local validators on a shared agent host | Validator pressure degrades the fleet, may exit `75` | CI-delegated validation — keep local checks bounded and tied to changed files; let CI run the full suite | `host_envelope.txt`, CI rollup |

The evidence-artifact column references files written into
`$EVIDENCE_DIR/` by this runbook. The orchestrator links the relevant
artifacts from the post-session report or PR body.

## Cleanup Is Forbidden By Default

Old workdirs and old runtime roots can hold uncommitted fixes that an earlier
agent never pushed. Destructive cleanup before audit is the most common way
ORDO has lost work in practice. The default policy is preservation.

The runbook **forbids** the following actions before an audit confirms the
target is empty of uncommitted work:

- Deleting or moving any workdir that ORDO ever managed.
- Running `git reset --hard`, `git clean -fdx`, `git checkout -- .`, or
  `git stash` on a workdir whose `git status --short` is non-empty.
- Removing a previous `$RUNTIME_ROOT`, `$ORCH_STATE_BASE`, or `$ORCH_LOG_DIR`.
- Killing a tmux session or pane whose `pane_current_path` is a workdir with
  uncommitted changes.
- `rm -rf` against any clone path discovered by `portfolio_session_start.sh`
  audit, including clones marked as missing-default or behind-default.

Audit before any cleanup:

```bash
for entry in "${AGENT_PANES[@]}"; do
  IFS='|' read -r label pane workdir <<<"$entry"
  [ -d "$workdir/.git" ] || continue
  status=$(timeout 5 git -C "$workdir" status --short 2>/dev/null)
  if [ -n "$status" ]; then
    {
      echo "# uncommitted in $workdir"
      git -C "$workdir" status --short --branch
      echo
      echo "# diff (text only, no binaries)"
      git -C "$workdir" diff --stat
    } > "$EVIDENCE_DIR/uncommitted.${label}.txt" 2>&1
  fi
done
```

Treat any `uncommitted.*.txt` as a preserve case:

1. Open an issue or task to triage the diff.
2. Decide whether to commit, stash with a labeled message, or migrate the diff
   into a feature branch via `worktree-migration` patterns.
3. Do not delete the workdir until the diff is preserved somewhere durable.

Cleanup is allowed only after every preservation step is recorded in evidence
and the operator explicitly confirms the workdir or runtime root is safe to
remove.

## Reconfiguration Path

If verification (Phase 3) fails, do not patch the runbook output by hand. Use
the existing reconfiguration tools:

```bash
timeout 30 bash scripts/onboarding_verification.sh \
  --profile "$ONBOARDING_PROFILE" \
  --state "$ONBOARDING_STATE" \
  --provisioning-input "$ONBOARDING_PROVISIONING_INPUT" \
  --reconfiguration-output "$EVIDENCE_DIR/reconfiguration.json"
```

The reconfiguration artifact feeds back into `scripts/fleet_provisioning.sh`
and the guided onboarding flow. This runbook documents the operator-facing
audit; the structured remediation continues to live in those scripts so the
existing onboarding system stays the single source of truth.

## Outputs

A complete fleet-preparation run produces:

- `evidence/fleet-prep-<timestamp>/INDEX.txt` — artifact index.
- `host_health.txt`, `host_health_refuse.txt`, `process_safety.txt`,
  `process_safety_refuse.txt`, `host_envelope.txt`,
  `docker_info.txt` (optional), `gh_rate_limit.json`,
  `gh_repo_probe.txt`, `gh_open_issues.txt`, `gh_open_prs.json`.
- `orch_ctl_status.txt`, `portfolio_session_start.json`,
  `portfolio_session_start_apply_preview.txt`.
- `tmux_sessions.txt`, `tmux_panes.txt`, `workdir_identity.txt`,
  `gh_auth_status.txt`, `gh_login.txt`, `model_mode_acceptance.txt`,
  `portfolio_status.json`.
- `audit_state.txt`, `scrollback.<label>.txt`, `legacy_panes.txt`,
  `legacy_scrollback.<pane>.txt` (when applicable),
  `uncommitted.<label>.txt` (only when preservation is required).

The orchestrator references this set when opening or reviewing a session,
reconciling portfolio status, or filing an `opportunity_findings` entry from
a session that did not complete cleanly.

## Boundaries

- This runbook does not validate a regulated deployment and does not change
  the CSV release disposition recorded in
  [docs/validation/README.md](../validation/README.md).
- It does not assume a specific tmux multiplexer version, model provider, or
  agent CLI. Vendor-specific UX (model selection, trust prompts) is captured
  as evidence rather than scripted.
- It is not a replacement for the guided onboarding flow. The onboarding
  scripts under `scripts/guided_onboarding.sh`,
  `scripts/onboarding_verification.sh`, `scripts/fleet_provisioning.sh`,
  `lib/host_assessment.sh`, and `lib/fleet_sizing.sh` remain the structured
  path to first-time provisioning. The runbook documents the operator audit
  surface that surrounds them.
