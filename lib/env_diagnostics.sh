#!/usr/bin/env bash
# lib/env_diagnostics.sh — read-only end-to-end environment probes for ORDO.
#
# Aggregates the existing host_health / host_load_gate / process_safety /
# portfolio_status / tmux_helpers signals plus a few extra lightweight
# probes (Docker health, API health, GitHub auth, issue/PR counts, dirty
# clones, non-default-base PRs) into a single operator preflight that
# answers ticket #255 acceptance: tmux shape, pane commands, current
# paths, server load, memory, disk, Docker health, API health, GitHub
# auth, open issues/PRs, and dirty clones.
#
# Read-only by design: every probe runs under a strict timeout and
# performs only inspect/list operations. Mutating actions are opt-in
# via dedicated subcommands on the matching CLIs and are NOT exposed by
# this library. Use this lib to build operator dashboards/preflights;
# when you need a refusal gate use `lib/host_load_gate.sh` instead.
#
# Functions:
#   env_diag_tmux_shape                              — list sessions / windows / live target
#   env_diag_pane_commands <session:0.0>             — dump pane_current_command + path
#   env_diag_server_load                             — uptime + load avg
#   env_diag_memory                                  — total/avail mem MB
#   env_diag_disk [path...]                          — df -P for given paths
#   env_diag_docker_health                           — running container count, daemon status
#   env_diag_api_health <url> [timeout_sec]          — bounded HEAD probe
#   env_diag_github_auth                             — gh auth status (host/login/scopes)
#   env_diag_open_issues_prs <repo>                  — open-issue/PR counts + non-default-base PRs
#   env_diag_dirty_clones <root>                     — git checkouts under root with porcelain output
#   env_diag_audit_artifact_path <kind> <id>         — canonical path for snapshots/ledgers/matrices/monitor outputs
#
# Each function prints structured `KEY=value` lines to stdout and at
# most one human hint per failed probe to stderr. Functions return 0
# even when a probe is missing/unavailable so the aggregator can keep
# going; callers inspect the structured output for status fields.

if [[ -n "${ORCH_ENV_DIAGNOSTICS_LIB_LOADED:-}" ]]; then
  return 0
fi
ORCH_ENV_DIAGNOSTICS_LIB_LOADED=1

: "${ORCH_ENV_DIAG_TIMEOUT_SEC:=3}"
: "${ORCH_ENV_DIAG_DISK_PATHS:=/}"
: "${ORCH_ENV_DIAG_API_TIMEOUT_SEC:=3}"
: "${ORCH_ENV_DIAG_DIRTY_MAX_DEPTH:=3}"
: "${ORCH_ENV_DIAG_AUDIT_BASE:=}"

