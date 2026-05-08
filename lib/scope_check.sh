#!/usr/bin/env bash
# scope_check.sh — fleet-level project scope posture (#343).
#
# Disambiguates "in scope / held / out of scope" by configured project
# KEY, never by repo path or naming inference. Universal: works for any
# agent CLI and any product. Sourced by brief_agents.sh and other
# briefing renderers.
#
# Inputs (operator-controlled environment, never hardcoded in templates):
#   ORCH_SCOPE_IN_SCOPE_PROJECTS     comma list of in-scope project keys
#   ORCH_SCOPE_HELD_PROJECTS         comma list of held project keys
#                                    (work paused, awaiting external gate)
#   ORCH_SCOPE_OUT_OF_SCOPE_PROJECTS comma list of project keys forbidden
#                                    for autonomous dispatch
#   ORCH_SCOPE_SECTION_TITLE         optional override for the rendered
#                                    section heading (default: "Scope Posture")
#   ORCH_SCOPE_STRICT                when "1"/"true"/"yes"/"on", treat
#                                    `unknown` classification as a
#                                    needs_scope_clarification failure
#                                    in ordo_scope_validate_active. The
#                                    default is permissive so deployments
#                                    that have not yet bound their scope
#                                    keys can still dispatch (the rendered
#                                    block makes the omission obvious).
#
# These are KEYS (e.g. "rbok", "ordo", "nomos", "wordpress"), not repo
# names or paths. Operators bind keys to repos in their project profiles.
# The keys are the source of truth — agents must never infer scope from
# prose like "business repository" or from path heuristics.

ordo_scope_normalize_list() {
  # Print a normalized comma list (lowercase, no horizontal whitespace,
  # sorted-uniq). Use [:blank:] not [:space:] so the per-key newline
  # split survives — tr -d [:space:] would also remove newlines and
  # collapse the entire list into one concatenated key.
  local raw=${1:-}
  printf '%s' "$raw" \
    | tr ',' '\n' \
    | tr '[:upper:]' '[:lower:]' \
    | tr -d '[:blank:]' \
    | sed '/^$/d' \
    | sort -u \
    | paste -sd, -
}

ordo_scope_normalize_key() {
  local key=${1:-}
  printf '%s' "$key" | tr '[:upper:]' '[:lower:]' | tr -d '[:blank:]'
}

ordo_scope_in_list() {
  local key=${1:?usage: ordo_scope_in_list <key> <list>}
  local list=${2:-}
  local needle
  needle=$(ordo_scope_normalize_key "$key")
  [[ -n "$needle" ]] || return 1
  printf '%s' "$list" | tr ',' '\n' | grep -Fxq "$needle"
}

ordo_scope_configured() {
  [[ -n "${ORCH_SCOPE_IN_SCOPE_PROJECTS:-}" \
   || -n "${ORCH_SCOPE_HELD_PROJECTS:-}" \
   || -n "${ORCH_SCOPE_OUT_OF_SCOPE_PROJECTS:-}" ]]
}

ordo_scope_strict_enabled() {
  case "${ORCH_SCOPE_STRICT:-0}" in
    1|true|yes|on|TRUE|YES|ON) return 0 ;;
    *) return 1 ;;
  esac
}

ordo_scope_classify() {
  # Echo one of: in_scope | held | out_of_scope | unknown
  local key=${1:?usage: ordo_scope_classify <project-key>}
  local in held out
  in=$(ordo_scope_normalize_list "${ORCH_SCOPE_IN_SCOPE_PROJECTS:-}")
  held=$(ordo_scope_normalize_list "${ORCH_SCOPE_HELD_PROJECTS:-}")
  out=$(ordo_scope_normalize_list "${ORCH_SCOPE_OUT_OF_SCOPE_PROJECTS:-}")
  if ordo_scope_in_list "$key" "$out"; then
    printf 'out_of_scope\n'
    return 0
  fi
  if ordo_scope_in_list "$key" "$held"; then
    printf 'held\n'
    return 0
  fi
  if ordo_scope_in_list "$key" "$in"; then
    printf 'in_scope\n'
    return 0
  fi
  printf 'unknown\n'
}

