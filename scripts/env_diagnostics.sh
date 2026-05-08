#!/usr/bin/env bash
# scripts/env_diagnostics.sh — operator preflight for ORDO end-to-end
# environment control (ticket #255).
#
# Read-only by default: every probe runs under a strict timeout and
# performs only inspect/list operations. There is no `--apply` or
# `--mutate` mode here — when a mutating action is needed, use the
# matching ORDO script:
#   - tmux session creation        : scripts/portfolio_session_start.sh
#   - workdir cleanup              : scripts/audit_state.sh / git directly
#   - Docker control               : docker compose / docker CLI directly
#   - GitHub auth refresh          : gh auth login / gh auth refresh
#   - dispatch (matrix gate)       : scripts/dispatch_matrix.sh +
#                                    scripts/dispatch_ticket.sh
#
# Subcommands:
#   preflight [--text|--json] [--repo <gh-repo>] [--api <url>] [--clones-root <dir>]
#       Runs every probe and prints a structured report.
#   tmux
#       tmux shape only (sessions, windows, live session:0.0 target).
#   pane <session:0.0>
#       pane_current_command + pane_current_path.
#   load
#       uptime + load averages.
#   memory
#       /proc/meminfo summary.
#   disk [path...]
#       df for given paths (default: ORCH_ENV_DIAG_DISK_PATHS, default `/`).
#   docker
#       Docker daemon + running containers.
#   api <url> [timeout-sec]
#       Bounded HTTP HEAD/GET probe.
#   gh-auth
#       gh auth status (host/login).
#   gh-repo <repo>
#       Open issue/PR counts + non-default-base PR detection.
#   clones <root>
#       Dirty clones under <root> (depth-bounded).
#   audit-name <kind> <id>
#       Print canonical audit artifact path for a kind in
#       {snapshot, ledger, matrix, monitor}.
#
# Exit code is always 0 unless the command line itself is invalid; the
# preflight is informational. Use the matching gate (e.g.
# host_load_gate, dispatch_matrix gate) for refusal.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# shellcheck source=../lib/env_diagnostics.sh
source "$TK/lib/env_diagnostics.sh"

usage() {
  sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'
}

SUB=${1:-}
[[ -n "$SUB" ]] || { usage; exit 2; }
shift

FORMAT=text
GH_REPO_ARG=""
API_URL_ARG=""
CLONES_ROOT_ARG=""
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) FORMAT=json; shift ;;
    --text) FORMAT=text; shift ;;
    --repo)
      GH_REPO_ARG=${2:?missing value for --repo}
      shift 2
      ;;
    --api)
      API_URL_ARG=${2:?missing value for --api}
      shift 2
      ;;
    --clones-root)
      CLONES_ROOT_ARG=${2:?missing value for --clones-root}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

# Convert a flat KEY=value stream into JSON. Lines without `=` are
# ignored so probes stay forward-compatible.
emit_json() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '{"error":"jq-required-for-json-output"}\n'
    return 0
  fi
  jq -Rn '
    [inputs | select(test("=")) | capture("^(?<k>[^=]+)=(?<v>.*)$")]
    | reduce .[] as $row ({}; . + { ($row.k): $row.v })
  '
}

cmd_preflight() {
  {
    _env_diag_safe_emit preflight.started_at "$(date -u +%FT%TZ)"
    env_diag_tmux_shape
    env_diag_server_load
    env_diag_memory
    env_diag_disk
    env_diag_docker_health
    if [[ -n "$API_URL_ARG" ]]; then
      env_diag_api_health "$API_URL_ARG"
    else
      _env_diag_safe_emit api.status not-requested
    fi
    env_diag_github_auth
    if [[ -n "$GH_REPO_ARG" ]]; then
      env_diag_open_issues_prs "$GH_REPO_ARG"
    else
      _env_diag_safe_emit gh.repo not-requested
    fi
    if [[ -n "$CLONES_ROOT_ARG" ]]; then
      env_diag_dirty_clones "$CLONES_ROOT_ARG"
    else
      _env_diag_safe_emit dirty.status not-requested
    fi
    _env_diag_safe_emit preflight.finished_at "$(date -u +%FT%TZ)"
  } | {
    if [[ "$FORMAT" == json ]]; then
      emit_json
    else
      cat
    fi
  }
}

cmd_tmux() { env_diag_tmux_shape; }
cmd_pane() {
  local target=${EXTRA_ARGS[0]:-}
  [[ -n "$target" ]] || { usage; exit 2; }
  env_diag_pane_commands "$target"
}
cmd_load() { env_diag_server_load; }
cmd_memory() { env_diag_memory; }
cmd_disk() {
  if [[ "${#EXTRA_ARGS[@]}" -gt 0 ]]; then
    env_diag_disk "${EXTRA_ARGS[@]}"
  else
    env_diag_disk
  fi
}
cmd_docker() { env_diag_docker_health; }
cmd_api() {
  local url=${EXTRA_ARGS[0]:-}
  local t=${EXTRA_ARGS[1]:-}
  [[ -n "$url" ]] || { usage; exit 2; }
  if [[ -n "$t" ]]; then
    env_diag_api_health "$url" "$t"
  else
    env_diag_api_health "$url"
  fi
}
cmd_gh_auth() { env_diag_github_auth; }
cmd_gh_repo() {
  local repo=${EXTRA_ARGS[0]:-}
  [[ -n "$repo" ]] || { usage; exit 2; }
  env_diag_open_issues_prs "$repo"
}
cmd_clones() {
  local root=${EXTRA_ARGS[0]:-}
  [[ -n "$root" ]] || { usage; exit 2; }
  env_diag_dirty_clones "$root"
}
cmd_audit_name() {
  local kind=${EXTRA_ARGS[0]:-}
  local id=${EXTRA_ARGS[1]:-}
  [[ -n "$kind" && -n "$id" ]] || { usage; exit 2; }
  env_diag_audit_artifact_path "$kind" "$id"
}

case "$SUB" in
  preflight)  cmd_preflight ;;
  tmux)       cmd_tmux ;;
  pane)       cmd_pane ;;
  load)       cmd_load ;;
  memory)     cmd_memory ;;
  disk)       cmd_disk ;;
  docker)     cmd_docker ;;
  api)        cmd_api ;;
  gh-auth)    cmd_gh_auth ;;
  gh-repo)    cmd_gh_repo ;;
  clones)     cmd_clones ;;
  audit-name) cmd_audit_name ;;
  -h|--help)  usage; exit 0 ;;
  *)          usage; exit 2 ;;
esac
