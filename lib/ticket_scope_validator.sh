#!/usr/bin/env bash
# lib/ticket_scope_validator.sh — refuse dispatch prompts whose ticket
# number, branch slug, and acceptance scope do not point at the same
# issue (#369).
#
# Background. During the 2026-05-08 autonomous unblock the orchestrator
# generated `/tmp/dispatch-rbok-gemini-367.md` whose header claimed
# `Ticket: ORDO #367` but whose acceptance / branch / commit scope
# actually belonged to #368. A PR can then implement the right patch
# under the wrong issue number, close the wrong issue, and poison
# audit evidence for GxP-grade development.
#
# Detection signals. The validator runs before render, when the
# template values are already known to `brief_agents.sh`:
#
#   1. structural mismatch — `branch_slug` follows the modern
#      `<type>/<issue>-<slug>` convention but the leading issue number
#      does not equal `ticket_num`. Always refuse.
#   2. semantic mismatch — `slug_tail` (the slug text after the leading
#      issue number) shares zero non-stopword tokens with `summary`
#      (the prompt objective). Refuse when both sides carry meaningful
#      tokens — this is the specific failure mode that #367/#368 hit:
#      `slug_tail = validate-portability-shell-tests` vs
#      `summary = workdir_not_ready diagnostics`.
#
# Audit. Every call emits a structured `TICKET_SCOPE_VALIDATION` line
# carrying `ticket_number`, `ticket_title`, `branch_issue_number`,
# `slug_tail`, `acceptance_scope_hash`, `status`, and (on refusal) the
# `mismatch` reason. Operators reading the audit log can therefore tell
# the orchestrator's intent (`ticket_number=367`) apart from the
# generated artifact (`branch_issue_number=368`, `slug_tail=...`).
#
# Manual rebind. When an operator wants to keep an existing brief but
# rebind it to the correct ticket, they pass `--allow-rebind` to
# `brief_agents.sh`, which calls `ticket_scope_assert_or_rebind` instead
# of `ticket_scope_assert`. Rebind never silently passes — it emits an
# explicit `action=rebind` audit line so the override is durable.

if [[ -n "${ORCH_TICKET_SCOPE_VALIDATOR_LIB_LOADED:-}" ]]; then
  return 0
fi
ORCH_TICKET_SCOPE_VALIDATOR_LIB_LOADED=1

: "${ORCH_TICKET_SCOPE_MISMATCH_EXIT_CODE:=86}"

# Stopwords filtered out before the slug↔summary overlap check. Single
# letters and 1-2 char tokens are dropped automatically; this list
# strips ORDO-shaped scaffolding tokens that would otherwise produce
# false-positive overlaps (e.g. every dispatch slug contains "ticket"
# in the legacy default form `feat/<project>-ticket-<N>`).
ORCH_TICKET_SCOPE_STOPWORDS=(
  the a an and or for of in to from on by at as is be with
  le la les un une et ou pour de du dans a sur par
  ticket issue feat fix chore docs refactor test perf ci build style
)

