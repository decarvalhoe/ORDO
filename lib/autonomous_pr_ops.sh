#!/usr/bin/env bash
# lib/autonomous_pr_ops.sh — autonomous PR operations gate library (#361).
#
# Sourceable helpers used by scripts/autonomous_pr_ops.sh and by tests.
# The library is universal: every behavior reads from project profile
# variables and from gh / state files; nothing is hardcoded to a
# specific project, agent, or model.
#
# Profile keys consumed (declared in the project profile via
# `lib/config_resolver.sh::load_project_config`):
#
#   AUTO_PR_OPS_ENABLED                — "1"/"0" master switch.
#   AUTO_PR_OPS_MODE                   — "dry-run" (default) or "live".
#   AUTO_PR_OPS_ALLOWED_BASES          — space- or comma-separated list of
#                                        base branch names eligible for
#                                        autonomous merge.
#   AUTO_PR_OPS_MERGE_STRATEGY         — "squash" (default) | "rebase" | "merge".
#   AUTO_PR_OPS_REQUIRE_REVIEWS        — "1"/"0" (default 1).
#   AUTO_PR_OPS_BUSINESS_EXCLUDED_PATHS — newline-list of path prefixes the
#                                        PR must not touch (business scope).
#   AUTO_PR_OPS_RELEASE_GATE_LABELS    — comma list of labels that, when
#                                        present on a PR, block the
#                                        autonomous path (release / GxP /
#                                        CSV / docs gate markers).
#
# State files (under the project state dir resolved by audit_log/state_persist):
#
#   auto_pr_ops_kill_switch.json  — engaged kill-switch marker. Presence
#                                   alone refuses every live action; the
#                                   file body documents who engaged it
#                                   and why.
#
# Doctrine:
#   * Universal — no Claude-CLI / no project hardcoding.
#   * Safe by default — every gate is conservative; an unknown,
#     pending, or ambiguous answer counts as a refusal.
#   * Explicit kill-switch — the kill-switch file is the canonical
#     pause control, accessible to every operator regardless of
#     terminal session.
#   * Evidence-first — every evaluation emits a JSON record that
#     callers can pipe into the audit trail before any mutation.

set -o pipefail

# Re-source guard — the library is small enough that callers can
# safely source it multiple times.
if [[ -n "${ORCH_AUTO_PR_OPS_LIB_LOADED:-}" ]]; then
  # shellcheck disable=SC2317  # the `|| true` fallback is intentional for non-sourced contexts
  return 0 2>/dev/null || true
fi
# shellcheck disable=SC2034  # consumed by callers after sourcing
ORCH_AUTO_PR_OPS_LIB_LOADED=1


# ---------------------------------------------------------------------------
# Version + constants
# ---------------------------------------------------------------------------

ORCH_AUTO_PR_OPS_VERSION="1.0.0"

ORCH_AUTO_PR_OPS_VALID_STRATEGIES="squash rebase merge"
ORCH_AUTO_PR_OPS_DEFAULT_STRATEGY="squash"

# Stable list of gate keys, in evaluation order. Tests pin this list so
# a re-ordering or rename surfaces in review.
# shellcheck disable=SC2034  # consumed by callers after sourcing
ORCH_AUTO_PR_OPS_GATE_KEYS=(
  policy_enabled
  not_kill_switched
  merge_strategy_valid
  target_branch_allowed
  not_draft
  mergeable_known_clean
  required_checks_pass
  required_reviews_satisfied
  no_release_gate_label
  no_business_scope_exclusion
)


# ---------------------------------------------------------------------------
# Policy resolution
# ---------------------------------------------------------------------------

# auto_pr_ops_policy_enabled
#   Returns 0 (true) when the profile master switch is enabled.
auto_pr_ops_policy_enabled() {
  local raw="${AUTO_PR_OPS_ENABLED:-0}"
  case "$raw" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# auto_pr_ops_mode
#   Echo "dry-run" or "live". Default dry-run.
auto_pr_ops_mode() {
  local raw="${AUTO_PR_OPS_MODE:-dry-run}"
  case "$raw" in
    live|LIVE) printf 'live\n' ;;
    *) printf 'dry-run\n' ;;
  esac
}

# auto_pr_ops_strategy
#   Echo the configured merge strategy (lowercased) or the default.
auto_pr_ops_strategy() {
  local raw="${AUTO_PR_OPS_MERGE_STRATEGY:-$ORCH_AUTO_PR_OPS_DEFAULT_STRATEGY}"
  printf '%s\n' "${raw,,}"
}

