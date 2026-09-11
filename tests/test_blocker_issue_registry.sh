#!/usr/bin/env bash
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

# shellcheck source=../lib/test_sanitize.sh disable=SC1091
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/blocker_issue_registry.sh

config="$TEST_TMP/project.config.sh"
cat > "$config" <<EOF
PROJECT="blocker-test"
DEFAULT_BRANCH="main"
GH_REPO="example/repo"
GH_CONFIG_DIR="$TEST_TMP/gh-config"
EOF

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/gh-out"
cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" >> "$GH_LOG"

body_file=""
issue_number=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --body-file)
      body_file=${2:?missing body file}
      shift 2
      ;;
    issue)
      shift
      case "${1:-}" in
        list)
          if [[ "${GH_SCENARIO:-none}" == "existing" ]]; then
            printf '[{"number":77,"state":"OPEN","url":"https://github.com/example/repo/issues/77","title":"[blocker][checks-missing] pr-42","body":"blocker-test:checks-missing:pr-42"}]\n'
          else
            printf '[]\n'
          fi
          exit 0
          ;;
        create)
          shift
          ;;
        comment)
          issue_number=${2:?missing issue number}
          shift 2
          ;;
        edit)
          issue_number=${2:?missing issue number}
          shift 2
          ;;
        close)
          issue_number=${2:?missing issue number}
          shift 2
          ;;
        reopen)
          issue_number=${2:?missing issue number}
          shift 2
          ;;
        *)
          printf 'unexpected issue subcommand: %s\n' "${1:-}" >&2
          exit 42
          ;;
      esac
      ;;
    *)
      shift
      ;;
  esac
done

if [[ -n "$body_file" ]]; then
  if grep -qxF 'create' "$GH_LOG"; then
    cp "$body_file" "$GH_OUT/create-body.md"
    printf 'https://github.com/example/repo/issues/88\n'
  else
    cp "$body_file" "$GH_OUT/comment-body.md"
    printf 'https://github.com/example/repo/issues/%s#issuecomment-1\n' "$issue_number"
  fi
fi
EOF
chmod +x "$TEST_TMP/bin/gh"

printf -v stable_key_line "Blocker-Key: \`%s\`" "blocker-test:checks-missing:pr-42"
printf -v profile_line "Profile: \`%s\`" "portfolio-standard"
printf -v command_line "Command: \`%s\`" "bash scripts/cycle.sh"
printf -v next_action_line "Next action: \`%s\`" "rerun required checks"
printf -v owner_line "Suggested owner: \`%s\`" "operator"
printf -v severity_line "Severity: \`%s\`" "P1"

run_registry() {
  # The issue mutations go through the provider adapter (#816): the gate
  # scopes must be authorised and the idempotency ledger must live under
  # the test's own state dir (never the operator's).
  GH_LOG="$TEST_TMP/gh-out/gh.log" \
  GH_OUT="$TEST_TMP/gh-out" \
  ORCH_STATE_BASE="$TEST_TMP/state" \
  ORCH_EXTERNAL_PR_MUTATIONS="${ORCH_EXTERNAL_PR_MUTATIONS:-issue_create,issue_comment,issue_labels,issue_close,issue_reopen}" \
  PATH="$TEST_TMP/bin:$PATH" \
    bash "$SANITIZED_ROOT/scripts/blocker_issue_registry.sh" "$config" "$@"
}

rm -f "$TEST_TMP/gh-out/"*
create_json=$(
  GH_SCENARIO=none run_registry report \
    --blocker-kind checks-missing \
    --resource pr-42 \
    --profile portfolio-standard \
    --command "bash scripts/cycle.sh" \
    --output-summary "required checks are missing for PR #42" \
    --artifact "/var/log/orch/realisons-wordpress.log" \
    --impacted-ref "PR #42" \
    --next-action "rerun required checks" \
    --owner operator \
    --severity P1 \
    --apply \
    --json
)
[[ "$(jq -r '.decision' <<< "$create_json")" == "created" ]] \
  || fail "first report should create an issue: $create_json"
[[ "$(jq -r '.dedupe_key' <<< "$create_json")" == "blocker-test:checks-missing:pr-42" ]] \
  || fail "created issue should report stable dedupe key: $create_json"
[[ "$(jq -r '.blocker_issue_url' <<< "$create_json")" == "https://github.com/example/repo/issues/88" ]] \
  || fail "created issue should expose status link: $create_json"
