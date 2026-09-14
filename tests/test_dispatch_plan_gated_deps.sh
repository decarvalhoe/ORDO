#!/usr/bin/env bash
# Coverage for #666 — first-class gated issue dependencies as dispatch policy.
# Mirrors the WordPress V2 consolidation case (issue #603 must wait for
# #642/#643/#644/#646) and exercises both the unit helpers in
# lib/portfolio_config.sh and the wiring in scripts/dispatch_plan.sh.
#
# Each end-to-end dispatch_plan invocation is sourced inline so the test
# stays inside the timeout budget on hosts with elevated fork latency.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/bin" "$TEST_TMP/logs"

for rel in \
  scripts/dispatch_plan.sh \
  lib/audit_log.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dispatch_plan_headers.sh \
  lib/dry_run.sh \
  lib/github_identity.sh \
  lib/label_helpers.sh \
  lib/portfolio_config.sh \
  lib/process_safety.sh \
  lib/external_mutation_gate.sh \
  lib/ordo_contracts.sh \
  lib/ordo_provider_adapter.sh \
  lib/ordo_provider_adapter_github.sh \
  lib/ordo_provider_adapter_fake.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/dispatch_plan.sh"

# ---------------------------------------------------------------------------
# Unit coverage: portfolio_config.sh helpers parse declarations and waivers
# without requiring any portfolio scaffolding to be loaded.
# ---------------------------------------------------------------------------
(
  set -euo pipefail
  # shellcheck disable=SC1090
  source "$SANITIZED_ROOT/lib/portfolio_config.sh"

  PROJECT_GATED_ISSUE_DEPENDENCIES=(
    "603=642,643,644,646"
    "#700|#701, #702"
    "not-a-number=999"
  )

  out=$(portfolio_gated_dependencies_for_issue 603)
  [[ "$out" == "642,643,644,646" ]] || {
    printf 'gated lookup for #603 returned %q\n' "$out" >&2
    exit 1
  }
  out=$(portfolio_gated_dependencies_for_issue "#700")
  [[ "$out" == "701,702" ]] || {
    printf 'gated lookup for #700 (alt format) returned %q\n' "$out" >&2
    exit 1
  }
  out=$(portfolio_gated_dependencies_for_issue 999)
  [[ -z "$out" ]] || {
    printf 'gated lookup for #999 should be empty, got %q\n' "$out" >&2
    exit 1
  }

  PROJECT_GATED_ISSUE_WAIVERS=(
    "603=642,646"
    "#800"
  )
  portfolio_gated_dependency_waived 603 642 || {
    printf 'per-dep waiver for #603/#642 should match\n' >&2; exit 1
  }
  portfolio_gated_dependency_waived 603 644 && {
    printf 'per-dep waiver for #603/#644 must NOT match\n' >&2; exit 1
  }
  portfolio_gated_dependency_waived 603 && {
    printf 'blanket waiver for #603 must NOT match (only per-dep configured)\n' >&2; exit 1
  }
  portfolio_gated_dependency_waived 800 || {
    printf 'blanket waiver for #800 should match\n' >&2; exit 1
  }
  portfolio_gated_dependency_waived 800 12345 || {
    printf 'blanket waiver should also cover any specific dep\n' >&2; exit 1
  }
  exit 0
) || fail "portfolio_config gated-dep helpers failed unit coverage"

# ---------------------------------------------------------------------------
# End-to-end fixtures: dispatch_plan honours PROJECT_GATED_ISSUE_DEPENDENCIES,
# surfaces the gating reason in TSV + JSON, hides gated issues from
# --ready-only, and re-admits them when waived.
#
# The mock gh server treats #642/#644 as still-open (they appear in the
# `issue list`) while #643/#646 are resolved (returned as CLOSED via
# `issue view`).
# ---------------------------------------------------------------------------
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"label list"*) printf '%s\n' '[]' ;;
  *"pr list"*) printf '%s\n' '[]' ;;
  *"issue list"*)
    cat <<'JSON'
[
  {"number":603,"title":"WordPress V2 consolidation rollout","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Production migration that gathers the V2 consolidation deliverables.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/603"},
  {"number":642,"title":"V2 prereq A","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Prereq still in flight.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/642"},
  {"number":644,"title":"V2 prereq C","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Prereq still in flight.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/644"},
  {"number":700,"title":"Unrelated ready work","labels":[{"name":"priority:P2"}],"assignees":[],"body":"Plain ready issue with no gating.","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/700"}
]
JSON
    ;;
  *"issue view 643"*) printf '%s\n' '{"state":"CLOSED"}' ;;
  *"issue view 646"*) printf '%s\n' '{"state":"CLOSED"}' ;;
  *"issue view"*)
    if [[ "$*" == *comments* ]]; then
      printf '%s\n' '{"comments":[]}'
    else
      printf '%s\n' '{"state":"OPEN"}'
    fi
    ;;
  *) printf '%s\n' '{}' ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

