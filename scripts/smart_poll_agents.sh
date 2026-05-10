#!/usr/bin/env bash
# scripts/smart_poll_agents.sh — wait for agents to commit a wave's worth of
# work, then return so the orchestrator can integrate.
#
# Usage: smart_poll_agents.sh <project_short|config_path> [wave_label]
#
# Surviving log signatures:
#   POLL start project=<id> main=<sha> agents=<N> trigger=<idle>+<committed> timeout=<sec>s
#   POLL TRIGGER idle=<X> committed=<Y> elapsed=<sec>s
#   POLL TIMEOUT idle=<X> committed=<Y> elapsed=<sec>s
#   POLL CYCLE idle=<X> committed=<Y> elapsed=<sec>s <pane>=<state> ...   (verbose only)
#
# Trigger semantics (from the log lines + the recovered behaviour):
#   - "idle"      = agent's tmux pane appears at the prompt (no spinner / running task)
#   - "committed" = agent's feature branch has ≥1 commit ahead of DEFAULT_BRANCH
#   - When BOTH counters reach the configured trigger AND that condition has held
#     for SMART_POLL_DEBOUNCE_SEC, return 0 (TRIGGER).
#   - On SMART_POLL_TIMEOUT_SEC elapsed without trigger, return 1 (TIMEOUT).
#   - In SMART_POLL_OBSERVE=1 mode, neither TRIGGER nor TIMEOUT fire — the loop
#     runs forever and only emits CYCLE log lines (use for background monitoring).
#
# Fleet declaration (two forms supported, AGENT_PANES takes precedence):
#
#   1. UNIVERSAL (multi-fleet projects):
#      AGENT_PANES=(
#        "planner|terminal-a:0.0|/workspace/product-planner"
#        "builder|terminal-b:0.0|/workspace/product-builder"
#        "reviewer|terminal-c:0.0|/workspace/product-reviewer"
#      )
#      Each entry is "label|pane_target|workdir_absolute_path".
#      No common prefix or naming convention assumed.
#
#   2. LEGACY (single fleet, unchanged):
#      AGENTS=(planner builder reviewer)
#      AGENT_SESSION_PREFIX="product-"         # default ""
#      AGENT_REPO_PREFIX="/workspace/product-"
#      AGENT_WINDOW_INDEX="0"                  # default "0"
#      → pane    = "${AGENT_SESSION_PREFIX}${a}:${AGENT_WINDOW_INDEX}.0"
#      → workdir = "${AGENT_REPO_PREFIX}${a}"
#
# Required env (from project config):
#   PROJECT, DEFAULT_BRANCH, plus one of the two fleet forms above.
#   SMART_POLL_TRIGGER_IDLE, SMART_POLL_TRIGGER_COMMITTED
#   SMART_POLL_TIMEOUT_SEC, SMART_POLL_INTERVAL_SEC, SMART_POLL_DEBOUNCE_SEC
#
# Optional env (script-level overrides):
#   SMART_POLL_OBSERVE   (0|1, default 0)  — never trigger/timeout, loop forever
#   SMART_POLL_VERBOSE   (0|1, default 0)  — emit per-agent state on each cycle
#   SMART_POLL_AUTOSWAP  (0|1, default: 1 if AGENTS legacy, 0 if AGENT_PANES universal)
#                        — enable cli_swap.sh on quota detection
#   SMART_POLL_IGNORE_OPEN_PR_BRANCHES (0|1, default 1)
#                        — do not count branches that already have open PRs
#                          as newly committed work ready for integration.
#   SMART_POLL_REGISTRY_POLICY (replace|refuse|coexist, default replace)
#                        — startup behavior when another smart poll for the
#                          same project is still registered.
set -uo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$TK/lib/config_resolver.sh"
source "$TK/lib/agent_inventory.sh"
source "$TK/lib/process_safety.sh"

CFG_ARG=${1:?usage: smart_poll_agents.sh <project_short|config_path> [wave_label]}
WAVE_LABEL=${2:-default}
load_project_config "$CFG_ARG"
CFG=${ORCH_CONFIG_PATH:?}

source "$TK/lib/audit_log.sh"
source "$TK/lib/quota_detect.sh"

