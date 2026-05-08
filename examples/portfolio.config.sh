#!/usr/bin/env bash
# Neutral multi-product portfolio example.
#
# Format:
#   "product|project-config"
#
# Each project config remains independent. A physical pane can appear in more
# than one project config when that agent is allowed to switch products.

PORTFOLIO_NAME="product-suite"
PORTFOLIO_PROJECTS=(
  "product-a|/profiles/product-a.config.sh"
  "product-b|/profiles/product-b.config.sh"
  "product-c|/profiles/product-c.config.sh"
  "product-web|/profiles/product-web.config.sh"
  "product-training|/profiles/product-training.config.sh"
)

PORTFOLIO_ENSURE_AGENT_MATRIX=1
PORTFOLIO_FLEET_AGENTS=(
  "planner|terminal-a:0.0"
  "builder|terminal-b:0.0"
  "reviewer|terminal-c:0.0"
)

PORTFOLIO_PRIORITIES=(
  "product-a=100"
  "product-b=80"
  "product-c=70"
  "product-web=60"
  "product-training=50"
)

# Add more project configs with neutral aliases or absolute paths:
#   "product-d|/absolute/path/to/product-d.config.sh"
#
# If repo names are custom or unknown, run portfolio_repo_bind_plan.sh before
# editing project configs. Bind plans are non-mutating and require explicit
# confirmation before session-start can clone anything:
#   PORTFOLIO_REPO_CANDIDATES=("product-d|example-org/custom-product-d|main|/workspace/product-d-%s")
#   PORTFOLIO_DISCOVERY_OWNERS=("example-org")
