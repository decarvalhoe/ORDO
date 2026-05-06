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
