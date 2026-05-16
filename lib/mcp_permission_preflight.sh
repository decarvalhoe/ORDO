#!/usr/bin/env bash
# lib/mcp_permission_preflight.sh — universal MCP permission preflight.
#
# Why this exists (#342):
#   Several MCP-aware agent CLIs (Claude Code, future codex/copilot CLIs,
#   etc.) gate first-time MCP tool calls behind an interactive per-workdir
#   permission prompt ("Do you want to proceed? 1.Yes 2.Yes-don't-ask-again
#   ..."). Remote orchestrators that dispatch via tmux paste-buffer cannot
#   answer those prompts. When the prompt fires after the brief is pasted,
#   the agent stalls indefinitely while the orchestrator narrative claims
#   the work is in flight.
#
#   This helper preflights each dispatch:
#     1. Detects which MCP tools the prompt will require, from explicit
#        declaration AND from configurable URL / command patterns.
#     2. Looks up the per-(workdir, mcp) grant state from a structured
#        permissions ledger (or a CLI-specific resolver hook supplied by
#        the operator's profile).
#     3. Emits a JSON decision with `granted` / `blocked` plus the per-MCP
#        grant map so the audit trail records *why* a dispatch was held.
#
#   The design is universal: no Claude-CLI hardcoding, no Figma-specific
#   logic. Figma is one concrete pattern in the default catalog; operators
#   add or replace patterns via `ORDO_MCP_PROMPT_PATTERNS`. CLI-specific
#   permission stores plug in via `ORDO_MCP_PERMISSION_RESOLVER`.

# ---------------------------------------------------------------------------
# Required MCP detection
# ---------------------------------------------------------------------------

# Default extended-regex patterns that map prompt content to MCP names.
# Format: `<extended-regex>=<mcp-name>`. Lines beginning with `#` are
# ignored. Operators replace with `ORDO_MCP_PROMPT_PATTERNS` (bash array)
# or extend with `ORDO_MCP_PROMPT_PATTERNS_EXTRA` (bash array).
mcp_preflight_default_patterns() {
  cat <<'PATTERNS'
figma\.com/(design|board|slides|file|make)/=figma
claude\.ai[[:space:]]+Figma=figma
mcp__claude_ai_Figma=figma
claude\.ai[[:space:]]+Canva=canva
mcp__claude_ai_Canva=canva
claude\.ai[[:space:]]+Wix=wix
mcp__claude_ai_Wix=wix
claude\.ai[[:space:]]+Gmail=gmail
mcp__claude_ai_Gmail=gmail
claude\.ai[[:space:]]+Google[[:space:]]+(Calendar|Drive)=google_workspace
mcp__claude_ai_Google_(Calendar|Drive)=google_workspace
claude\.ai[[:space:]]+n8n=n8n
mcp__claude_ai_n8n=n8n
PATTERNS
}

mcp_preflight_patterns() {
  if declare -p ORDO_MCP_PROMPT_PATTERNS >/dev/null 2>&1 \
     && [ "${#ORDO_MCP_PROMPT_PATTERNS[@]}" -gt 0 ]; then
    printf '%s\n' "${ORDO_MCP_PROMPT_PATTERNS[@]}"
  else
    mcp_preflight_default_patterns
  fi
  if declare -p ORDO_MCP_PROMPT_PATTERNS_EXTRA >/dev/null 2>&1 \
     && [ "${#ORDO_MCP_PROMPT_PATTERNS_EXTRA[@]}" -gt 0 ]; then
    printf '%s\n' "${ORDO_MCP_PROMPT_PATTERNS_EXTRA[@]}"
  fi
}