: "${DEFAULT_BRANCH:=main}" "${AGENT_SESSION_PREFIX:=}" "${AGENT_WINDOW_INDEX:=0}"
: "${SMART_POLL_TRIGGER_IDLE:=4}"
: "${SMART_POLL_TRIGGER_COMMITTED:=4}"
: "${SMART_POLL_TIMEOUT_SEC:=900}"
: "${SMART_POLL_INTERVAL_SEC:=60}"
: "${SMART_POLL_DEBOUNCE_SEC:=60}"
: "${QUOTA_SWAP_COOLDOWN_SEC:=300}"
: "${SMART_POLL_OBSERVE:=0}"
: "${SMART_POLL_VERBOSE:=0}"
: "${SMART_POLL_IDLE_MODE:=pane}"     # pane | git; git avoids slow/hung TUI capture-pane
: "${SMART_POLL_CAPTURE_TIMEOUT_SEC:=3}"
: "${SMART_POLL_TMUX_TIMEOUT_SEC:=3}"
: "${SMART_POLL_GIT_TIMEOUT_SEC:=5}"
: "${SMART_POLL_GH_TIMEOUT_SEC:=5}"
: "${SMART_POLL_IGNORE_OPEN_PR_BRANCHES:=1}"
: "${SMART_POLL_OPEN_PR_CACHE_SEC:=60}"
: "${SMART_POLL_OPEN_PR_LIMIT:=100}"
: "${SMART_POLL_REGISTRY_POLICY:=replace}"

# --- Fleet resolution: build parallel arrays UNIT_PANES / UNIT_WORKDIRS / UNIT_NAMES ---
declare -a UNIT_PANES=()
declare -a UNIT_WORKDIRS=()
declare -a UNIT_NAMES=()  # logical names (used by cli_swap.sh in legacy mode only)

# Detect AGENT_PANES (universal mode) without tripping `set -u`:
# `${VAR+x}` expands to "x" if VAR is set (even to empty), to "" otherwise.
if [ -n "${AGENT_PANES+x}" ] && [ "${#AGENT_PANES[@]}" -gt 0 ]; then
  FLEET_MODE="universal"
  while IFS='|' read -r label pane workdir; do
    UNIT_PANES+=("$pane")
    UNIT_WORKDIRS+=("$workdir")
    UNIT_NAMES+=("$label")
  done < <(agent_inventory_entries)
else
  FLEET_MODE="legacy"
  : "${AGENT_REPO_PREFIX:?need AGENT_PANES (universal) or AGENT_REPO_PREFIX (legacy)}"
  if [ -z "${AGENTS+x}" ] || [ "${#AGENTS[@]}" -eq 0 ]; then
    echo "neither AGENT_PANES nor AGENTS array is set in $CFG" >&2
    exit 1
  fi
  for a in "${AGENTS[@]}"; do
    UNIT_PANES+=("${AGENT_SESSION_PREFIX}${a}:${AGENT_WINDOW_INDEX}.0")
    UNIT_WORKDIRS+=("${AGENT_REPO_PREFIX}${a}")
    UNIT_NAMES+=("$a")
  done
fi

# Default auto-swap on in legacy mode (preserves prior behaviour),
# off in universal mode (cli_swap.sh expects a logical agent name keyed
# in the project config, not a free-form pane target).
if [ -z "${SMART_POLL_AUTOSWAP:-}" ]; then
  if [ "$FLEET_MODE" = "legacy" ]; then SMART_POLL_AUTOSWAP=1; else SMART_POLL_AUTOSWAP=0; fi
fi

