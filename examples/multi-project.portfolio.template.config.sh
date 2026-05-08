#!/usr/bin/env bash
# examples/multi-project.portfolio.template.config.sh — generic, vendor-neutral
# template for the multi-project onboarding extension (#252).
#
# This file is a TEMPLATE: rename it, replace placeholders, and check it
# into your operator profile area. It is NOT a working ORDO portfolio
# config — it documents the field shapes expected by
# scripts/multi_project_onboarding.sh and scripts/guided_onboarding.sh.
#
# How this template differs from examples/*.config.sh in this repo:
#   - examples/portfolio.config.sh, examples/ordo.config.sh, etc. are
#     concrete RBOKproject reference fixtures that ship with ORDO.
#   - This template is the starting point for any operator (internal
#     ORDO operator OR an external agent contributing to a multi-project
#     fleet) who is wiring up onboarding for projects ORDO has never
#     seen before.
#
# Required runtime root layout (per project, AC #5 of issue #252):
#   <runtime-root>/
#     cache/         derived data, indexes, downloaded artifacts
#     repos/         git checkouts, one subdir per agent label
#     profiles/      generated onboarding profiles + project configs
#     logs/          per-project audit-able logs
#     state/         orch state JSON (assignments, dispatch records)
#     launch/        reproducible launch scripts (tmux/agent boot)
#     audit/         append-only audit trail per project
#     orchestrator/  orchestrator-private state, never read by agents
#
# When a project sets ``validation_mode=gxp`` the operator MUST keep
# audit/ append-only and rotate logs/ on a documented schedule. When a
# project sets ``validation_mode=dev`` (normal-dev) those constraints
# are relaxed; the layout is still recommended but the audit subdir
# can hold rolling buffers.

PORTFOLIO_NAME="example-portfolio"
PORTFOLIO_OPERATOR_CLASS="internal"   # internal | external
PORTFOLIO_RUNTIME_ROOT_BASE="/var/lib/ordo/example-portfolio"

# Each entry maps an alias to a project config that the operator will
# author from examples/ordo.config.sh (or any neutral starting point).
# The aliases are the ONLY identifiers used by ORDO state directories;
# they MUST be unique and short.
PORTFOLIO_PROJECTS=(
  "alpha|${PORTFOLIO_RUNTIME_ROOT_BASE}/profiles/alpha.config.sh"
  "beta|${PORTFOLIO_RUNTIME_ROOT_BASE}/profiles/beta.config.sh"
)

# Per-project metadata consumed by guided_onboarding.sh / multi_project_onboarding.sh.
# These map 1:1 to the JSON manifest fields the wrapper expects.
PORTFOLIO_PROJECT_DEFAULT_BRANCHES=(
  "alpha=main"
  "beta=trunk"
)
PORTFOLIO_PROJECT_VALIDATION_MODES=(
  "alpha=gxp"     # validated workflow (audit append-only, evidence-first)
  "beta=dev"      # normal-dev workflow
)
PORTFOLIO_PROJECT_AGENT_LABELS=(
  "alpha=primary,review"
  "beta=primary"
)

# Internal vs external operator guidance (AC #6 of issue #252).
# Internal operators run ORDO from inside the org's network and can
# resolve identity bindings from a private identity store. External
# agents are expected to:
#   - bring their own gh/CLI credentials with `gh auth status`,
#   - declare `validation_mode=dev` unless explicitly granted GxP scope,
#   - never bind their identity to internal-only repository roles.
PORTFOLIO_EXTERNAL_AGENT_HANDOFF=(
  "support_email=ops-handoff@example.invalid"
  "evidence_drop=${PORTFOLIO_RUNTIME_ROOT_BASE}/audit/external-handoff"
)

# Reminder: this is a template. Replace every "example", "alpha",
# "beta", and PORTFOLIO_RUNTIME_ROOT_BASE value before treating this as
# a real config. See docs/onboarding-multi-project.md for the operator
# walkthrough.
