#!/usr/bin/env bash
# examples/portfolio.config.sh - multi-product portfolio example.
#
# Format:
#   "product|project-config"
#
# Each project config remains independent. A physical pane can appear in more
# than one project config when that agent is allowed to switch products.

PORTFOLIO_NAME="rbok-suite"
PORTFOLIO_PROJECTS=(
  "rbok|rbok"
  "ordo|ordo"
  "nomos|nomos"
  "realisons-wordpress|realisons-wp"
  "praxis|praxis"
)

# Optional physical fleet matrix. When set, session-start preflight verifies
# every listed physical agent has a clone for every project, even when the
# project config only lists the currently assigned panes. Existing entries are
# matched by label or pane, so historical workdir names do not create duplicate
# clone proposals.
PORTFOLIO_ENSURE_AGENT_MATRIX=1
PORTFOLIO_FLEET_AGENTS=(
  "rbok-claude|rbok-claude:0.0"
  "rbok-codex|rbok-codex:0.0"
  "rbok-copilot|rbok-copilot:0.0"
  "rbok-cursor|rbok-cursor:0.0"
  "rbok-gemini|rbok-gemini:0.0"
  "claude|claude:0.0"
  "codex|codex:0.0"
  "copilot|copilot:0.0"
  "cursor|cursor:0.0"
  "gemini|gemini:0.0"
  "orch|orch:0.0"
)

# Higher numbers mean higher dispatch preference when several products are
# simultaneously ready. These POC defaults are intentionally explicit and can
# be tuned by operators without changing project configs.
PORTFOLIO_PRIORITIES=(
  "rbok=100"
  "ordo=90"
  "realisons-wordpress=70"
  "nomos=60"
  "praxis=50"
)

# Add product configs for LUMEN or any other repo, then append them:
#   "lumen|/absolute/path/to/lumen.config.sh"
#
# If repo names are custom or unknown, run portfolio_repo_bind_plan.sh before
# editing project configs. Bind plans are non-mutating and require explicit
# confirmation before session-start can clone anything:
#   PORTFOLIO_REPO_CANDIDATES=("lumen|RBOKproject/custom-lumen-core|main|/root/repos/lumen-%s")
#   PORTFOLIO_DISCOVERY_OWNERS=("RBOKproject")
