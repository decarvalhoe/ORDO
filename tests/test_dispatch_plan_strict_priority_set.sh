#!/usr/bin/env bash
# tests/test_dispatch_plan_strict_priority_set.sh -- coverage for issue #266.
#
# The strict priority-set mode must filter the queue to the allowlist
# regardless of readiness, so a ready older ticket cannot leak into the
# dispatch candidates of an operator-scoped wave. Output keeps the allowlist
# rows (so blocked/atomize reasons remain visible) and a per-ticket status
# summary is emitted on stderr.
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
  lib/dry_run.sh \
  lib/github_identity.sh \
  lib/process_safety.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/dispatch_plan.sh"

cat > "$TEST_TMP/config.sh" <<EOF
PROJECT="strict-priority-set-test"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

# Fixture sketch:
#   #10 priority:P1 -> ready (older, not in operator's strict allowlist)
#   #11 priority:P0 -> blocked (`Blocked by: #99`)
#   #12 size:xl with checklist -> atomize
#   #99 -> open dependency for #11
#   #237 priority:P1 -> ready (older "leaky" sibling that should NOT appear in
#        a strict wave whose allowlist is {249,250,251})
#   #249 EPIC priority:P1 -> atomize
#   #250 priority:P1 -> ready (only ready ticket inside the allowlist)
#   #251 priority:P1 -> blocked (`Blocked by: #99`)
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >> "${GH_MOCK_LOG:-/dev/null}"

if [[ "$args" == *"issue list"* && "$args" == *"ORDO-ATOMIZE"* ]]; then
  printf '%s\n' '[]'
  exit 0
fi

case "$args" in
  *"pr list"* )
    printf '%s\n' '[]'
    ;;
  *"issue list"* )
    cat <<'JSON'
[
  {"number":10,"title":"Frontend routing fix","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Ready issue (older sibling)","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/10"},
  {"number":11,"title":"Backend blocked work","labels":[{"name":"priority:P0"}],"assignees":[],"body":"Blocked by: #99","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/11"},
  {"number":12,"title":"Large parent feature","labels":[{"name":"size:xl"}],"assignees":[],"body":"Parent scope stays here\n\n- [ ] child one\n- [ ] child two\n- [ ] child three","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/12"},
  {"number":99,"title":"Dependency","labels":[],"assignees":[],"body":"","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/99"},
  {"number":237,"title":"Older Six Sigma sibling","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Older ready sibling that must not leak into a strict-mode wave","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/237"},
  {"number":249,"title":"EPIC: nuclear umbrella","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Umbrella epic with sibling pack","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/249"},
  {"number":250,"title":"docs: child of #249","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Parent epic: #249","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/250"},
  {"number":251,"title":"docs: blocked child of #249","labels":[{"name":"priority:P1"}],"assignees":[],"body":"Parent epic: #249\n\nBlocked by: #99","updatedAt":"2026-05-06T00:00:00Z","url":"https://example.test/251"}
]
JSON
    ;;
  *"issue view 10"* )    printf '%s\n' '{"number":10,"state":"OPEN","assignees":[],"title":"Frontend routing fix"}' ;;
  *"issue view 11"* )    printf '%s\n' '{"number":11,"state":"OPEN","assignees":[],"title":"Backend blocked work"}' ;;
  *"issue view 12"* )    printf '%s\n' '{"number":12,"state":"OPEN","assignees":[],"title":"Large parent feature"}' ;;
  *"issue view 99"* )    printf '%s\n' '{"state":"OPEN"}' ;;
  *"issue view 237"* )   printf '%s\n' '{"number":237,"state":"OPEN","assignees":[],"title":"Older Six Sigma sibling"}' ;;
  *"issue view 249"* )   printf '%s\n' '{"number":249,"state":"OPEN","assignees":[],"title":"EPIC: nuclear umbrella"}' ;;
  *"issue view 250"* )   printf '%s\n' '{"number":250,"state":"OPEN","assignees":[],"title":"docs: child of #249"}' ;;
  *"issue view 251"* )   printf '%s\n' '{"number":251,"state":"OPEN","assignees":[],"title":"docs: blocked child of #249"}' ;;
  *"issue view"* )       exit 1 ;;
  *"pr view"* )          exit 1 ;;
  *"issue create"* )     printf '%s\n' 'https://example.test/issues/9999' ;;
  *"issue comment"*|*"issue edit"* ) printf '%s\n' '{}' ;;
  * )                    printf '%s\n' '{}' ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