N_UNITS=${#UNIT_PANES[@]}

# Resolve current default-branch SHA for the log header.
main_sha="?"
if [ -n "${SUPERVISOR_REPO:-}" ] && [ -d "$SUPERVISOR_REPO/.git" ]; then
  main_sha=$(orch_run_timeout "$SMART_POLL_GIT_TIMEOUT_SEC" git -C "$SUPERVISOR_REPO" rev-parse --short "$DEFAULT_BRANCH" 2>/dev/null || echo "?")
elif [ -d "${UNIT_WORKDIRS[0]}/.git" ]; then
  main_sha=$(orch_run_timeout "$SMART_POLL_GIT_TIMEOUT_SEC" git -C "${UNIT_WORKDIRS[0]}" rev-parse --short "$DEFAULT_BRANCH" 2>/dev/null || echo "?")
fi

poll_registry_safe_component() {
  local value=${1:-unknown}
  value=${value//[^A-Za-z0-9_.-]/_}
  [ -n "$value" ] || value=unknown
  printf '%s\n' "$value"
}

poll_registry_dir() {
  local d
  d="$(state_dir)/poll-registry"
  mkdir -p "$d" 2>/dev/null || return 1
  printf '%s\n' "$d"
}

poll_registry_read() {
  local file=${1:?usage: poll_registry_read <file> <key>}
  local key=${2:?usage: poll_registry_read <file> <key>}
  local line k v
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*)
        IFS='=' read -r k v <<< "$line"
        if [ "$k" = "$key" ]; then
          printf '%s\n' "$v"
          return 0
        fi
        ;;
    esac
  done < "$file"
  return 1
}

poll_registry_numeric_or_zero() {
  local value=${1:-0}
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '0\n'
  fi
}

poll_registry_age() {
  local file=${1:?usage: poll_registry_age <file>}
  local started now
  started=$(poll_registry_numeric_or_zero "$(poll_registry_read "$file" start_ts 2>/dev/null || printf '0')")
  now=$(date +%s)
  if [ "$started" -gt "$now" ]; then
    printf '0\n'
  else
    printf '%s\n' $((now - started))
  fi
}

poll_registry_stale_threshold() {
  local file=${1:?usage: poll_registry_stale_threshold <file>}
  local timeout_sec
  timeout_sec=$(poll_registry_numeric_or_zero "$(poll_registry_read "$file" timeout_sec 2>/dev/null || printf '%s' "$SMART_POLL_TIMEOUT_SEC")")
  printf '%s\n' $((timeout_sec * 2))
}

poll_registry_pid_alive() {
  local pid=${1:-}
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

poll_registry_pid_is_smart_poll() {
  local pid=${1:-}
  local args
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  args=$(orch_run_timeout "$ORCH_PS_TIMEOUT_SEC" ps -p "$pid" -o args= 2>/dev/null || true)
  [[ "$args" == *"smart_poll_agents.sh"* ]]
}

poll_registry_shutdown_file() {
  local file=${1:?usage: poll_registry_shutdown_file <file> <reason>}
  local reason=${2:?usage: poll_registry_shutdown_file <file> <reason>}
  local pid wave age threshold action
  pid=$(poll_registry_read "$file" pid 2>/dev/null || true)
  wave=$(poll_registry_read "$file" wave_id 2>/dev/null || printf 'unknown')
  age=$(poll_registry_age "$file")
  threshold=$(poll_registry_stale_threshold "$file")

  if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" != "$$" ] && poll_registry_pid_alive "$pid"; then
    if poll_registry_pid_is_smart_poll "$pid"; then
      kill -TERM "$pid" 2>/dev/null || true
      action=term
    else
      action=skip-non-smart-poll-pid
    fi
  else
    action=remove-dead
  fi

  rm -f "$file" 2>/dev/null || true
  audit "POLL stale-poll action=$action project=$PROJECT pid=${pid:-unknown} wave=$wave age=${age}s threshold=${threshold}s reason=$reason"
}

poll_registry_prepare_existing() {
  local dir file pid wave age threshold alive
  dir=$(poll_registry_dir) || {
    audit "POLL_REGISTRY action=disabled reason=state-dir-unavailable project=$PROJECT"
    return 0
  }

  case "$SMART_POLL_REGISTRY_POLICY" in
    replace|refuse|coexist) ;;
    *)
      audit "POLL_REGISTRY action=invalid-policy policy=$SMART_POLL_REGISTRY_POLICY default=replace"
      SMART_POLL_REGISTRY_POLICY=replace
      ;;
  esac

  shopt -s nullglob
  for file in "$dir"/*.env; do
    pid=$(poll_registry_read "$file" pid 2>/dev/null || true)
    [ "$pid" = "$$" ] && continue
    wave=$(poll_registry_read "$file" wave_id 2>/dev/null || printf 'unknown')
    age=$(poll_registry_age "$file")
    threshold=$(poll_registry_stale_threshold "$file")
    alive=0
    if poll_registry_pid_alive "$pid"; then
      alive=1
    fi

    if [ "$age" -ge "$threshold" ]; then
      poll_registry_shutdown_file "$file" "stale"
      continue
    fi

    if [ "$alive" -eq 0 ]; then
      rm -f "$file" 2>/dev/null || true
      audit "POLL_REGISTRY action=remove-dead project=$PROJECT pid=${pid:-unknown} wave=$wave age=${age}s"
      continue
    fi

    if ! poll_registry_pid_is_smart_poll "$pid"; then
      rm -f "$file" 2>/dev/null || true
      audit "POLL_REGISTRY action=remove-invalid project=$PROJECT pid=${pid:-unknown} wave=$wave reason=pid-not-smart-poll"
      continue
    fi

    case "$SMART_POLL_REGISTRY_POLICY" in
      replace)
        poll_registry_shutdown_file "$file" "superseded"
        ;;
      refuse)
        audit "POLL_REGISTRY action=refuse project=$PROJECT existing_pid=$pid existing_wave=$wave age=${age}s"
        exit 75
        ;;
      coexist)
        audit "POLL_REGISTRY action=coexist project=$PROJECT existing_pid=$pid existing_wave=$wave age=${age}s"
        ;;
    esac
  done
  shopt -u nullglob
}

poll_registry_register() {
  local dir safe_wave file tmp
  dir=$(poll_registry_dir) || return 0
  safe_wave=$(poll_registry_safe_component "$WAVE_LABEL")
  file="$dir/${safe_wave}.$$.env"
  tmp="$file.tmp"

  {
    printf 'pid=%s\n' "$$"
    printf 'project=%s\n' "$PROJECT"
    printf 'wave_id=%s\n' "$WAVE_LABEL"
    printf 'start_ts=%s\n' "$start_ts"
    printf 'timeout_sec=%s\n' "$SMART_POLL_TIMEOUT_SEC"
    printf 'observe=%s\n' "$SMART_POLL_OBSERVE"
    printf 'policy=%s\n' "$SMART_POLL_REGISTRY_POLICY"
  } > "$tmp" && mv "$tmp" "$file"

  POLL_REGISTRY_FILE="$file"
  audit "POLL_REGISTRY action=register project=$PROJECT pid=$$ wave=$WAVE_LABEL file=$file"
}

poll_registry_cleanup() {
  if [ -n "${POLL_REGISTRY_FILE:-}" ]; then
    rm -f "$POLL_REGISTRY_FILE" 2>/dev/null || true
  fi
}

poll_registry_term() {
  audit "POLL shutdown project=$PROJECT pid=$$ wave=$WAVE_LABEL signal=TERM"
  poll_registry_cleanup
  exit 143
}

start_ts=$(date +%s)
poll_registry_prepare_existing
poll_registry_register
trap poll_registry_cleanup EXIT
trap poll_registry_term INT TERM

audit "POLL start project=$PROJECT main=$main_sha agents=$N_UNITS mode=$FLEET_MODE trigger=${SMART_POLL_TRIGGER_IDLE}+${SMART_POLL_TRIGGER_COMMITTED} timeout=${SMART_POLL_TIMEOUT_SEC}s observe=$SMART_POLL_OBSERVE autoswap=$SMART_POLL_AUTOSWAP idle_mode=$SMART_POLL_IDLE_MODE ignore_open_pr=$SMART_POLL_IGNORE_OPEN_PR_BRANCHES wave=$WAVE_LABEL"

# --- Per-unit helpers (operate on pane + workdir, not logical agent name) ---

OPEN_PR_BRANCHES=""
OPEN_PR_LAST_FETCH=0

refresh_open_pr_branches() {
  local now=${1:?usage: refresh_open_pr_branches <epoch-seconds>}

  [ "$SMART_POLL_IGNORE_OPEN_PR_BRANCHES" = "1" ] || {
    OPEN_PR_BRANCHES=""
    return 0
  }
  [ -n "${GH_REPO:-}" ] || {
    OPEN_PR_BRANCHES=""
    return 0
  }
  command -v gh >/dev/null 2>&1 || {
    OPEN_PR_BRANCHES=""
    return 0
  }
  command -v jq >/dev/null 2>&1 || {
    OPEN_PR_BRANCHES=""
    return 0
  }
  if [ "$OPEN_PR_LAST_FETCH" -gt 0 ] && [ $((now - OPEN_PR_LAST_FETCH)) -lt "$SMART_POLL_OPEN_PR_CACHE_SEC" ]; then
    return 0
  fi

  OPEN_PR_LAST_FETCH=$now
  OPEN_PR_BRANCHES=$(
    orch_run_timeout "$SMART_POLL_GH_TIMEOUT_SEC" env GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" gh pr list \
      --repo "$GH_REPO" \
      --base "$DEFAULT_BRANCH" \
      --state open \
      --limit "$SMART_POLL_OPEN_PR_LIMIT" \
      --json headRefName 2>/dev/null \
      | jq -r '.[].headRefName' 2>/dev/null || true
  )
}

branch_has_open_pr() {
  local branch=${1:-}
  [ -n "$branch" ] || return 1
  [ -n "$OPEN_PR_BRANCHES" ] || return 1
  grep -Fxq -- "$branch" <<< "$OPEN_PR_BRANCHES"
}

unit_idle() {
  local pane=$1
  local workdir=${2:-}

  # Non-blocking mode for Codex/Claude TUI panes. Some panes can make
  # `tmux capture-pane` or even tmux metadata calls stall for minutes.
  # Git mode deliberately avoids tmux and treats an existing clone as idle;
  # unit_committed() independently detects branches ahead of DEFAULT_BRANCH.
  if [ "$SMART_POLL_IDLE_MODE" = "git" ]; then
    # Avoid `git status`: on the RBOK host it can block on every clone.
    # In this mode idle means the clone is present; readiness is gated by
    # unit_committed() below, which checks commits ahead of DEFAULT_BRANCH.
    [ -n "$workdir" ] && [ -d "$workdir/.git" ]
    return
  fi

  orch_run_timeout "$SMART_POLL_TMUX_TIMEOUT_SEC" tmux has-session -t "${pane%%:*}" 2>/dev/null || return 1
  local cap
  cap=$(orch_run_timeout "$SMART_POLL_CAPTURE_TIMEOUT_SEC" tmux capture-pane -t "$pane" -p 2>/dev/null | tail -10 | tr -d '\r') || return 1
  # 1. Spinner glyph at line start = busy.
  if printf '%s' "$cap" | grep -qE '^[[:space:]]*[✻✽✶✷✸✹◦⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]' ; then
    return 1
  fi
  # 2. Active task line (codex / Claude Code working states).
  if printf '%s' "$cap" | grep -qE 'Working \([0-9].*esc to interrupt|Pouncing|Cogitated|Brewed.*esc to interrupt'; then
    return 1
  fi
  # 3. Idle prompt sentinel — Claude Code 2.x = "❯ " / Codex TUI = "› ".
  if printf '%s' "$cap" | grep -qE '^❯ ?$|^❯ +$|^› '; then
    return 0
  fi
  return 1
}
unit_branch() {
  local d=$1
  [ -d "$d/.git" ] || return 1
  orch_run_timeout "$SMART_POLL_GIT_TIMEOUT_SEC" git -C "$d" branch --show-current 2>/dev/null
}

unit_dirty() {
  local d=$1
  [ -d "$d/.git" ] || return 1
  local dirty
  dirty=$(orch_run_timeout "$SMART_POLL_GIT_TIMEOUT_SEC" git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ') || return 1
  [ "${dirty:-0}" -gt 0 ]
}

unit_committed() {
  local d=$1
  local branch=${2:-}
  [ -d "$d/.git" ] || return 1
  if [ -z "$branch" ]; then
    branch=$(unit_branch "$d") || return 1
  fi
  [ "$branch" = "$DEFAULT_BRANCH" ] && return 1   # not on a feature branch yet
  local ahead
  ahead=$(orch_run_timeout "$SMART_POLL_GIT_TIMEOUT_SEC" git -C "$d" rev-list --count "${DEFAULT_BRANCH}..${branch}" 2>/dev/null || echo 0)
  [ "$ahead" -ge 1 ]
}

quota_autoswap_unit() {
  # Only callable in legacy mode — needs a logical agent name to invoke cli_swap.
  local agent=$1 pane=$2
  local cap pattern
  orch_run_timeout "$SMART_POLL_TMUX_TIMEOUT_SEC" tmux has-session -t "${pane%%:*}" 2>/dev/null || return 1
  cap=$(orch_run_timeout "$SMART_POLL_CAPTURE_TIMEOUT_SEC" tmux capture-pane -t "$pane" -p 2>/dev/null | tail -20 | tr -d '\r') || return 1

  if ! quota_content_matches "$cap"; then
    return 1
  fi

  pattern=$QUOTA_MATCH_PATTERN
  if quota_swap_cooldown_active "$agent"; then
    audit "QUOTA_DETECT cooldown agent=$agent pattern=$pattern cooldown=${QUOTA_SWAP_COOLDOWN_SEC}s"
    return 0
  fi

  audit "QUOTA_DETECT agent=$agent pattern=$pattern action=cli_swap:auto wave=$WAVE_LABEL"
  if bash "$TK/scripts/cli_swap.sh" "$CFG" "$agent" auto; then
    quota_mark_swap "$agent"
    audit "QUOTA_SWAP agent=$agent mode=auto pattern=$pattern"
  else
    audit "QUOTA_SWAP FAILED agent=$agent mode=auto pattern=$pattern"
  fi
}

# --- Main loop ---

debounce_started=0

while true; do
  now=$(date +%s)
  refresh_open_pr_branches "$now"

  idle=0
  committed=0
  submitted=0
  dirty=0
  branched=0
  per_agent_log=""
  for i in "${!UNIT_PANES[@]}"; do
    pane=${UNIT_PANES[$i]}
    workdir=${UNIT_WORKDIRS[$i]}

    if [ "$SMART_POLL_AUTOSWAP" = "1" ] && [ "$FLEET_MODE" = "legacy" ]; then
      quota_autoswap_unit "${UNIT_NAMES[$i]}" "$pane" || true
    fi

    state=""
    branch=""
    has_open_pr=0
    if unit_idle "$pane" "$workdir"; then idle=$((idle+1));         state+="i"; fi
    branch=$(unit_branch "$workdir" 2>/dev/null || true)
    if [ -n "$branch" ] && [ "$branch" != "$DEFAULT_BRANCH" ]; then
      branched=$((branched+1))
      state+="b"
    fi
    if branch_has_open_pr "$branch"; then
      submitted=$((submitted+1))
      has_open_pr=1
      state+="p"
    fi
    if unit_dirty "$workdir"; then
      dirty=$((dirty+1))
      state+="d"
    fi
    if unit_committed "$workdir" "$branch"; then
      if [ "$has_open_pr" -eq 0 ]; then
        committed=$((committed+1))
        state+="c"
      fi
    fi
    [ -z "$state" ] && state="-"
    per_agent_log+=" ${pane}=${state}"
  done

  elapsed=$((now-start_ts))

  if [ "$SMART_POLL_VERBOSE" = "1" ]; then
    audit "POLL CYCLE idle=$idle committed=$committed submitted=$submitted dirty=$dirty branched=$branched elapsed=${elapsed}s${per_agent_log}"
  fi

  # In observe mode, never trigger or timeout — pure background monitor.
  if [ "$SMART_POLL_OBSERVE" = "1" ]; then
    sleep "$SMART_POLL_INTERVAL_SEC"
    continue
  fi

  # Debounce window: both thresholds must hold continuously for
  # SMART_POLL_DEBOUNCE_SEC before TRIGGER fires.
  if [ "$idle" -ge "$SMART_POLL_TRIGGER_IDLE" ] && [ "$committed" -ge "$SMART_POLL_TRIGGER_COMMITTED" ]; then
    if [ "$debounce_started" -eq 0 ]; then
      debounce_started=$now
      if [ "$SMART_POLL_DEBOUNCE_SEC" -le 0 ]; then
        audit "POLL TRIGGER idle=$idle committed=$committed submitted=$submitted dirty=$dirty branched=$branched elapsed=${elapsed}s"
        exit 0
      fi
    elif [ $((now - debounce_started)) -ge "$SMART_POLL_DEBOUNCE_SEC" ]; then
      audit "POLL TRIGGER idle=$idle committed=$committed submitted=$submitted dirty=$dirty branched=$branched elapsed=${elapsed}s"
      exit 0
    fi
  else
    debounce_started=0
  fi

  if [ "$elapsed" -ge "$SMART_POLL_TIMEOUT_SEC" ]; then
    audit "POLL TIMEOUT idle=$idle committed=$committed submitted=$submitted dirty=$dirty branched=$branched elapsed=${elapsed}s"
    exit 1
  fi

  sleep "$SMART_POLL_INTERVAL_SEC"
done
