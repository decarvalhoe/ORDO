#!/usr/bin/env bash
# lib/pr_ops_tasks.sh — pure helpers for delegated PR operations dispatch (#359).
#
# Issue #359 (parent epic #357): when PRs are blocked by CI, conflicts, stale
# branches, or readiness cleanup, the orchestrator should be able to assign
# bounded remediation work to fleet agents instead of handling every unblock
# centrally.
#
# This module is universal — no Claude/Codex/Copilot/Cursor/Gemini-specific
# assumptions, no project-name hardcoding. Inputs are JSON shapes already
# emitted by `scripts/pr_block_signals.sh` and `scripts/agent_pool_status.sh`.
# Outputs are dispatch markdown rendered from operator-owned templates under
# `templates/pr_op_*.md.tpl`.
#
# Public functions:
#   pr_ops_classify_signals     — pick one task kind from a PR signal CSV.
#   pr_ops_mutation_scope_for   — list allowed PR mutations for a task kind.
#   pr_ops_template_path        — resolve the template path for a task kind.
#   pr_ops_render_template      — substitute placeholders into a template.
#   pr_ops_validate_candidate   — refuse on dirty clone, unknown mergeability,
#                                  duplicate assignment, hotspot conflict, or
#                                  missing project policy.
#
# Capacity classes consumed (from pr_block_signals signals[] field):
#   ci-failed           → fix_ci
#   ci-pending          → not actionable on its own (wait for CI)
#   merge-conflict      → resolve_conflict
#   needs-rebase        → resolve_conflict
#   draft               → mark_ready_candidate (when CI passes and no other blocker)
#   merge-blocked       → not auto-assigned (operator/orch only)
#   merge-ready         → not auto-assigned (operator/orch merges directly)

# Recognised task kinds. Order matters for tests that iterate the list.
# shellcheck disable=SC2034 # consumed by callers after sourcing
PR_OPS_TASK_KINDS=(fix_ci resolve_conflict mark_ready_candidate)

# Recognised PR-ops modes (epic #357). Only `delegated` and `centralized` are
# in scope for this iteration; `autonomous` is reserved for a future PR.
# shellcheck disable=SC2034 # consumed by callers after sourcing
PR_OPS_MODES=(observe centralized delegated autonomous)

# Default refusal exit code for missing-policy / blocker outcomes. Operators
# can override via env without touching this file.
: "${ORCH_PR_OPS_REFUSED_EXIT_CODE:=80}"

# Classify a comma-separated signal list (from pr_block_signals.sh) into the
# single highest-priority remediation task kind. Echo the kind on stdout, or
# the literal string `none` when no remediation applies.
#
# Priority order: resolve_conflict > fix_ci > mark_ready_candidate > none.
# Reasoning: a conflict will block any later fix-CI run and any readiness
# flip; CI must be green before we ask anyone to mark a draft ready.
pr_ops_classify_signals() {
  local signals_csv=${1:-}
  case ",$signals_csv," in
    *,merge-conflict,*) printf 'resolve_conflict\n'; return 0 ;;
  esac
  case ",$signals_csv," in
    *,needs-rebase,*) printf 'resolve_conflict\n'; return 0 ;;
  esac
  case ",$signals_csv," in
    *,ci-failed,*) printf 'fix_ci\n'; return 0 ;;
  esac
  case ",$signals_csv," in
    *,draft,*)
      case ",$signals_csv," in
        *,ci-pass,*) printf 'mark_ready_candidate\n'; return 0 ;;
      esac
      ;;
  esac
  printf 'none\n'
}

# Allowed mutation scopes for a task kind. Values match the
# `external-pr-mutations` scope vocabulary in `lib/audit_log.sh`. The list is
# intentionally restrictive: agents may push to the feature branch (covered by
# the standard worktree contract, not by this scope vocabulary), but they
# must not by default flip draft/ready, edit labels/assignees, comment, or
# merge unless the active mode/policy explicitly grants the relevant scope.
pr_ops_mutation_scope_for() {
  local kind=${1:?usage: pr_ops_mutation_scope_for <kind>}
  case "$kind" in
    fix_ci|resolve_conflict)
      printf 'audit_evidence\n'
      ;;
    mark_ready_candidate)
      printf 'audit_evidence,pr_state\n'
      ;;
    *)
      printf 'audit_evidence\n'
      ;;
  esac
}

# Resolve the template path (relative to TK) for a task kind. The script that
# calls into this module is responsible for setting TK to the toolkit root.
pr_ops_template_path() {
  local kind=${1:?usage: pr_ops_template_path <kind>}
  local template_dir=${PR_OPS_TEMPLATE_DIR:-templates}
  case "$kind" in
    fix_ci)               printf '%s/pr_op_fix_ci.md.tpl\n' "$template_dir" ;;
    resolve_conflict)     printf '%s/pr_op_resolve_conflict.md.tpl\n' "$template_dir" ;;
    mark_ready_candidate) printf '%s/pr_op_mark_ready_candidate.md.tpl\n' "$template_dir" ;;
    *)
      printf 'pr_ops_template_path: unknown kind %s\n' "$kind" >&2
      return 2 ;;
  esac
}

