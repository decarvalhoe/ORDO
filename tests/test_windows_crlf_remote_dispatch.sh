#!/usr/bin/env bash
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

mkdir -p "$TEST_TMP/bin"

cat > "$TEST_TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target=${1:?missing target}
shift
remote_command=${1:?missing remote command}

printf '%s\n' "$target" > "${SSH_TARGET_LOG:?missing SSH_TARGET_LOG}"
printf '%s\n' "$remote_command" > "${SSH_COMMAND_LOG:?missing SSH_COMMAND_LOG}"

bash -c "$remote_command"
EOF
chmod +x "$TEST_TMP/bin/ssh"

parser="$TEST_TMP/parse_flag.sh"
cat > "$parser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  --dry-run)
    printf 'flag ok\n'
    ;;
  *)
    printf 'unknown arg: %q\n' "${1:-}" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$parser"

crlf_dispatch="$TEST_TMP/dispatch.crlf.sh"
printf 'bash %q --dry-run\r\n' "$parser" > "$crlf_dispatch"

export SSH_TARGET_LOG="$TEST_TMP/ssh-target.log"
export SSH_COMMAND_LOG="$TEST_TMP/ssh-command.log"

set +e
output=$(
  PATH="$TEST_TMP/bin:$PATH" \
    bash "$ROOT/scripts/windows_ssh_dispatch.sh" \
      --host "operator@example" \
      --file "$crlf_dispatch" \
      2>&1
)
status=$?
set -e

[[ "$status" -eq 0 ]] || fail "CRLF-safe dispatch failed with $status: $output"
[[ "$output" == *"flag ok"* ]] || fail "sanitized dispatch did not preserve the supported flag: $output"
[[ "$output" != *"unknown arg"* ]] || fail "sanitized dispatch still produced unknown-arg output: $output"
[[ "$(cat "$SSH_TARGET_LOG")" == "operator@example" ]] || fail "unexpected ssh target: $(cat "$SSH_TARGET_LOG")"
[[ "$(cat "$SSH_COMMAND_LOG")" == "tr -d '\\r' | bash -s" ]] || fail "missing remote CRLF filter: $(cat "$SSH_COMMAND_LOG")"

diagnostic_log="$TEST_TMP/diagnostic.log"
printf "unknown arg: --dry-run\n+ export PATH=\$'...\\\\r'\n" > "$diagnostic_log"

diagnostic=$(
  bash "$ROOT/scripts/windows_ssh_dispatch.sh" \
    --diagnose-output "$diagnostic_log"
)

[[ "$diagnostic" == *"diagnostic=windows-crlf-argv-contamination"* ]] \
  || fail "diagnostic did not classify CRLF argv contamination: $diagnostic"
[[ "$diagnostic" == *"scripts/windows_ssh_dispatch.sh"* ]] \
  || fail "diagnostic did not include safe helper remediation: $diagnostic"

printf 'ok - windows ssh dispatch strips CRLF before remote bash and diagnoses argv contamination\n'
