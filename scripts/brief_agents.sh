#!/usr/bin/env bash
# scripts/brief_agents.sh — render a templated dispatch markdown for an agent
# from the canonical dispatch template and a kvargs list.
#
# Usage:
#   brief_agents.sh <project_short|config_path> <agent> <ticket#> [--require-local-validators] [--allow-unknown-scope] [--audit-only] [k=v ...]
#   k=v keys recognized by the default template:
#     branch_slug=     (e.g. feat/sfi-01-source-segment-ledger)
#     base_sha=        (sha of main the agent must branch from)
#     scope_files=     (glob list of files agent may modify)
#     forbidden_files= (glob list agent must NOT touch)
#     validation=      (command the agent must run before commit)
#     summary=         (one-line ticket summary)
#
# Empty allowed-files scope (#538): implementation briefs must declare at
# least one allowed file via scope_files=. Briefs that intentionally
# carry no mutation scope (audit, diagnostic, observation) must pass
# `--audit-only` so the dispatch leaves an explicit ledger entry instead
# of pinning a worker pane against an unmutatable scope.
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
source "$TK/lib/host_load_gate.sh"
source "$TK/lib/scope_check.sh"
source "$TK/lib/prompt_integrity.sh"
# shellcheck source=../lib/brief_acceptance.sh
source "$TK/lib/brief_acceptance.sh"
# shellcheck source=../lib/ticket_scope_validator.sh
source "$TK/lib/ticket_scope_validator.sh"
# shellcheck source=/dev/null
source "$TK/lib/validation_sufficiency.sh"
# dispatch_capacity.sh exposes the in-flight scope-claim ledger helpers
# (#721 sub-A). The brief renderer consults the ledger so it can prepend
# in-flight scope_files that intersect this brief's allowlist to the
# rendered `Fichiers interdits` block — surfacing two-agent contention
# at render time rather than at commit time. Sanitized test sandboxes
# may omit the lib; treat that as "no in-flight claims visible".
if [ -f "$TK/lib/dispatch_capacity.sh" ]; then
  # shellcheck source=../lib/dispatch_capacity.sh
  source "$TK/lib/dispatch_capacity.sh"
fi
# worktree_helpers exposes agent_repo_root which is AGENT_PANES-aware.
# Source it for the [repo] default so matrix labels resolve through the
# configured inventory rather than through legacy prefix concatenation.
# Defensive — the sanitized shell-test sandbox only copies brief_agents'
# historical deps, so we fall back below to the legacy concat when
# worktree_helpers is absent.
if [ -f "$TK/lib/worktree_helpers.sh" ]; then
  # shellcheck source=/dev/null
  source "$TK/lib/worktree_helpers.sh"
fi

TICKET_NUM=${TICKET#\#}

# Issue #466: render the canonical brief branch_slug from the same source as
# the worktree branch so that, when USE_WORKTREES=1, the worktree branch,
# context proof branch, assignment branch, and rendered prompt match by
# default. The legacy `feat/<project>-ticket-<N>` form remains the default
# when worktrees are disabled (or when worktree_helpers is not sourced —
# e.g. in sandboxed shell tests that intentionally omit it).
brief_default_branch_slug() {
  local ticket=${TICKET_NUM:?usage: brief_default_branch_slug requires TICKET_NUM}
  if [[ "${USE_WORKTREES:-0}" == "1" ]] \
      && declare -F worktree_feature_branch >/dev/null 2>&1; then
    worktree_feature_branch "$ticket"
    return 0
  fi
  printf 'feat/%s-ticket-%s\n' "$PROJECT" "$ticket"
}
TEMPLATE="${DISPATCH_TEMPLATE:-$TK/templates/dispatch-canonical.md.tpl}"
[ -f "$TEMPLATE" ] || { echo "template not found: $TEMPLATE" >&2; exit 1; }

: "${ORCH_HEAVY_VALIDATION_EXIT_CODE:=78}"
REQUIRE_LOCAL_VALIDATORS="${ORCH_REQUIRE_LOCAL_VALIDATORS:-0}"
ALLOW_UNKNOWN_SCOPE=0

ci_delegated_validation() {
  printf '%s\n' "none"
}

ci_delegated_allowed_focused_checks() {
  cat <<'EOF'
  - timeout 30 bash -n <edited-shell-script>
  - timeout 120 bash <targeted-shell-test>
  - timeout 30 git diff --check
EOF
}

local_validators_validation() {
  cat <<'EOF'
timeout 300 bash scripts/run_shellcheck.sh
timeout 300 bash scripts/run_shell_tests.sh
timeout 300 bash scripts/run_bats.sh
EOF
}

validation_as_command_line() {
  local validation=${1:-}
  local line out=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ [^[:space:]] ]] || continue
    if [[ -z "$out" ]]; then
      out="$line"
    else
      out="$out && $line"
    fi
  done <<< "$validation"

  printf '%s\n' "${out:-none}"
}

validation_as_focused_check_list() {
  local validation=${1:-}
  local line emitted=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ [^[:space:]] ]] || continue
    printf '  - %s\n' "$line"
    emitted=1
  done <<< "$validation"

  if [[ "$emitted" -eq 0 ]]; then
    printf '  - none\n'
  fi
}