# Echo, one MCP name per line (sorted, deduplicated), every MCP the prompt
# requires. Sources, in order:
#   1. Explicit `Required MCPs: a,b,c` line (case-insensitive label).
#   2. Pattern matching from mcp_preflight_patterns.
#   3. Project-wide always-required from `ORDO_MCP_REQUIRED_FOR_PROJECT`
#      (CSV) — used when an entire project is gated on an MCP regardless
#      of prompt content.
mcp_preflight_detect_required() {
  local prompt_file=${1:?usage: mcp_preflight_detect_required <prompt-file>}
  [ -f "$prompt_file" ] || return 1

  local found=""
  local explicit_line list mcp pattern_line pattern

  explicit_line=$(grep -iE '^[[:space:]]*[#-]*[[:space:]]*Required[[:space:]]+MCPs[[:space:]]*:' \
    "$prompt_file" 2>/dev/null | head -1 || true)
  if [ -n "$explicit_line" ]; then
    list=${explicit_line#*:}
    while IFS= read -r mcp; do
      mcp=${mcp// /}
      [ -n "$mcp" ] || continue
      found="${found}${mcp}"$'\n'
    done < <(printf '%s\n' "$list" | tr ',' '\n')
  fi

  while IFS= read -r pattern_line; do
    [ -n "$pattern_line" ] || continue
    case "$pattern_line" in \#*) continue ;; esac
    pattern=${pattern_line%%=*}
    mcp=${pattern_line#*=}
    if [ -z "$pattern" ] || [ -z "$mcp" ]; then
      continue
    fi
    if grep -qE -- "$pattern" "$prompt_file" 2>/dev/null; then
      found="${found}${mcp}"$'\n'
    fi
  done < <(mcp_preflight_patterns)

  if [ -n "${ORDO_MCP_REQUIRED_FOR_PROJECT:-}" ]; then
    while IFS= read -r mcp; do
      mcp=${mcp// /}
      [ -n "$mcp" ] || continue
      found="${found}${mcp}"$'\n'
    done < <(printf '%s\n' "$ORDO_MCP_REQUIRED_FOR_PROJECT" | tr ',' '\n')
  fi

  [ -n "$found" ] || return 0
  printf '%s' "$found" | sort -u
}

# ---------------------------------------------------------------------------
# Per-workdir grant lookup
# ---------------------------------------------------------------------------

mcp_preflight_permissions_file() {
  printf '%s' "${ORDO_MCP_PERMISSIONS_FILE:-${HOME:-/root}/.config/ordo/mcp-permissions.json}"
}

# Look up the grant state for a (workdir, mcp) pair. Echoes one of:
#   granted | needs_operator_permission | blocked | unknown
#
# Resolution order:
#   1. `ORDO_MCP_PERMISSION_RESOLVER` — operator-supplied executable that
#      receives `<workdir> <mcp>` and prints the state. This is the
#      universal CLI-extension hook (Claude Code, codex, copilot, ...).
#      A non-empty stdout becomes the answer.
#   2. The structured permissions ledger at
#      `mcp_preflight_permissions_file`. Shape:
#        { "by_workdir": { "<workdir>": { "<mcp>": "<state>" } } }
#   3. `unknown` if neither source resolves.
mcp_preflight_lookup_grant() {
  local workdir=${1:?usage: mcp_preflight_lookup_grant <workdir> <mcp>}
  local mcp=${2:?usage: mcp_preflight_lookup_grant <workdir> <mcp>}

  if [ -n "${ORDO_MCP_PERMISSION_RESOLVER:-}" ]; then
    local resolver_out
    if resolver_out=$("$ORDO_MCP_PERMISSION_RESOLVER" "$workdir" "$mcp" 2>/dev/null); then
      resolver_out=${resolver_out//$'\n'/}
      if [ -n "$resolver_out" ]; then
        printf '%s' "$resolver_out"
        return 0
      fi
    fi
  fi

  local file
  file=$(mcp_preflight_permissions_file)
  if [ -s "$file" ] && command -v jq >/dev/null 2>&1; then
    local state
    state=$(jq -r --arg w "$workdir" --arg m "$mcp" \
      '(.by_workdir // {}) | (.[$w] // {}) | (.[$m] // "unknown")' \
      "$file" 2>/dev/null) || state="unknown"
    [ -n "$state" ] || state="unknown"
    printf '%s' "$state"
    return 0
  fi

  printf '%s' "unknown"
}

# ---------------------------------------------------------------------------
# Decision
# ---------------------------------------------------------------------------

# Build a structured JSON decision for a dispatch. Stdout = decision JSON.
# Return 0 when decision is `granted`, 1 when `blocked`, 2 on usage error.
#
# A grant state of `granted` passes. Anything else (`needs_operator_permission`,
# `blocked`, `unknown`) blocks — the operator must explicitly grant before
# dispatch lands in the agent pane.
mcp_preflight_for_dispatch() {
  local prompt_file=${1:?usage: mcp_preflight_for_dispatch <prompt> <agent> <workdir>}
  local agent=${2:?usage: mcp_preflight_for_dispatch <prompt> <agent> <workdir>}
  local workdir=${3:?usage: mcp_preflight_for_dispatch <prompt> <agent> <workdir>}

  if [ ! -f "$prompt_file" ]; then
    printf '{"agent":"%s","workdir":"%s","decision":"blocked","error":"prompt_file_not_found"}\n' \
      "$agent" "$workdir"
    return 2
  fi

  local -a required_mcps=()
  local mcp
  while IFS= read -r mcp; do
    [ -n "$mcp" ] || continue
    required_mcps+=("$mcp")
  done < <(mcp_preflight_detect_required "$prompt_file")

  local required_json
  if [ "${#required_mcps[@]}" -gt 0 ]; then
    required_json=$(printf '%s\n' "${required_mcps[@]}" | jq -R . | jq -sc '.')
  else
    required_json='[]'
  fi

  local grants_json='{}'
  local decision="granted"
  local -a blocking=()
  local state

  for mcp in "${required_mcps[@]}"; do
    state=$(mcp_preflight_lookup_grant "$workdir" "$mcp")
    grants_json=$(printf '%s' "$grants_json" \
      | jq -c --arg m "$mcp" --arg s "$state" '. + {($m): $s}')
    case "$state" in
      granted) ;;
      *)
        decision="blocked"
        blocking+=("${mcp}:${state}")
        ;;
    esac
  done

  local blocking_json
  if [ "${#blocking[@]}" -gt 0 ]; then
    blocking_json=$(printf '%s\n' "${blocking[@]}" | jq -R . | jq -sc '.')
  else
    blocking_json='[]'
  fi

  jq -nc \
    --arg agent "$agent" \
    --arg workdir "$workdir" \
    --arg prompt_basename "$(basename "$prompt_file")" \
    --argjson required "$required_json" \
    --argjson grants "$grants_json" \
    --arg decision "$decision" \
    --argjson blocking "$blocking_json" \
    --arg permissions_file "$(mcp_preflight_permissions_file)" \
    '{
      agent: $agent,
      workdir: $workdir,
      prompt_file: $prompt_basename,
      required_mcps: $required,
      grants: $grants,
      decision: $decision,
      blocking: $blocking,
      permissions_file: $permissions_file,
      remediation: (
        if $decision == "granted" then null
        else (
          "Grant the listed MCP(s) for this workdir before redispatching: "
          + "either add granted entries under .by_workdir[\"" + $workdir + "\"] "
          + "in " + $permissions_file + ", or have the operator run the agent CLI "
          + "per-workdir grant flow once. ORDO_MCP_PERMISSION_RESOLVER can be set "
          + "for CLI-specific lookup integration."
        )
        end
      )
    }'

  if [ "$decision" = "granted" ]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Startup auth-failure classification (#670)
# ---------------------------------------------------------------------------
#
# Why this exists (#670):
#   Codex/Claude/copilot CLIs that bring up MCP transports during fleet
#   startup can emit nonblocking auth failures that look fatal in the
#   console — e.g. a Cloudflare MCP `invalid_token` from the rmcp worker:
#
#     ERROR rmcp::transport::worker: worker quit with fatal
#       { code: 0, message: "AuthRequired" }
#       source=https://mcp.cloudflare.com/sse error=invalid_token
#
#   The agent CLI keeps running and the orchestrated work proceeds. But
#   if the orch loop treats every MCP startup error as fatal, operators
#   chase Cloudflare auth issues instead of looking at the real
#   assignment. The classifier below distinguishes:
#     - blocking    when the failing MCP is in the active assignment's
#                   required list (`ORDO_MCP_REQUIRED_FOR_PROJECT`-style
#                   csv passed by the caller);
#     - degraded    when it is in a degraded list (best-effort use only);
#     - nonblocking otherwise — operator noise the orchestrator audits
#                   but does NOT promote to a fleet-fatal blocker.
#
# Universality: detection covers the rmcp worker shape AND the Codex
# `<name> MCP server is not logged in.` / `MCP startup incomplete
# (failed: ...)` shapes, so the same helper serves codex, claude,
# copilot, or future MCP-aware CLIs without per-CLI hardcoding.

# Echo, one MCP name per line (sorted, deduplicated), every MCP server
# whose startup auth failed in <log-file>. Returns 0 always — absence
# of matches is a normal outcome; failure to read the log silently
# yields no records so callers can no-op rather than spam blockers.
mcp_preflight_detect_auth_failure_lines() {
  local log_file=${1:?usage: mcp_preflight_detect_auth_failure_lines <log-file>}
  [ -f "$log_file" ] && [ -r "$log_file" ] || return 0

  local line raw name failed found=""

  while IFS= read -r line; do
    case "$line" in
      *"rmcp::transport::worker"*"AuthRequired"*|\
      *"rmcp::transport::worker"*"invalid_token"*|\
      *"AuthRequired"*"mcp."*|\
      *"invalid_token"*"mcp."*)
        name=$(printf '%s' "$line" \
          | grep -oE 'mcp\.[a-z0-9_.-]+' \
          | head -1 \
          | sed -E 's|^mcp\.([a-z0-9_-]+).*|\1|')
        if [ -n "$name" ]; then
          found="${found}${name}"$'\n'
        fi
        ;;
    esac

    case "$line" in
      *" MCP server is not logged in."*)
        raw=${line%% MCP server is not logged in.*}
        raw=${raw##* }
        name=$(printf '%s' "$raw" | tr -d '[:space:]' | tr -dc '[:alnum:]._-')
        if [ -n "$name" ]; then
          found="${found}${name}"$'\n'
        fi
        ;;
    esac

    case "$line" in
      *"MCP startup incomplete (failed:"*)
        failed=${line#*MCP startup incomplete (failed:}
        failed=${failed%%)*}
        failed=${failed//,/ }
        for raw in $failed; do
          name=$(printf '%s' "$raw" | tr -d '[:space:]' | tr -dc '[:alnum:]._-')
          if [ -n "$name" ]; then
            found="${found}${name}"$'\n'
          fi
        done
        ;;
    esac
  done < "$log_file"

  [ -n "$found" ] || return 0
  printf '%s' "$found" | sort -u
}

# Echo one of `blocking | degraded | nonblocking` for <mcp> based on
# whether it appears in <required_csv> or <degraded_csv>. Comparison
# is case-insensitive on MCP name and surrounding whitespace is
# trimmed. Always returns 0.
mcp_preflight_classify_auth_severity() {
  local mcp=${1:?usage: mcp_preflight_classify_auth_severity <mcp> <required_csv> [<degraded_csv>]}
  local required=${2:-}
  local degraded=${3:-}
  local entry mcp_lc entry_lc

  mcp_lc=$(printf '%s' "$mcp" | tr '[:upper:]' '[:lower:]')

  local IFS=','
  for entry in $required; do
    entry=${entry// /}
    [ -n "$entry" ] || continue
    entry_lc=$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')
    if [ "$entry_lc" = "$mcp_lc" ]; then
      printf 'blocking\n'
      return 0
    fi
  done
  for entry in $degraded; do
    entry=${entry// /}
    [ -n "$entry" ] || continue
    entry_lc=$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')
    if [ "$entry_lc" = "$mcp_lc" ]; then
      printf 'degraded\n'
      return 0
    fi
  done
  printf 'nonblocking\n'
}

# Top-level: scan <log-file> for MCP auth failures, classify each by
# severity (blocking/degraded/nonblocking), and emit one structured
# record per distinct failing MCP on stdout in the form:
#
#   MCP_AUTH_CLASSIFICATION mcp=<name> severity=<state> source=startup
#
# Severity is derived from the active assignment's required-MCP list
# (<required_csv>) and an optional degraded-MCP list (<degraded_csv>).
#
# Exit codes:
#   0 — no failures, or only nonblocking/degraded failures (operator
#       noise, but no fleet-fatal startup failure for this assignment).
#   1 — at least one failure mapped to severity=blocking.
mcp_preflight_classify_startup_log() {
  local log_file=${1:?usage: mcp_preflight_classify_startup_log <log-file> [<required_csv>] [<degraded_csv>]}
  local required=${2:-}
  local degraded=${3:-}

  local rc=0 mcp severity
  while IFS= read -r mcp; do
    [ -n "$mcp" ] || continue
    severity=$(mcp_preflight_classify_auth_severity "$mcp" "$required" "$degraded")
    printf 'MCP_AUTH_CLASSIFICATION mcp=%s severity=%s source=startup\n' \
      "$mcp" "$severity"
    if [ "$severity" = "blocking" ]; then
      rc=1
    fi
  done < <(mcp_preflight_detect_auth_failure_lines "$log_file")

  return "$rc"
}
