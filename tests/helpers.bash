setup_orch_test() {
  if [[ -z "${BATS_TEST_TMPDIR:-}" ]]; then
    BATS_TEST_TMPDIR="$(mktemp -d)"
    export BATS_TEST_TMPDIR
  fi

  export TK="${TK:-$(cd "$BATS_TEST_DIRNAME/.." && pwd)}"
  export PROJECT="test-bats-${BATS_TEST_NAME// /-}-${BATS_TEST_NUMBER}"
  export ORCH_LOG_DIR="$BATS_TEST_TMPDIR/log"
  export ORCH_STATE_BASE="$BATS_TEST_TMPDIR/state"
  export GH_CONFIG_DIR="$BATS_TEST_TMPDIR/gh"
  export TEST_BIN_DIR="$BATS_TEST_TMPDIR/bin"
  export SANITIZED_TK="$BATS_TEST_TMPDIR/toolkit"
  export AGENT_WORKDIR_TEMPLATE="$BATS_TEST_TMPDIR/work/%s"

  mkdir -p "$ORCH_LOG_DIR" "$ORCH_STATE_BASE" "$GH_CONFIG_DIR" "$TEST_BIN_DIR" "$SANITIZED_TK" "$BATS_TEST_TMPDIR/work"
  export PATH="$TEST_BIN_DIR:$PATH"
}

orch_env_exports() {
  cat <<EOF
export PROJECT='$PROJECT'
export ORCH_LOG_DIR='$ORCH_LOG_DIR'
export ORCH_STATE_BASE='$ORCH_STATE_BASE'
export GH_CONFIG_DIR='$GH_CONFIG_DIR'
export AGENT_WORKDIR_TEMPLATE='$AGENT_WORKDIR_TEMPLATE'
export PATH='$TEST_BIN_DIR:$PATH'
EOF
}

toolkit_file() {
  local rel="${1:?usage: toolkit_file <relative-path>}"
  local src="$TK/$rel"
  local dest="$SANITIZED_TK/$rel"
  mkdir -p "$(dirname "$dest")"
  tr -d '\r' < "$src" > "$dest"
  printf '%s' "$dest"
}

write_mock_bin() {
  local name="${1:?usage: write_mock_bin <name>}"
  shift || true
  cat > "$TEST_BIN_DIR/$name"
  chmod +x "$TEST_BIN_DIR/$name"
}
