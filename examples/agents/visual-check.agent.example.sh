#!/usr/bin/env bash
# examples/agents/visual-check.agent.example.sh
#
# Example agent profile for an opt-in visual-check agent that participates
# in the visual verification lane defined under issue #264. The visual lane
# is opt-in via ORCH_VISUAL_DISPLAY: when the variable is unset, this agent
# is a silent no-op. This file is illustrative and is NOT loaded by ORDO.
# Copy it into your operator-owned profile location, replace placeholders,
# and reference it from your project profile.
#
# Doctrine: docs/external-agent-skills.md
# Multi-agent docs pack: docs/templates/multi-agent/
# Template: templates/agents/agent-config.sh.tpl
# Default prompt template: templates/agents/local-skill-default.md
# Operator policy template: templates/agents/operator-policy.md
# Roster template: templates/agents/multi-agent-roster.md
# Secrets policy: SECRETS.md (no token values may appear in this file).

ORDO_AGENT_DISPLAY_NAME="Visual Check Worker (example)"
ORDO_AGENT_DESCRIPTION="Opt-in visual-check agent for the #264 visual lane; no-op when ORCH_VISUAL_DISPLAY is unset."
ORDO_AGENT_LABEL="visual-check-worker"
ORDO_AGENT_GITHUB_IDENTITY="{{provider_account_for_visual_check_worker}}"

ORDO_AGENT_DEFAULT_PROMPT_FILE="{{absolute_path_to}}/local-skill-default.md"

# Visual-check agents read the rendered UI but do not dispatch remote work.
# They share the local-skill-default control plane (issue-pack-handoff +
# read-only-status) and add the visual-lane probe surface as an explicit
# entry. The probe surface is itself opt-in via ORCH_VISUAL_DISPLAY.
ORDO_AGENT_ALLOWED_CONTROL_PLANE=(
  "issue-pack-handoff"
  "local-tests"
  "read-only-status"
  "visual-lane-probe"
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

ORDO_AGENT_VALIDATION_MODE="ci-delegated"

# --- Visual lane opt-in --------------------------------------------------
#
# The visual verification lane (issue #264) is intentionally opt-in. When
# ORCH_VISUAL_DISPLAY is unset, this agent reports "visual lane disabled"
# and stays a silent no-op so it does not interfere with deployments that
# do not have a configured display surface. Operators who want to enable
# the lane export ORCH_VISUAL_DISPLAY in their operator-controlled
# environment (typical default: ":0"). The corresponding XAUTHORITY path
# is set the same way; never hardcode it in this example.

: "${ORCH_VISUAL_DISPLAY:=}"
: "${ORCH_VISUAL_XAUTHORITY:=}"

# Optional probe binary path used by scripts/visual_lane_probe.sh once
# issue #264 ships. Operators override per host. Leave empty to defer to
# the toolkit defaults.
: "${ORCH_VISUAL_PROBE_BIN:=}"

# Placeholder names only. Real values must be loaded from an
# operator-controlled credential source at runtime per SECRETS.md.
ORDO_AGENT_ENV_VARS=(
  "GH_TOKEN_AGENT_${ORDO_AGENT_LABEL}"
  "ORCH_VISUAL_DISPLAY"
  "ORCH_VISUAL_XAUTHORITY"
  "ORCH_VISUAL_PROBE_BIN"
)

# Self-check shim: when the visual lane is not opted in, log and exit
# cleanly so callers can compose this agent with a portfolio that may or
# may not have a display surface.
ordo_visual_check_lane_enabled() {
  if [[ -z "${ORCH_VISUAL_DISPLAY}" ]]; then
    return 1
  fi
  return 0
}
