#!/usr/bin/env bash
# tests/test_file_hotspots.sh — covers lib/file_hotspots.sh helpers and the
# scripts/dispatch_plan.sh --hotspots subcommand.
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
  lib/label_helpers.sh \
  lib/log_bounds.sh \
  lib/config_check.sh \
  lib/config_resolver.sh \
  lib/dispatch_plan_headers.sh \
  lib/dry_run.sh \
  lib/file_hotspots.sh \
  lib/github_identity.sh \
  lib/process_safety.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/dispatch_plan.sh"

# Unit tests for lib/file_hotspots.sh helpers.
# shellcheck disable=SC1091 # sourcing sanitized copy
source "$SANITIZED_ROOT/lib/file_hotspots.sh"

if ! file_hotspots_match_path "README.md"; then
  fail "default patterns should match README.md"
fi
if ! file_hotspots_match_path ".github/workflows/ci.yml"; then
  fail "default patterns should match .github/workflows/ci.yml"
fi
if file_hotspots_match_path "docs/install.md"; then
  fail "default patterns must not flag a leaf doc as a hotspot"
fi
if file_hotspots_match_path "src/main.go"; then
  fail "default patterns must not flag arbitrary source files"
fi

mapfile -t default_patterns < <(file_hotspots_default_patterns | awk 'NF')
case " ${default_patterns[*]} " in
  *" PRODUCT.md "*) ;;
  *) fail "PRODUCT.md is missing from default coordination surfaces" ;;
esac
case " ${default_patterns[*]} " in
  *" install.sh "*) ;;
  *) fail "install.sh is missing from default coordination surfaces" ;;
esac

# Override exercises: ORDO_FILE_HOTSPOT_PATTERNS replaces the defaults.
ORDO_FILE_HOTSPOT_PATTERNS=(only-this.md)
if file_hotspots_match_path "README.md"; then
  fail "ORDO_FILE_HOTSPOT_PATTERNS override did not replace defaults"
fi
if ! file_hotspots_match_path "only-this.md"; then
  fail "ORDO_FILE_HOTSPOT_PATTERNS override did not include the operator pattern"
fi
unset ORDO_FILE_HOTSPOT_PATTERNS

# Extras append to the defaults.
ORDO_FILE_HOTSPOT_EXTRA=(custom/central.sh)
if ! file_hotspots_match_path "README.md"; then
  fail "ORDO_FILE_HOTSPOT_EXTRA must not drop the defaults"
fi
if ! file_hotspots_match_path "custom/central.sh"; then
  fail "ORDO_FILE_HOTSPOT_EXTRA must add operator extras"
fi
unset ORDO_FILE_HOTSPOT_EXTRA

# Agent resolution heuristic.
ORDO_FILE_HOTSPOT_LOGIN_PREFIXES=("RBOKCLI")
agent=$(file_hotspots_pr_agent "RBOKCLIcodex" "type:docs,priority:P1")
[ "$agent" = "codex" ] || fail "agent resolution should strip RBOKCLI prefix (got: $agent)"
agent=$(file_hotspots_pr_agent "anyuser" "agent:planner,type:docs")
[ "$agent" = "planner" ] || fail "agent label should win over author (got: $agent)"
agent=$(file_hotspots_pr_agent "" "")
[ "$agent" = "unknown" ] || fail "missing inputs should resolve to unknown (got: $agent)"

# Classification matrix.
[ "$(file_hotspots_classify 1 1 0)" = "single_owner" ] || fail "1 PR should be single_owner"
[ "$(file_hotspots_classify 3 1 0)" = "single_owner" ] || fail "3 PRs but 1 agent stays single_owner"
[ "$(file_hotspots_classify 3 3 0)" = "blocker" ] || fail "3 PRs / 3 agents must be blocker"
[ "$(file_hotspots_classify 3 3 1)" = "accepted_risk" ] || fail "3 PRs / 3 agents with --accept-risk must be accepted_risk"

# End-to-end dispatch_plan.sh --hotspots.
cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="hotspot-test"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
ORDO_FILE_HOTSPOT_LOGIN_PREFIXES=("RBOKCLI")
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >> "${GH_MOCK_LOG:-/dev/null}"

case "$args" in
  *"pr list"*)
    cat <<'JSON'
[
  {"number":269,"title":"docs(258): architecture","url":"https://example.test/pull/269","headRefName":"docs/258-docs-architecture","updatedAt":"2026-05-08T08:50:00Z","author":{"login":"RBOKCLIcodex"},"labels":[{"name":"type:docs"}],"isDraft":true},
  {"number":270,"title":"docs(250): fleet runbook","url":"https://example.test/pull/270","headRefName":"docs/250-fleet-prep-runbook","updatedAt":"2026-05-08T09:05:00Z","author":{"login":"RBOKCLIclaude"},"labels":[{"name":"type:docs"}],"isDraft":true},
  {"number":272,"title":"docs(259): install/integration/usage","url":"https://example.test/pull/272","headRefName":"docs/259-install-integration-usage-guides","updatedAt":"2026-05-08T09:14:00Z","author":{"login":"RBOKCLIgemini"},"labels":[{"name":"type:docs"}],"isDraft":true},
  {"number":280,"title":"feat: leaf only","url":"https://example.test/pull/280","headRefName":"feat/leaf","updatedAt":"2026-05-08T09:20:00Z","author":{"login":"RBOKCLIcursor"},"labels":[{"name":"type:feat"}],"isDraft":false}
]
JSON
    ;;
  *"pr view 269"*"--json files"*)
    printf '%s\n' '{"files":[{"path":"README.md"},{"path":"PRODUCT.md"},{"path":"docs/architecture.md"}]}'
    ;;
  *"pr view 270"*"--json files"*)
    printf '%s\n' '{"files":[{"path":"README.md"},{"path":"docs/fleet/runbook.md"}]}'
    ;;
  *"pr view 272"*"--json files"*)
    printf '%s\n' '{"files":[{"path":"README.md"},{"path":"docs/install.md"},{"path":"docs/integration.md"},{"path":"docs/usage.md"}]}'
    ;;
  *"pr view 280"*"--json files"*)
    printf '%s\n' '{"files":[{"path":"src/feature.go"},{"path":"src/feature_test.go"}]}'
    ;;
  *)
    printf '%s\n' '[]'
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