# auto_pr_ops_strategy_valid <strategy>
#   Return 0 if the strategy is one of the allowed values.
auto_pr_ops_strategy_valid() {
  local s="${1:-}"
  local valid
  for valid in $ORCH_AUTO_PR_OPS_VALID_STRATEGIES; do
    if [[ "$s" == "$valid" ]]; then
      return 0
    fi
  done
  return 1
}

# auto_pr_ops_require_reviews
#   Return 0 when the profile requires approving reviews. Default 1.
auto_pr_ops_require_reviews() {
  local raw="${AUTO_PR_OPS_REQUIRE_REVIEWS:-1}"
  case "$raw" in
    0|false|FALSE|no|NO|off|OFF) return 1 ;;
    *) return 0 ;;
  esac
}

# auto_pr_ops_allowed_bases
#   Echo the configured allowed-base branch list, one branch per line.
auto_pr_ops_allowed_bases() {
  local raw="${AUTO_PR_OPS_ALLOWED_BASES:-}"
  # Accept comma- or whitespace-separated input.
  printf '%s\n' "$raw" | tr ',' '\n' | awk 'NF { print $1 }'
}

# auto_pr_ops_base_allowed <branch>
auto_pr_ops_base_allowed() {
  local branch="${1:-}"
  [[ -n "$branch" ]] || return 1
  local b
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    if [[ "$b" == "$branch" ]]; then
      return 0
    fi
  done < <(auto_pr_ops_allowed_bases)
  return 1
}

# auto_pr_ops_release_gate_labels
#   Echo the configured release-gate label list, one per line.
auto_pr_ops_release_gate_labels() {
  local raw="${AUTO_PR_OPS_RELEASE_GATE_LABELS:-}"
  printf '%s\n' "$raw" | tr ',' '\n' | awk 'NF { print $1 }'
}

# auto_pr_ops_business_excluded_paths
#   Echo the configured business-scope path prefixes, one per line.
auto_pr_ops_business_excluded_paths() {
  local raw="${AUTO_PR_OPS_BUSINESS_EXCLUDED_PATHS:-}"
  # Profiles may use newline- or comma-separated lists.
  printf '%s\n' "$raw" | tr ',' '\n' | awk 'NF { print $1 }'
}


# ---------------------------------------------------------------------------
# Kill switch
# ---------------------------------------------------------------------------

