#!/usr/bin/env bash
# scripts/ordo.sh — unified ORDO CLI entry point (epic #806, child #809).
#
# Usage:
#   ordo.sh <command> [--json] [args...]
#   ordo.sh help [<command> [<variant-flag>]]
#   ordo.sh completion bash
#
# Commands:
#   status    fleet status (agent_pool_status.sh); --loop -> orch_ctl.sh status;
#             --portfolio -> portfolio_status.sh
#   plan      dispatch_plan.sh
#   dispatch  dispatch_ticket.sh; --wave -> dispatch_wave.sh
#   watch     smart_poll_agents.sh; --prs -> pr_block_signals.sh
#   recover   recover.sh
#   merge     pr_merge_wave.sh; --portfolio -> portfolio_auto_merge.sh
#   resume    not implemented yet (scheduler, #810) -> exit 6 + error object
#   cancel    not implemented yet (scheduler, #810) -> exit 6 + error object
#   approve   not implemented yet (approvals, #812) -> exit 6 + error object
#   help, version, completion
#
# Every routed command passes its arguments through verbatim to the existing
# script; direct invocation of those scripts keeps working unchanged. `--json`
# (anywhere in argv) selects machine-readable output. Errors are one JSON line
# on stderr and follow the exit-code table in docs/exit-codes.md ("Agentic
# control plane" section). Full reference: docs/architecture/cli.md.
#
# `ordo` is expected to be a symlink or shell alias to this script:
#   ln -s "$PWD/scripts/ordo.sh" ~/.local/bin/ordo
set -euo pipefail
TK="${TK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export TK

# shellcheck source=lib/ordo_cli.sh
source "$TK/lib/ordo_cli.sh"

ordo_cli_main "$@"