cat > "$TEST_TMP/bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/sha256sum "$@"
EOF
chmod +x "$TEST_TMP/bin/sha256sum"

mkdir -p "$TEST_TMP/state/orch-state"
mkdir -p "$TEST_TMP/log"

run_dispatch_plan() {
  PATH="$TEST_TMP/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  ORCH_LOG_DIR="$TEST_TMP/log" \
  ORCH_STATE_BASE="$TEST_TMP/state/orch-state" \
  XDG_DATA_HOME="$TEST_TMP/state" \
  GH_MOCK_LOG="$TEST_TMP/gh.log" \
  ORCH_GITHUB_IDENTITY_GUARD=0 \
  ORCH_VALIDATOR_FORK_PREFLIGHT=0 \
    bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" "$@"
}

# TSV: README.md must be classified blocker; agents must list codex,claude,gemini.
tsv_out=$(run_dispatch_plan --hotspots --tsv)
if ! grep -qP '^README\.md\t3\t' <<< "$tsv_out"; then
  printf '%s\n' "$tsv_out" >&2
  fail "README.md should appear with pr_count=3"
fi
if ! grep -qE 'README\.md\s+3\s+#269,#270,#272' <<< "$tsv_out"; then
  printf '%s\n' "$tsv_out" >&2
  fail "README.md row should list PRs in order #269,#270,#272"
fi
if ! grep -qE 'README\.md\s+3\s+#269,#270,#272\s+codex,claude,gemini\s+blocker' <<< "$tsv_out"; then
  printf '%s\n' "$tsv_out" >&2
  fail "README.md should be classified blocker with codex,claude,gemini"
fi
if ! grep -qE 'PRODUCT\.md\s+1\s+#269\s+codex\s+single_owner' <<< "$tsv_out"; then
  printf '%s\n' "$tsv_out" >&2
  fail "PRODUCT.md should appear as single_owner with one PR"
fi
if grep -qE '^docs/install\.md\s' <<< "$tsv_out"; then
  printf '%s\n' "$tsv_out" >&2
  fail "leaf docs (docs/install.md) must not be flagged as a hotspot"
fi
if grep -qE '^src/feature\.go\s' <<< "$tsv_out"; then
  printf '%s\n' "$tsv_out" >&2
  fail "leaf source files must not appear in the hotspot matrix"
fi

# JSON: same data, machine-readable shape.
json_out=$(run_dispatch_plan --hotspots --json)
readme_classification=$(printf '%s' "$json_out" | jq -r '.[] | select(.hotspot == "README.md") | .classification')
[ "$readme_classification" = "blocker" ] || fail "json README.md classification must be blocker (got: $readme_classification)"
readme_pr_count=$(printf '%s' "$json_out" | jq -r '.[] | select(.hotspot == "README.md") | .pr_count')
[ "$readme_pr_count" = "3" ] || fail "json README.md pr_count must be 3 (got: $readme_pr_count)"
readme_suggested=$(printf '%s' "$json_out" | jq -r '.[] | select(.hotspot == "README.md") | .suggested_order | join(",")')
[ "$readme_suggested" = "#269,#270,#272" ] || fail "json README.md suggested_order must be ascending by updatedAt (got: $readme_suggested)"

# --accept-risk drops the blocker to accepted_risk.
accepted_out=$(run_dispatch_plan --hotspots --accept-risk README.md --json)
readme_accepted_class=$(printf '%s' "$accepted_out" | jq -r '.[] | select(.hotspot == "README.md") | .classification')
[ "$readme_accepted_class" = "accepted_risk" ] || fail "--accept-risk README.md must move classification to accepted_risk (got: $readme_accepted_class)"
readme_accepted_flag=$(printf '%s' "$accepted_out" | jq -r '.[] | select(.hotspot == "README.md") | .accepted_risk')
[ "$readme_accepted_flag" = "true" ] || fail "--accept-risk README.md must set accepted_risk=true (got: $readme_accepted_flag)"

# --refuse-on-blocker exits non-zero when at least one blocker remains.
set +e
run_dispatch_plan --hotspots --tsv --refuse-on-blocker >/dev/null
refuse_rc=$?
set -e
if [ "$refuse_rc" -eq 0 ]; then
  fail "--refuse-on-blocker must exit non-zero when README.md is a blocker (got rc=$refuse_rc)"
fi

# --refuse-on-blocker must succeed once the only blocker is accepted.
set +e
run_dispatch_plan --hotspots --tsv --accept-risk README.md --refuse-on-blocker >/dev/null
accepted_rc=$?
set -e
if [ "$accepted_rc" -ne 0 ]; then
  fail "--refuse-on-blocker should pass once the blocker is accepted (got rc=$accepted_rc)"
fi

printf 'ok - test_file_hotspots\n'