# auto_pr_ops_kill_switch_path
#   Echo the kill-switch file path under the project state dir. The
#   ``state_dir`` helper from lib/audit_log.sh / lib/state_persist.sh
#   is preferred when it has been sourced; otherwise we fall back to
#   the plain $ORCH_STATE_BASE/$PROJECT/ layout so the library remains
#   testable in isolation.
auto_pr_ops_kill_switch_path() {
  local override="${ORCH_AUTO_PR_OPS_KILL_SWITCH_PATH:-}"
  if [[ -n "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  if declare -F state_file >/dev/null 2>&1; then
    state_file auto_pr_ops_kill_switch.json
    return 0
  fi
  local base="${ORCH_STATE_BASE:-/tmp}"
  local proj="${PROJECT:-default}"
  printf '%s/%s/auto_pr_ops_kill_switch.json\n' "$base" "$proj"
}

# auto_pr_ops_kill_switch_active
#   Returns 0 (true) when a kill-switch file exists at the configured
#   path. Refuses every live action when active.
auto_pr_ops_kill_switch_active() {
  local path
  path=$(auto_pr_ops_kill_switch_path)
  [[ -f "$path" ]]
}

# auto_pr_ops_kill_switch_engage <reason>
#   Write a kill-switch marker. The marker body is JSON for machine
#   parsing; the body is intentionally small so the file can be
#   inspected with cat.
auto_pr_ops_kill_switch_engage() {
  local reason="${1:-engaged}"
  local path
  path=$(auto_pr_ops_kill_switch_path)
  mkdir -p "$(dirname "$path")"
  local now
  now=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  printf '{"engaged_at":"%s","reason":"%s"}\n' "$now" "${reason//\"/\\\"}" \
    >"$path"
}

# auto_pr_ops_kill_switch_release
auto_pr_ops_kill_switch_release() {
  local path
  path=$(auto_pr_ops_kill_switch_path)
  if [[ -f "$path" ]]; then
    rm -f "$path"
  fi
}


# ---------------------------------------------------------------------------
# PR-level signals (gh-backed). Each helper either returns the answer
# or signals "unknown" — callers treat unknown as a refusal.
# ---------------------------------------------------------------------------

# auto_pr_ops_pr_field <repo> <pr> <jq-expr>
#   Run gh pr view with --json fields and extract the requested jq
#   expression. Echo nothing on error; caller treats empty as
#   "unknown" / refused.
auto_pr_ops_pr_field() {
  local repo="${1:?usage: auto_pr_ops_pr_field <repo> <pr> <jq-expr> [json-fields]}"
  local pr="${2:?}"
  local expr="${3:?}"
  local fields="${4:-baseRefName,isDraft,mergeable,mergeStateStatus,labels,reviewDecision,statusCheckRollup,files}"
  local gh_bin="${ORCH_GH_BIN:-gh}"
  GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" "$gh_bin" pr view "$pr" \
    --repo "$repo" --json "$fields" 2>/dev/null \
    | jq -r "$expr" 2>/dev/null
}


# ---------------------------------------------------------------------------
# Gate evaluators
#
# Each gate prints JSON to stdout: {"key":"<name>","ok":true|false,
# "reason":"<short>"}. The JSON line never embeds newlines so callers
# can read line-by-line.
# ---------------------------------------------------------------------------

_auto_pr_ops_gate() {
  local key="${1:?}"
  local ok="${2:?}"
  local reason="${3:-}"
  printf '{"key":"%s","ok":%s,"reason":"%s"}\n' \
    "$key" "$ok" "${reason//\"/\\\"}"
}

auto_pr_ops_gate_policy_enabled() {
  if auto_pr_ops_policy_enabled; then
    _auto_pr_ops_gate "policy_enabled" "true" "AUTO_PR_OPS_ENABLED=1 in profile"
  else
    _auto_pr_ops_gate "policy_enabled" "false" "AUTO_PR_OPS_ENABLED is not 1"
  fi
}

auto_pr_ops_gate_not_kill_switched() {
  if auto_pr_ops_kill_switch_active; then
    _auto_pr_ops_gate "not_kill_switched" "false" "kill switch engaged at $(auto_pr_ops_kill_switch_path)"
  else
    _auto_pr_ops_gate "not_kill_switched" "true" "no kill switch active"
  fi
}

auto_pr_ops_gate_merge_strategy_valid() {
  local s
  s=$(auto_pr_ops_strategy)
  if auto_pr_ops_strategy_valid "$s"; then
    _auto_pr_ops_gate "merge_strategy_valid" "true" "strategy=$s"
  else
    _auto_pr_ops_gate "merge_strategy_valid" "false" "strategy=$s not in {$ORCH_AUTO_PR_OPS_VALID_STRATEGIES}"
  fi
}

auto_pr_ops_gate_target_branch_allowed() {
  local base="${1:-}"
  if [[ -z "$base" ]]; then
    _auto_pr_ops_gate "target_branch_allowed" "false" "base branch unknown"
    return 0
  fi
  if auto_pr_ops_base_allowed "$base"; then
    _auto_pr_ops_gate "target_branch_allowed" "true" "base=$base in allowed list"
  else
    _auto_pr_ops_gate "target_branch_allowed" "false" "base=$base not in AUTO_PR_OPS_ALLOWED_BASES"
  fi
}

auto_pr_ops_gate_not_draft() {
  local is_draft="${1:-unknown}"
  case "$is_draft" in
    false|FALSE)
      _auto_pr_ops_gate "not_draft" "true" "PR is not draft"
      ;;
    true|TRUE)
      _auto_pr_ops_gate "not_draft" "false" "PR is draft"
      ;;
    *)
      _auto_pr_ops_gate "not_draft" "false" "draft state unknown"
      ;;
  esac
}

auto_pr_ops_gate_mergeable_known_clean() {
  local mergeable="${1:-UNKNOWN}"
  local merge_state="${2:-UNKNOWN}"
  if [[ "$mergeable" != "MERGEABLE" ]]; then
    _auto_pr_ops_gate "mergeable_known_clean" "false" "mergeable=$mergeable (not MERGEABLE)"
    return 0
  fi
  case "$merge_state" in
    CLEAN|UNSTABLE)
      _auto_pr_ops_gate "mergeable_known_clean" "true" "mergeable=MERGEABLE state=$merge_state"
      ;;
    BLOCKED)
      # BLOCKED is treated separately by the review/required-checks
      # gates; here we want a clear-or-unstable signal only.
      _auto_pr_ops_gate "mergeable_known_clean" "false" "mergeStateStatus=BLOCKED"
      ;;
    *)
      _auto_pr_ops_gate "mergeable_known_clean" "false" "mergeStateStatus=$merge_state"
      ;;
  esac
}

