#!/usr/bin/env bash
# lib/pr_ops_mode.sh — universal PR operations mode policy (#357 / #360).
#
# Why this exists:
#   The #357 epic asks ORDO to expose explicit, profile-driven PR
#   operations modes so the orchestrator/operator can keep tighter
#   control over final PR mutations on stricter portfolios while
#   still letting agents prepare evidence and patches. This module
#   delivers the *centralized* mode policy (issue #360) and lays a
#   stable foundation for the other modes — observe, delegated,
#   autonomous — to land in follow-ups without a schema break.
#
# Modes:
#   observe      Read-only. Final mutations are always refused.
#                Default when no profile/env value is set.
#   centralized  Final mutations require actor=operator AND every
#                required gate satisfied. Agents may still perform
#                preparation actions. Operator override is allowed
#                only when explicitly enabled in profile.
#   delegated    Reserved for #361 (delegated remediation). Final
#                mutations are refused by this controller until
#                that PR lands so the policy stays explicit.
#   autonomous   Reserved for #362 (autonomous merge gates). Same
#                refusal policy as delegated until it ships.
#
# Universal contract:
#   - No CLI vendor (Claude / codex / copilot) is hardcoded.
#   - No project name is hardcoded.
#   - Actor identity is supplied via env (ORDO_PR_OPS_ACTOR), with
#     "agent" the default; the operator pane sets it to "operator"
#     before invoking the controller.
#   - Required gates are configured per-action via bash arrays
#     (ORDO_PR_OPS_REQUIRED_GATES_<ACTION>) so any project profile
#     can declare its own gate list.
#
# Exit codes (reserved here, mapped in docs/exit-codes.md follow-up):
#   90 ORCH_PR_OPS_UNAUTHORIZED_ACTOR_EXIT_CODE — actor not allowed
#   91 ORCH_PR_OPS_GATE_FAILED_EXIT_CODE        — required gate missing
#   92 ORCH_PR_OPS_OVERRIDE_DENIED_EXIT_CODE    — override disabled in profile

# shellcheck disable=SC2155 # readonly compound assignment is fine here.
ORDO_PR_OPS_FINAL_ACTIONS=(merge ready-for-review rerun close branch-delete)
ORDO_PR_OPS_PREP_ACTIONS=(prepare-fix evidence-record comment-audit-only report-status)
ORDO_PR_OPS_VALID_MODES=(observe centralized delegated autonomous)

: "${ORCH_PR_OPS_UNAUTHORIZED_ACTOR_EXIT_CODE:=90}"
: "${ORCH_PR_OPS_GATE_FAILED_EXIT_CODE:=91}"
: "${ORCH_PR_OPS_OVERRIDE_DENIED_EXIT_CODE:=92}"

# Echo the configured PR ops mode. Resolution order:
#   1. ORDO_PR_OPS_MODE (env override; per-session)
#   2. PR_OPS_MODE       (project profile / portfolio config)
#   3. "observe"         (default — least surprising)
pr_ops_mode() {
  local mode="${ORDO_PR_OPS_MODE:-${PR_OPS_MODE:-observe}}"
  case " ${ORDO_PR_OPS_VALID_MODES[*]} " in
    *" $mode "*)
      printf '%s' "$mode"
      return 0
      ;;
  esac
  printf 'pr_ops_mode: invalid mode %q (valid: %s)\n' \
    "$mode" "${ORDO_PR_OPS_VALID_MODES[*]}" >&2
  return 2
}

# Echo the actor name. Default "agent" so unauthenticated callers
# never accidentally receive operator privileges.
pr_ops_actor() {
  printf '%s' "${ORDO_PR_OPS_ACTOR:-agent}"
}

pr_ops_action_is_final() {
  local action=${1:?usage: pr_ops_action_is_final <action>}
  case " ${ORDO_PR_OPS_FINAL_ACTIONS[*]} " in
    *" $action "*) return 0 ;;
  esac
  return 1
}