# ticket_scope_extract_branch_issue_number <branch_slug>
#   Echo the leading issue number when `branch_slug` follows the
#   modern `<type>/<issue>-<slug>` convention. Echo nothing on miss.
#   Always exits 0 — empty output is the documented "not present"
#   signal so callers can use the function under `set -e` without a
#   spurious abort.
ticket_scope_extract_branch_issue_number() {
  local slug=${1-}
  if [[ "$slug" =~ ^(feat|fix|chore|docs|refactor|test|perf|ci|build|style)/([0-9]+)- ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}

# ticket_scope_extract_slug_tail <branch_slug>
#   Echo the slug content after `<type>/<number>-`. Empty when the slug
#   does not follow the modern convention (legacy `feat/<scope>-ticket-<N>`
#   shapes deliberately produce no tail so the semantic check is skipped).
ticket_scope_extract_slug_tail() {
  local slug=${1-}
  if [[ "$slug" =~ ^(feat|fix|chore|docs|refactor|test|perf|ci|build|style)/[0-9]+-(.+)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  fi
}

# Lower-case + tokenize a free-text input, dropping stopwords and tokens
# shorter than 3 characters. Output: one token per line, deduplicated
# while preserving first-seen order.
_ticket_scope_tokenize() {
  local input=${1-}
  [[ -n "$input" ]] || return 0
  local lowered raw token
  lowered=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')
  raw=$(printf '%s' "$lowered" | tr -c 'a-z0-9' ' ')
  local seen=()
  for token in $raw; do
    [[ ${#token} -ge 3 ]] || continue
    local skip=0 sw
    for sw in "${ORCH_TICKET_SCOPE_STOPWORDS[@]}"; do
      if [[ "$token" == "$sw" ]]; then skip=1; break; fi
    done
    [[ "$skip" -eq 1 ]] && continue
    local already=0 prev
    for prev in "${seen[@]}"; do
      if [[ "$prev" == "$token" ]]; then already=1; break; fi
    done
    [[ "$already" -eq 1 ]] && continue
    seen+=("$token")
    printf '%s\n' "$token"
  done
}

# Echo the count of tokens that appear in BOTH inputs after tokenization.
# Uses `wc -l` instead of `grep -c .` so an empty intersection returns
# "0" with exit 0 — `grep -c .` exits 1 on no-match and would trip a
# caller's `set -e` in the (common) "0 overlap" branch.
_ticket_scope_overlap_count() {
  local left_tokens right_tokens
  left_tokens=$(_ticket_scope_tokenize "${1-}" | sort -u)
  right_tokens=$(_ticket_scope_tokenize "${2-}" | sort -u)
  if [[ -z "$left_tokens" || -z "$right_tokens" ]]; then
    printf '0\n'
    return 0
  fi
  comm -12 <(printf '%s\n' "$left_tokens") <(printf '%s\n' "$right_tokens") \
    | wc -l | tr -d ' '
}

# Echo the count of distinct tokens in <input> after stopword filtering.
_ticket_scope_token_count() {
  _ticket_scope_tokenize "${1-}" | sort -u | wc -l | tr -d ' '
}

# Return 0 when <input> contains at least one non-whitespace character.
_ticket_scope_has_text() {
  [[ "${1-}" =~ [^[:space:]] ]]
}

# Echo the acceptance surfaces that are specific enough to compare with
# dispatch allow/forbid paths. Each row is:
#   <surface-name>\t<natural-path-prefix>\t<path-token-regex>
#
# This is deliberately conservative: generic summaries still rely on the
# ticket/slug/title checks above, while known UAT clusters get blocked
# when a dispatch allowlist can only touch sibling files.
_ticket_scope_required_acceptance_surfaces() {
  local summary=${1-} title=${2-}
  local text
  text=$(printf '%s %s' "$summary" "$title" | tr '[:upper:]' '[:lower:]')

  if [[ "$text" =~ uc[-_[:space:]]?mgr ]] \
    || { [[ "$text" =~ manager ]] && [[ "$text" =~ (lifecycle|gate|gates|uat|coverage) ]]; }; then
    printf '%s\t%s\t%s\n' \
      "manager-lifecycle" \
      "frontend/e2e/uat/tests/uat-manager" \
      '(uc[-_/[:space:]]?mgr|uat[-_/]manager|manager)'
  fi

  if [[ "$text" =~ adm[-_/[:space:]]*[0-9] ]] \
    || { [[ "$text" =~ admin ]] && [[ "$text" =~ (access|lifecycle|coverage) ]]; }; then
    printf '%s\t%s\t%s\n' \
      "admin-access-lifecycle" \
      "frontend/tests/e2e/uat-admin/access-lifecycle" \
      '(adm[-_/[:space:]]*[0-9]|uat[-_/]admin|access[-_/]lifecycle|admin)'
  fi
}

# Return 0 when a glob-ish allow/forbid entry covers a known natural
# surface path. Exact token matches are handled separately; this helper
# is for broad ancestors such as `frontend/e2e/uat/tests/**`, which can
# satisfy `frontend/e2e/uat/tests/uat-manager/**` even though the literal
# manager segment is not present in the configured allowlist.
_ticket_scope_entry_covers_natural_path() {
  local entry=${1-} natural=${2-}
  [[ -n "$entry" && -n "$natural" ]] || return 1

  entry=${entry,,}
  natural=${natural,,}
  entry=${entry//\"/}
  entry=${entry//\'/}
  entry=${entry//\`/}
  entry=${entry#./}
  natural=${natural#./}

  case "$entry" in
    "."|"./"|"*"|"**"|"**/"|"./**")
      return 0
      ;;
  esac

  local base
  base=$entry
  base=${base%%\**}
  base=${base%%\?*}
  base=${base%%\[*}
  base=${base%/}
  [[ -n "$base" ]] || return 1

  [[ "$natural" == "$base" || "$natural" == "$base"/* ]]
}

# Return 0 when any path/glob in <paths> directly names or broadly covers
# the acceptance surface.
_ticket_scope_path_list_covers_surface() {
  local paths=${1-} natural=${2-} token_re=${3-}
  local path lowered
  for path in $paths; do
    lowered=${path,,}
    if [[ "$lowered" =~ $token_re ]]; then
      return 0
    fi
    if _ticket_scope_entry_covers_natural_path "$path" "$natural"; then
      return 0
    fi
  done
  return 1
}

# Echo an acceptance-surface mismatch reason when the ticket text points
# at a known implementation surface that the allowlist cannot reach or
# that the forbidden list explicitly blocks. Empty output means no
# acceptance-surface mismatch was found.
_ticket_scope_acceptance_surface_mismatch() {
  local summary=${1-} title=${2-} scope=${3-} forbidden=${4-}
  local surface natural token_re

  _ticket_scope_has_text "$scope" || _ticket_scope_has_text "$forbidden" || return 0

  while IFS=$'\t' read -r surface natural token_re; do
    [[ -n "$surface" ]] || continue
    if _ticket_scope_path_list_covers_surface "$forbidden" "$natural" "$token_re"; then
      printf '%s\n' "forbidden-acceptance-surface"
      return 0
    fi
    if _ticket_scope_has_text "$scope" \
      && ! _ticket_scope_path_list_covers_surface "$scope" "$natural" "$token_re"; then
      printf '%s\n' "acceptance-scope-uncovered"
      return 0
    fi
  done < <(_ticket_scope_required_acceptance_surfaces "$summary" "$title")
}

# ticket_scope_compute_acceptance_hash <ticket> <branch_slug> <summary> [<scope_files>] [<forbidden_files>]
#   Echo a stable sha1 over the dispatch content fields. The hash is a
#   compact fingerprint suitable for the audit ledger; it is NOT a
#   security primitive — operators read the value to spot drift between
#   what the prompt generator believes is the scope and what the brief
#   actually carries.
ticket_scope_compute_acceptance_hash() {
  local ticket=${1-} branch=${2-} summary=${3-} scope=${4-} forbidden=${5-}
  local payload
  printf -v payload 'ticket=%s\nbranch=%s\nsummary=%s\nscope=%s\nforbidden=%s\n' \
    "$ticket" "$branch" "$summary" "$scope" "$forbidden"
  if command -v sha1sum >/dev/null 2>&1; then
    printf '%s' "$payload" | sha1sum | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$payload" | shasum -a 1 | awk '{print $1}'
    return 0
  fi
  printf '%s\n' "no-sha1-available"
}

# ticket_scope_emit_audit <action> <ticket> <ticket_title> <branch_slug>
#                         <branch_issue_number> <slug_tail> <hash>
#                         <status> <mismatch_reason> [<context>]
#   Emit the canonical TICKET_SCOPE_VALIDATION audit line. The shape is
#   deliberately verbose — the whole point of #369 is that operators
#   need to see ticket intent vs. brief content side by side.
ticket_scope_emit_audit() {
  local action=${1:?usage: ticket_scope_emit_audit <action> <ticket> <title> <branch> <branch_issue> <slug_tail> <hash> <status> <reason> [<context>]}
  local ticket=${2-}
  local title=${3-}
  local branch=${4-}
  local branch_issue=${5-}
  local slug_tail=${6-}
  local hash=${7-}
  local status=${8-}
  local reason=${9-}
  local context=${10-unspecified}
  local title_safe=${title//[$'\n\r\t']/ }
  local slug_safe=${slug_tail//[$'\n\r\t']/ }
  local msg
  msg=$(printf 'TICKET_SCOPE_VALIDATION action=%s ticket_number=%s ticket_title=%q branch_slug=%s branch_issue_number=%s slug_tail=%q acceptance_scope_hash=%s status=%s mismatch=%s context=%s' \
    "$action" "$ticket" "$title_safe" "$branch" "$branch_issue" "$slug_safe" "$hash" "$status" "${reason:-none}" "$context")
  if declare -F audit >/dev/null 2>&1; then
    audit "$msg"
  else
    printf 'AUDIT LOG: %s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$msg" >&2
  fi
}

# ticket_scope_validate <ticket> <branch_slug> <summary> [<scope_files>] [<title>] [<context>] [<forbidden_files>]
#   Pure: classify the dispatch values without emitting audit. Echo:
#     <status>\t<mismatch_reason>\t<branch_issue>\t<slug_tail>\t<hash>
#   `<status>` is one of `ok` or `mismatch`. `<mismatch_reason>` is one of
#   `none`, `branch-issue-mismatch`, `slug-summary-divergence`,
#   `title-summary-divergence`, `acceptance-scope-uncovered`, or
#   `forbidden-acceptance-surface`.
ticket_scope_validate() {
  local ticket=${1-}
  local branch=${2-}
  local summary=${3-}
  local scope=${4-}
  local title=${5-}
  local _context=${6-unspecified}
  local forbidden=${7-}
  local branch_issue slug_tail hash
  branch_issue=$(ticket_scope_extract_branch_issue_number "$branch")
  slug_tail=$(ticket_scope_extract_slug_tail "$branch")
  hash=$(ticket_scope_compute_acceptance_hash "$ticket" "$branch" "$summary" "$scope" "$forbidden")

  local status=ok reason=none

  if [[ -n "$branch_issue" && "$branch_issue" != "$ticket" ]]; then
    status=mismatch
    reason="branch-issue-mismatch"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$status" "$reason" "$branch_issue" "$slug_tail" "$hash"
    return 0
  fi

  # Semantic check only fires when the slug followed the modern numbered
  # convention. Legacy default slugs (`feat/<project>-ticket-<N>`) emit
  # an empty slug_tail and skip the overlap check.
  if [[ -n "$slug_tail" ]]; then
    local slug_tokens summary_tokens overlap
    slug_tokens=$(_ticket_scope_token_count "$slug_tail")
    summary_tokens=$(_ticket_scope_token_count "$summary")
    if [[ "$slug_tokens" -ge 2 && "$summary_tokens" -ge 2 ]]; then
      overlap=$(_ticket_scope_overlap_count "$slug_tail" "$summary")
      if [[ "$overlap" -eq 0 ]]; then
        status=mismatch
        reason="slug-summary-divergence"
      fi
    fi
  fi

  # Optional title cross-check: if a title was provided AND it carries
  # ≥2 meaningful tokens, the summary must share at least one with it.
  # This catches dispatches where the slug+summary tell the same story
  # but neither matches the actual ticket title.
  if [[ "$status" == "ok" && -n "$title" ]]; then
    local title_tokens summary_tokens overlap
    title_tokens=$(_ticket_scope_token_count "$title")
    summary_tokens=$(_ticket_scope_token_count "$summary")
    if [[ "$title_tokens" -ge 2 && "$summary_tokens" -ge 2 ]]; then
      overlap=$(_ticket_scope_overlap_count "$title" "$summary")
      if [[ "$overlap" -eq 0 ]]; then
        status=mismatch
        reason="title-summary-divergence"
      fi
    fi
  fi

  # Optional acceptance-surface cross-check: known UAT acceptance clusters
  # must be reachable through the allowlist and must not be explicitly
  # forbidden. This prevents dispatching briefs that are internally
  # consistent but impossible to satisfy from their declared file scope.
  if [[ "$status" == "ok" ]]; then
    local acceptance_reason
    acceptance_reason=$(_ticket_scope_acceptance_surface_mismatch "$summary" "$title" "$scope" "$forbidden")
    if [[ -n "$acceptance_reason" ]]; then
      status=mismatch
      reason="$acceptance_reason"
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$status" "$reason" "$branch_issue" "$slug_tail" "$hash"
}

# Internal: parse a TSV row produced by `ticket_scope_validate` into
# the named fields. `cut -f` handles empty fields between consecutive
# tabs correctly; `IFS=$'\t' read` would collapse them because tab is
# whitespace IFS, which would shift the hash into branch_issue_number
# whenever a legacy slug produced an empty branch_issue+slug_tail.
_ticket_scope_parse_row() {
  local row=${1-} field=${2:?usage: _ticket_scope_parse_row <row> <1..5>}
  printf '%s' "$row" | cut -f"$field"
}

# ticket_scope_assert <ticket> <branch_slug> <summary> [<scope_files>] [<title>] [<context>]
#   Run validate, emit audit, and exit non-zero on mismatch. This is the
#   primary entry point from `brief_agents.sh`.
ticket_scope_assert() {
  local ticket=${1-} branch=${2-} summary=${3-} scope=${4-} title=${5-} context=${6-brief_agents} forbidden=${7-}
  local row status reason branch_issue slug_tail hash
  row=$(ticket_scope_validate "$ticket" "$branch" "$summary" "$scope" "$title" "$context" "$forbidden")
  status=$(_ticket_scope_parse_row "$row" 1)
  reason=$(_ticket_scope_parse_row "$row" 2)
  branch_issue=$(_ticket_scope_parse_row "$row" 3)
  slug_tail=$(_ticket_scope_parse_row "$row" 4)
  hash=$(_ticket_scope_parse_row "$row" 5)

  ticket_scope_emit_audit "validate" "$ticket" "$title" "$branch" \
    "$branch_issue" "$slug_tail" "$hash" "$status" "$reason" "$context"

  if [[ "$status" != "ok" ]]; then
    printf 'ticket_scope_mismatch: ticket=%s branch=%s reason=%s\n' \
      "$ticket" "$branch" "$reason" >&2
    return "$ORCH_TICKET_SCOPE_MISMATCH_EXIT_CODE"
  fi
  return 0
}

# ticket_scope_assert_or_rebind <ticket> <branch_slug> <summary>
#                               [<scope_files>] [<title>] [<context>]
#   Operator manual-correction path: emit a `TICKET_SCOPE_VALIDATION
#   action=rebind` audit line carrying the same evidence shape as
#   `ticket_scope_assert`, then return 0. Operators choose this entry
#   when they have already verified the brief's scope by hand and want
#   the dispatch to proceed under the supplied ticket number anyway.
ticket_scope_assert_or_rebind() {
  local ticket=${1-} branch=${2-} summary=${3-} scope=${4-} title=${5-} context=${6-brief_agents_rebind} forbidden=${7-}
  local row status reason branch_issue slug_tail hash
  row=$(ticket_scope_validate "$ticket" "$branch" "$summary" "$scope" "$title" "$context" "$forbidden")
  status=$(_ticket_scope_parse_row "$row" 1)
  reason=$(_ticket_scope_parse_row "$row" 2)
  branch_issue=$(_ticket_scope_parse_row "$row" 3)
  slug_tail=$(_ticket_scope_parse_row "$row" 4)
  hash=$(_ticket_scope_parse_row "$row" 5)
  ticket_scope_emit_audit "rebind" "$ticket" "$title" "$branch" \
    "$branch_issue" "$slug_tail" "$hash" "$status" "$reason" "$context"
  return 0
}