validation_mentions_heavy_runner() {
  local validation=${1:-}
  grep -Eq '(^|[^A-Za-z0-9_./-])(timeout[[:space:]]+[0-9]+[[:space:]]+)?bash[[:space:]]+scripts/(run_shellcheck|run_shell_tests|run_bats)\.sh([^A-Za-z0-9_./-]|$)' <<< "$validation"
}

# #479 — RBOK frontend validation commands fail on the default Node 20
# shell because the project pins Node 22 (vite/vitest/eslint flat config
# require >= 22). Workers re-discovered the same `nvm use 22` fix on
# every dispatch during the 2026-05-09 UX/UI wave. We inject the Node 22
# preflight automatically when the rendered validation command uses a
# frontend tool (npm/pnpm/yarn/npx/vite/vitest/eslint/prettier/tsc/next/nx
# /node) and does not already select a Node runtime, so the rendered
# brief carries an executable setup step instead of a false validation
# blocker.
NODE22_PREFLIGHT_LINE='source ~/.nvm/nvm.sh && nvm use 22'

brief_validation_pins_node_runtime() {
  local validation=${1:-}
  # `nvm use ...`, `nvm exec ...`, or any explicit ~/.nvm/nvm.sh source
  # counts as an operator-managed Node runtime selection — don't
  # double-inject in that case.
  grep -Eq '(^|[^A-Za-z0-9_./-])nvm[[:space:]]+(use|exec)([[:space:]]|$)' <<< "$validation" && return 0
  grep -Eq '(^|[[:space:]])(\.|source)[[:space:]]+~/.nvm/nvm\.sh([[:space:]]|$)' <<< "$validation" && return 0
  return 1
}

brief_validation_uses_frontend_tools() {
  local validation=${1:-}
  grep -Eq '(^|[^A-Za-z0-9_./-])(npm|npx|pnpm|yarn|vite|vitest|jest|tsc|eslint|prettier|next|nx|node)([[:space:]]|$)' <<< "$validation"
}

brief_inject_node22_preflight() {
  local validation=${1:-}
  if [[ -z "$validation" || "$validation" == "none" ]]; then
    printf '%s\n' "$validation"
    return 0
  fi
  if brief_validation_pins_node_runtime "$validation"; then
    printf '%s\n' "$validation"
    return 0
  fi
  if ! brief_validation_uses_frontend_tools "$validation"; then
    printf '%s\n' "$validation"
    return 0
  fi
  printf '%s\n%s\n' "$NODE22_PREFLIGHT_LINE" "$validation"
}

brief_agent_workdir() {
  local agent=${1:?usage: brief_agent_workdir <agent> <ticket>}
  local ticket=${2:?usage: brief_agent_workdir <agent> <ticket>}

  if declare -F worktree_enabled >/dev/null 2>&1 \
    && declare -F worktree_path >/dev/null 2>&1 \
    && worktree_enabled; then
    worktree_path "$agent" "$ticket"
    return 0
  fi

  if declare -F agent_effective_workdir >/dev/null 2>&1; then
    agent_effective_workdir "$agent"
  elif declare -F agent_repo_root >/dev/null 2>&1; then
    agent_repo_root "$agent"
  else
    printf '%s%s' "${AGENT_REPO_PREFIX:-}" "$agent"
  fi
}

brief_agent_repo_root() {
  local agent=${1:?usage: brief_agent_repo_root <agent>}

  if declare -F agent_repo_root >/dev/null 2>&1; then
    agent_repo_root "$agent"
  else
    printf '%s%s' "${AGENT_REPO_PREFIX:-}" "$agent"
  fi
}

brief_filesystem_path_like() {
  local value=${1:-}
  case "$value" in
    /*|./*|../*|~/*)
      return 0
      ;;
  esac
  [[ "$value" == */* && -e "$value" ]]
}

brief_resolve_base_remote() {
  local configured=${1:-origin}
  local agent=${2:?usage: brief_resolve_base_remote <configured> <agent>}
  local repo supervisor_url remote remote_url

  if ! brief_filesystem_path_like "$configured"; then
    printf '%s\n' "$configured"
    return 0
  fi

  repo=$(brief_agent_repo_root "$agent")
  supervisor_url=$(git -C "$configured" remote get-url origin 2>/dev/null || true)
  if [[ -n "$supervisor_url" && -n "$repo" ]] \
    && git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r remote; do
      [[ -n "$remote" ]] || continue
      remote_url=$(git -C "$repo" remote get-url "$remote" 2>/dev/null || true)
      if [[ -n "$remote_url" && "$remote_url" == "$supervisor_url" ]]; then
        printf '%s\n' "$remote"
        return 0
      fi
    done < <(git -C "$repo" remote 2>/dev/null || true)
  fi

  printf '%s\n' "$configured"
  return 3
}

