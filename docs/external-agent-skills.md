# External Agent Skills and Configuration Reference

This document gives ORDO operators reusable recommendations for configuring
local and remote agents so behavior stays consistent across projects, vendors,
and CLI tools. It covers skill defaults, the dispatch authorization gate,
required agent config fields, and vendor-neutral example agents.

ORDO is agent-neutral and provider-adapter based (see `README.md`). Nothing in
this document hardcodes a specific vendor as the ORDO default. The Claude,
Codex, Cursor, Copilot, Gemini, and generic-CLI examples are illustrative
profiles operators may adapt; they are not bundled vendor presets.

Related ORDO docs:

- `docs/dispatch-planning.md` — pre-dispatch planner and validation placement.
- `docs/orchestrator-injected-rules.md` — rules injected into orchestrator
  briefings.
- `docs/fleet-injected-rules.md` — rules injected into worker dispatch prompts.
- `docs/controlled-operations.md` — evidence-gated exception workflow.
- `SECRETS.md` — required handling of secret values, names, and rotation.

## Default Posture: Issue-Pack Handoff, Not Direct Dispatch

A local agent (one running in an operator's terminal or IDE) must default to
the **issue-pack handoff** flow:

1. Plan the work locally.
2. Open or update a parent epic and atomized child issues in the configured
   issue provider, following the templates referenced from
   `docs/dispatch-planning.md`.
3. Notify the configured remote orchestrator that an issue pack is ready
   (`NEW ISSUE PACK READY`-style notification per the local handoff policy).
4. Stop. Do not assign issues to remote agents, do not push work to remote
   tmux panes, and do not invoke `dispatch_ticket.sh` from a local session.

Local agents must therefore be configured with the remote dispatch surface in
their **forbidden actions** list. The remote orchestrator owns assignment and
dispatch.

The issue-pack handoff is the standard skill template every local agent should
ship with. Operators clone the local skill template from
`templates/agents/local-skill-default.md` and customize the handoff
notification target, audit ledger location, and provider account.

## Exception: Direct Dispatch with Authorization and Matrix Gate

Direct dispatch (a local agent or operator sending a brief straight to a
target agent's terminal) is an exception, not a normal flow. It is allowed
only when:

- the operator has explicit, named authorization for the target agent and
  scope (recorded out-of-band, for example in a controlled operation evidence
  file per `docs/controlled-operations.md`);
- a current dispatch matrix exists for the involved repo or portfolio, or one
  is created compliant with ORDO dispatch directives before dispatch;
- the matrix row for the target agent is in a `ready` state with one active
  issue, a clean worktree, no conflicting hot spots, an explicit branch, and
  explicit PR expectations;
- the row is not `blocked`, `dirty`, `conflicting`, or already owned by
  another agent.

The exception template lives at
`templates/agents/direct-dispatch-exception.md`. It must be copied into the
controlled operation evidence trail and reviewed before any direct tmux
assignment.

## Agent Config Fields

Every agent configuration (local or remote) should declare the following
fields. They are independent of the provider adapter — the same fields apply
whether the agent runs Claude, Codex, Cursor, Copilot, Gemini, or a generic
CLI.

| Field | Purpose |
| --- | --- |
| `display name` | Short, human-readable label for dashboards and audit lines. |
| `short description` | One-sentence statement of what this agent does. |
| `default prompt` | Path to or inline reference for the operator-approved system prompt the agent boots with. |
| `allowed control plane` | Enumerated set of orchestration surfaces this agent may use (for example `issue-pack-handoff`, `local-tests`, `read-only-status`). |
| `forbidden actions` | Enumerated actions the agent must refuse (for example `remote-dispatch`, `force-push`, `merge-without-gate`, `secret-write`). |
| `audit root` | Path or remote location where the agent writes audit lines and findings ledger entries. |
| `GitHub identity` | The provider account name the agent commits and authenticates as (separate from the operator account). For non-GitHub providers, name the equivalent identity field explicitly. |
| `validation mode` | `ci-delegated` (default) or `require-local-validators`. Mirrors the `--require-local-validators` opt-in used by `scripts/dispatch_plan.sh` and `scripts/brief_agents.sh`. |
| `external sidecar root` | Absolute path OUTSIDE every product worktree where the agent CLI is configured to write its scheduler/session lock, cache, and other runtime metadata. Required whenever the agent CLI exposes a config-dir / state-dir override. See "Sidecar Paths and Runtime Metadata" below. |

The shell-style template at `templates/agents/agent-config.sh.tpl` exposes
these fields as ORDO-prefixed environment variables so they compose with the
existing project profile contract documented in `README.md`.

## Sidecar Paths and Runtime Metadata

Agent CLIs write runtime metadata to disk: scheduler locks, session state,
cache files, and MRU lists. When the agent is launched from a product
worktree, those files land inside the worktree (for example
`.claude/scheduled_tasks.lock` containing a session id, pid, and acquisition
timestamp). They are owned by the agent, NOT by the product, and they cause
two concrete problems if left in place:

- They make otherwise-clean clones look dirty, which blocks dispatch
  readiness gates and the runtime-freshness preflight.
- They risk being accidentally committed, which leaks per-host runtime data
  into the product repository's history.

The two-layer fix:

1. **Externalize at the agent CLI.** Set
   `ORDO_AGENT_EXTERNAL_SIDECAR_ROOT` to an absolute path on the operator
   host outside every product worktree (for example
   `~/.local/state/ordo/agent-state/<agent_label>`). For each lock or
   cache the agent CLI exposes a config knob for, list it under
   `ORDO_AGENT_EXTERNAL_SIDECAR_PATHS` and have the launcher export the
   matching CLI environment variable (e.g. `CLAUDE_CONFIG_DIR`,
   `CURSOR_HOME`) before the agent starts. The agent then never writes
   into product worktrees.

2. **Classify cleanly when the CLI cannot externalize.** Some agent CLIs
   do not yet support a state-dir override. The runtime-freshness lib
   (`lib/runtime_freshness.sh`) recognizes the well-known sidecar paths
   listed in `DEFAULT_SIDECAR_GLOBS` (including
   `.claude/scheduled_tasks.lock`, `.cursor/*`, `.aider/*`,
   `.vscode/*`, `.idea/*`) and classifies a worktree carrying ONLY those
   files as `sidecar-dirty` rather than `dirty-tracked`. Action stays
   `noop` so the preflight does not refuse, but the audit line records
   `remediation=externalize-agent-sidecar-paths` so the operator sees an
   explicit pointer back to the config field above. Business or
   out-of-scope worktrees mounted read-only are reported the same way —
   visible in the audit ledger, never silently ignored.

If a project's hygiene policy requires the worktree to be entirely free of
agent metadata, set `ORCH_RUNTIME_FRESHNESS_SIDECAR_GLOBS=""` in the project
profile (which empties the allowlist) and rely on the externalized agent
root above. ORDO will then refuse readiness on any untracked agent file.

## Vendor-Neutral Examples

The `examples/agents/` directory ships sample profiles for common agent
runtimes. They are **examples only** — none of them are loaded by ORDO by
default and they are not implied recommendations:

- `examples/agents/claude.agent.example.sh` — Anthropic Claude CLI (or IDE
  extension) running a local skill.
- `examples/agents/codex.agent.example.sh` — OpenAI Codex CLI agent.
- `examples/agents/cursor.agent.example.sh` — Cursor IDE agent.
- `examples/agents/copilot.agent.example.sh` — GitHub Copilot CLI / chat
  agent.
- `examples/agents/gemini.agent.example.sh` — Google Gemini CLI agent.
- `examples/agents/generic-cli.agent.example.sh` — any other terminal-driven
  agent.

Each example fills in the agent config fields above with placeholder values
and references the local skill template as its default. Operators copy a file
into their own profile directory, replace placeholders, and load it from a
project profile alongside `examples/ordo.config.sh`.

## Secrets Handling

Agent config files committed to a repository must contain variable names and
placeholders only. Never commit token values, private keys, credential
directories, or per-account passwords. Follow the rules in `SECRETS.md`:

- store secret values only in approved operator-controlled credential stores
  (shell loader, OS keyring, or provider config directory referenced via
  `GH_CONFIG_DIR` or its equivalent);
- if an agent needs a per-agent provider token, declare it via the
  `GH_TOKEN_AGENT_<label>` template variable defined in
  `examples/orch-tokens.env.example` and load it from the operator-controlled
  source at runtime;
- never paste token values into issue comments, PR descriptions, dispatch
  briefs, or terminal screenshots;
- `audit root` must point at a destination that does not capture environment
  variables verbatim (no `set -x` dumps, no full env logging).

Private skill directories owned by the operator (for example a personal
`~/.config/agent-cli/skills/` tree) are out of scope for this reference and
must not be copied into the repository even as examples.