run_dispatch_plan() {
  local cfg=${1:?}
  shift
  PATH="$TEST_TMP/bin:$PATH" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$cfg" "$@"
}

# Base config: WordPress V2 consolidation gate. No waivers yet.
cat > "$TEST_TMP/base.config.sh" <<EOF
PROJECT="gated-deps-test"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"

# WordPress V2 consolidation gate (issue #666): #603 must wait for
# #642,#643,#644,#646 to be closed before dispatch_plan classifies it as
# ready. Encoded as repo-owned config instead of a manual blocked label.
PROJECT_GATED_ISSUE_DEPENDENCIES=(
  "603=642,643,644,646"
)
EOF

# Run #1 — JSON: full classification + waiver-free blockers + signals.
json_output=$(run_dispatch_plan "$TEST_TMP/base.config.sh" --json)
jq -e '
  def row($n): map(select(.issue == $n))[0];
  (row(603).status == "blocked")
    and (row(603).gated_deps == [642,643,644,646])
    and ((row(603).gated_by | sort) == [642,644])
    and (row(603).gated_waived == false)
    and (row(603).blockers | index("gated:#642:OPEN"))
    and (row(603).blockers | index("gated:#644:OPEN"))
    and ((row(603).blockers | map(select(test("^gated:#643"))) | length) == 0)
    and ((row(603).blockers | map(select(test("^gated:#646"))) | length) == 0)
    and (row(603).signals | index("has-gated-deps"))
    and (row(603).signals | index("gated-by-policy"))
    and (row(603).signals | index("gated-by:#642"))
    and (row(603).signals | index("gated-by:#644"))
    and (row(700).status == "ready")
    and ((row(700).gated_deps // []) | length == 0)
    and ((row(700).gated_by // []) | length == 0)
    and (((row(700).signals // []) | index("has-gated-deps")) == null)
' <<< "$json_output" >/dev/null \
  || fail "JSON output missing gated-dep classification: $json_output"

# Run #2 — TSV: human-readable blockers cell + signals (AC 3, human form).
tsv_output=$(run_dispatch_plan "$TEST_TMP/base.config.sh" --tsv)
[[ "$tsv_output" == *$'603\tP1\t300\tblocked'* ]] || fail "TSV missing blocked status for #603: $tsv_output"
[[ "$tsv_output" == *'gated:#642:OPEN'* ]] || fail "TSV blockers cell missing gated:#642:OPEN: $tsv_output"
[[ "$tsv_output" == *'gated:#644:OPEN'* ]] || fail "TSV blockers cell missing gated:#644:OPEN: $tsv_output"
[[ "$tsv_output" != *'gated:#643'* ]] || fail "TSV must not list closed dep #643 as a gated blocker: $tsv_output"
[[ "$tsv_output" != *'gated:#646'* ]] || fail "TSV must not list closed dep #646 as a gated blocker: $tsv_output"
[[ "$tsv_output" == *'gated-by:#642'* ]] || fail "TSV signals missing gated-by:#642: $tsv_output"

# Run #3 — --ready-only: gated #603 must be excluded without manual labels.
ready_output=$(run_dispatch_plan "$TEST_TMP/base.config.sh" --ready-only --json)
jq -e '(map(.issue) | sort) == [642,644,700]' <<< "$ready_output" >/dev/null \
  || fail "--ready-only should exclude gated #603 without a manual label: $ready_output"

# Per-dep waiver: dropping the still-open deps from the gate should leave
# only the already-closed deps, which produce no blockers, so #603 becomes
# ready again. Confirms both readiness and the waived-dep signals (AC 1
# "or waived").
cat > "$TEST_TMP/waived.config.sh" <<EOF
. "$TEST_TMP/base.config.sh"
PROJECT_GATED_ISSUE_WAIVERS=(
  "603=642,644"
)
EOF
waived_output=$(run_dispatch_plan "$TEST_TMP/waived.config.sh" --json)
jq -e '
  def row($n): map(select(.issue == $n))[0];
  (row(603).status == "ready")
    and ((row(603).gated_by // []) | length == 0)
    and ((row(603).gated_waivers | sort) == [642,644])
    and (row(603).signals | index("has-gated-deps"))
    and (row(603).signals | index("gated-dep-waived:#642"))
    and (row(603).signals | index("gated-dep-waived:#644"))
    and (((row(603).signals // []) | index("gated-by-policy")) == null)
' <<< "$waived_output" >/dev/null \
  || fail "per-dep waiver should remove #603 blockers and surface waived signals: $waived_output"

printf 'ok - dispatch_plan encodes gated issue dependencies as first-class policy (#666)\n'
