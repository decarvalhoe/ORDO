#!/usr/bin/env bash
# examples/agents/codex.agent.example.sh
#
# Example agent profile for an OpenAI Codex CLI agent. This file is
# illustrative and is NOT loaded by ORDO. Copy it into your operator-owned
# profile location, replace placeholders, and reference it from your project
# profile.
#
# Doctrine: docs/external-agent-skills.md
# Template: templates/agents/agent-config.sh.tpl
# Default prompt template: templates/agents/local-skill-default.md
# Operator policy template: templates/agents/operator-policy.md
# Secrets policy: SECRETS.md (no token values may appear in this file).

ORDO_AGENT_DISPLAY_NAME="Codex Worker (example)"
ORDO_AGENT_DESCRIPTION="Local OpenAI Codex agent that prepares issue packs and hands them to the orchestrator."
ORDO_AGENT_LABEL="codex-worker"
ORDO_AGENT_GITHUB_IDENTITY="{{provider_account_for_codex_worker}}"

ORDO_AGENT_DEFAULT_PROMPT_FILE="{{absolute_path_to}}/local-skill-default.md"

ORDO_AGENT_ALLOWED_CONTROL_PLANE=(
  "issue-pack-handoff"
  "local-tests"
  "read-only-status"
)

ORDO_AGENT_FORBIDDEN_ACTIONS=(
  "remote-dispatch"
  "force-push"
  "merge-without-gate"
  "secret-write"
  "bypass-validation"
  "cross-product-mutation"
)

ORDO_AGENT_AUDIT_ROOT="{{absolute_path_to}}/audit/${ORDO_AGENT_LABEL}"

# External sidecar root (#372). Place agent runtime metadata outside every
# product worktree. Operators mirror any supported Codex CLI state/config
# override into their launcher environment; entries below are documentary only.
ORDO_AGENT_EXTERNAL_SIDECAR_ROOT="{{absolute_path_to}}/agent-state/${ORDO_AGENT_LABEL}"
ORDO_AGENT_EXTERNAL_SIDECAR_PATHS=(
  # "codex.config_dir=${ORDO_AGENT_EXTERNAL_SIDECAR_ROOT}/codex"
  # "codex.sessions_dir=${ORDO_AGENT_EXTERNAL_SIDECAR_ROOT}/codex/sessions"
)

ORDO_AGENT_VALIDATION_MODE="ci-delegated"

# Placeholder names only. Real values must be loaded from an operator-controlled
# credential source at runtime per SECRETS.md.
ORDO_AGENT_ENV_VARS=(
  "OPENAI_API_KEY"
  "GH_TOKEN_AGENT_${ORDO_AGENT_LABEL}"
)