_env_diag_run_timeout() {
  local seconds=${1:-$ORCH_ENV_DIAG_TIMEOUT_SEC}
  shift || true
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

_env_diag_safe_emit() {
  # Squash newlines + tabs in values so a probe stays one line.
  local key=$1
  local value=${2-}
  value=${value//$'\n'/ }
  value=${value//$'\t'/ }
  printf '%s=%s\n' "$key" "$value"
}

env_diag_tmux_shape() {
  if ! command -v tmux >/dev/null 2>&1; then
    _env_diag_safe_emit tmux.status missing
    return 0
  fi
  local sessions
  sessions=$(_env_diag_run_timeout "$ORCH_ENV_DIAG_TIMEOUT_SEC" \
    tmux list-sessions -F '#{session_name}|#{session_windows}|#{?session_attached,attached,detached}' \
    2>/dev/null || true)
  if [[ -z "$sessions" ]]; then
    _env_diag_safe_emit tmux.status no-sessions
    return 0
  fi
  _env_diag_safe_emit tmux.status ok
  local count=0 line name windows attached
  while IFS='|' read -r name windows attached; do
    [[ -n "$name" ]] || continue
    count=$((count + 1))
    _env_diag_safe_emit "tmux.session.${count}.name" "$name"
    _env_diag_safe_emit "tmux.session.${count}.windows" "$windows"
    _env_diag_safe_emit "tmux.session.${count}.attached" "$attached"
    # Per epic #249 finding: trust live target probing, not stale window
    # counts. Probe the canonical session:0.0 pane explicitly.
    local live_path
    live_path=$(_env_diag_run_timeout "$ORCH_ENV_DIAG_TIMEOUT_SEC" \
      tmux display-message -p -t "${name}:0.0" -F '#{pane_current_path}' \
      2>/dev/null || true)
    if [[ -n "$live_path" ]]; then
      _env_diag_safe_emit "tmux.session.${count}.live_target" "${name}:0.0"
      _env_diag_safe_emit "tmux.session.${count}.pane_current_path" "$live_path"
    else
      _env_diag_safe_emit "tmux.session.${count}.live_target" "${name}:0.0:unreachable"
    fi
  done <<< "$sessions"
  _env_diag_safe_emit tmux.session.count "$count"
}

env_diag_pane_commands() {
  local target=${1:?usage: env_diag_pane_commands <session:0.0>}
  if ! command -v tmux >/dev/null 2>&1; then
    _env_diag_safe_emit pane.status tmux-missing
    return 0
  fi
  local cmd path
  cmd=$(_env_diag_run_timeout "$ORCH_ENV_DIAG_TIMEOUT_SEC" \
    tmux display-message -p -t "$target" -F '#{pane_current_command}' \
    2>/dev/null || true)
  path=$(_env_diag_run_timeout "$ORCH_ENV_DIAG_TIMEOUT_SEC" \
    tmux display-message -p -t "$target" -F '#{pane_current_path}' \
    2>/dev/null || true)
  if [[ -z "$cmd" && -z "$path" ]]; then
    _env_diag_safe_emit "pane.${target}.status" unreachable
    return 0
  fi
  _env_diag_safe_emit "pane.${target}.status" ok
  _env_diag_safe_emit "pane.${target}.command" "${cmd:-unknown}"
  _env_diag_safe_emit "pane.${target}.path" "${path:-unknown}"
}

env_diag_server_load() {
  local uptime_line
  uptime_line=$(_env_diag_run_timeout "$ORCH_ENV_DIAG_TIMEOUT_SEC" uptime 2>/dev/null || true)
  if [[ -z "$uptime_line" ]]; then
    _env_diag_safe_emit load.status unavailable
    return 0
  fi
  _env_diag_safe_emit load.status ok
  _env_diag_safe_emit load.uptime "$uptime_line"
  # Parse load averages: "load average: 0.10, 0.20, 0.30"
  local la
  la=$(awk -F'load averages?:' '{print $2}' <<< "$uptime_line" | sed 's/^[[:space:]]*//')
  _env_diag_safe_emit load.averages "${la:-unknown}"
}

env_diag_memory() {
  if [[ ! -r /proc/meminfo ]]; then
    _env_diag_safe_emit memory.status unavailable
    return 0
  fi
  local total_kb avail_kb
  total_kb=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)
  avail_kb=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)
  _env_diag_safe_emit memory.status ok
  _env_diag_safe_emit memory.total_mb "$(( ${total_kb:-0} / 1024 ))"
  _env_diag_safe_emit memory.available_mb "$(( ${avail_kb:-0} / 1024 ))"
}

env_diag_disk() {
  local -a paths=()
  if [[ "$#" -gt 0 ]]; then
    paths=("$@")
  else
    IFS=':' read -ra paths <<< "$ORCH_ENV_DIAG_DISK_PATHS"
  fi
  if ! command -v df >/dev/null 2>&1; then
    _env_diag_safe_emit disk.status df-missing
    return 0
  fi
  _env_diag_safe_emit disk.status ok
  local idx=0 path line size used avail pct mount
  for path in "${paths[@]}"; do
    [[ -n "$path" ]] || continue
    idx=$((idx + 1))
    line=$(_env_diag_run_timeout "$ORCH_ENV_DIAG_TIMEOUT_SEC" \
      df -P -k "$path" 2>/dev/null | awk 'NR==2 { print $2,$3,$4,$5,$6 }' || true)
    if [[ -z "$line" ]]; then
      _env_diag_safe_emit "disk.${idx}.path" "$path"
      _env_diag_safe_emit "disk.${idx}.status" unavailable
      continue
    fi
    read -r size used avail pct mount <<< "$line"
    _env_diag_safe_emit "disk.${idx}.path" "$path"
    _env_diag_safe_emit "disk.${idx}.mount" "${mount:-unknown}"
    _env_diag_safe_emit "disk.${idx}.size_mb" "$(( ${size:-0} / 1024 ))"
    _env_diag_safe_emit "disk.${idx}.used_mb" "$(( ${used:-0} / 1024 ))"
    _env_diag_safe_emit "disk.${idx}.avail_mb" "$(( ${avail:-0} / 1024 ))"
    _env_diag_safe_emit "disk.${idx}.used_pct" "${pct%%%*}"
  done
  _env_diag_safe_emit disk.count "$idx"
}

env_diag_docker_health() {
  if ! command -v docker >/dev/null 2>&1; then
    _env_diag_safe_emit docker.status missing
    return 0
  fi
  local info_rc=1 info_out
  info_out=$(_env_diag_run_timeout "$ORCH_ENV_DIAG_TIMEOUT_SEC" \
    docker info --format '{{.ServerVersion}}' 2>/dev/null) && info_rc=0
  if [[ "$info_rc" -ne 0 ]]; then
    _env_diag_safe_emit docker.status daemon-unreachable
    return 0
  fi
  _env_diag_safe_emit docker.status ok
  _env_diag_safe_emit docker.server_version "${info_out:-unknown}"
  local running
  running=$(_env_diag_run_timeout "$ORCH_ENV_DIAG_TIMEOUT_SEC" \
    docker ps --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ' || printf '0')
  _env_diag_safe_emit docker.running_containers "${running:-0}"
}

env_diag_api_health() {
  local url=${1:?usage: env_diag_api_health <url> [timeout_sec]}
  local timeout_sec=${2:-$ORCH_ENV_DIAG_API_TIMEOUT_SEC}
  if ! command -v curl >/dev/null 2>&1; then
    _env_diag_safe_emit api.status curl-missing
    return 0
  fi
  local code
  code=$(_env_diag_run_timeout "$timeout_sec" \
    curl -sS -o /dev/null -w '%{http_code}' --max-time "$timeout_sec" \
    -X GET "$url" 2>/dev/null || printf '000')
  _env_diag_safe_emit api.url "$url"
  _env_diag_safe_emit api.http_code "${code:-000}"
  if [[ "$code" =~ ^[12] ]]; then
    _env_diag_safe_emit api.status ok
  elif [[ "$code" == "000" ]]; then
    _env_diag_safe_emit api.status unreachable
  else
    _env_diag_safe_emit api.status non-2xx
  fi
}

env_diag_github_auth() {
  if ! command -v gh >/dev/null 2>&1; then
    _env_diag_safe_emit gh.status missing
    return 0
  fi
  local out rc=1
  out=$(_env_diag_run_timeout "$ORCH_ENV_DIAG_TIMEOUT_SEC" gh auth status 2>&1) && rc=0
  if [[ "$rc" -ne 0 ]]; then
    _env_diag_safe_emit gh.status not-authenticated
    return 0
  fi
  _env_diag_safe_emit gh.status authenticated
  local login host
  login=$(grep -oE 'account [^ ]+' <<< "$out" | head -1 | awk '{print $2}')
  host=$(grep -oE 'Logged in to [^ ]+' <<< "$out" | head -1 | awk '{print $4}')
  _env_diag_safe_emit gh.login "${login:-unknown}"
  _env_diag_safe_emit gh.host "${host:-github.com}"
}

env_diag_open_issues_prs() {
  local repo=${1:?usage: env_diag_open_issues_prs <repo>}
  if ! command -v gh >/dev/null 2>&1; then
    _env_diag_safe_emit gh.repo "$repo"
    _env_diag_safe_emit gh.status missing
    return 0
  fi
  _env_diag_safe_emit gh.repo "$repo"
  local issues_count prs_default_count prs_total prs_non_default
  issues_count=$(_env_diag_run_timeout "$ORCH_ENV_DIAG_TIMEOUT_SEC" \
    gh issue list --repo "$repo" --state open --limit 1000 --json number 2>/dev/null \
    | (command -v jq >/dev/null 2>&1 && jq 'length' || wc -l) 2>/dev/null \
    || printf '0')
  prs_total=$(_env_diag_run_timeout "$ORCH_ENV_DIAG_TIMEOUT_SEC" \
    gh pr list --repo "$repo" --state open --limit 1000 --json number,baseRefName 2>/dev/null \
    || printf '[]')
  if command -v jq >/dev/null 2>&1; then
    local default_branch
    default_branch=$(_env_diag_run_timeout "$ORCH_ENV_DIAG_TIMEOUT_SEC" \
      gh repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name' \
      2>/dev/null || printf 'main')
    prs_default_count=$(jq --arg b "${default_branch:-main}" \
      '[.[] | select(.baseRefName == $b)] | length' <<< "$prs_total" 2>/dev/null \
      || printf '0')
    prs_non_default=$(jq --arg b "${default_branch:-main}" \
      '[.[] | select(.baseRefName != $b)] | length' <<< "$prs_total" 2>/dev/null \
      || printf '0')
    _env_diag_safe_emit gh.default_branch "${default_branch:-main}"
  else
    prs_default_count=$(printf '%s' "$prs_total" | grep -c '"number"' 2>/dev/null || printf '0')
    prs_non_default=0
    _env_diag_safe_emit gh.default_branch unknown
  fi
  _env_diag_safe_emit gh.issues_open "${issues_count:-0}"
  _env_diag_safe_emit gh.prs_open_default_base "${prs_default_count:-0}"
  _env_diag_safe_emit gh.prs_open_non_default_base "${prs_non_default:-0}"
}

# Walk a root looking for git checkouts that have an unclean porcelain.
# Bounded by ORCH_ENV_DIAG_DIRTY_MAX_DEPTH (default 3) so a misconfigured
# root can't sweep an entire filesystem.
env_diag_dirty_clones() {
  local root=${1:?usage: env_diag_dirty_clones <root>}
  if [[ ! -d "$root" ]]; then
    _env_diag_safe_emit dirty.status root-missing
    return 0
  fi
  if ! command -v git >/dev/null 2>&1; then
    _env_diag_safe_emit dirty.status git-missing
    return 0
  fi
  local dirty_count=0 clone porcelain branch
  while IFS= read -r clone; do
    [[ -n "$clone" ]] || continue
    porcelain=$(_env_diag_run_timeout "$ORCH_ENV_DIAG_TIMEOUT_SEC" \
      git -C "$clone" status --porcelain 2>/dev/null || printf '')
    if [[ -n "$porcelain" ]]; then
      dirty_count=$((dirty_count + 1))
      branch=$(_env_diag_run_timeout "$ORCH_ENV_DIAG_TIMEOUT_SEC" \
        git -C "$clone" rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown')
      _env_diag_safe_emit "dirty.${dirty_count}.workdir" "$clone"
      _env_diag_safe_emit "dirty.${dirty_count}.branch" "$branch"
      _env_diag_safe_emit "dirty.${dirty_count}.porcelain_lines" "$(printf '%s\n' "$porcelain" | wc -l | tr -d ' ')"
    fi
  done < <(find "$root" -mindepth 1 -maxdepth "$ORCH_ENV_DIAG_DIRTY_MAX_DEPTH" \
    -type d -name '.git' -prune 2>/dev/null \
    | sed 's:/\.git$::')
  _env_diag_safe_emit dirty.status ok
  _env_diag_safe_emit dirty.count "$dirty_count"
  _env_diag_safe_emit dirty.root "$root"
}

# Audit artifact naming convention helper. Returns the canonical path
# for a kind in {snapshot, ledger, matrix, monitor}. Path layout:
#
#   <base>/snapshots/<id>.tsv
#   <base>/ledgers/<id>.jsonl
#   <base>/matrices/<id>.tsv
#   <base>/monitors/<id>.log
#
# `<base>` defaults to the per-project ORDO state dir, then a temp dir,
# so callers without a project config still get a valid path.
env_diag_audit_artifact_path() {
  local kind=${1:?usage: env_diag_audit_artifact_path <kind> <id>}
  local id=${2:?usage: env_diag_audit_artifact_path <kind> <id>}
  local base="$ORCH_ENV_DIAG_AUDIT_BASE"
  if [[ -z "$base" ]]; then
    if command -v state_dir >/dev/null 2>&1; then
      base=$(state_dir 2>/dev/null || printf '')
    fi
  fi
  [[ -n "$base" ]] || base="${TMPDIR:-/tmp}/ordo-audit"
  local subdir ext
  case "$kind" in
    snapshot|snapshots) subdir=snapshots; ext=tsv ;;
    ledger|ledgers)     subdir=ledgers;   ext=jsonl ;;
    matrix|matrices)    subdir=matrices;  ext=tsv ;;
    monitor|monitors)   subdir=monitors;  ext=log ;;
    *)
      printf 'env_diag_audit_artifact_path: unknown kind: %s\n' "$kind" >&2
      return 1
      ;;
  esac
  printf '%s/%s/%s.%s\n' "$base" "$subdir" "$id" "$ext"
}