run_plan() {
  PATH="$TEST_TMP/bin:$PATH" \
  GH_MOCK_LOG="$TEST_TMP/logs/gh.log" \
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/dispatch_plan.sh" "$TEST_TMP/config.sh" "$@"
}

# ---- 1. Mixed allowlist (ready + atomize + blocked).
# The bug: in non-strict mode, allowlist 249/250/251 has #250 ready, so the
# refusal kicks in correctly. To reproduce the original leak we use an
# allowlist with no ready ticket: {249,251}. In legacy mode the planner
# leaves the queue unchanged so #237 leaks. In strict mode the planner must
# filter to {249,251} regardless.
strict_mixed_stderr="$TEST_TMP/logs/strict_mixed.stderr"
strict_mixed_json=$(
  run_plan --priority-set "249,251" --strict-priority-set --json 2>"$strict_mixed_stderr"
)

grep -q 'priority-set: strict mode — filtering to allowlist regardless of readiness' "$strict_mixed_stderr" \
  || fail "strict mode header missing on stderr: $(cat "$strict_mixed_stderr")"
grep -q 'strict-priority-set: allowlist statuses:' "$strict_mixed_stderr" \
  || fail "strict mode status summary missing on stderr: $(cat "$strict_mixed_stderr")"
grep -qE '#249=(atomize|ready)' "$strict_mixed_stderr" \
  || fail "strict mode summary missing #249 status: $(cat "$strict_mixed_stderr")"
grep -q '#251=blocked' "$strict_mixed_stderr" \
  || fail "strict mode summary missing #251 blocked status: $(cat "$strict_mixed_stderr")"

jq -e '
  (map(.issue) | sort) == [249,251]
  and (map(select(.issue == 251 and .status == "blocked")) | length == 1)
' <<< "$strict_mixed_json" >/dev/null \
  || fail "strict mixed allowlist must filter to {249,251} and keep #251=blocked: $strict_mixed_json"

# Older sibling #237 must not appear even though it is ready.
jq -e 'map(select(.issue == 237)) | length == 0' <<< "$strict_mixed_json" >/dev/null \
  || fail "strict mode must NOT leak the older ready sibling #237: $strict_mixed_json"

# ---- 2. Allowlist with one ready ticket: should still emit only allowlist.
strict_ready_stderr="$TEST_TMP/logs/strict_ready.stderr"
strict_ready_json=$(
  run_plan --priority-set "250" --strict-priority-set --json 2>"$strict_ready_stderr"
)

grep -q '#250=ready' "$strict_ready_stderr" \
  || fail "strict mode summary missing #250 ready status: $(cat "$strict_ready_stderr")"
jq -e '(map(.issue) | sort) == [250]' <<< "$strict_ready_json" >/dev/null \
  || fail "strict mode with single ready allowlist must emit only #250: $strict_ready_json"

# ---- 3. Allowlist with only blocked tickets: queue must stay scoped to the
# allowlist, status reflected, and #237 must stay out.
strict_blocked_stderr="$TEST_TMP/logs/strict_blocked.stderr"
strict_blocked_json=$(
  run_plan --priority-set "11,251" --strict-priority-set --json 2>"$strict_blocked_stderr"
)

grep -q '#11=blocked' "$strict_blocked_stderr" \
  || fail "strict blocked allowlist summary missing #11 blocked: $(cat "$strict_blocked_stderr")"
grep -q '#251=blocked' "$strict_blocked_stderr" \
  || fail "strict blocked allowlist summary missing #251 blocked: $(cat "$strict_blocked_stderr")"
jq -e '
  (map(.issue) | sort) == [11,251]
  and (map(select(.status == "blocked")) | length == 2)
' <<< "$strict_blocked_json" >/dev/null \
  || fail "strict blocked allowlist must keep both #11 and #251 as blocked rows: $strict_blocked_json"
jq -e 'map(select(.issue == 237 or .issue == 250 or .issue == 10)) | length == 0' <<< "$strict_blocked_json" >/dev/null \
  || fail "strict blocked allowlist must not leak any non-allowlisted issue: $strict_blocked_json"

# ---- 4. Allowlist with only atomize tickets (e.g. parent epic + xl parent).
strict_atomize_stderr="$TEST_TMP/logs/strict_atomize.stderr"
strict_atomize_json=$(
  run_plan --priority-set "12,249" --strict-priority-set --json 2>"$strict_atomize_stderr"
)

