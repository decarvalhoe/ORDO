#!/usr/bin/env bash
# external_mutation_gate.sh — repo-/provider-neutral gate for external PR
# (and adjacent issue) mutations.
#
# Purpose
#   ORDO's audit-vs-external-mutation boundary (Required Rule 11) requires
#   that every GitHub mutation call site asks the gate for permission before
#   it actually mutates a third-party-managed repo. Without a single gate
#   helper, future scripts can call `gh pr merge`, `gh pr comment`,
#   `gh pr edit --add-label`, `gh pr edit --add-assignee`, `gh issue edit`,
#   etc. and silently bypass the audit-only default.
#
# Design
#   - audit-only by default: with no env, every refusable scope is denied
#     and refusals exit with $ORCH_EXTERNAL_PR_MUTATION_EXIT_CODE (80).
#   - audit_evidence is always allowed because it never leaves the host.
#   - Operators authorize scopes via ORCH_EXTERNAL_PR_MUTATIONS — a
#     comma-separated list, or the literal "all" wildcard.
#   - Repo-/provider-neutral: scope names describe abstract actions only.
#
# Sourcing contract
#   audit_log.sh must already be sourced (this file calls audit() to record
#   gate decisions). Callers normally do:
#
#     source "$TK/lib/audit_log.sh"
#     source "$TK/lib/external_mutation_gate.sh"
#
#   When audit() is unavailable (e.g. in unit tests that skip audit_log.sh),
#   the gate degrades to silent — it still enforces the policy, it just
#   does not emit an AUDIT line.
#
# Public functions
#   external_pr_mutation_known_scopes
#   external_pr_mutation_scope_known <scope>
#   external_pr_mutation_authorized <scope>
#   external_pr_mutation_assert <scope> [context]
#   external_pr_mutation_classify_gh <topic> <action>
#   external_pr_mutation_classify_gh_args <topic> <action> [<gh-args>...]
#   external_pr_mutation_run <context> -- <gh-args>...
#   record_local_gate_evidence <slug> [content]

: "${ORCH_EXTERNAL_PR_MUTATION_EXIT_CODE:=80}"
: "${ORCH_EXTERNAL_PR_MUTATIONS:=}"

# Repo-/provider-neutral scope registry. Order: most local -> most invasive.
# audit_evidence covers local-only evidence capture (always allowed).
# issue_pack_notify covers orchestrator-bound issue-pack notifications.
# pr_* / issue_* cover external mutations on a third-party-managed repo.
ORCH_EXTERNAL_PR_MUTATION_KNOWN_SCOPES="audit_evidence \
issue_pack_notify \
pr_comment \
pr_edit \
pr_state \
pr_labels \
pr_assignees \
pr_review \
pr_ready \
pr_merge \
pr_close \
pr_reopen \
issue_create \
issue_comment \
issue_edit \
issue_labels \
issue_assignees \
issue_close \
issue_reopen"

external_pr_mutation_known_scopes() {
  # Intentional word-splitting on whitespace — the registry is a single
  # whitespace-delimited string for readability; each scope must be emitted
  # on its own line.
  # shellcheck disable=SC2086
  printf '%s\n' $ORCH_EXTERNAL_PR_MUTATION_KNOWN_SCOPES
}

external_pr_mutation_scope_known() {
  local scope=${1:-}
  [ -n "$scope" ] || return 1
  local known
  for known in $ORCH_EXTERNAL_PR_MUTATION_KNOWN_SCOPES; do
    [ "$known" = "$scope" ] && return 0
  done
  return 1
}

# Returns 0 (allowed), 1 (not authorized), or 2 (unknown scope).
external_pr_mutation_authorized() {
  local scope=${1:?usage: external_pr_mutation_authorized <scope>}
  external_pr_mutation_scope_known "$scope" || return 2
  [ "$scope" = "audit_evidence" ] && return 0
  local list=${ORCH_EXTERNAL_PR_MUTATIONS:-}
  [ -n "$list" ] || return 1
  [ "$list" = "all" ] && return 0
  local entry
  local IFS=,
  for entry in $list; do
    entry=${entry# }
    entry=${entry% }
    [ "$entry" = "$scope" ] && return 0
  done
  return 1
}

# Internal: emit a structured audit line iff audit() is available.
_external_pr_mutation_audit_signal() {
  local scope=${1:?}
  local mode=${2:?}
  local context=${3:-}
  if declare -F audit_external_mutation >/dev/null 2>&1; then
    audit_external_mutation "$scope" "$mode" "$context"
  elif declare -F audit >/dev/null 2>&1; then
    audit "EXTERNAL_PR_MUTATION action=${scope} mode=${mode} context=${context}"
  fi
}

# external_pr_mutation_assert <scope> [context]
#   - exits 0 if the scope is authorized,
#   - exits $ORCH_EXTERNAL_PR_MUTATION_EXIT_CODE if not authorized,
#   - exits 2 if the scope is unknown.
# Always emits an audit signal so refusals are observable.
external_pr_mutation_assert() {
  local scope=${1:?usage: external_pr_mutation_assert <scope> [context]}
  local context=${2:-external-mutation}
  local rc=0
  external_pr_mutation_authorized "$scope" || rc=$?
  case "$rc" in
    0)
      _external_pr_mutation_audit_signal "$scope" allowed "$context"
      return 0
      ;;
    2)
      _external_pr_mutation_audit_signal "$scope" unknown "$context"
      printf 'external_pr_mutation_unknown_scope: scope=%s context=%s known=%s\n' \
        "$scope" "$context" "$(external_pr_mutation_known_scopes | paste -sd, -)" >&2
      return 2
      ;;
    *)
      _external_pr_mutation_audit_signal "$scope" refused "$context"
      printf 'external_pr_mutation_refused: scope=%s context=%s authorize via ORCH_EXTERNAL_PR_MUTATIONS\n' \
        "$scope" "$context" >&2
      return "$ORCH_EXTERNAL_PR_MUTATION_EXIT_CODE"
      ;;
  esac
}