brief_default_base_sha() {
  local agent=${1:?usage: brief_default_base_sha <agent> <base-ref> <default-branch>}
  local base_ref=${2:?usage: brief_default_base_sha <agent> <base-ref> <default-branch>}
  local default_branch=${3:?usage: brief_default_base_sha <agent> <base-ref> <default-branch>}
  local repo ref

  repo=$(brief_agent_repo_root "$agent")
  if [[ -n "$repo" ]] \
    && git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    for ref in "$base_ref" "origin/$default_branch" "$default_branch" "HEAD"; do
      git -C "$repo" rev-parse --verify "${ref}^{commit}" 2>/dev/null && return 0
    done
  fi

  printf '%s\n' "HEAD"
}

# Default values (overridable via kv args).
DEFAULT_BRANCH_VALUE="${DEFAULT_BRANCH:-main}"
BASE_REMOTE_RESOLUTION_STATUS=0
BASE_REMOTE="$(brief_resolve_base_remote "${SUPERVISOR_REPO:-origin}" "$AGENT")" \
  || BASE_REMOTE_RESOLUTION_STATUS=$?
if [[ "$BASE_REMOTE_RESOLUTION_STATUS" -eq 0 ]]; then
  BASE_REF="${BASE_REMOTE}/${DEFAULT_BRANCH_VALUE}"
else
  BASE_REF="<invalid-base-ref>"
fi
declare -A K=(
  [agent]="$AGENT"
  [ticket]="$TICKET_NUM"
  [project]="$PROJECT"
  [repo]="$(brief_agent_workdir "$AGENT" "$TICKET_NUM")"
  [base_remote]="$BASE_REMOTE"
  [base_ref]="$BASE_REF"
  [orch_remote]="$BASE_REMOTE"
  [default_branch]="$DEFAULT_BRANCH_VALUE"
  [branch_slug]="$(brief_default_branch_slug)"
  [base_sha]="$(brief_default_base_sha "$AGENT" "$BASE_REF" "$DEFAULT_BRANCH_VALUE")"
  [scope_files]=""
  [audit_evidence_files]=""
  [forbidden_files]="cli/internal/app/app.go"
  [validation]="$(ci_delegated_validation)"
  [validation_policy]="ci-delegated"
  [validation_command]="none"
  [allowed_focused_checks]="$(ci_delegated_allowed_focused_checks)"
  [require_local_validators]="no"
  [summary]=""
  [gh_repo]="$GH_REPO"
  [project_meta_context]="$(state_dir)/project_meta_context.md"
  [scope_active_project]="${ORCH_SCOPE_ACTIVE_KEY:-$PROJECT}"
  [scope_classification]="$(ordo_scope_classify "${ORCH_SCOPE_ACTIVE_KEY:-$PROJECT}")"
  [scope_posture_block]="$(ordo_scope_render_block "${ORCH_SCOPE_ACTIVE_KEY:-$PROJECT}" "$GH_REPO" "$DEFAULT_BRANCH_VALUE")"
  [ticket_title]=""
  [source_url]="https://github.com/${GH_REPO}/issues/${TICKET_NUM}"
  [source_title]=""
  [source_body]=""
  [source_substance_appendix]=""
)

brief_fetch_source_issue_json() {
  local fetch_timeout=${ORCH_SOURCE_FETCH_TIMEOUT_SEC:-15}

  command -v gh >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  if [[ -n "${GH_CONFIG_DIR:-}" ]]; then
    timeout "$fetch_timeout" env GH_CONFIG_DIR="$GH_CONFIG_DIR" gh issue view "${K[ticket]}" \
      --repo "${K[gh_repo]}" \
      --json title,body,url 2>/dev/null
  else
    timeout "$fetch_timeout" gh issue view "${K[ticket]}" \
      --repo "${K[gh_repo]}" \
      --json title,body,url 2>/dev/null
  fi
}

brief_prepare_source_substance() {
  local source_json=""

  if [[ -z "${K[source_body]}" ]]; then
    source_json=$(brief_fetch_source_issue_json || true)
    # `gh issue view --json ...` returns an object; sandboxed tests and
    # offline fixtures may surface `[]` or other non-object JSON. Treat
    # those as "no source available" so jq does not error on `.body`.
    if [[ -n "$source_json" ]] && jq -e 'type == "object"' >/dev/null 2>&1 <<< "$source_json"; then
      K[source_body]=$(jq -r '.body // ""' <<< "$source_json")
      K[source_title]=$(jq -r '.title // ""' <<< "$source_json")
      K[source_url]=$(jq -r '.url // ""' <<< "$source_json")
    fi
  fi

  if [[ -z "${K[source_title]}" ]]; then
    K[source_title]="${K[ticket_title]:-}"
  fi
  if [[ -z "${K[source_url]}" ]]; then
    K[source_url]="https://github.com/${K[gh_repo]}/issues/${K[ticket]}"
  fi

  K[source_substance_appendix]="$(prompt_source_substance_appendix \
    "${K[source_url]}" \
    "${K[source_title]}" \
    "${K[source_body]}")"
}

