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

ordo_scope_brief_classification() {
  # Issue #488 — extract the classification token rendered into a brief's
  # Scope Posture block. Echo one of:
  #   in_scope | held | out_of_scope | unknown — when the brief carries a
  #     well-formed scope-classification line
  #   missing — when the brief has no Scope Posture block (legacy fixtures
  #     or hand-rolled briefs that predate #343)
  # The grep anchors on `^- scope classification:` so it matches the
  # rendered bullet line and not the recovery prose ("If the active
  # project key resolves to `unknown` ...") that also mentions the tokens.
  local brief_file=${1:?usage: ordo_scope_brief_classification <brief-file>}
  local line classification
  if [[ ! -r "$brief_file" ]]; then
    printf 'missing\n'
    return 0
  fi
  line=$(grep -m1 '^- scope classification:' "$brief_file" 2>/dev/null || printf '')
  if [[ -z "$line" ]]; then
    printf 'missing\n'
    return 0
  fi
  classification=$(printf '%s' "$line" \
    | sed -n 's/^- scope classification:[[:space:]]*`\([^`]*\)`.*$/\1/p')
  if [[ -z "$classification" ]]; then
    printf 'missing\n'
    return 0
  fi
  printf '%s\n' "$classification"
}

ordo_scope_brief_active_key() {
  # Issue #488 — extract the active project key from the brief's Scope
  # Posture block. Echoes the empty string when the brief has no
  # active-project-key line (legacy fixtures). Used by the dispatch
  # preflight so the audit/refusal message names the key the operator
  # needs to re-bind.
  local brief_file=${1:?usage: ordo_scope_brief_active_key <brief-file>}
  [[ -r "$brief_file" ]] || return 0
  grep -m1 '^- active project key:' "$brief_file" 2>/dev/null \
    | sed -n 's/^- active project key:[[:space:]]*`\([^`]*\)`.*$/\1/p'
}

ordo_scope_dispatch_preflight() {
  # Issue #488 — refuse a dispatch BEFORE assignment persistence and
  # BEFORE any tmux pane writes when the rendered brief carries
  # `scope classification: unknown` or `out_of_scope`. The orchestrator
  # would otherwise mark the lane occupied while the worker
  # short-circuits with needs_scope_clarification, leaving the
  # assignments ledger stale and the lane appearing busy while doing no
  # work.
  #
  # Return 0 (proceed) when classification is in_scope, held, or missing
  # (missing preserves backward compatibility with legacy fixtures /
  # briefs predating #343). Return 1 (refuse) for unknown / out_of_scope
  # / brief-malformed, after writing a structured needs_scope_clarification
  # line to stderr.
  #
  # The two globals below let the caller (dispatch_ticket.sh) audit the
  # classification and active key without re-parsing the brief.
  local brief_file=${1:?usage: ordo_scope_dispatch_preflight <brief-file>}
  local classification active_key
  classification=$(ordo_scope_brief_classification "$brief_file")
  active_key=$(ordo_scope_brief_active_key "$brief_file")
  ORDO_SCOPE_DISPATCH_PREFLIGHT_CLASSIFICATION="$classification"
  ORDO_SCOPE_DISPATCH_PREFLIGHT_ACTIVE_KEY="$active_key"
  case "$classification" in
    in_scope|held|missing)
      return 0
      ;;
    unknown)
      printf 'needs_scope_clarification: active=%s classification=unknown source=ORCH_SCOPE_*_PROJECTS-not-bound — refuse dispatch before assignment persistence; bind the active project key in ORCH_SCOPE_IN_SCOPE_PROJECTS or re-dispatch with the correct active project key\n' \
        "${active_key:-<unknown>}" >&2
      return 1
      ;;
    out_of_scope)
      printf 'needs_scope_clarification: active=%s classification=out_of_scope source=ORCH_SCOPE_OUT_OF_SCOPE_PROJECTS — refuse dispatch before assignment persistence; remove the key from the out-of-scope list or re-dispatch with the correct active project key\n' \
        "${active_key:-<unknown>}" >&2
      return 1
      ;;
    *)
      printf 'needs_scope_clarification: active=%s classification=%s source=brief-malformed — refuse dispatch before assignment persistence; re-render the brief\n' \
        "${active_key:-<unknown>}" "$classification" >&2
      return 1
      ;;
  esac
}