# Render a template by substituting `{{KEY}}` tokens. Reads the file named by
# $1 and echoes to stdout. Substitutions come from the environment variables
# prefixed `PR_OPS_TPL_` (e.g. PR_OPS_TPL_PR_URL → `{{PR_URL}}`). Unknown
# placeholders are left as the literal `{{KEY}}` token so a misnamed key
# surfaces obviously in the rendered prompt rather than silently disappearing.
#
# The walker advances past every match (substituted or not) so a literal
# fallback never re-triggers the regex on the next iteration. Without that
# guard, an unset placeholder would loop forever.
pr_ops_render_template() {
  local template_file=${1:?usage: pr_ops_render_template <template-file>}
  [ -f "$template_file" ] || { printf 'pr_ops_render_template: template not found: %s\n' "$template_file" >&2; return 2; }

  # Inline-prefix assignments (`VAR=val func`) make a variable visible inside
  # the function's shell scope but DO NOT export it to a subprocess started
  # from the function. Re-export every PR_OPS_TPL_* variable currently set
  # in this shell so awk's ENVIRON dictionary picks them up.
  local _pr_ops_var
  while IFS= read -r _pr_ops_var; do
    [ -n "$_pr_ops_var" ] || continue
    export "${_pr_ops_var?}"
  done < <(compgen -v PR_OPS_TPL_ 2>/dev/null || true)

  awk '
    {
      line = $0
      out = ""
      while (1) {
        if (match(line, /\{\{[A-Z_][A-Z0-9_]*\}\}/) == 0) {
          out = out line
          break
        }
        out = out substr(line, 1, RSTART - 1)
        token = substr(line, RSTART + 2, RLENGTH - 4)
        env_key = "PR_OPS_TPL_" token
        if (env_key in ENVIRON) {
          out = out ENVIRON[env_key]
        } else {
          out = out substr(line, RSTART, RLENGTH)
        }
        line = substr(line, RSTART + RLENGTH)
      }
      print out
    }
  ' "$template_file"
}

# Validate a candidate (PR + agent + portfolio state) before emitting a task.
# Returns 0 when the candidate is dispatchable. Returns
# $ORCH_PR_OPS_REFUSED_EXIT_CODE and prints a single blocker reason on stderr
# otherwise. Inputs are passed by argument so the function stays pure and is
# trivially testable.
#
#   $1 task_kind          one of fix_ci|resolve_conflict|mark_ready_candidate
#   $2 mergeable          PR's mergeable field (MERGEABLE|CONFLICTING|UNKNOWN)
#   $3 agent_dirty        agent workdir dirty count (0 = clean)
#   $4 agent_capacity     capacity class from agent_pool_status (#278) — must
#                          be `available` to receive a new PR-op task
#   $5 mode               pr-ops mode (observe|centralized|delegated|autonomous)
#   $6 hotspot_conflict   "1" when the PR's files overlap another open PR
#                          owned by a different agent in the same wave; "0"
#                          otherwise
#   $7 already_assigned   "1" when this agent is already carrying another PR-op
#                          task in this dispatch wave; "0" otherwise
pr_ops_validate_candidate() {
  local kind=${1:?usage: pr_ops_validate_candidate <kind> <mergeable> <agent_dirty> <agent_capacity> <mode> <hotspot_conflict> <already_assigned>}
  local mergeable=${2:-UNKNOWN}
  local agent_dirty=${3:-0}
  local agent_capacity=${4:-unknown}
  local mode=${5:-observe}
  local hotspot_conflict=${6:-0}
  local already_assigned=${7:-0}

  case "$mode" in
    observe)
      printf 'mode-observe-emits-no-task\n' >&2
      return "$ORCH_PR_OPS_REFUSED_EXIT_CODE" ;;
    centralized|delegated|autonomous) ;;
    *)
      printf 'unknown-mode:%s\n' "$mode" >&2
      return "$ORCH_PR_OPS_REFUSED_EXIT_CODE" ;;
  esac

  case "$mergeable" in
    UNKNOWN|"")
      printf 'mergeability-unknown\n' >&2
      return "$ORCH_PR_OPS_REFUSED_EXIT_CODE" ;;
    CONFLICTING)
      if [ "$kind" != "resolve_conflict" ]; then
        printf 'mergeability-conflicting-but-task-kind=%s\n' "$kind" >&2
        return "$ORCH_PR_OPS_REFUSED_EXIT_CODE"
      fi ;;
  esac

  if [ "${agent_dirty:-0}" != "0" ]; then
    printf 'dirty-clone\n' >&2
    return "$ORCH_PR_OPS_REFUSED_EXIT_CODE"
  fi

  case "$agent_capacity" in
    available) ;;
    *)
      printf 'agent-not-available:%s\n' "$agent_capacity" >&2
      return "$ORCH_PR_OPS_REFUSED_EXIT_CODE" ;;
  esac

  if [ "$already_assigned" = "1" ]; then
    printf 'duplicate-assignment\n' >&2
    return "$ORCH_PR_OPS_REFUSED_EXIT_CODE"
  fi

  if [ "$hotspot_conflict" = "1" ]; then
    printf 'hotspot-conflict-with-other-pr\n' >&2
    return "$ORCH_PR_OPS_REFUSED_EXIT_CODE"
  fi

  if [ "$kind" = "mark_ready_candidate" ] && [ "$mode" = "centralized" ]; then
    printf 'mark-ready-requires-delegated-or-autonomous\n' >&2
    return "$ORCH_PR_OPS_REFUSED_EXIT_CODE"
  fi

  return 0
}
