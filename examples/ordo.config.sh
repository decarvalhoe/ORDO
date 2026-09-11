#!/usr/bin/env bash
# examples/ordo.config.sh - dogfooding config loader.
#
# Keep live repository names, tmux labels, host paths, and credentials outside
# the repository. Point ORDO_PROJECT_PROFILE at an operator-owned config file
# that defines PROJECT, GH_REPO, AGENT_PANES, and related topology values.

ordo_external_profile_error() {
  printf 'ordo.config.sh requires ORDO_PROJECT_PROFILE to point at an external project config\n' >&2
  return 2 2>/dev/null || exit 2
}

ordo_git_identity_alias_reason() {
  local left_label="$1"
  local right_label="$2"
  local entry alias_label canonical_label reason extra

  if [[ ! -v AGENT_GIT_IDENTITY_ALIASES || "${#AGENT_GIT_IDENTITY_ALIASES[@]}" -eq 0 ]]; then
    return 1
  fi

  for entry in "${AGENT_GIT_IDENTITY_ALIASES[@]}"; do
    IFS='|' read -r alias_label canonical_label reason extra <<<"$entry"
    if [[ -z "$alias_label" || -z "$canonical_label" || -z "$reason" || -n "$extra" ]]; then
      printf 'AGENT_GIT_IDENTITY_ALIASES entry malformed (need alias|canonical|reason): %s\n' "$entry" >&2
      return 2
    fi

    if [[ "$alias_label" == "$left_label" && "$canonical_label" == "$right_label" ]] ||
      [[ "$alias_label" == "$right_label" && "$canonical_label" == "$left_label" ]]; then
      printf '%s' "$reason"
      return 0
    fi
  done

  return 1
}

ordo_validate_git_identity_aliases() {
  local pane label entry identity_label identity_name identity_email extra
  local name email key previous reason alias_rc
  local -a labels=()
  declare -A explicit_names=()
  declare -A explicit_emails=()
  declare -A seen_identity_labels=()

  for pane in "${AGENT_PANES[@]}"; do
    label="${pane%%|*}"
    [[ -n "$label" ]] && labels+=("$label")
  done

  if [[ -v AGENT_GIT_IDENTITIES && "${#AGENT_GIT_IDENTITIES[@]}" -gt 0 ]]; then
    for entry in "${AGENT_GIT_IDENTITIES[@]}"; do
      IFS='|' read -r identity_label identity_name identity_email extra <<<"$entry"
      if [[ -z "$identity_label" || -z "$identity_name" || -z "$identity_email" || -n "$extra" ]]; then
        printf 'AGENT_GIT_IDENTITIES entry malformed (need label|name|email): %s\n' "$entry" >&2
        return 2
      fi
      explicit_names["$identity_label"]="$identity_name"
      explicit_emails["$identity_label"]="$identity_email"
    done
  fi

  for label in "${labels[@]}"; do
    if [[ -n "${explicit_names[$label]+x}" ]]; then
      name="${explicit_names[$label]}"
      email="${explicit_emails[$label]}"
    elif [[ -n "${AGENT_GIT_IDENTITY_NAME_TEMPLATE:-}" &&
      -n "${AGENT_GIT_IDENTITY_EMAIL_TEMPLATE:-}" ]]; then
      printf -v name "$AGENT_GIT_IDENTITY_NAME_TEMPLATE" "$label"
      printf -v email "$AGENT_GIT_IDENTITY_EMAIL_TEMPLATE" "$label"
    else
      continue
    fi

    key="${name}"$'\034'"${email}"
    if [[ -n "${seen_identity_labels[$key]+x}" ]]; then
      previous="${seen_identity_labels[$key]}"
      if reason="$(ordo_git_identity_alias_reason "$label" "$previous")"; then
        alias_rc=0
      else
        alias_rc=$?
      fi
      if [[ "$alias_rc" -eq 0 ]]; then
        printf 'documented git identity alias: %s shares identity with %s (%s)\n' \
          "$label" "$previous" "$reason" >&2
      elif [[ "$alias_rc" -eq 1 ]]; then
        printf 'shared git identity requires AGENT_GIT_IDENTITY_ALIASES: %s and %s both resolve to %s <%s>\n' \
          "$previous" "$label" "$name" "$email" >&2
        return 2
      else
        return 2
      fi
    else
      seen_identity_labels["$key"]="$label"
    fi
  done

  return 0
}

if [[ -z "${ORDO_PROJECT_PROFILE:-}" ]]; then
  ordo_external_profile_error
fi

if [[ ! -f "$ORDO_PROJECT_PROFILE" ]]; then
  printf 'external project config not found: %s\n' "$ORDO_PROJECT_PROFILE" >&2
  return 2 2>/dev/null || exit 2
fi

# shellcheck source=/dev/null
source "$ORDO_PROJECT_PROFILE"

missing=()
for required_name in PROJECT GH_REPO DEFAULT_BRANCH GH_CONFIG_DIR AGENT_REPO_PREFIX AGENT_WORKDIR_TEMPLATE; do
  if [[ -z "${!required_name:-}" ]]; then
    missing+=("$required_name")
  fi