auto_pr_ops_gate_required_checks_pass() {
  # Status: pass | fail | pending | unknown.
  local status="${1:-unknown}"
  case "$status" in
    pass)
      _auto_pr_ops_gate "required_checks_pass" "true" "all required checks pass"
      ;;
    fail)
      _auto_pr_ops_gate "required_checks_pass" "false" "at least one required check failed"
      ;;
    pending)
      _auto_pr_ops_gate "required_checks_pass" "false" "required checks still pending"
      ;;
    not-applicable)
      # Reuses the pr_merge no-check policy classification: when the
      # PR's scope is paths-filtered docs/workflow-only and the
      # operator has opted into the no-check policy, an empty rollup
      # is acceptable. Defaults still treat empty as pending.
      _auto_pr_ops_gate "required_checks_pass" "true" "no-check policy applied (paths-filtered scope)"
      ;;
    *)
      _auto_pr_ops_gate "required_checks_pass" "false" "check status unknown"
      ;;
  esac
}

auto_pr_ops_gate_required_reviews_satisfied() {
  local review_decision="${1:-NONE}"
  if ! auto_pr_ops_require_reviews; then
    _auto_pr_ops_gate "required_reviews_satisfied" "true" "profile sets AUTO_PR_OPS_REQUIRE_REVIEWS=0"
    return 0
  fi
  case "$review_decision" in
    APPROVED)
      _auto_pr_ops_gate "required_reviews_satisfied" "true" "reviewDecision=APPROVED"
      ;;
    CHANGES_REQUESTED)
      _auto_pr_ops_gate "required_reviews_satisfied" "false" "reviewDecision=CHANGES_REQUESTED"
      ;;
    REVIEW_REQUIRED)
      _auto_pr_ops_gate "required_reviews_satisfied" "false" "reviewDecision=REVIEW_REQUIRED"
      ;;
    *)
      _auto_pr_ops_gate "required_reviews_satisfied" "false" "reviewDecision=$review_decision (unknown)"
      ;;
  esac
}

auto_pr_ops_gate_no_release_gate_label() {
  # Args: each PR label as a separate positional argument.
  local hits=()
  local label
  local config
  while IFS= read -r config; do
    [[ -n "$config" ]] || continue
    for label in "$@"; do
      [[ -n "$label" ]] || continue
      if [[ "${label,,}" == "${config,,}" ]]; then
        hits+=("$label")
      fi
    done
  done < <(auto_pr_ops_release_gate_labels)
  if [[ "${#hits[@]}" -eq 0 ]]; then
    _auto_pr_ops_gate "no_release_gate_label" "true" "no configured release-gate label present"
  else
    _auto_pr_ops_gate "no_release_gate_label" "false" "release-gate labels present: ${hits[*]}"
  fi
}

auto_pr_ops_gate_no_business_scope_exclusion() {
  # Args: each PR file path as a separate positional argument.
  local hits=()
  local prefix
  local path
  while IFS= read -r prefix; do
    [[ -n "$prefix" ]] || continue
    for path in "$@"; do
      [[ -n "$path" ]] || continue
      case "$path" in
        "$prefix"|"$prefix"*) hits+=("$path"); break ;;
      esac
    done
  done < <(auto_pr_ops_business_excluded_paths)
  if [[ "${#hits[@]}" -eq 0 ]]; then
    _auto_pr_ops_gate "no_business_scope_exclusion" "true" "no excluded path touched"
  else
    _auto_pr_ops_gate "no_business_scope_exclusion" "false" "excluded paths touched: ${hits[*]}"
  fi
}


# ---------------------------------------------------------------------------
# High-level evaluator
#
# Reads PR signals (or the test-supplied environment) once, runs every
# gate, and prints the aggregate result as a single JSON object.
# ---------------------------------------------------------------------------

