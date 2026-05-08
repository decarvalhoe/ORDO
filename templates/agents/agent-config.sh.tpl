#!/usr/bin/env bash
# templates/agents/agent-config.sh.tpl
#
# Vendor-neutral agent config template. Copy this file into your operator-owned
# profile location (outside this repository), replace every placeholder, and
# load it from your ORDO project profile alongside examples/ordo.config.sh.
#
# Doctrine: docs/external-agent-skills.md
# Default skill template: templates/agents/local-skill-default.md
# Direct-dispatch exception template: templates/agents/direct-dispatch-exception.md
#
# Never commit secret values. See SECRETS.md for required handling.

# --- Identity --------------------------------------------------------------

# display name shown in dashboards and audit lines.
ORDO_AGENT_DISPLAY_NAME="{{display_name}}"

# short description (one sentence).
ORDO_AGENT_DESCRIPTION="{{short_description}}"

# stable agent label used by ORDO scripts.
ORDO_AGENT_LABEL="{{agent_label}}"

# GitHub identity (or provider-equivalent identity field) the agent commits and
# authenticates as. Must be distinct from the operator's personal account.
ORDO_AGENT_GITHUB_IDENTITY="{{provider_account}}"

# --- Default prompt --------------------------------------------------------

# Path to the operator-approved system prompt the agent boots with. Default to
# the local skill template (issue-pack handoff). Override only with a prompt
# that still forbids remote-dispatch unless the agent IS the orchestrator.
ORDO_AGENT_DEFAULT_PROMPT_FILE="{{absolute_path_to}}/local-skill-default.md"

# --- Allowed control plane -------------------------------------------------

# Enumerated set of orchestration surfaces this agent may use. Add or remove
# items per agent role. Use the empty form `()` to forbid all control-plane
# operations.
ORDO_AGENT_ALLOWED_CONTROL_PLANE=(
  "issue-pack-handoff"
  "local-tests"
  "read-only-status"
)

# --- Forbidden actions -----------------------------------------------------

# Enumerated actions the agent must refuse. Keep `remote-dispatch` listed for
# every non-orchestrator agent.
ORDO_AGENT_FORBIDDEN_ACTIONS=(
  "remote-dispatch"
  "force-push"
  "merge-without-gate"
  "secret-write"
  "bypass-validation"
  "cross-product-mutation"
)

# --- Audit root ------------------------------------------------------------

# Destination where the agent appends audit lines and findings ledger entries.
# Must not capture environment dumps. Prefer a directory outside agent
# worktrees so findings survive worktree resets.
ORDO_AGENT_AUDIT_ROOT="{{absolute_path_to}}/audit/{{agent_label}}"

# --- External sidecar paths (#372) -----------------------------------------

# Where the agent runtime should write its OWN sidecar/cache/lock files
# (scheduler locks, session state, cached prompts, MRU lists). These files
# belong to the agent CLI, NOT to the product worktree, and must live OUTSIDE
# every product worktree so:
#   - readiness checks do not flag the worktree as dirty when only agent
#     runtime metadata is present (`.claude/scheduled_tasks.lock`,
#     `.claude/sessions/`, `.cursor/agent.log`, …);
#   - those files cannot be accidentally committed to the product repo;
#   - findings and lock acquisition timestamps survive worktree resets.
#
# Set this to a colon-separated list of absolute paths the operator has
# pre-created on the host. ORDO does NOT write to these paths itself — the
# value is consumed by the agent CLI launcher (Claude Code, Codex, Cursor,
# …) via whatever environment variable / config flag that CLI exposes for
# state directory overrides.
#
# Example mapping (operator fills in real CLI knobs):
#   CLAUDE_CONFIG_DIR="$ORDO_AGENT_EXTERNAL_SIDECAR_ROOT/claude"
#   CURSOR_HOME="$ORDO_AGENT_EXTERNAL_SIDECAR_ROOT/cursor"
#
# When the agent CLI does not support an externalized state directory, leave
# this empty and rely on the toolkit's runtime-freshness sidecar allowlist
# (lib/runtime_freshness.sh DEFAULT_SIDECAR_GLOBS) to keep readiness reports
# clean. The lib classifies that case as `sidecar-dirty` with remediation
# `externalize-agent-sidecar-paths`, which is the explicit pointer back to
# this field.
ORDO_AGENT_EXTERNAL_SIDECAR_ROOT="{{absolute_path_to}}/agent-state/{{agent_label}}"

# Per-agent overrides for individual sidecar/cache/lock paths the agent CLI
# is configured to write outside the worktree. Names are documentary only —
# ORDO does not export them. Operators should mirror these into the agent
# launcher's environment (or the agent CLI's own config file).
ORDO_AGENT_EXTERNAL_SIDECAR_PATHS=(
  # "claude.scheduled_tasks_lock=$ORDO_AGENT_EXTERNAL_SIDECAR_ROOT/claude/scheduled_tasks.lock"
  # "claude.sessions_dir=$ORDO_AGENT_EXTERNAL_SIDECAR_ROOT/claude/sessions"
  # "cursor.agent_log=$ORDO_AGENT_EXTERNAL_SIDECAR_ROOT/cursor/agent.log"
)

# --- Validation mode -------------------------------------------------------

# "ci-delegated" (default) or "require-local-validators". The latter must only
# be set after explicit operator authorization; it mirrors the
# --require-local-validators opt-in used by scripts/dispatch_plan.sh and
# scripts/brief_agents.sh.
ORDO_AGENT_VALIDATION_MODE="ci-delegated"

# --- Optional environment map ---------------------------------------------

# Per-agent environment variable names ONLY (no values). Real values must be
# loaded at runtime from the operator-controlled credential source per
# SECRETS.md. Example placeholders:
#
#   ORDO_AGENT_ENV_VARS=(
#     "GH_TOKEN_AGENT_{{agent_label}}"
#     "OPENAI_API_KEY"
#     "ANTHROPIC_API_KEY"
#   )
ORDO_AGENT_ENV_VARS=()

# --- Self-check ------------------------------------------------------------

# Light validation. ORDO scripts that load this file can call
# ordo_agent_config_self_check to detect missing required fields early.
ordo_agent_config_self_check() {
  local missing=()
  local required_name
  for required_name in \
    ORDO_AGENT_DISPLAY_NAME \
    ORDO_AGENT_DESCRIPTION \
    ORDO_AGENT_LABEL \
    ORDO_AGENT_GITHUB_IDENTITY \
    ORDO_AGENT_DEFAULT_PROMPT_FILE \
    ORDO_AGENT_AUDIT_ROOT \
    ORDO_AGENT_VALIDATION_MODE
  do
    if [[ -z "${!required_name:-}" || "${!required_name}" == *"{{"* ]]; then
      missing+=("$required_name")
    fi
  done
  if [[ "${#ORDO_AGENT_ALLOWED_CONTROL_PLANE[@]}" -eq 0 ]]; then
    : # explicit empty allowed list is valid; agent is read-only
  fi
  if [[ "${#ORDO_AGENT_FORBIDDEN_ACTIONS[@]}" -eq 0 ]]; then
    missing+=("ORDO_AGENT_FORBIDDEN_ACTIONS")
  fi
  if [[ "${#missing[@]}" -gt 0 ]]; then
    printf 'agent config missing required values: %s\n' "${missing[*]}" >&2
    return 2
  fi
  return 0
}