jq -e '
  (map(.issue) | sort) == [12,249]
  and (map(select(.status == "atomize")) | length >= 1)
' <<< "$strict_atomize_json" >/dev/null \
  || fail "strict atomize allowlist must keep #12 and #249 with atomize signals: $strict_atomize_json"
grep -qE '#12=atomize' "$strict_atomize_stderr" \
  || fail "strict atomize summary missing #12 atomize status: $(cat "$strict_atomize_stderr")"

# ---- 5. Empty allowlist (no allowlisted ticket exists in the repo).
strict_empty_stderr="$TEST_TMP/logs/strict_empty.stderr"
strict_empty_json=$(
  run_plan --priority-set "9001,9002" --strict-priority-set --json 2>"$strict_empty_stderr"
)

grep -q 'priority-set: strict mode — filtering to allowlist regardless of readiness' "$strict_empty_stderr" \
  || fail "strict empty allowlist must still print the strict-mode header: $(cat "$strict_empty_stderr")"
grep -q 'strict-priority-set: allowlist statuses: (no allowlisted tickets are open in this repo)' "$strict_empty_stderr" \
  || fail "strict empty allowlist must print the empty-summary line: $(cat "$strict_empty_stderr")"
jq -e 'length == 0' <<< "$strict_empty_json" >/dev/null \
  || fail "strict empty allowlist must produce an empty queue, not leak older work: $strict_empty_json"

# ---- 6. Strict mode honors --ready-only: only the allowlisted ready row ships.
strict_ready_only_stderr="$TEST_TMP/logs/strict_ready_only.stderr"
strict_ready_only_json=$(
  run_plan --priority-set "249,250,251" --strict-priority-set --ready-only --json 2>"$strict_ready_only_stderr"
)

jq -e '(map(.issue) | sort) == [250]' <<< "$strict_ready_only_json" >/dev/null \
  || fail "strict + --ready-only must emit only the allowlisted ready ticket #250: $strict_ready_only_json"

# ---- 7. Backward compatibility: legacy --priority-set 11,42 still leaves
# the queue unchanged (the bug behavior, kept on purpose for compat) and
# now points the operator at --strict-priority-set as the remediation.
legacy_idle_stderr="$TEST_TMP/logs/legacy_idle.stderr"
legacy_idle_json=$(
  run_plan --priority-set "11,42" --json 2>"$legacy_idle_stderr"
)

grep -q 'priority-set: no allowlisted ready tickets' "$legacy_idle_stderr" \
  || fail "legacy mode must keep the historical idle banner: $(cat "$legacy_idle_stderr")"
grep -q 'use --strict-priority-set' "$legacy_idle_stderr" \
  || fail "legacy idle banner must point operators at --strict-priority-set: $(cat "$legacy_idle_stderr")"
jq -e 'any(.[]; .issue == 237) and any(.[]; .issue == 250)' <<< "$legacy_idle_json" >/dev/null \
  || fail "legacy mode preserves the older queue (the bug) so opt-in remains required: $legacy_idle_json"

# ---- 8. Argument validation: strict without --priority-set fails fast.
if run_plan --strict-priority-set --json >/dev/null 2>"$TEST_TMP/logs/strict_arg_missing.stderr"; then
  fail "--strict-priority-set without --priority-set should exit non-zero"
fi
grep -q -- '--strict-priority-set requires --priority-set' "$TEST_TMP/logs/strict_arg_missing.stderr" \
  || fail "missing-priority-set message not emitted: $(cat "$TEST_TMP/logs/strict_arg_missing.stderr")"

# ---- 9. Argument validation: strict + override is rejected.
if run_plan --priority-set "250" --strict-priority-set --priority-set-override --json >/dev/null 2>"$TEST_TMP/logs/strict_arg_conflict.stderr"; then
  fail "--strict-priority-set with --priority-set-override should exit non-zero"
fi
grep -q -- '--strict-priority-set and --priority-set-override are mutually exclusive' "$TEST_TMP/logs/strict_arg_conflict.stderr" \
  || fail "mutually-exclusive message not emitted: $(cat "$TEST_TMP/logs/strict_arg_conflict.stderr")"

printf 'ok - dispatch_plan strict priority-set filters allowlist regardless of readiness (#266)\n'
