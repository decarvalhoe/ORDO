#!/usr/bin/env bash
# Issue #721: portfolio_dispatch.sh produces a unified plan across
# configured projects, caps per-project rows via MAX_CONCURRENT_DISPATCHES
# (per project config or PORTFOLIO_MAX_CONCURRENT_DISPATCHES override),
# excludes locally-assigned and conflict-with rows, and surfaces
# brief_missing entries without dispatching them. The script invokes
# dispatch_plan once per project and assembles a matrix that
# dispatch_wave can consume under a single wave id.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/logs" "$TEST_TMP/wave-state"

# Stub dispatch_plan: each invocation returns a fixed JSON payload based
# on which config it was called with. Stub dispatch_wave: just record
# the invocation so we can verify the wave id and matrix path get
# forwarded.
cat > "$TEST_TMP/bin/dispatch_plan_stub.sh" <<'EOF'
#!/usr/bin/env bash
# Stub: emit a fixed JSON payload per project config. The second
# positional arg may be `--ready-only` and the third `--json` (we ignore
# both and always return the JSON path matched on the project basename).
project_cfg=$1
project_name=$(basename "$project_cfg" .config.sh)
fixture_file="${ORCH_TEST_PLAN_FIXTURE_DIR:-/tmp}/${project_name}.json"
if [ -f "$fixture_file" ]; then
  cat "$fixture_file"
else
  printf '[]\n'
fi
EOF
chmod +x "$TEST_TMP/bin/dispatch_plan_stub.sh"

cat > "$TEST_TMP/bin/dispatch_wave_stub.sh" <<'EOF'
#!/usr/bin/env bash
# Stub: record the wave invocation arguments so the test can assert
# that --apply hands off the wave id + matrix path correctly.
printf 'wave_id=%s\nmatrix=%s\nrest=%s\n' "$1" "$2" "${*:3}" \
  > "$ORCH_TEST_WAVE_RECORD"
EOF
chmod +x "$TEST_TMP/bin/dispatch_wave_stub.sh"

export ORCH_PORTFOLIO_DISPATCH_PLAN_BIN="$TEST_TMP/bin/dispatch_plan_stub.sh"
export ORCH_PORTFOLIO_DISPATCH_WAVE_BIN="$TEST_TMP/bin/dispatch_wave_stub.sh"
export ORCH_TEST_PLAN_FIXTURE_DIR="$TEST_TMP/fixtures"
export ORCH_TEST_WAVE_RECORD="$TEST_TMP/wave-state/wave_invocation.txt"
mkdir -p "$ORCH_TEST_PLAN_FIXTURE_DIR"

# Project configs. project-a sets its own MAX_CONCURRENT_DISPATCHES,
# project-b inherits the portfolio-level override, project-c gets the
# fallback default. Each config also pins state so dispatch_plan / lib
# helpers stay isolated per project.
for project in project-a project-b project-c; do
  cat > "$TEST_TMP/${project}.config.sh" <<EOF
PROJECT="$project"
GH_REPO="example/$project"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
EOF
  case "$project" in
    project-a)
      printf 'MAX_CONCURRENT_DISPATCHES=2\n' >> "$TEST_TMP/${project}.config.sh"
      ;;
  esac
done

# Portfolio config: lists three projects, overrides project-b to cap at
# 1 concurrent dispatch, and leaves project-c at the default fallback.
cat > "$TEST_TMP/portfolio.config.sh" <<EOF
PORTFOLIO_PROJECTS=(
  "project-a|$TEST_TMP/project-a.config.sh"
  "project-b|$TEST_TMP/project-b.config.sh"
  "project-c|$TEST_TMP/project-c.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "project-a=100"
  "project-b=80"
  "project-c=60"
)
PORTFOLIO_MAX_CONCURRENT_DISPATCHES=(
  "project-b=1"
)
PORTFOLIO_DEFAULT_MAX_CONCURRENT_DISPATCHES=1
EOF

# Fixtures for each project's dispatch_plan stub. project-a has three
# ready candidates (will be capped to 2). project-b has two ready
# candidates (capped to 1). project-c has one ready candidate and one
# in conflict_with (must be filtered out — the latter should NOT enter
# the matrix even though the project has spare capacity). project-c
# also has a locally-assigned ready row, which must be excluded.
cat > "$ORCH_TEST_PLAN_FIXTURE_DIR/project-a.json" <<'JSON'
[
  {"issue":1001,"status":"ready","agent_hint":"claude","signals":["ready","unassigned"],"local_assigned":false,"conflict_with":[]},
  {"issue":1002,"status":"ready","agent_hint":"claude","signals":["ready","unassigned"],"local_assigned":false,"conflict_with":[]},
  {"issue":1003,"status":"ready","agent_hint":"claude","signals":["ready","unassigned"],"local_assigned":false,"conflict_with":[]}
]
JSON

cat > "$ORCH_TEST_PLAN_FIXTURE_DIR/project-b.json" <<'JSON'
[
  {"issue":2001,"status":"ready","agent_hint":"claude","signals":["ready"],"local_assigned":false,"conflict_with":[]},
  {"issue":2002,"status":"ready","agent_hint":"claude","signals":["ready"],"local_assigned":false,"conflict_with":[]}
]
JSON