done

if [[ ! -v AGENT_PANES || "${#AGENT_PANES[@]}" -eq 0 ]]; then
  missing+=("AGENT_PANES")
fi

if [[ "${#missing[@]}" -gt 0 ]]; then
  printf 'external project config missing required values: %s\n' "${missing[*]}" >&2
  return 2 2>/dev/null || exit 2
fi

if ! ordo_validate_git_identity_aliases; then
  return 2 2>/dev/null || exit 2
fi

# PR-ops policy default for ORDO dogfooding profiles (#680).
#
# scripts/dispatch_pr_ops.sh refuses non-`observe` modes unless the project
# profile opts in via PR_OPS_MODE_ALLOWED (a comma list — see lib/pr_ops_tasks.sh
# PR_OPS_MODES). ORDO live profiles loaded through this template inherit a
# safe default of `centralized` so operator-driven follow-up dispatch (PR
# rebase / CI fix prompts) can flow through dispatch_pr_ops without the
# gate firing `missing-policy`. External profiles may override by setting
# PR_OPS_MODE_ALLOWED to the empty string (roll back to observe-only) or
# `centralized,delegated` once governance review approves delegated mode.
# `autonomous` is reserved and must not be added here.
: "${PR_OPS_MODE_ALLOWED:=centralized}"
export PR_OPS_MODE_ALLOWED

# Runtime and provider adapters (#811, docs/architecture/adapters.md).
#
# The agentic control plane reaches agents through `ordo_runtime` and the
# forge through `ordo_provider`. Both are selected per profile; the defaults
# below reproduce today's behaviour (local tmux panes, GitHub through `gh`),
# so an existing profile needs nothing. Uncomment and adapt to switch forge.
#
#   ORDO_RUNTIME_ADAPTER    tmux | ssh | fake      (default tmux)
#   ORDO_PROVIDER_ADAPTER   github | forgejo | gitlab | fake   (default github;
#                           forgejo = Forgejo/Gitea REST v1, gitlab = GitLab REST v4,
#                           both through curl — docs/architecture/providers.md, #815)
#   ORDO_FORGE_REPO         owner/repo used by ordo_provider when --repo is absent
#                           (GH_REPO remains the fallback for existing profiles;
#                           on GitLab this is the project path, e.g. group/sub/repo)
#   ORDO_FORGE_URL          base URL of the forge instance for the REST adapters
#                           (https://forge.example — /api/v1 or /api/v4 is appended,
#                           a URL already ending with it is accepted); for github a
#                           non-github.com host becomes GH_HOST
#   ORDO_FORGE_TOKEN_FILE   token file for the REST adapters — a path, never the
#                           token itself; must be mode 0600 (group/other bits =>
#                           refused, exit 3); it is never logged. ORDO_FORGE_TOKEN
#                           (env) is the fallback when no file is configured
#   ORDO_PROVIDER_TIMEOUT_SEC          read timeout of one forge call (30)
#   ORDO_PROVIDER_MUTATION_TIMEOUT_SEC timeout of one mutating call (120); a
#                           mutation that times out is reported non-retryable
#   ORDO_PROVIDER_HTTP_RETRIES         bounded retries of READS on 429/5xx/transport
#                           errors (0); Retry-After honoured up to
#                           ORDO_PROVIDER_HTTP_RETRY_MAX_SLEEP (5). Mutations are never
#                           retried by the HTTP layer: retry with the same idempotency key
#   ORDO_PROVIDER_HTTP_PAGE_SIZE / ORDO_PROVIDER_HTTP_MAX_PAGES
#                           page size (50) and page cap (20) of the "fetch every page"
#                           loops (files, reviews, comments, locally filtered lists)
#   ORDO_PROVIDER_HTTP_LOG  optional request trace file (ts method url status ms —
#                           never headers, never bodies)
#   ORDO_FORGEJO_WIP_PREFIXES  draft title prefixes recognised on Forgejo
#                           ("WIP:|[WIP]|Draft:|[Draft]"; the first one is written)
#   ORDO_GITLAB_DRAFT_PREFIX   draft title prefix written on GitLab ("Draft:")
#   ORDO_SSH_HOST           ssh target of the ssh runtime adapter (plus optional
#                           ORDO_SSH_OPTS, ORDO_SSH_TIMEOUT_SEC, ORDO_SSH_REMOTE_TMUX)
#   ORDO_FAKE_ADAPTER_DIR   fixture root when a fake adapter is selected
#
# Forgejo example:
# : "${ORDO_RUNTIME_ADAPTER:=tmux}"
# : "${ORDO_PROVIDER_ADAPTER:=forgejo}"
# : "${ORDO_FORGE_REPO:=$GH_REPO}"
# : "${ORDO_FORGE_URL:=https://forge.example.org}"
# : "${ORDO_FORGE_TOKEN_FILE:=$HOME/.config/ordo/forge-token}"
# : "${ORDO_SSH_HOST:=agent@win-host}"
# export ORDO_RUNTIME_ADAPTER ORDO_PROVIDER_ADAPTER ORDO_FORGE_REPO ORDO_FORGE_URL ORDO_FORGE_TOKEN_FILE ORDO_SSH_HOST
#
# GitLab example (the project path may be nested):
# : "${ORDO_PROVIDER_ADAPTER:=gitlab}"
# : "${ORDO_FORGE_REPO:=platform/tools/widgets}"
# : "${ORDO_FORGE_URL:=https://gitlab.example.org}"
# : "${ORDO_FORGE_TOKEN_FILE:=$HOME/.config/ordo/gitlab-token}"
# export ORDO_PROVIDER_ADAPTER ORDO_FORGE_REPO ORDO_FORGE_URL ORDO_FORGE_TOKEN_FILE