pr_ops_action_is_preparation() {
  local action=${1:?usage: pr_ops_action_is_preparation <action>}
  case " ${ORDO_PR_OPS_PREP_ACTIONS[*]} " in
    *" $action "*) return 0 ;;
  esac
  return 1
}

pr_ops_action_is_valid() {
  local action=${1:?usage: pr_ops_action_is_valid <action>}
  pr_ops_action_is_final "$action" || pr_ops_action_is_preparation "$action"
}

# pr_ops_required_gates <action>
#
# Echo, one gate per line, the gates that must be satisfied for
# <action> to be allowed in centralized / autonomous modes. Source
# of truth is the bash array ORDO_PR_OPS_REQUIRED_GATES_<ACTION>
# (uppercased, dashes -> underscores). When unset, falls back to a
# small default per known final action.
pr_ops_required_gates() {
  local action=${1:?usage: pr_ops_required_gates <action>}
  local var
  var="ORDO_PR_OPS_REQUIRED_GATES_$(printf '%s' "$action" \
    | tr '[:lower:]' '[:upper:]' \
    | tr '-' '_')"
  if declare -p "$var" >/dev/null 2>&1; then
    # shellcheck disable=SC1087  # ${!var[*]} not portable; use namedref
    local -n _ref="$var"
    if [ "${#_ref[@]}" -gt 0 ]; then
      printf '%s\n' "${_ref[@]}"
      return 0
    fi
  fi
  case "$action" in
    merge)            printf 'ci\nreview\n' ;;
    ready-for-review) printf 'ci\n' ;;
    rerun|close|branch-delete) ;;
    *) ;;
  esac
}

# pr_ops_override_allowed
#
# Returns 0 when the project profile permits an explicit operator
# override (--override <reason>). Default: disabled.
pr_ops_override_allowed() {
  case "${ORDO_PR_OPS_OVERRIDE_ENABLED:-0}" in
    1|true|yes|on|TRUE|YES|ON) return 0 ;;
  esac
  return 1
}