cat > "$ORCH_TEST_PLAN_FIXTURE_DIR/project-c.json" <<'JSON'
[
  {"issue":3001,"status":"ready","agent_hint":"claude","signals":["ready"],"local_assigned":false,"conflict_with":[]},
  {"issue":3002,"status":"ready","agent_hint":"claude","signals":["ready","scope-claim-conflict","conflict-with:#3001"],"local_assigned":false,"conflict_with":[3001]},
  {"issue":3003,"status":"ready","agent_hint":"claude","signals":["ready","local-assigned"],"local_assigned":true,"conflict_with":[]}
]
JSON

# Pre-stage matching brief files so the planner counts the rows as
# ready (it surfaces a brief_missing status when no /tmp brief is
# present). Only stage rows we expect to dispatch — missing briefs
# must be surfaced separately.
export ORCH_DISPATCH_STAGING_DIR="$TEST_TMP/stage"
mkdir -p "$ORCH_DISPATCH_STAGING_DIR"
for ticket in 1001 1002 2001 3001; do
  touch "$ORCH_DISPATCH_STAGING_DIR/dispatch-claude-${ticket}.md"
done
# Intentionally leave 1003's brief missing — even though project-a's
# cap is 2, the third row would be excluded anyway, so this confirms
# the cap drives the truncation, not the missing brief.

matrix_out="$TEST_TMP/portfolio.matrix.tsv"

plan_output=$(
  bash "$ROOT/scripts/portfolio_dispatch.sh" \
    "$TEST_TMP/portfolio.config.sh" wave-721 \
    --matrix-out "$matrix_out" --json
)

# 1) JSON plan structure: each configured project must appear with the
#    resolved max_concurrent and selected count.
jq -e '
  (.wave_id == "wave-721")
  and (.projects["project-a"].max_concurrent == 2)
  and (.projects["project-a"].selected == 2)
  and (.projects["project-b"].max_concurrent == 1)
  and (.projects["project-b"].selected == 1)
  and (.projects["project-c"].max_concurrent == 1)
  and (.projects["project-c"].selected == 1)
' <<<"$plan_output" >/dev/null \
  || fail "portfolio plan caps/selected counts wrong: $plan_output"

# 2) Matrix file: one row per dispatched ticket, in TSV form expected
#    by dispatch_wave. project-a contributes 1001+1002, project-b 2001,
#    project-c 3001 (3002 dropped by conflict_with, 3003 by
#    local_assigned). Comment / header lines must not count.
matrix_rows=$(grep -c '^[^#]' "$matrix_out" 2>/dev/null || printf '0')
[[ "$matrix_rows" == "4" ]] \
  || fail "expected 4 matrix rows, got $matrix_rows — $(cat "$matrix_out")"

for ticket in 1001 1002 2001 3001; do
  grep -qE "(^|	)$ticket(	|$)" "$matrix_out" \
    || fail "ticket $ticket missing from matrix: $(cat "$matrix_out")"
done
for ticket in 3002 3003 1003 2002; do
  if grep -qE "(^|	)$ticket(	|$)" "$matrix_out"; then
    fail "ticket $ticket should NOT be in matrix: $(cat "$matrix_out")"
  fi
done

# 3) --apply hands the wave id and matrix path to dispatch_wave under
#    a single wave id. The stub records what it was called with.
rm -f "$ORCH_TEST_WAVE_RECORD"
bash "$ROOT/scripts/portfolio_dispatch.sh" \
  "$TEST_TMP/portfolio.config.sh" wave-721-apply \
  --matrix-out "$matrix_out" --apply >/dev/null

[[ -s "$ORCH_TEST_WAVE_RECORD" ]] \
  || fail "dispatch_wave was not invoked under --apply"
grep -q '^wave_id=wave-721-apply$' "$ORCH_TEST_WAVE_RECORD" \
  || fail "wave id not forwarded: $(cat "$ORCH_TEST_WAVE_RECORD")"
grep -q "^matrix=${matrix_out}$" "$ORCH_TEST_WAVE_RECORD" \
  || fail "matrix path not forwarded: $(cat "$ORCH_TEST_WAVE_RECORD")"

# 4) --project filters portfolio_dispatch to a single project — useful
#    when an operator wants to dispatch one product without touching
#    siblings.
filtered_output=$(
  bash "$ROOT/scripts/portfolio_dispatch.sh" \
    "$TEST_TMP/portfolio.config.sh" wave-721-filter \
    --matrix-out "$matrix_out" --project project-b --json
)
jq -e '
  (.projects | keys | length == 1)
  and (.projects | has("project-b"))
  and (.projects["project-b"].selected == 1)
' <<<"$filtered_output" >/dev/null \
  || fail "--project filter did not constrain to project-b: $filtered_output"

# 5) Invalid wave id is rejected before any dispatch_plan call so a
#    malformed CI input cannot accidentally fan out work.
if bash "$ROOT/scripts/portfolio_dispatch.sh" \
    "$TEST_TMP/portfolio.config.sh" 'bad wave id' >/dev/null 2>&1; then
  fail "invalid wave id was not rejected"
fi

printf 'ok - portfolio_dispatch produces a capped unified plan and hands it to dispatch_wave under one wave id\n'
