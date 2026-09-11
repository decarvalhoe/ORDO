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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/configs" "$TEST_TMP/bin"

for rel in \
  scripts/portfolio_repo_bind_plan.sh \
  lib/config_resolver.sh \
  lib/portfolio_config.sh \
  lib/ordo_contracts.sh \
  lib/external_mutation_gate.sh \
  lib/ordo_provider_adapter.sh \
  lib/ordo_provider_adapter_github.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/portfolio_repo_bind_plan.sh"

cat > "$TEST_TMP/configs/rbok.config.sh" <<'EOF'
PROJECT="rbok"
GH_REPO="RBOKproject/RBOK"
DEFAULT_BRANCH="develop"
export AGENT_WORKDIR_TEMPLATE="/tmp/rbok-%s"
EOF

cat > "$TEST_TMP/configs/lumen.config.sh" <<'EOF'
PROJECT="lumen"
DEFAULT_BRANCH="main"
export AGENT_WORKDIR_TEMPLATE="/tmp/lumen-%s"
EOF

cat > "$TEST_TMP/configs/praxis.config.sh" <<'EOF'
PROJECT="praxis"
DEFAULT_BRANCH="main"
export AGENT_WORKDIR_TEMPLATE="/tmp/praxis-%s"
EOF

cat > "$TEST_TMP/configs/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="bind-test"
PORTFOLIO_PROJECTS=(
  "rbok|$TEST_TMP/configs/rbok.config.sh"
  "lumen|$TEST_TMP/configs/lumen.config.sh"
  "praxis|$TEST_TMP/configs/praxis.config.sh"
)
PORTFOLIO_REPO_CANDIDATES=(
  "lumen|RBOKproject/custom-lumen-core|main|/tmp/custom-lumen-%s"
)
EOF

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "repo list RBOKproject --limit 101 --json name,nameWithOwner,description,url,defaultBranchRef,isPrivate,isArchived")
    cat <<'JSON'
[
  {"name":"PRAXIS","nameWithOwner":"RBOKproject/PRAXIS","description":"Praxis testing intelligence","url":"https://github.com/RBOKproject/PRAXIS","defaultBranchRef":{"name":"main"}},
  {"name":"unrelated","nameWithOwner":"RBOKproject/unrelated","description":"other repo","url":"https://github.com/RBOKproject/unrelated","defaultBranchRef":{"name":"main"}}
]
JSON
    ;;
  *)
    printf 'unexpected gh args: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$TEST_TMP/bin/gh"

json_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  bash "$SANITIZED_ROOT/scripts/portfolio_repo_bind_plan.sh" "$TEST_TMP/configs/portfolio.config.sh" \
    --json \
    --discover-owner RBOKproject
)

printf '%s\n' "$json_output" | jq -e '.[] | select(.alias == "rbok" and .status == "confirmed_existing" and .confirmation_required == false and .candidate_repo == "RBOKproject/RBOK")' >/dev/null \
  || fail "existing GH_REPO should be confirmed without mutation: $json_output"
printf '%s\n' "$json_output" | jq -e '.[] | select(.alias == "lumen" and .status == "needs_confirmation" and .confirmation_required == true and .source == "user_config" and .candidate_repo == "RBOKproject/custom-lumen-core" and (.config_snippet | contains("GH_REPO=RBOKproject/custom-lumen-core")))' >/dev/null \
  || fail "custom user candidate should require confirmation: $json_output"
printf '%s\n' "$json_output" | jq -e 'map(select(.alias != "lumen" and .source == "user_config")) | length == 0' >/dev/null \
  || fail "explicit user candidates should not bind to other projects: $json_output"
printf '%s\n' "$json_output" | jq -e '.[] | select(.alias == "praxis" and .status == "needs_confirmation" and .confirmation_required == true and .source == "discovered" and .candidate_repo == "RBOKproject/PRAXIS")' >/dev/null \
  || fail "discovered holistic candidate should require confirmation: $json_output"

tsv_output=$(
  PATH="$TEST_TMP/bin:$PATH" \
  bash "$SANITIZED_ROOT/scripts/portfolio_repo_bind_plan.sh" "$TEST_TMP/configs/portfolio.config.sh" \
    --tsv \
    --candidate "praxis|RBOKproject/custom-praxis|main"
)
[[ "$tsv_output" == *$'alias\tproject\tstatus\tconfirmation_required'* ]] || fail "missing TSV header: $tsv_output"
[[ "$tsv_output" == *$'praxis\tpraxis\tneeds_confirmation\ttrue\tuser_cli'* ]] || fail "CLI candidate missing: $tsv_output"

printf 'ok - portfolio_repo_bind_plan proposes strict repo bindings\n'