# auto_pr_ops_evaluate_pr <repo> <pr>
#
# The function reads the gh pr view payload once into temp variables
# (or honors test-supplied AUTO_PR_OPS_TEST_* env vars to skip the gh
# call). Output is one JSON object per call.
auto_pr_ops_evaluate_pr() {
  local repo="${1:?usage: auto_pr_ops_evaluate_pr <repo> <pr>}"
  local pr="${2:?}"

  local base draft mergeable merge_state review_decision check_status
  local labels_arr=()
  local files_arr=()

  if [[ -n "${AUTO_PR_OPS_TEST_PR_PAYLOAD:-}" ]]; then
    # Tests may stub the pr payload as a JSON file path. The file
    # must contain a single object with the same shape gh pr view
    # --json returns.
    local payload_path="$AUTO_PR_OPS_TEST_PR_PAYLOAD"
    base=$(jq -r '.baseRefName // ""' "$payload_path")
    draft=$(jq -r '.isDraft // "false"' "$payload_path")
    mergeable=$(jq -r '.mergeable // "UNKNOWN"' "$payload_path")
    merge_state=$(jq -r '.mergeStateStatus // "UNKNOWN"' "$payload_path")
    review_decision=$(jq -r '.reviewDecision // "NONE"' "$payload_path")
    check_status=$(jq -r '.checkStatus // "unknown"' "$payload_path")
    mapfile -t labels_arr < <(jq -r '.labels[]?.name // empty' "$payload_path")
    mapfile -t files_arr < <(jq -r '.files[]?.path // empty' "$payload_path")
  else
    local payload
    payload=$(GH_CONFIG_DIR="${GH_CONFIG_DIR:-}" "${ORCH_GH_BIN:-gh}" pr view "$pr" \
      --repo "$repo" \
      --json baseRefName,isDraft,mergeable,mergeStateStatus,labels,reviewDecision,statusCheckRollup,files \
      2>/dev/null)
    base=$(printf '%s' "$payload" | jq -r '.baseRefName // ""')
    draft=$(printf '%s' "$payload" | jq -r '.isDraft // "false"')
    mergeable=$(printf '%s' "$payload" | jq -r '.mergeable // "UNKNOWN"')
    merge_state=$(printf '%s' "$payload" | jq -r '.mergeStateStatus // "UNKNOWN"')
    review_decision=$(printf '%s' "$payload" | jq -r '.reviewDecision // "NONE"')
    mapfile -t labels_arr < <(printf '%s' "$payload" | jq -r '.labels[]?.name // empty')
    mapfile -t files_arr < <(printf '%s' "$payload" | jq -r '.files[]?.path // empty')
    # Reuse the existing gov_pr_check_status helper if it's been
    # sourced; otherwise default to unknown.
    if declare -F gov_pr_check_status >/dev/null 2>&1; then
      check_status=$(gov_pr_check_status "$repo" "$pr" 2>/dev/null || printf 'unknown')
    else
      check_status="unknown"
    fi
  fi

  # Run every gate and capture results into one aggregate JSON object.
  local gate_lines=()
  gate_lines+=("$(auto_pr_ops_gate_policy_enabled)")
  gate_lines+=("$(auto_pr_ops_gate_not_kill_switched)")
  gate_lines+=("$(auto_pr_ops_gate_merge_strategy_valid)")
  gate_lines+=("$(auto_pr_ops_gate_target_branch_allowed "$base")")
  gate_lines+=("$(auto_pr_ops_gate_not_draft "$draft")")
  gate_lines+=("$(auto_pr_ops_gate_mergeable_known_clean "$mergeable" "$merge_state")")
  gate_lines+=("$(auto_pr_ops_gate_required_checks_pass "$check_status")")
  gate_lines+=("$(auto_pr_ops_gate_required_reviews_satisfied "$review_decision")")
  gate_lines+=("$(auto_pr_ops_gate_no_release_gate_label "${labels_arr[@]}")")
  gate_lines+=("$(auto_pr_ops_gate_no_business_scope_exclusion "${files_arr[@]}")")

  local mode strategy
  mode=$(auto_pr_ops_mode)
  strategy=$(auto_pr_ops_strategy)

  printf '%s' "${gate_lines[@]}" \
    | jq -s --arg repo "$repo" --arg pr "$pr" --arg mode "$mode" \
        --arg strategy "$strategy" \
        --arg version "$ORCH_AUTO_PR_OPS_VERSION" '
        {
          version: $version,
          repo: $repo,
          pr: ($pr | tonumber? // $pr),
          mode: $mode,
          strategy: $strategy,
          gates: .,
          eligible: (all(.[]; .ok)),
          refused_reasons: (
            [.[] | select(.ok == false) | .key + ": " + .reason]
          )
        }
      '
}


# ---------------------------------------------------------------------------
# Evidence renderer
# ---------------------------------------------------------------------------

# auto_pr_ops_render_evidence <evaluation-json>
#   Render a one-paragraph evidence block from a single
#   evaluate_pr output. Designed to be appended to the audit trail
#   before any mutation in live mode.
auto_pr_ops_render_evidence() {
  local payload="${1:?usage: auto_pr_ops_render_evidence <evaluation-json>}"
  printf '%s' "$payload" | jq -r '
    "AUTONOMOUS_PR_OPS evaluation: repo=\(.repo) pr=\(.pr) mode=\(.mode) strategy=\(.strategy) eligible=\(.eligible)"
    + (if (.refused_reasons | length) > 0 then " refused=" + (.refused_reasons | join("; ")) else "" end)
  '
}
