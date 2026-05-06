#!/usr/bin/env bash
# scripts/brief_agents.sh — render a templated dispatch markdown for an agent
# from the canonical dispatch template and a kvargs list.
#
# Usage:
#   brief_agents.sh <project_short|config_path> <agent> <ticket#> [k=v ...]
#   k=v keys recognized by the default template:
#     branch_slug=     (e.g. feat/sfi-01-source-segment-ledger)
#     base_sha=        (sha of main the agent must branch from)
#     scope_files=     (glob list of files agent may modify)
#     forbidden_files= (glob list agent must NOT touch)
#     validation=      (command the agent must run before commit)
#     summary=         (one-line ticket summary)
#
# Output: prints the rendered markdown to stdout. Caller pipes to a file
# under /tmp/dispatch-<agent>-<ticket>.md, then invokes dispatch_ticket.sh.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TK/lib/config_resolver.sh"

CFG_ARG=${1:?usage: brief_agents.sh <project> <agent> <ticket#> [k=v ...]}
AGENT=${2:?}
TICKET=${3:?}
shift 3
load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"
# worktree_helpers exposes agent_repo_root which is AGENT_PANES-aware.
# Sourced for the [repo] default below so SECONDARY labels (e.g. RBOK-claude-2)
# resolve to /root/repos/RBOK-claude-2 instead of ${PREFIX}${LABEL} (which
# would produce /root/repos/RBOK-RBOK-claude-2 for the no-prefix fleet).
# Defensive — the sanitized shell-test sandbox only copies brief_agents'
# historical deps, so we fall back below to the legacy concat when
# worktree_helpers is absent.
if [ -f "$TK/lib/worktree_helpers.sh" ]; then
  # shellcheck source=/dev/null
  source "$TK/lib/worktree_helpers.sh"
fi

TICKET_NUM=${TICKET#\#}
TEMPLATE="${DISPATCH_TEMPLATE:-$TK/templates/dispatch-canonical.md.tpl}"
[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE" >&2; exit 1; }

# Default values (overridable via kv args).
declare -A K=(
  [agent]="$AGENT"
  [ticket]="$TICKET_NUM"
  [project]="$PROJECT"
  [repo]="$(if declare -F agent_repo_root >/dev/null 2>&1; then agent_repo_root "$AGENT"; else printf '%s%s' "${AGENT_REPO_PREFIX:-}" "$AGENT"; fi)"
  [orch_remote]="${SUPERVISOR_REPO:-orchestrator}"
  [default_branch]="${DEFAULT_BRANCH:-main}"
  [branch_slug]="feat/${PROJECT}-ticket-${TICKET_NUM}"
  [base_sha]="HEAD"
  [scope_files]=""
  [forbidden_files]="cli/internal/app/app.go"
  [validation]=""
  [summary]=""
  [gh_repo]="$GH_REPO"
  [project_meta_context]="$(state_dir)/project_meta_context.md"
)

# Override via k=v args.
for kv in "$@"; do
  case "$kv" in
    *=*) K[${kv%%=*}]="${kv#*=}" ;;
    *)   echo "ignoring non-kv arg: $kv" >&2 ;;
  esac
done

# Render template by substitution.
render() {
  local content val
  content=$(<"$TEMPLATE")
  for k in "${!K[@]}"; do
    # bash 5.2+ interprets `&` in the replacement of ${var//pat/repl} as
    # "the matched pattern". A value containing `&&` therefore expands to
    # `{{key}}{{key}}` instead of being inserted literally. Escape `&` in
    # the value so it's treated as a literal ampersand on bash 5.2+ (and
    # is harmless on earlier versions, where `\&` was already literal).
    val=${K[$k]//&/\\&}
    content=${content//\{\{${k}\}\}/$val}
  done
  printf '%s\n' "$content"
}

render
