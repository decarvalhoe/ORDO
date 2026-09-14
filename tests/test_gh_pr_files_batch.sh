#!/usr/bin/env bash
# tests/test_gh_pr_files_batch.sh -- coverage for lib/gh_pr_files_batch.sh
# (issue #293).
#
# Mocks `gh api graphql -f query=@<file>` so the test exercises the real
# query construction, chunking, and TSV emission paths without GitHub.
# The mock parses the query file, extracts every `pr_<N>:` alias, and
# synthesizes a deterministic GraphQL response so we can assert on output
# shape, ordering, batching cost, and error propagation.
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

mkdir -p "$TEST_TMP/bin" "$TEST_TMP/logs"

cat > "$TEST_TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Minimal gh mock. Only `gh api graphql -f query=@FILE` is supported.
mode=""
qfile=""
for a in "$@"; do
  case "$a" in
    api) mode="api" ;;
    graphql) [ "$mode" = "api" ] && mode="api-graphql" ;;
    -f|--field) ;;
    query=@*) qfile=${a#query=@} ;;
  esac
done

if [ "$mode" != "api-graphql" ]; then
  printf 'unexpected gh invocation: %s\n' "$*" >&2
  exit 2
fi
if [ -z "$qfile" ] || [ ! -f "$qfile" ]; then
  printf 'gh api graphql: missing -f query=@FILE\n' >&2
  exit 2
fi

if [ -n "${GH_PR_FILES_BATCH_FAIL:-}" ]; then
  printf 'API rate limit exceeded for installation\n' >&2
  exit 1
fi

log_file=${GH_PR_FILES_BATCH_QLOG:-/dev/null}
{
  cat "$qfile"
  printf '\n----CHUNK-END----\n'
} >> "$log_file"

aliases=$(grep -Eo 'pr_[0-9]+:' "$qfile" | sort -u | tr -d ':')

{
  printf '{"data":{"repository":{'
  first=1
  for alias in $aliases; do
    n=${alias#pr_}
    [ "$first" -eq 1 ] || printf ','
    first=0
    if [ -n "${GH_PR_FILES_BATCH_NULL_PR:-}" ] && [ "$n" = "${GH_PR_FILES_BATCH_NULL_PR}" ]; then
      printf '"%s":null' "$alias"
      continue
    fi
    printf '"%s":{"number":%s,"files":{"nodes":[' "$alias" "$n"
    printf '{"path":"src/file_%s_a.go"},' "$n"
    printf '{"path":"src/file_%s_b.go"}' "$n"
    printf ']}}'
  done
  printf '}}}'
}
EOF
chmod +x "$TEST_TMP/bin/gh"

GH_CONFIG_DIR="$TEST_TMP/gh"
mkdir -p "$GH_CONFIG_DIR"

run_helper() {
  PATH="$TEST_TMP/bin:$PATH" \
  GH_CONFIG_DIR="$GH_CONFIG_DIR" \
  bash -c '
    set -euo pipefail
    source "'"$ROOT"'/lib/gh_pr_files_batch.sh"
    gh_pr_files_batch_fetch "$@"
  ' _ "$@"
}

count_chunks() {
  local log=$1
  if [ ! -s "$log" ]; then
    printf '0\n'
    return
  fi
  grep -c '^----CHUNK-END----$' "$log" || true
}

# ----------------------------------------------------------------------------
# 1. Single PR -> 2 file rows, one chunk.
log1="$TEST_TMP/logs/single.qlog"; : > "$log1"
out=$(GH_PR_FILES_BATCH_QLOG="$log1" run_helper example/repo 17)
expected=$(printf '17\tsrc/file_17_a.go\n17\tsrc/file_17_b.go')
[[ "$out" == "$expected" ]] || fail "single PR shape:
got:
$out
expected:
$expected"
[[ "$(count_chunks "$log1")" == "1" ]] || fail "single PR should issue exactly 1 GraphQL call (got $(count_chunks "$log1"))"
grep -q 'pr_17: pullRequest(number: 17)' "$log1" || fail "query missing pr_17 alias"
grep -q 'repository(owner: "example", name: "repo")' "$log1" || fail "query missing owner/repo"

# ----------------------------------------------------------------------------
# 2. Multiple PRs in one batch (default max 25) -> 3 PRs * 2 files = 6 rows,
# still one chunk, sorted by PR number then path.
log2="$TEST_TMP/logs/multi.qlog"; : > "$log2"
out=$(GH_PR_FILES_BATCH_QLOG="$log2" run_helper example/repo 19 17 18)
[[ "$(printf '%s\n' "$out" | wc -l)" == "6" ]] || fail "multi-PR row count: got $out"
first=$(printf '%s\n' "$out" | head -1)
last=$(printf '%s\n' "$out" | tail -1)
[[ "$first" == "17"$'\t'"src/file_17_a.go" ]] || fail "multi-PR not sorted by PR# first row: $first"
[[ "$last"  == "19"$'\t'"src/file_19_b.go" ]] || fail "multi-PR not sorted by PR# last row: $last"
[[ "$(count_chunks "$log2")" == "1" ]] || fail "multi-PR (n<=max) should be 1 chunk (got $(count_chunks "$log2"))"

# ----------------------------------------------------------------------------
# 3. Chunking: max=2, request 5 PRs -> ceil(5/2) = 3 chunked GraphQL calls.
log3="$TEST_TMP/logs/chunk.qlog"; : > "$log3"
out=$(GH_PR_FILES_BATCH_MAX_PRS=2 GH_PR_FILES_BATCH_QLOG="$log3" \
  run_helper example/repo 1 2 3 4 5)
[[ "$(printf '%s\n' "$out" | wc -l)" == "10" ]] || fail "chunked rows count: got $out"
chunks=$(count_chunks "$log3")
[[ "$chunks" == "3" ]] || fail "chunked PR set should issue 3 GraphQL calls (got $chunks)"
# First chunk should contain pr_1 and pr_2 only.
awk '/^query \{/{n++} {print > "'"$TEST_TMP/logs/chunk_"'" n ".gql"}' "$log3"
grep -q 'pr_1:' "$TEST_TMP/logs/chunk_1.gql" || fail "chunk 1 missing pr_1"
grep -q 'pr_2:' "$TEST_TMP/logs/chunk_1.gql" || fail "chunk 1 missing pr_2"
grep -q 'pr_3:' "$TEST_TMP/logs/chunk_1.gql" && fail "chunk 1 leaked pr_3"
grep -q 'pr_5:' "$TEST_TMP/logs/chunk_3.gql" || fail "chunk 3 missing pr_5"

# ----------------------------------------------------------------------------
# 4. Empty input -> rc=0, no GraphQL call, no output.
log4="$TEST_TMP/logs/empty.qlog"; : > "$log4"
out=$(GH_PR_FILES_BATCH_QLOG="$log4" run_helper example/repo)
[[ -z "$out" ]] || fail "empty input must produce no output, got: $out"
[[ "$(count_chunks "$log4")" == "0" ]] || fail "empty input must not call gh ($(count_chunks "$log4") chunks seen)"

# ----------------------------------------------------------------------------
# 5. GraphQL failure -> rc=1, single-line error on stderr (caller-fallback path).
log5="$TEST_TMP/logs/fail.qlog"; : > "$log5"
err5="$TEST_TMP/logs/fail.stderr"
if GH_PR_FILES_BATCH_FAIL=1 GH_PR_FILES_BATCH_QLOG="$log5" \
   run_helper example/repo 17 18 > /dev/null 2> "$err5"; then
  fail "GraphQL failure should produce non-zero exit"
fi
grep -q 'gh_pr_files_batch: provider pr_files_batch failed' "$err5" || \
  fail "failure path must surface a single-line error on stderr: $(cat "$err5")"

# ----------------------------------------------------------------------------
# 6. Argument validation: non-numeric PR id -> rc=2 with clear message.
err6="$TEST_TMP/logs/badpr.stderr"
if run_helper example/repo 17 abc > /dev/null 2> "$err6"; then
  fail "non-numeric PR id should exit non-zero"
fi
grep -q 'gh_pr_files_batch: invalid PR number: abc' "$err6" || \
  fail "non-numeric PR error message missing: $(cat "$err6")"

# ----------------------------------------------------------------------------
# 7. Argument validation: missing slash in repo -> rc=2.
err7="$TEST_TMP/logs/badrepo.stderr"
if run_helper notarepo 17 > /dev/null 2> "$err7"; then
  fail "invalid repo should exit non-zero"
fi
grep -q 'gh_pr_files_batch: invalid repo' "$err7" || \
  fail "invalid repo error message missing: $(cat "$err7")"

# ----------------------------------------------------------------------------
# 8. Null repository entry (deleted/inaccessible PR) -> filtered out, no failure.
log8="$TEST_TMP/logs/null.qlog"; : > "$log8"
out=$(GH_PR_FILES_BATCH_NULL_PR=18 GH_PR_FILES_BATCH_QLOG="$log8" \
  run_helper example/repo 17 18 19)
# 17 and 19 each contribute 2 rows, 18 is null -> 4 rows total.
[[ "$(printf '%s\n' "$out" | wc -l)" == "4" ]] || fail "null-PR filtering: got $out"
printf '%s\n' "$out" | grep -q '^18'$'\t' && fail "null PR should be skipped, but #18 row appeared: $out"

printf 'ok - gh_pr_files_batch_fetch batches PR file lookups in one GraphQL call (#293)\n'
