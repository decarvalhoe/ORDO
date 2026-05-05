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

mkdir -p "$SANITIZED_ROOT"

tr -d '\r' < "$ROOT/install.sh" > "$SANITIZED_ROOT/install.sh"
chmod +x "$SANITIZED_ROOT/install.sh"

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/examples"

cat > "$SANITIZED_ROOT/examples/alpha.config.sh" <<'EOF'
PROJECT="alpha"
EOF

cat > "$SANITIZED_ROOT/examples/beta.config.sh" <<'EOF'
export PROJECT="beta"
EOF

cat > "$SANITIZED_ROOT/examples/orch-tokens.env.example" <<'EOF'
TOKEN_PLACEHOLDER=1
EOF

cat > "$TEST_TMP/chmod" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_TMP/chmod"

cat > "$TEST_TMP/stat" <<'EOF'
#!/usr/bin/env bash
printf '600\n'
EOF
chmod +x "$TEST_TMP/stat"

cat > "$TEST_TMP/mkdir" <<EOF
#!/usr/bin/env bash
set -euo pipefail
last_arg="\${@: -1}"
if [[ "\$last_arg" == "/var/log/orch" ]]; then
  exec /bin/mkdir -p "$TEST_TMP/var-log-orch"
fi
exec /bin/mkdir "\$@"
EOF
chmod +x "$TEST_TMP/mkdir"

run_home="$TEST_TMP/home"
run_root="$TEST_TMP/root"
mkdir -p "$run_home" "$run_root/.config"

output=$(
  PATH="$TEST_TMP:$PATH" \
  HOME="$run_home" \
  XDG_DATA_HOME="$run_home/.local/share" \
  bash "$SANITIZED_ROOT/install.sh" 2>&1
)

[[ -d "$run_home/.local/share/orch-state/alpha" ]] || fail "alpha state dir was not created"
[[ -d "$run_home/.local/share/orch-state/beta" ]] || fail "beta state dir was not created"
[[ "$output" == *"alpha ->"* ]] || fail "alpha project was not reported in output"
[[ "$output" == *"beta ->"* ]] || fail "beta project was not reported in output"

printf 'ok - install.sh creates state dirs for plain and exported PROJECT configs\n'