# pr_ops_check_authorization <action> <gates-passed-csv> [<override-reason>]
#
# Stdout: a one-line JSON decision with these fields:
#   action, mode, actor, required_gates[], passed_gates[],
#   override_reason (string|null), decision ("allowed"|"refused"),
#   reason (machine-readable kebab code).
#
# Exit code:
#   0   when the decision is "allowed";
#   90  when refusal is due to actor authorization;
#   91  when refusal is due to missing required gate;
#   92  when refusal is due to override-disabled profile;
#   2   when the action or mode is invalid.
pr_ops_check_authorization() {
  local action=${1:?usage: pr_ops_check_authorization <action> <gates-passed-csv> [<override-reason>]}
  local gates_passed_csv=${2:-}
  local override_reason=${3:-}
  local mode actor required_csv

  if ! pr_ops_action_is_valid "$action"; then
    _pr_ops_emit_decision \
      "$action" "" "" "" "$gates_passed_csv" "$override_reason" \
      "refused" "unknown_action"
    return 2
  fi

  if ! mode=$(pr_ops_mode); then
    return 2
  fi
  actor=$(pr_ops_actor)
  required_csv=$(pr_ops_required_gates "$action" | paste -sd, -)

  # Preparation actions: always allowed. Agents and operator alike
  # can record evidence and prepare patches in every mode.
  if pr_ops_action_is_preparation "$action"; then
    _pr_ops_emit_decision \
      "$action" "$mode" "$actor" "$required_csv" "$gates_passed_csv" \
      "$override_reason" "allowed" "preparation_action"
    return 0
  fi

  # Final actions: per-mode policy.
  case "$mode" in
    observe)
      _pr_ops_emit_decision \
        "$action" "$mode" "$actor" "$required_csv" "$gates_passed_csv" \
        "$override_reason" "refused" "observe_mode_refuses_final_mutation"
      return "$ORCH_PR_OPS_UNAUTHORIZED_ACTOR_EXIT_CODE"
      ;;
    centralized)
      if [ "$actor" != "operator" ]; then
        if [ -n "$override_reason" ]; then
          if ! pr_ops_override_allowed; then
            _pr_ops_emit_decision \
              "$action" "$mode" "$actor" "$required_csv" "$gates_passed_csv" \
              "$override_reason" "refused" "override_disabled"
            return "$ORCH_PR_OPS_OVERRIDE_DENIED_EXIT_CODE"
          fi
          # Override accepted: skip both actor check and gate check.
          # The operator is intentionally bypassing the policy and
          # owns the audit consequence.
          _pr_ops_emit_decision \
            "$action" "$mode" "$actor" "$required_csv" "$gates_passed_csv" \
            "$override_reason" "allowed" "operator_override"
          return 0
        fi
        _pr_ops_emit_decision \
          "$action" "$mode" "$actor" "$required_csv" "$gates_passed_csv" \
          "$override_reason" "refused" "centralized_mode_agent_actor"
        return "$ORCH_PR_OPS_UNAUTHORIZED_ACTOR_EXIT_CODE"
      fi
      # Operator actor — gates must be satisfied unless an explicit
      # override is provided AND profile permits it.
      if ! _pr_ops_gates_satisfied "$required_csv" "$gates_passed_csv"; then
        if [ -n "$override_reason" ] && pr_ops_override_allowed; then
          _pr_ops_emit_decision \
            "$action" "$mode" "$actor" "$required_csv" "$gates_passed_csv" \
            "$override_reason" "allowed" "operator_override"
          return 0
        fi
        _pr_ops_emit_decision \
          "$action" "$mode" "$actor" "$required_csv" "$gates_passed_csv" \
          "$override_reason" "refused" "missing_required_gate"
        return "$ORCH_PR_OPS_GATE_FAILED_EXIT_CODE"
      fi
      _pr_ops_emit_decision \
        "$action" "$mode" "$actor" "$required_csv" "$gates_passed_csv" \
        "$override_reason" "allowed" "operator_authorized"
      return 0
      ;;
    delegated|autonomous)
      # Reserved for follow-up issues. Refuse explicitly so this PR
      # does not accidentally enable broader modes.
      _pr_ops_emit_decision \
        "$action" "$mode" "$actor" "$required_csv" "$gates_passed_csv" \
        "$override_reason" "refused" \
        "mode_${mode}_not_implemented_in_pr_360"
      return "$ORCH_PR_OPS_UNAUTHORIZED_ACTOR_EXIT_CODE"
      ;;
  esac
}

# Internal: returns 0 when every gate listed in required_csv also
# appears in passed_csv. An empty required_csv means no gates.
_pr_ops_gates_satisfied() {
  local required_csv=$1 passed_csv=$2
  [ -n "$required_csv" ] || return 0
  local gate
  while IFS= read -r gate; do
    [ -n "$gate" ] || continue
    case ",$passed_csv," in
      *",$gate,"*) ;;
      *) return 1 ;;
    esac
  done < <(printf '%s\n' "$required_csv" | tr ',' '\n')
  return 0
}

# Internal: emit a one-line JSON decision payload to stdout.
_pr_ops_emit_decision() {
  local action=$1 mode=$2 actor=$3 required=$4 passed=$5 override=$6 status=$7 reason=$8
  jq -nc \
    --arg action "$action" \
    --arg mode "$mode" \
    --arg actor "$actor" \
    --arg required "$required" \
    --arg passed "$passed" \
    --arg override "$override" \
    --arg status "$status" \
    --arg reason "$reason" \
    '{
      action: $action,
      mode: (if $mode == "" then null else $mode end),
      actor: (if $actor == "" then null else $actor end),
      required_gates: ($required | split(",") | map(select(length > 0))),
      passed_gates: ($passed | split(",") | map(select(length > 0))),
      override_reason: (if $override == "" then null else $override end),
      decision: $status,
      reason: $reason
    }'
}