# Scheduler substrate (#810, docs/architecture/scheduler.md).
#
# Durable leases, heartbeats, retries with backoff, timeouts and budgets on
# top of the event journal. Everything is off / default-sized unless a
# profile opts in; the loop hook is the only knob that changes orch_loop.sh
# behaviour and it defaults to off.
#
#   ORDO_SCHEDULER_ENABLED         1 = orch_loop.sh runs one scheduler tick per cycle (default 0)
#   ORDO_SCHED_MAX_FANOUT          runs holding a lease at once (default 2)
#   ORDO_SCHED_LEASE_TTL           lease TTL seconds (default 300); ORDO_SCHED_HEARTBEAT_SEC renew cadence (60)
#   ORDO_SCHED_RUN_TIMEOUT_SEC     max active seconds per attempt (default 3600, 0 = off)
#   ORDO_SCHED_TIMEOUT_POLICY      requeue | fail (default requeue); ORDO_SCHED_LEASE_EXPIRY_POLICY likewise
#   ORDO_SCHED_MAX_RETRIES         retry budget (default 3 -> max_attempts 4)
#   ORDO_SCHED_BACKOFF_BASE_SEC    exponential backoff base / cap (default 30 / 1800); ORDO_SCHED_JITTER=0 pins it
#   ORDO_SCHED_BUDGET_MAX_TURNS    per-run defaults: turns 200, tool calls 2000, seconds 14400,
#   ORDO_SCHED_BUDGET_MAX_*        tokens 5000000, cost 0 (unlimited)
#   ORDO_SCHED_REQUIRE_READINESS   1 = every run needs an explicit readiness verdict before a pick (fail-closed)
#   ORDO_SCHED_WORKER_ID           lease owner label (the loop uses orch-loop@<host>:<pid>)
#
# : "${ORDO_SCHEDULER_ENABLED:=1}"
# : "${ORDO_SCHED_MAX_FANOUT:=3}"
# : "${ORDO_SCHED_LEASE_TTL:=300}"
# : "${ORDO_SCHED_RUN_TIMEOUT_SEC:=5400}"
# : "${ORDO_SCHED_MAX_RETRIES:=2}"
# : "${ORDO_SCHED_BUDGET_MAX_TOKENS:=2000000}"
# export ORDO_SCHEDULER_ENABLED ORDO_SCHED_MAX_FANOUT ORDO_SCHED_LEASE_TTL ORDO_SCHED_RUN_TIMEOUT_SEC ORDO_SCHED_MAX_RETRIES ORDO_SCHED_BUDGET_MAX_TOKENS

# Approval-safe actions and traces (#812, docs/architecture/approvals.md,
# docs/architecture/tracing.md).
#
# Every external mutation launched through the approval bridge is granted by
# an operator, re-authorized immediately before execution and idempotent. The
# bridge never widens ORCH_EXTERNAL_PR_MUTATIONS: live mutation stays off
# until an operator scopes the gate AND names who may approve what. Defaults
# below are the safe ones; uncomment to enable one scoped action.
#
#   ORDO_APPROVAL_PRINCIPALS  allow-list "principal[=action|action],..." ("*" = any
#                             principal); empty => the gate scope decides
#   ORDO_POLICY_VERSION       pin the policy version approvals are tied to; empty =>
#                             computed from the gate configuration (any policy
#                             edit refuses grants and executions made under the old one)
#   ORDO_APPROVAL_DEFAULT_TTL seconds before a fresh approval expires (3600)
#   ORDO_OPERATOR             operator id used by grant/deny when no --by is given ($USER)
#   ORDO_TRACE_ENABLED        1|0 — spans under $(state_dir)/traces (ORDO_TRACE_DIR overrides)
#   ORDO_TRACE_REDACT_RE      extra regex masked in every span attribute
#
# : "${ORCH_EXTERNAL_PR_MUTATIONS:=pr_merge}"
# : "${ORDO_APPROVAL_PRINCIPALS:=eric=pr.merge}"
# : "${ORDO_POLICY_VERSION:=policy-2026-09-11}"
# : "${ORDO_APPROVAL_DEFAULT_TTL:=900}"
# export ORCH_EXTERNAL_PR_MUTATIONS ORDO_APPROVAL_PRINCIPALS ORDO_POLICY_VERSION ORDO_APPROVAL_DEFAULT_TTL