# Override via k=v args.
ALLOW_REBIND=0
AUDIT_ONLY=0
VALIDATION_OVERRIDDEN=0
# #721 sub-A — `--ignore-scope-claims` opts a single brief out of the
# in-flight scope-claim cross-check. Default is to consult the ledger
# and prepend any intersecting in-flight scope_files to the rendered
# brief's forbidden_files block, making two-agent contention visible at
# render time. Operators flip this flag for legitimate parallel work on
# the same file (rare; usually only for non-mutating audits).
IGNORE_SCOPE_CLAIMS="${ORCH_BRIEF_IGNORE_SCOPE_CLAIMS:-0}"
# #724 — validation_command sufficiency gate. Defaults to `auto-augment`
# so the dispatch wave that originally surfaced the gap (PRs #719/#722
# spent 4 follow-up commits on lint shellcheck would have caught) gains
# coverage transparently. Operators flip to `enforce` once the audit
# rows show no false positives, or to `off` for a targeted bypass.
VALIDATION_SUFFICIENCY_MODE="${ORCH_BRIEF_VALIDATION_SUFFICIENCY:-auto-augment}"
for kv in "$@"; do
  case "$kv" in
    --require-local-validators)
      REQUIRE_LOCAL_VALIDATORS=1
      ;;
    --allow-unknown-scope)
      ALLOW_UNKNOWN_SCOPE=1
      ;;
    --allow-rebind)
      ALLOW_REBIND=1
      ;;
    --audit-only)
      AUDIT_ONLY=1
      ;;
    --ignore-scope-claims)
      IGNORE_SCOPE_CLAIMS=1
      ;;
    --validation-sufficiency=*)
      VALIDATION_SUFFICIENCY_MODE="${kv#--validation-sufficiency=}"
      ;;
    *=*)
      key=${kv%%=*}
      K[$key]="${kv#*=}"
      if [[ "$key" == "validation" ]]; then
        VALIDATION_OVERRIDDEN=1
      fi
      ;;
    *)   echo "ignoring non-kv arg: $kv" >&2 ;;
  esac
done

# Issue #466: emit a clear warning when an explicit branch_slug override
# diverges from the canonical worktree branch under USE_WORKTREES=1. The
# worktree is created on `worktree_feature_branch`, so a mismatched slug
# would push agents to checkout a divergent branch and silently weaken
# integration, audit, and recovery flows.
if [[ "${USE_WORKTREES:-0}" == "1" ]] \
    && declare -F worktree_feature_branch >/dev/null 2>&1; then
  expected_branch_slug=$(worktree_feature_branch "$TICKET_NUM")
  if [[ "${K[branch_slug]}" != "$expected_branch_slug" ]]; then
    printf 'WARN: brief branch_slug=%s diverges from worktree branch %s for ticket %s\n' \
      "${K[branch_slug]}" "$expected_branch_slug" "$TICKET_NUM" >&2
  fi
fi