grep -qxF 'list' "$TEST_TMP/gh-out/gh.log" || fail "create path should search first"
grep -qxF 'create' "$TEST_TMP/gh-out/gh.log" || fail "create path should call gh issue create"
grep -qF "$stable_key_line" "$TEST_TMP/gh-out/create-body.md" \
  || fail "created issue body missing stable key"
grep -qF "$profile_line" "$TEST_TMP/gh-out/create-body.md" \
  || fail "created issue body missing profile"
grep -qF "$command_line" "$TEST_TMP/gh-out/create-body.md" \
  || fail "created issue body missing command"
grep -qF 'required checks are missing for PR #42' "$TEST_TMP/gh-out/create-body.md" \
  || fail "created issue body missing synthetic output"
grep -qF '/var/log/orch/realisons-wordpress.log' "$TEST_TMP/gh-out/create-body.md" \
  || fail "created issue body missing artifact"
grep -qF 'PR #42' "$TEST_TMP/gh-out/create-body.md" \
  || fail "created issue body missing impacted ref"
grep -qF "$next_action_line" "$TEST_TMP/gh-out/create-body.md" \
  || fail "created issue body missing next action"
grep -qF "$owner_line" "$TEST_TMP/gh-out/create-body.md" \
  || fail "created issue body missing owner"
grep -qF "$severity_line" "$TEST_TMP/gh-out/create-body.md" \
  || fail "created issue body missing severity"

rm -f "$TEST_TMP/gh-out/"*
update_json=$(
  GH_SCENARIO=existing run_registry report \
    --blocker-kind checks-missing \
    --resource pr-42 \
    --profile portfolio-standard \
    --command "bash scripts/cycle.sh" \
    --output-summary "required checks are still missing for PR #42" \
    --artifact "/var/log/orch/realisons-wordpress.log" \
    --impacted-ref "PR #42" \
    --next-action "rerun required checks" \
    --owner operator \
    --severity P1 \
    --apply \
    --json
)
[[ "$(jq -r '.decision' <<< "$update_json")" == "updated" ]] \
  || fail "second report should update the existing issue: $update_json"
[[ "$(jq -r '.issue_number' <<< "$update_json")" == "77" ]] \
  || fail "second report should reuse existing issue number: $update_json"
if grep -qxF 'create' "$TEST_TMP/gh-out/gh.log"; then
  fail "deduped report must not create a second issue"
fi
grep -qxF 'comment' "$TEST_TMP/gh-out/gh.log" || fail "deduped report should comment on the existing issue"
grep -qF "$stable_key_line" "$TEST_TMP/gh-out/comment-body.md" \
  || fail "update comment missing stable key"
grep -qF 'required checks are still missing for PR #42' "$TEST_TMP/gh-out/comment-body.md" \
  || fail "update comment missing latest synthetic output"

rm -f "$TEST_TMP/gh-out/"*
resolve_json=$(
  GH_SCENARIO=existing run_registry resolve \
    --blocker-kind checks-missing \
    --resource pr-42 \
    --resolution-summary "required checks are present" \
    --resolution-policy close \
    --apply \
    --json
)
[[ "$(jq -r '.decision' <<< "$resolve_json")" == "resolved" ]] \
  || fail "resolve should report a resolved decision: $resolve_json"
[[ "$(jq -r '.resolution_policy' <<< "$resolve_json")" == "close" ]] \
  || fail "resolve should record close policy: $resolve_json"
grep -qxF 'comment' "$TEST_TMP/gh-out/gh.log" || fail "close policy should comment before closing"
grep -qxF 'close' "$TEST_TMP/gh-out/gh.log" || fail "close policy should close the issue"
grep -qF "$stable_key_line" "$TEST_TMP/gh-out/comment-body.md" \
  || fail "resolution comment missing stable key"
grep -qF 'required checks are present' "$TEST_TMP/gh-out/comment-body.md" \
  || fail "resolution comment missing summary"

rm -f "$TEST_TMP/gh-out/"*
dry_json=$(
  GH_SCENARIO=none run_registry report \
    --blocker-kind loop-stopped \
    --resource orchestrator \
    --profile portfolio-standard \
    --command "bash scripts/orch_loop.sh" \
    --output-summary "loop stopped before final mutation" \
    --next-action "operator review" \
    --owner operator \
    --severity P1 \
    --json
)
[[ "$(jq -r '.decision' <<< "$dry_json")" == "dry-run" ]] \
  || fail "report without --apply should be non-mutating: $dry_json"
[[ ! -e "$TEST_TMP/gh-out/gh.log" ]] \
  || fail "dry-run report should not call gh"

printf 'ok - blocker_issue_registry creates, deduplicates, resolves, and reports status links\n'
