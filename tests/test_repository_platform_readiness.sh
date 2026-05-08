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

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/repository_platform_readiness.sh
chmod +x "$SANITIZED_ROOT/scripts/repository_platform_readiness.sh"

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/repos/writer" "$TEST_TMP/repos/reviewer"

cat > "$TEST_TMP/bin/platform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$PLATFORM_MOCK_LOG"

case "${PLATFORM_SCENARIO:-ready}" in
  no-auth)
    if [[ "${1:-} ${2:-}" == "identity current" ]]; then
      printf '%s\n' "auth unavailable" >&2
      exit 7
    fi
    ;;
esac

if [[ "${1:-} ${2:-}" == "identity current" ]]; then
  printf '%s\n' "${PLATFORM_ACTIVE_IDENTITY:-writer-id}"
  exit 0
fi

if [[ "${1:-} ${2:-}" == "repository metadata" ]]; then
  case "${PLATFORM_SCENARIO:-ready}" in
    no-repo)
      printf '%s\n' "repository unavailable" >&2
      exit 4
      ;;
    read-only)
      printf '%s\n' '{"permission":"read","default_branch":"main","repository":"sample-owner/sample-repository"}'
      ;;
    *)
      printf '%s\n' '{"permission":"write","default_branch":"main","repository":"sample-owner/sample-repository"}'
      ;;
  esac
  exit 0
fi

if [[ "${1:-} ${2:-}" == "ci status-check" ]]; then
  case "${PLATFORM_SCENARIO:-ready}" in
    no-ci)
      printf '%s\n' "ci hidden" >&2
      exit 5
      ;;
    *)
      printf '%s\n' '[]'
      exit 0
      ;;
  esac
fi

if [[ "${1:-} ${2:-}" == "pull-request review-check" ]]; then
  case "${PLATFORM_SCENARIO:-ready}" in
    read-only|no-review)
      printf '%s\n' "review unavailable" >&2
      exit 8
      ;;
    *)
      printf '%s\n' '{}'
      exit 0
      ;;
  esac
fi

if [[ "${1:-} ${2:-}" == "issue assignment-check" ]]; then
  case "${PLATFORM_SCENARIO:-ready}" in
    read-only|no-assign)
      printf '%s\n' "not assignable" >&2
      exit 6
      ;;
    *)
      printf '%s\n' '{}'
      exit 0
      ;;
  esac
fi

printf 'unexpected platform invocation: %s\n' "$*" >&2
exit 9
EOF
chmod +x "$TEST_TMP/bin/platform"

cat > "$TEST_TMP/config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="repository-platform-test"
REPOSITORY_PLATFORM_REPOSITORY="\${TEST_REPOSITORY:-sample-owner/sample-repository}"
REPOSITORY_PLATFORM_CONFIG_DIR="$TEST_TMP/platform-config"
REPOSITORY_PLATFORM_CLI_BIN="$TEST_TMP/bin/platform"
ORCH_EXPECTED_REPOSITORY_PLATFORM_IDENTITY="writer-id"
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=(
  "writer|unused-target|$TEST_TMP/repos/writer"
  "reviewer|unused-target|$TEST_TMP/repos/reviewer"
)
AGENT_REPOSITORY_PLATFORM_IDENTITIES=(
  "writer=writer-id"
  "reviewer=reviewer-id"
)
EOF

export PLATFORM_MOCK_LOG="$TEST_TMP/platform.log"

ready_json=$(
  PLATFORM_ACTIVE_IDENTITY="writer-id" \
  bash "$SANITIZED_ROOT/scripts/repository_platform_readiness.sh" "$TEST_TMP/config.sh" --json
)

jq -e '
  .status == "ready" and
  .repository == "sample-owner/sample-repository" and
  .active_identity == "writer-id" and
  (.capabilities.repository_access.ready == true) and
  (.capabilities.push_permission.ready == true) and
  (.capabilities.pr_review_capability.ready == true) and
  (.capabilities.issue_assignment_capability.ready == true) and
  (.capabilities.ci_status_visibility.ready == true) and
  (.capabilities.identity_binding.ready == true) and
  (.identity_bindings | length == 2) and
  (.identity_bindings | map(select(.agent == "writer" and .identity == "writer-id" and .status == "bound")) | length == 1) and
  (.identity_bindings | map(select(.agent == "reviewer" and .identity == "reviewer-id" and .status == "bound")) | length == 1) and
  (.blockers | length == 0)
' <<< "$ready_json" >/dev/null \
  || fail "ready repository-platform report unexpected: $ready_json"

set +e
no_auth_json=$(
  PLATFORM_SCENARIO="no-auth" \
  bash "$SANITIZED_ROOT/scripts/repository_platform_readiness.sh" "$TEST_TMP/config.sh" --json
)
no_auth_status=$?
set -e
[[ "$no_auth_status" -eq 78 ]] \
  || fail "missing auth should refuse with 78, got $no_auth_status: $no_auth_json"
jq -e '
  .status == "blocked" and
  (.blockers | index("repository_platform_auth_unusable")) and
  (.capabilities.identity_binding.ready == false)
' <<< "$no_auth_json" >/dev/null \
  || fail "missing auth report should include repository_platform_auth_unusable: $no_auth_json"

set +e
mismatch_json=$(
  PLATFORM_ACTIVE_IDENTITY="other-id" \
  bash "$SANITIZED_ROOT/scripts/repository_platform_readiness.sh" "$TEST_TMP/config.sh" --json
)
mismatch_status=$?
set -e
[[ "$mismatch_status" -eq 78 ]] \
  || fail "identity mismatch should refuse with 78, got $mismatch_status: $mismatch_json"
jq -e '
  .status == "blocked" and
  .active_identity == "other-id" and
  (.blockers | index("identity_binding")) and
  (.capabilities.identity_binding.ready == false)
' <<< "$mismatch_json" >/dev/null \
  || fail "identity mismatch report should block identity_binding: $mismatch_json"

set +e
read_only_json=$(
  PLATFORM_SCENARIO="read-only" PLATFORM_ACTIVE_IDENTITY="writer-id" \
  bash "$SANITIZED_ROOT/scripts/repository_platform_readiness.sh" "$TEST_TMP/config.sh" --json
)
read_only_status=$?
set -e
[[ "$read_only_status" -eq 78 ]] \
  || fail "read-only repository permission should refuse with 78, got $read_only_status: $read_only_json"
jq -e '
  .status == "blocked" and
  (.blockers | index("push_permission")) and
  (.blockers | index("pr_review_capability")) and
  (.blockers | index("issue_assignment_capability")) and
  (.capabilities.repository_access.ready == true) and
  (.capabilities.ci_status_visibility.ready == true)
' <<< "$read_only_json" >/dev/null \
  || fail "read-only report should block mutating platform capabilities: $read_only_json"

printf 'ok - repository platform readiness validates auth, identity, and capabilities\n'