ordo_scope_render_block() {
  # Render the structured Scope Posture block for inclusion in a dispatch
  # brief or briefing template. Always renders the active project context
  # so every dispatch carries the four mandatory fields:
  #   active project key, active repo, active branch, scope classification.
  # Lists are shown verbatim (or "<none-configured>") so the operator can
  # see at a glance what bindings are active for this dispatch.
  local active_key=${1:?usage: ordo_scope_render_block <active-project-key> [active-repo-url] [active-branch]}
  local active_repo=${2:-}
  local active_branch=${3:-}
  local title=${ORCH_SCOPE_SECTION_TITLE:-Scope Posture}
  local in held out classification
  in=$(ordo_scope_normalize_list "${ORCH_SCOPE_IN_SCOPE_PROJECTS:-}")
  held=$(ordo_scope_normalize_list "${ORCH_SCOPE_HELD_PROJECTS:-}")
  out=$(ordo_scope_normalize_list "${ORCH_SCOPE_OUT_OF_SCOPE_PROJECTS:-}")
  classification=$(ordo_scope_classify "$active_key")
  cat <<EOF
## ${title}

- active project key: \`${active_key}\`
- active repo: \`${active_repo:-<not provided>}\`
- active branch: \`${active_branch:-<not provided>}\`
- scope classification: \`${classification}\`
- in-scope project keys (allowlist): \`${in:-<none-configured>}\`
- held project keys (work paused, awaiting external gate): \`${held:-<none>}\`
- out-of-scope project keys (forbidden for autonomous dispatch): \`${out:-<none>}\`

The classification above is computed by configured project key, not by
repo path or naming inference. If the active project key resolves to
\`unknown\` or \`out_of_scope\`, the agent must STOP and report
\`needs_scope_clarification\` with the operator-supplied keys, the active
project key, and the active repo URL. Do NOT infer scope from prose
like "business repository", "product app", or "company website" — the
explicit keys above are the source of truth.

Recovery path for the orchestrator:
  1. Re-read the operator profile for this deployment.
  2. Update \`ORCH_SCOPE_IN_SCOPE_PROJECTS\` / \`ORCH_SCOPE_HELD_PROJECTS\`
     / \`ORCH_SCOPE_OUT_OF_SCOPE_PROJECTS\` to bind the missing key
     explicitly, OR re-dispatch the agent with the correct active project
     key, OR record an explicit per-action authorization in a controlled
     operation evidence file.
  3. Re-render the dispatch brief and re-dispatch.
EOF
}

ordo_scope_validate_active() {
  # Return 0 if the active project may proceed (in_scope or held).
  # Held passes validation but the brief still flags the held state so
  # the agent is aware. out_of_scope and (when ORCH_SCOPE_STRICT is on)
  # unknown both emit a structured needs_scope_clarification line on
  # stderr and return non-zero. The structured line is the orchestrator's
  # recovery handle.
  local active_key=${1:?usage: ordo_scope_validate_active <active-project-key>}
  local classification
  classification=$(ordo_scope_classify "$active_key")
  case "$classification" in
    in_scope|held)
      return 0
      ;;
    out_of_scope)
      printf 'needs_scope_clarification: active=%s classification=out_of_scope source=ORCH_SCOPE_OUT_OF_SCOPE_PROJECTS\n' \
        "$(ordo_scope_normalize_key "$active_key")" >&2
      return 1
      ;;
    unknown)
      if ordo_scope_strict_enabled; then
        printf 'needs_scope_clarification: active=%s classification=unknown source=ORCH_SCOPE_*_PROJECTS-not-bound strict=1\n' \
          "$(ordo_scope_normalize_key "$active_key")" >&2
        return 1
      fi
      return 0
      ;;
  esac
}