# Issue #520: warn when scope_files lists an explicit (non-glob) path that
# does not exist in the agent workdir. Globs are skipped because they may
# legitimately expand against future files. The warning is audit logged but
# never blocks dispatch — Worker #505 evidence showed stale literals in
# generated allowlists waste worker time chasing missing files; surfacing
# them at brief render is enough.
brief_scope_entry_is_glob() {
  local entry=$1
  [[ "$entry" == *[*?\[\{]* ]]
}

brief_scope_strip_marker() {
  local entry=$1
  # Trim leading whitespace, then strip common bullet/comment markers.
  entry=${entry#"${entry%%[![:space:]]*}"}
  entry=${entry%"${entry##*[![:space:]]}"}
  case "$entry" in
    '- '*|'* '*|'# '*|'// '*)
      entry=${entry#* }
      ;;
  esac
  printf '%s\n' "$entry"
}

brief_warn_missing_scope_paths() {
  local raw=${K[scope_files]:-}
  [[ -n "$raw" ]] || return 0

  local workdir
  workdir=$(brief_agent_workdir "$AGENT" "$TICKET_NUM")
  # USE_WORKTREES=1 worktrees are created later in dispatch_ticket.sh, so
  # the workdir may not exist at brief render time. Falling back to the
  # base agent repo lets the check still run against the configured slot
  # for the common case; if neither exists, skip silently.
  if [[ ! -d "$workdir" ]]; then
    workdir=$(brief_agent_repo_root "$AGENT" 2>/dev/null || true)
  fi
  [[ -n "$workdir" && -d "$workdir" ]] || return 0

  local line entry path
  while IFS= read -r line || [[ -n "$line" ]]; do
    entry=$(brief_scope_strip_marker "$line")
    [[ -n "$entry" ]] || continue
    if brief_scope_entry_is_glob "$entry"; then
      continue
    fi
    if [[ "$entry" == /* ]]; then
      path="$entry"
    else
      path="$workdir/$entry"
    fi
    if [[ ! -e "$path" ]]; then
      audit "BRIEF_SCOPE_PATH_MISSING ticket=#${TICKET_NUM} agent=${AGENT} project=${PROJECT} path=${entry} workdir=${workdir}"
      printf 'WARN: brief scope_files entry %s does not exist in workdir %s for ticket %s\n' \
        "$entry" "$workdir" "$TICKET_NUM" >&2
    fi
  done <<< "$raw"
}

brief_warn_missing_scope_paths

# #483 — surface missing audit evidence before worker handoff.
#
# Dispatch briefs sometimes reference audit docs that are not present in
# the verified base; the worker can't inspect the source audit locally
# and ends up reconciling missing evidence instead of implementing. The
# preflight runs only when the brief explicitly declares
# `audit_evidence_files=<paths>` (newline-separated). For each non-glob
# entry, it either:
#   * embeds the file content (truncated) into the rendered brief so
#     the worker has the evidence inline; or
#   * refuses dispatch with a clear stderr blocker plus a
#     BRIEF_AUDIT_EVIDENCE_MISSING audit row when the path is absent
#     from the agent workdir (the verified base).
# Globs are skipped (same convention as scope_files literals) because
# they may legitimately expand against files added later in the branch.
brief_audit_evidence_preflight() {
  local raw=${K[audit_evidence_files]:-}
  [[ -n "$raw" ]] || return 0

  local workdir
  workdir=$(brief_agent_workdir "$AGENT" "$TICKET_NUM")
  if [[ ! -d "$workdir" ]]; then
    workdir=$(brief_agent_repo_root "$AGENT" 2>/dev/null || true)
  fi
  [[ -n "$workdir" && -d "$workdir" ]] || return 0

  local -a missing=()
  local excerpt_max=${ORCH_AUDIT_EVIDENCE_EXCERPT_LINES:-200}
  local appendix=""
  local line entry path body total

  while IFS= read -r line || [[ -n "$line" ]]; do
    entry=$(brief_scope_strip_marker "$line")
    [[ -n "$entry" ]] || continue
    if brief_scope_entry_is_glob "$entry"; then
      continue
    fi
    if [[ "$entry" == /* ]]; then
      path="$entry"
    else
      path="$workdir/$entry"
    fi
    if [[ ! -e "$path" ]]; then
      missing+=("$entry")
      audit "BRIEF_AUDIT_EVIDENCE_MISSING ticket=#${TICKET_NUM} agent=${AGENT} project=${PROJECT} path=${entry} workdir=${workdir}"
      continue
    fi

    body=$(head -n "$excerpt_max" "$path" 2>/dev/null | prompt_escape_source_appendix_text || true)
    total=$(wc -l < "$path" 2>/dev/null | tr -d '[:space:]' || true)
    total=${total:-0}
    appendix+=$'\n### '"$entry"$'\n\n'
    if [[ "$total" -gt "$excerpt_max" ]]; then
      appendix+="(showing first ${excerpt_max} of ${total} lines)"$'\n\n'
    fi
    appendix+='```'$'\n'"$body"$'\n''```'$'\n'
    audit "BRIEF_AUDIT_EVIDENCE_EMBEDDED ticket=#${TICKET_NUM} agent=${AGENT} project=${PROJECT} path=${entry} lines=${total}"
  done <<< "$raw"

  if (( ${#missing[@]} > 0 )); then
    local m
    for m in "${missing[@]}"; do
      printf 'brief_agents: AUDIT_EVIDENCE_MISSING path=%s workdir=%s ticket=#%s — referenced audit evidence is absent from the verified base; ensure the file exists on base or remove it from audit_evidence_files before dispatch\n' \
        "$m" "$workdir" "$TICKET_NUM" >&2
    done
    audit "BRIEF AUDIT_EVIDENCE_PREFLIGHT_REFUSED project=${PROJECT} agent=${AGENT} ticket=#${TICKET_NUM} missing_count=${#missing[@]}"
    exit 86
  fi

  if [[ -n "$appendix" ]]; then
    local section=$'\n\n## Audit evidence excerpts (preflight-embedded)\n'"$appendix"
    K[source_substance_appendix]="${K[source_substance_appendix]:-}${section}"
  fi
}

brief_profile_preflight_enabled() {
  case "${ORCH_DISPATCH_PROFILE_PREFLIGHT:-auto}" in
    1|true|yes|on|strict)
      return 0
      ;;
    0|false|no|off)
      return 1
      ;;
    auto|"")
      if declare -F ordo_scope_strict_enabled >/dev/null 2>&1 \
        && ordo_scope_strict_enabled; then
        return 0
      fi
      brief_filesystem_path_like "${SUPERVISOR_REPO:-}" && return 0
      case "${PR_OPS_MODE:-}${ORCH_PR_OPS_MODE:-}" in
        *autonomous*) return 0 ;;
      esac
      return 1
      ;;
    *)
      printf 'brief_agents: invalid ORCH_DISPATCH_PROFILE_PREFLIGHT value: %s\n' \
        "${ORCH_DISPATCH_PROFILE_PREFLIGHT}" >&2
      exit 2
      ;;
  esac
}

brief_profile_preflight_refuse() {
  local reason=${1:?usage: brief_profile_preflight_refuse <reason> <remediation>}
  local remediation=${2:?usage: brief_profile_preflight_refuse <reason> <remediation>}
  audit "BRIEF PROFILE_PREFLIGHT_REFUSED project=${K[project]} agent=${K[agent]} ticket=#${K[ticket]} reason=${reason} scope_classification=${K[scope_classification]} base_remote=${K[base_remote]} base_ref=${K[base_ref]} remediation=${remediation// /_}"
  printf 'brief_agents: PROFILE_PREFLIGHT_REFUSED reason=%s project=%s agent=%s ticket=#%s remediation=%s\n' \
    "$reason" "${K[project]}" "${K[agent]}" "${K[ticket]}" "$remediation" >&2
  exit 81
}

brief_profile_preflight() {
  brief_profile_preflight_enabled || return 0

  if [[ "${K[scope_classification]}" == "unknown" ]]; then
    if [[ "$ALLOW_UNKNOWN_SCOPE" -eq 1 ]]; then
      audit "BRIEF PROFILE_PREFLIGHT_AUTHORIZED project=${K[project]} agent=${K[agent]} ticket=#${K[ticket]} reason=scope_unknown authorization=per_dispatch_flag"
    else
      brief_profile_preflight_refuse \
        "scope_unknown" \
        "bind the active project key in ORCH_SCOPE_IN_SCOPE_PROJECTS or pass --allow-unknown-scope for this dispatch with audit evidence"
    fi
  fi

  if brief_filesystem_path_like "${K[base_remote]}"; then
    brief_profile_preflight_refuse \
      "base_remote_filesystem_path" \
      "set SUPERVISOR_REPO to a git remote name such as origin, or pass base_remote=<remote> base_ref=<remote>/<branch>"
  fi

  case "${K[base_ref]}" in
    /*|./*|../*|~/*|"<invalid-base-ref>")
      brief_profile_preflight_refuse \
        "base_ref_not_remote_ref" \
        "set base_ref to a git ref such as origin/${K[default_branch]} and keep filesystem workdirs in PROJECT_REPO_ROOT or AGENT_PANES"
      ;;
  esac
}

brief_profile_preflight

# #538 — refuse implementation briefs that ship with an empty
# allowed-files scope. The 2026-05 dispatch of #518 sent a brief whose
# `Fichiers autorises` block was empty, which left the worker pane
# marked occupied while no productive mutation was possible. Audit /
# diagnostic / observation briefs that legitimately ship with no
# mutation scope must pass `--audit-only` so the dispatch is logged as
# an intentional audit assignment rather than a missing scope.
brief_scope_files_is_empty() {
  local value=${1-}
  # Whitespace-only (spaces, tabs, newlines, CR) counts as empty.
  value=${value//[[:space:]]/}
  [[ -z "$value" ]]
}

if brief_scope_files_is_empty "${K[scope_files]}"; then
  if [[ "$AUDIT_ONLY" -eq 1 ]]; then
    audit "BRIEF AUDIT_ONLY_AUTHORIZED project=${K[project]} agent=${K[agent]} ticket=#${K[ticket]} reason=empty_allowed_files_scope authorization=audit_only_flag"
  else
    audit "BRIEF EMPTY_SCOPE_REFUSED project=${K[project]} agent=${K[agent]} ticket=#${K[ticket]} reason=empty_allowed_files_scope remediation=pass_scope_files_or_audit_only_flag"
    printf 'brief_agents: EMPTY_SCOPE_REFUSED project=%s agent=%s ticket=#%s reason=empty_allowed_files_scope — implementation briefs require a non-empty scope_files; pass scope_files=<paths> or --audit-only for audit/diagnostic tickets\n' \
      "${K[project]}" "${K[agent]}" "${K[ticket]}" >&2
    exit 87
  fi
fi

# #369 — refuse dispatch when the ticket number, branch slug, and
# summary do not point at the same issue. The validator emits a
# structured TICKET_SCOPE_VALIDATION audit line carrying ticket_number,
# ticket_title, branch_issue_number, slug_tail, acceptance_scope_hash,
# and the mismatch reason. `--allow-rebind` swaps the assert for an
# audit-only rebind so operators can keep the brief and re-aim it at
# the right ticket without losing evidence.
TICKET_SCOPE_CONTEXT="brief_agents:${PROJECT}:${AGENT}:#${K[ticket]}"
if [[ "$ALLOW_REBIND" -eq 1 ]]; then
  ticket_scope_assert_or_rebind \
    "${K[ticket]}" "${K[branch_slug]}" "${K[summary]}" \
    "${K[scope_files]}" "${K[ticket_title]:-}" \
    "$TICKET_SCOPE_CONTEXT" "${K[forbidden_files]}"
else
  ticket_scope_assert \
    "${K[ticket]}" "${K[branch_slug]}" "${K[summary]}" \
    "${K[scope_files]}" "${K[ticket_title]:-}" \
    "$TICKET_SCOPE_CONTEXT" "${K[forbidden_files]}"
fi

case "$REQUIRE_LOCAL_VALIDATORS" in
  1|yes|true|on)
    orch_host_load_gate \
      "local_validators_brief:${PROJECT}:${AGENT}:#${TICKET_NUM}" \
      "${ORCH_HOST_GATE_LOCAL_VALIDATORS_MODE:-${ORCH_HOST_GATE_MODE:-off}}"
    K[require_local_validators]="yes"
    if ! validation_mentions_heavy_runner "${K[validation]}"; then
      K[validation]="$(local_validators_validation)"
    fi
    ;;
  0|no|false|off|'')
    K[require_local_validators]="no"
    if validation_mentions_heavy_runner "${K[validation]}"; then
      printf '%s\n' \
        "brief_agents: full local validators require --require-local-validators; default is CI-delegated validation" >&2
      exit "$ORCH_HEAVY_VALIDATION_EXIT_CODE"
    fi
    ;;
  *)
    printf 'brief_agents: invalid ORCH_REQUIRE_LOCAL_VALIDATORS value: %s\n' "$REQUIRE_LOCAL_VALIDATORS" >&2
    exit 2
    ;;
esac

K[validation]="$(brief_inject_node22_preflight "${K[validation]}")"

if [[ "${K[require_local_validators]}" == "yes" ]]; then
  K[validation_policy]="require-local-validators"
  K[validation_command]="$(validation_as_command_line "${K[validation]}")"
  K[allowed_focused_checks]="$(validation_as_focused_check_list "${K[validation]}")"
elif [[ "$VALIDATION_OVERRIDDEN" -eq 1 && "${K[validation]}" != "none" ]]; then
  K[validation_policy]="dispatch-provided"
  K[validation_command]="$(validation_as_command_line "${K[validation]}")"
  K[allowed_focused_checks]="$(validation_as_focused_check_list "${K[validation]}")"
else
  K[validation_policy]="ci-delegated"
  K[validation_command]="none"
  K[allowed_focused_checks]="$(ci_delegated_allowed_focused_checks)"
fi

brief_prepare_source_substance

# #753 — inject the Acceptance proof scaffold built from the source
# issue's DoD bullets. The closure_acceptance gate (#723) refuses to
# auto-close an issue whose merged PR body lacks a fenced ```acceptance```
# block covering each DoD bullet with verifiable artifact pointers; this
# scaffold pre-fills the block at brief render time so the worker just
# replaces each placeholder during their validation run instead of
# rebuilding the structure by hand.
brief_acceptance_inject() {
  local section
  section=$(brief_acceptance_render_section "${K[source_body]:-}")
  [[ -n "$section" ]] || return 0
  # Escape `{{`/`}}` in the rendered section so a DoD bullet containing
  # literal template-style braces cannot trip the unresolved-placeholder
  # guard in render() below.
  section=$(printf '%s' "$section" | prompt_escape_source_appendix_text)
  K[source_substance_appendix]="${K[source_substance_appendix]:-}${section}"
}

brief_acceptance_inject

brief_audit_evidence_preflight

# #724 — validation_command sufficiency gate. Only fires when the
# brief carries `validation_policy=dispatch-provided`; CI-delegated
# briefs are validated by the configured CI rollup and require-local
# briefs already run the full heavy runners. Source-body waivers
# (`- validation-policy-exception: <reason>`) opt a brief out without
# disabling the gate fleet-wide. The mode is read once from
# ORCH_BRIEF_VALIDATION_SUFFICIENCY or --validation-sufficiency=<mode>.
brief_validation_sufficiency_gate() {
  case "$VALIDATION_SUFFICIENCY_MODE" in
    off|disabled|none)
      return 0
      ;;
    enforce|auto-augment)
      :
      ;;
    *)
      printf 'brief_agents: invalid --validation-sufficiency value: %s (expected enforce|auto-augment|off)\n' \
        "$VALIDATION_SUFFICIENCY_MODE" >&2
      exit 2
      ;;
  esac

  [[ "${K[validation_policy]}" == "dispatch-provided" ]] || return 0

  if validation_sufficiency_brief_declares_exception "${K[source_body]:-}"; then
    audit "BRIEF VALIDATION_POLICY_EXCEPTION project=${K[project]} agent=${K[agent]} ticket=#${K[ticket]} mode=${VALIDATION_SUFFICIENCY_MODE} reason=source_body_declaration"
    return 0
  fi

  local missing
  missing=$(validation_sufficiency_missing_classes \
    "${K[scope_files]}" "${K[validation_command]}")
  [[ -n "$missing" ]] || return 0

  if [[ "$VALIDATION_SUFFICIENCY_MODE" == "enforce" ]]; then
    audit "BRIEF VALIDATION_INSUFFICIENT project=${K[project]} agent=${K[agent]} ticket=#${K[ticket]} missing_classes=${missing// /,} validation_command=${K[validation_command]}"
    # shellcheck disable=SC2016
    printf 'brief_agents: BRIEF_VALIDATION_INSUFFICIENT project=%s agent=%s ticket=#%s missing_classes=%s — validation_command does not cover scope language classes; add the missing linters or declare `- validation-policy-exception: <reason>` in the brief source, or rerun with --validation-sufficiency=auto-augment\n' \
      "${K[project]}" "${K[agent]}" "${K[ticket]}" "${missing// /,}" >&2
    exit 88
  fi

  # auto-augment: stitch the canonical invocations onto the front of
  # validation, then re-derive validation_command and the focused-check
  # list so the rendered brief reflects the augmentation 1:1.
  local original_command=${K[validation_command]}
  local augmented
  augmented=$(validation_sufficiency_augment_command \
    "${K[scope_files]}" "$original_command")
  if [[ -z "$augmented" || "$augmented" == "$original_command" ]]; then
    return 0
  fi
  K[validation]="$augmented"
  K[validation_command]="$(validation_as_command_line "$augmented")"
  K[allowed_focused_checks]="$(validation_as_focused_check_list "$augmented")"

  local audit_line
  while IFS= read -r audit_line; do
    [[ -n "$audit_line" ]] || continue
    audit "BRIEF VALIDATION_AUTO_AUGMENTED project=${K[project]} agent=${K[agent]} ticket=#${K[ticket]} ${audit_line}"
  done < <(validation_sufficiency_augment_audit_lines \
    "${K[scope_files]}" "$original_command")
}

brief_validation_sufficiency_gate

# #721 sub-A — surface in-flight scope conflicts at render time.
#
# When `dispatch_ticket.sh` promotes an assignment it records the
# resolved scope_files in `assignments_scope_claims.json`. Before
# rendering a new brief we re-read that ledger and intersect the
# claimed files (from agents OTHER than this brief's target agent)
# with the brief's own scope_files. Any intersecting path is prepended
# to `forbidden_files` so the rendered brief carries an explicit
# do-not-touch list whenever another in-flight dispatch is already
# claiming the same file. `--ignore-scope-claims` (or
# `ORCH_BRIEF_IGNORE_SCOPE_CLAIMS=1`) opts a single brief out and
# emits an explicit audit row.
brief_scope_claim_inject_forbidden() {
  if [ "$IGNORE_SCOPE_CLAIMS" -eq 1 ]; then
    audit "BRIEF SCOPE_CLAIM_IGNORED project=${K[project]} agent=${K[agent]} ticket=#${K[ticket]} reason=ignore_scope_claims_flag"
    return 0
  fi
  declare -F dispatch_capacity_scope_claim_files >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local own_scope=${K[scope_files]:-}
  [ -n "$own_scope" ] || return 0

  local claimed
  claimed=$(dispatch_capacity_scope_claim_files "$AGENT" 2>/dev/null || true)
  [ -n "$claimed" ] || return 0

  local entry intersection=""
  while IFS= read -r line || [ -n "$line" ]; do
    entry=$(brief_scope_strip_marker "$line")
    [ -n "$entry" ] || continue
    if printf '%s\n' "$claimed" | grep -qFx -- "$entry"; then
      intersection+="${entry}"$'\n'
    fi
  done <<< "$own_scope"

  [ -n "$intersection" ] || return 0

  local current_forbidden=${K[forbidden_files]:-}
  if [ -n "$current_forbidden" ]; then
    K[forbidden_files]="${intersection}${current_forbidden}"
  else
    K[forbidden_files]="${intersection%$'\n'}"
  fi
  local files_csv
  files_csv=$(printf '%s' "$intersection" | tr '\n' ',' | sed 's/,*$//')
  audit "BRIEF SCOPE_CLAIM_FORBIDDEN_INJECTED project=${K[project]} agent=${K[agent]} ticket=#${K[ticket]} files=${files_csv}"
  printf 'brief_agents: SCOPE_CLAIM_FORBIDDEN_INJECTED files=%s — these paths are claimed by other in-flight dispatches; pass --ignore-scope-claims to override\n' \
    "$files_csv" >&2
}

brief_scope_claim_inject_forbidden

# Render template by substitution.
#
# Shell-safety contract (issue #121, source: issue #89 comment 19:14Z):
# the template is read as a file via "$(<...)" — never via an unquoted
# heredoc — and values are inserted with bash parameter substitution
# only, which does NOT re-evaluate the replacement string. Backticks,
# command-substitution syntax, single/double quotes and embedded
# newlines in K[$k] are inserted literally and cannot trigger shell
# execution during rendering.
render() {
  local content val
  content=$(<"$TEMPLATE")
  for k in "${!K[@]}"; do
    # bash 5.2+ interprets `&` in the replacement of ${var//pat/repl} as
    # "the matched pattern". A value containing `&&` therefore expands to
    # `{{key}}{{key}}` instead of being inserted literally. Escape `&` in
    # the value so it's treated as a literal ampersand on bash 5.2+ (and
    # is harmless on earlier versions, where `\&` was already literal).
    # `\` must be escaped first or the `&` escape itself gets mangled.
    val=${K[$k]//\\/\\\\}
    val=${val//&/\\&}
    content=${content//\{\{${k}\}\}/$val}
  done

  # Refuse to emit a half-rendered brief — an unresolved {{key}} downstream
  # is exactly the corruption pattern dispatch_ticket.sh now rejects, and
  # catching it here gives a clearer error than the staged-prompt check.
  if [[ "$content" =~ \{\{[a-zA-Z_][a-zA-Z0-9_]*\}\} ]]; then
    printf 'brief_agents: unresolved template placeholder %s\n' \
      "${BASH_REMATCH[0]}" >&2
    return 1
  fi

  prompt_validate_source_fidelity \
    "${K[source_url]}" \
    "${K[source_title]}" \
    "${K[source_body]}" \
    "$content" || return 1

  printf '%s\n' "$content"
}

render
