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
  "realisons-wp|realisons-wp"
)

# Add product configs for PRAXIS, LUMEN, or any other repo, then append them:
#   "praxis|/absolute/path/to/praxis.config.sh"
#   "lumen|/absolute/path/to/lumen.config.sh"