# external_pr_mutation_classify_gh <topic> <action>
#   Map a gh subcommand pair to its mutation scope name. Stdout is the scope;
#   exit 1 if the (topic, action) pair is read-only or unsupported.
external_pr_mutation_classify_gh() {
  local topic=${1:-}
  local action=${2:-}
  case "$topic $action" in
    "pr merge")      printf 'pr_merge' ;;
    "pr comment")    printf 'pr_comment' ;;
    "pr edit")       printf 'pr_edit' ;;
    "pr review")     printf 'pr_review' ;;
    "pr ready")      printf 'pr_ready' ;;
    "pr close")      printf 'pr_close' ;;
    "pr reopen")     printf 'pr_reopen' ;;
    "pr create")     printf 'pr_state' ;;
    "issue create")  printf 'issue_create' ;;
    "issue comment") printf 'issue_comment' ;;
    "issue edit")    printf 'issue_edit' ;;
    "issue close")   printf 'issue_close' ;;
    "issue reopen")  printf 'issue_reopen' ;;
    *) return 1 ;;
  esac
}

# external_pr_mutation_classify_gh_args <topic> <action> [<gh-args>...]
#   Like classify_gh, but refines pr_edit/issue_edit when --add-label,
#   --remove-label, --add-assignee, or --remove-assignee narrows the scope.
external_pr_mutation_classify_gh_args() {
  local topic=${1:-}
  local action=${2:-}
  shift 2 2>/dev/null || true
  local base
  base=$(external_pr_mutation_classify_gh "$topic" "$action") || return 1
  case "$base" in
    pr_edit|issue_edit)
      local subject=${base%%_edit}
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --add-label|--remove-label)
            printf '%s_labels' "$subject"
            return 0
            ;;
          --add-assignee|--remove-assignee)
            printf '%s_assignees' "$subject"
            return 0
            ;;
        esac
        shift
      done
      printf '%s' "$base"
      ;;
    *) printf '%s' "$base" ;;
  esac
}

# external_pr_mutation_run <context> -- <gh-args>...
#   Convenience wrapper: classify the gh invocation, assert if it is a
#   mutation, then exec gh. Read-only gh invocations pass through unchanged.
external_pr_mutation_run() {
  local context=${1:?usage: external_pr_mutation_run <context> -- <gh-args>...}
  shift
  if [ "${1:-}" = "--" ]; then
    shift
  fi
  local topic=${1:-}
  local action=${2:-}
  local scope rc=0
  scope=$(external_pr_mutation_classify_gh_args "$topic" "$action" "$@" 2>/dev/null) || scope=
  if [ -n "$scope" ]; then
    external_pr_mutation_assert "$scope" "$context" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
  fi
  command gh "$@"
}

# record_local_gate_evidence <slug> [content]
#   Audit-only fallback: persist evidence under
#   <state-dir>/gate-evidence/<slug>.md and emit an audit signal. Echoes the
#   final path on stdout so callers can reference it in their own report.
record_local_gate_evidence() {
  local slug=${1:?usage: record_local_gate_evidence <slug> [content]}
  local content=${2:-}
  local dir target
  if declare -F state_dir >/dev/null 2>&1; then
    dir="$(state_dir)/gate-evidence"
  else
    dir="${ORCH_STATE_BASE:-${XDG_DATA_HOME:-/root/.local/share}/orch-state}/${PROJECT:-default}/gate-evidence"
  fi
  mkdir -p "$dir"
  # Slug is a filename-safe identifier; collapse anything else to '_'.
  local safe_slug
  safe_slug=$(printf '%s' "$slug" | tr -c 'A-Za-z0-9._-' '_')
  target="$dir/${safe_slug}.md"
  if [ -n "$content" ]; then
    printf '%s\n' "$content" > "$target"
  else
    : > "$target"
  fi
  _external_pr_mutation_audit_signal audit_evidence allowed "record_local_gate_evidence:${safe_slug}:${target}"
  printf '%s\n' "$target"
}
