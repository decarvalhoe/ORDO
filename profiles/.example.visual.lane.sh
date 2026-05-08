#!/usr/bin/env bash
# profiles/.example.visual.lane.sh — non-canonical example profile fragment.
#
# This file is NOT a canonical profile. It exists to document, as runnable
# bash, how an operator opts a project into the ORDO visual verification
# lane (#264). Source it from a real project profile or copy the relevant
# blocks; never reference this file directly from production scripts.
#
# Usage from a project profile:
#   source "$ORCH_PROFILES/visual-lane.sh"   # operator-owned override
# or, for a one-off shell session:
#   source profiles/.example.visual.lane.sh
#
# All values shown are operator-controlled. The lane is provider-neutral;
# nothing below should be treated as the only valid configuration.

# --- Required to enable the lane -------------------------------------------
# Set to your windowing-system display value. Empty = lane is silent.
# Example for X on this audited host: ":20".
export ORCH_VISUAL_DISPLAY="${ORCH_VISUAL_DISPLAY:-}"

# --- Optional: X authority cookie ------------------------------------------
# Set when X requires an explicit cookie (typical for Chrome Remote Desktop
# style sessions where DISPLAY is reused across users).
export ORCH_VISUAL_XAUTHORITY="${ORCH_VISUAL_XAUTHORITY:-}"

# --- Optional: display probe binary ----------------------------------------
# `xdpyinfo` is the X-specific reference probe. Operators on Wayland or
# other windowing systems should point this at the equivalent (`wlr-randr`,
# `swaymsg`, etc.). Leaving it default is correct on X hosts.
export ORCH_VISUAL_DISPLAY_PROBE="${ORCH_VISUAL_DISPLAY_PROBE:-xdpyinfo}"

# --- Optional: explicit browser/automation overrides -----------------------
# When unset, the lane probes a small candidate list (see lib/visual_lane.sh
# for defaults). Override only when the operator wants to pin a specific
# binary — pinning by version is the operator's responsibility.
export ORCH_VISUAL_BROWSER="${ORCH_VISUAL_BROWSER:-}"
export ORCH_VISUAL_AUTOMATION="${ORCH_VISUAL_AUTOMATION:-}"

# --- Optional: design-tool MCP hint ----------------------------------------
# Free-form string the lane echoes back so PR bodies can record which
# design MCP the run depended on (the lane does not introspect MCPs).
export ORCH_VISUAL_DESIGN_MCP_HINT="${ORCH_VISUAL_DESIGN_MCP_HINT:-}"

# --- Required: evidence directory outside any active worktree --------------
# The lane reports `evidence_dir_in_worktree=true` when this resolves under
# the current $PWD, which the dispatcher should treat as a hard error so
# screenshots cannot be committed by accident.
export ORCH_VISUAL_EVIDENCE_DIR="${ORCH_VISUAL_EVIDENCE_DIR:-$HOME/orch-visual-evidence}"

# --- Optional: viewport spec list ------------------------------------------
# Comma-separated `name:WIDTHxHEIGHT`. Override per-project if a brief
# requires extra viewports (e.g. tablet portrait).
export ORCH_VISUAL_VIEWPORTS="${ORCH_VISUAL_VIEWPORTS:-desktop:1280x800,mobile:390x844}"

# --- Optional: fallback policy ---------------------------------------------
# `skip` — the dispatch brief asks the agent to mark the visual step
#          SKIPPED with the unreadiness reason recorded.
# `headless` — fall back to a headless run that does not depend on $DISPLAY.
export ORCH_VISUAL_FALLBACK="${ORCH_VISUAL_FALLBACK:-skip}"

# --- Optional: link to a host-capability audit file ------------------------
# Surfaced under `audit.host_evidence` in the JSON report so PR reviewers
# can trace which host the run was supposed to use, without trusting the
# agent's self-report.
export ORCH_VISUAL_HOST_EVIDENCE="${ORCH_VISUAL_HOST_EVIDENCE:-}"
