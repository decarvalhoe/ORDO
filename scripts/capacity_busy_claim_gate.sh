#!/usr/bin/env bash
# scripts/capacity_busy_claim_gate.sh — runtime enforcement of the
# capacity busy-claim rule (#283).
#
# The 2026-05-08 incident saw the orchestrator narrate
#   "All 11 agents now busy (8 ORDO + 2 RBOK + 1 supervisor)."
# while structured state showed 3 free ORDO agents, 2 stale RBOK
# assignment records pointing at parkable PR owners, and a supervisor
# session conflated with the agent matrix. PR #299 derived
# `capacity_report.busy_claim_valid` from structured state but did NOT
# add an enforcement path — the rule lived only as a textual clause in
# `docs/orchestrator-injected-rules.md`. This gate closes that gap.
#
# Usage:
#   bash scripts/capacity_busy_claim_gate.sh <portfolio-config>
#                                            [--require-busy-claim-valid]
#                                            [--context <tag>]
#                                            [--json]
#
# Default mode (no `--require-busy-claim-valid`): print the rollup and
# exit 0. Useful for operators who just want to inspect capacity
# without short-circuiting their pipeline.
#
# `--require-busy-claim-valid` is the orchestrator-narrative gate. The
# script consumes `portfolio_status.sh --json`, aggregates per-project
# `capacity_report` blocks into a portfolio-wide verdict, emits a
# structured `CAPACITY_BUSY_CLAIM` audit line, and exits with
# `ORCH_CAPACITY_BUSY_CLAIM_REFUSED_EXIT_CODE` (default 87) when ANY
# project still has free, parkable, or switchable capacity. The
# orchestrator MUST call this gate (or call
# `capacity_report_busy_claim_assert` from the lib) before narrating
# "all agents busy"; refusal evidence becomes durable in the audit
# trail and is replayable from the rollup.
#
# `--json` prints the aggregated rollup JSON instead of the
# human-readable text rollup. The exit-code contract is the same.

set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../lib/portfolio_config.sh
source "$TK/lib/portfolio_config.sh"
# Source the project audit pipeline when PROJECT is set so the
# CAPACITY_BUSY_CLAIM line lands in the per-project log file. When
# PROJECT is unset (operator running without a config sourced first)
# the lib's assert function falls back to a stderr `printf` emitter,
# which keeps the gate useful for ad-hoc inspection.
if [[ -n "${PROJECT:-}" ]]; then
  # shellcheck source=../lib/audit_log.sh
  source "$TK/lib/audit_log.sh"
fi
# shellcheck source=../lib/capacity_report.sh
source "$TK/lib/capacity_report.sh"

PORTFOLIO_ARG=${1:?usage: capacity_busy_claim_gate.sh <portfolio-config> [--require-busy-claim-valid] [--context <tag>] [--json]}
shift

REQUIRE_VALID=0
CONTEXT_TAG="capacity_busy_claim_gate"
EMIT_JSON=0
PORTFOLIO_FIXTURE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --require-busy-claim-valid)
      REQUIRE_VALID=1
      shift
      ;;
    --context)
      CONTEXT_TAG=${2:?--context needs a value}
      shift 2
      ;;
    --json)
      EMIT_JSON=1
      shift
      ;;
    --portfolio-json)
      # Test-only: skip running portfolio_status.sh and consume the
      # JSON document at the named path. Lets bats / shell tests stage
      # synthetic portfolio shapes without forking portfolio_status.
      PORTFOLIO_FIXTURE=${2:?--portfolio-json needs a path}
      shift 2
      ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'capacity_busy_claim_gate: unknown arg %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ -n "$PORTFOLIO_FIXTURE" ]]; then
  if [[ ! -s "$PORTFOLIO_FIXTURE" ]]; then
    printf 'capacity_busy_claim_gate: fixture not found: %s\n' "$PORTFOLIO_FIXTURE" >&2
    exit 2
  fi
  PORTFOLIO_JSON=$(cat "$PORTFOLIO_FIXTURE")
else
  PORTFOLIO_JSON=$(bash "$TK/scripts/portfolio_status.sh" "$PORTFOLIO_ARG" --json)
fi

if [[ "$EMIT_JSON" -eq 1 ]]; then
  # JSON-only stdout — keep the channel parser-friendly. Strict mode
  # still emits the audit line and propagates the refusal exit code,
  # but suppresses the human-readable rollup text so the JSON is the
  # only document on stdout.
  capacity_report_busy_claim_aggregate "$PORTFOLIO_JSON"
  if [[ "$REQUIRE_VALID" -eq 1 ]]; then
    set +e
    capacity_report_busy_claim_assert "$PORTFOLIO_JSON" "$CONTEXT_TAG" >/dev/null
    rc=$?
    set -e
    exit "$rc"
  fi
  exit 0
fi

if [[ "$REQUIRE_VALID" -eq 1 ]]; then
  capacity_report_busy_claim_assert "$PORTFOLIO_JSON" "$CONTEXT_TAG"
  exit $?
fi

# Default mode: render the rollup and exit 0 — this is the inspect-only
# call surface for operators.
capacity_report_busy_claim_render "$PORTFOLIO_JSON"
