#!/usr/bin/env bash
# tests/test_runbook_freshness.sh — flag stale runbooks where the parent
# issue is closed but the runbook lacks a closure marker. Implements
# issue #427 (parent epic #257).
#
# What this asserts:
#   For each docs/runbooks/issue-<N>-<slug>.md, query GitHub for the
#   parent issue's state via `gh`. If the issue is CLOSED, the runbook
#   must contain at least one of three closure markers:
#     - a "Closed:" line (e.g. "Closed: 2026-05-08")
#     - a `state: closed` frontmatter line
#     - a "## Resolution" heading
#
# Output:
#   A TSV stream of (runbook, issue_state, freshness_status) on stdout
#   so dashboards can consume the structured result. The final line is
#   "ok - test_runbook_freshness ..." on success and "not ok - ..."
#   when at least one stale runbook is found.
#
# CI-friendly skip:
#   When `gh` is not on PATH, or GH_REPO is unset, the test prints a
#   "skipped: no gh / no GH_REPO" line and exits 0. This keeps CI green
#   in offline mode without losing detection where GH_REPO is wired up.
#
# Exit codes:
#   0  — every closed-issue runbook has a closure marker, OR the test
#        skipped because gh / GH_REPO were unavailable.
#   1  — at least one stale runbook; the gap list is printed to stderr.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNBOOK_DIR="$ROOT/docs/runbooks"

# A short timeout keeps the test bounded inside the shell-tests harness
# (which itself wraps each test in `timeout $ORCH_SHELL_TEST_TIMEOUT_SEC`).
GH_TIMEOUT_SEC="${ORCH_RUNBOOK_FRESHNESS_GH_TIMEOUT_SEC:-10}"

skip() {
  printf 'skipped: no gh / no GH_REPO (%s)\n' "$*"
  exit 0
}

if ! command -v gh >/dev/null 2>&1; then
  skip "gh not on PATH"
fi
if [ -z "${GH_REPO:-}" ]; then
  skip "GH_REPO env unset"
fi

if [ ! -d "$RUNBOOK_DIR" ]; then
  printf 'ok - test_runbook_freshness (no docs/runbooks/ dir)\n'
  exit 0
fi

mapfile -t runbooks < <(
  find "$RUNBOOK_DIR" -maxdepth 1 -mindepth 1 -type f -name 'issue-*-*.md' \
    | sort
)

if [ "${#runbooks[@]}" -eq 0 ]; then
  printf 'ok - test_runbook_freshness (no issue-*-*.md runbooks)\n'
  exit 0
fi

# Structured TSV stream — header first so dashboards can parse the column
# layout without prior knowledge of the script.
printf 'runbook\tissue_state\tfreshness_status\n'

stale=()
for runbook in "${runbooks[@]}"; do
  filename=$(basename "$runbook")
  if [[ "$filename" =~ ^issue-([0-9]+)- ]]; then
    issue_num="${BASH_REMATCH[1]}"
  else
    # Defensive — find pattern already filters, but a non-numeric infix
    # would otherwise break the gh call.
    continue
  fi

  rel="${runbook#"$ROOT"/}"

  # Strict-timeout query. A failure (network, auth, missing issue, hung
  # gh) produces an empty `state`; we record it as UNKNOWN and skip the
  # freshness assertion so transient infra problems do not turn into
  # stale-marker false positives.
  state=$(
    timeout "$GH_TIMEOUT_SEC" \
      gh issue view "$issue_num" --repo "$GH_REPO" --json state --jq '.state' \
      2>/dev/null || true
  )

  if [ -z "$state" ]; then
    printf '%s\tUNKNOWN\tskipped\n' "$rel"
    continue
  fi

  case "$state" in
    CLOSED)
      if grep -qE '^Closed:|^state: closed$|^## Resolution' "$runbook"; then
        printf '%s\t%s\tfresh\n' "$rel" "$state"
      else
        printf '%s\t%s\tstale\n' "$rel" "$state"
        stale+=("$rel (issue #$issue_num is CLOSED; no closure marker)")
      fi
      ;;
    OPEN)
      printf '%s\t%s\tactive\n' "$rel" "$state"
      ;;
    *)
      printf '%s\t%s\tunknown\n' "$rel" "$state"
      ;;
  esac
done

if [ "${#stale[@]}" -gt 0 ]; then
  printf 'not ok - test_runbook_freshness (%d stale runbook(s))\n' \
    "${#stale[@]}" >&2
  for s in "${stale[@]}"; do
    printf '  - %s\n' "$s" >&2
  done
  # shellcheck disable=SC2016  # Backticked tokens are Markdown literals printed verbatim, not shell expressions.
  printf '\nAdd one of: a `Closed: <date>` line, a `state: closed` frontmatter line, or a `## Resolution` heading to each stale runbook.\n' >&2
  exit 1
fi

printf 'ok - test_runbook_freshness (%d runbook(s) checked)\n' \
  "${#runbooks[@]}"
