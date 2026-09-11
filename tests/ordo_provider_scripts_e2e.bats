#!/usr/bin/env bats
# tests/ordo_provider_scripts_e2e.bats — #816 end-to-end proof.
#
# With ORDO_PROVIDER_ADAPTER=fake, the fixtures of tests/fixtures/adapters/fake
# under ORDO_FAKE_ADAPTER_DIR and NO `gh` binary on PATH, the status/inventory
# scripts (agent_pool_status.sh, pr_block_signals.sh), a dispatch dry-run
# (dispatch_plan.sh, --atomize --dry-run) and a merge dry-run
# (pr_merge_wave.sh --dry-run) complete with the expected output, and no
# mutation reaches the forge.
#
# Fixture dataset (repo acme/widgets): open PRs #12 (branch feat/wave-7-12,
# clean, approved, one failed check) and #13 (draft, conflicting, no checks),
# merged PR #14; open issues #7, #8, #10, #11 (#9 closed); PR bodies close #7.

bats_require_minimum_version 1.5.0

load './helpers.bash'

setup() {
  setup_orch_test
  export ORDO_PROVIDER_ADAPTER=fake
  export ORDO_FAKE_ADAPTER_DIR="$BATS_TEST_TMPDIR/fake"
  cp -R "$TK/tests/fixtures/adapters/fake" "$ORDO_FAKE_ADAPTER_DIR"
  unset GH_REPO ORDO_FORGE_REPO ORCH_EXTERNAL_PR_MUTATIONS

  # PATH without gh: every executable of the current PATH except `gh`.
  NOGH_BIN="$BATS_TEST_TMPDIR/nogh_bin"
  mkdir -p "$NOGH_BIN"
  local dir entry name
  local -a path_dirs=()
  IFS=: read -r -a path_dirs <<< "$PATH"
  for dir in "${path_dirs[@]}"; do
    [ -d "$dir" ] || continue
    for entry in "$dir"/*; do
      name=${entry##*/}
      [ "$name" = gh ] && continue
      [ -e "$NOGH_BIN/$name" ] || ln -s "$entry" "$NOGH_BIN/$name" 2>/dev/null || true
    done
  done
  export PATH="$NOGH_BIN"

  # One agent parked on the branch of PR #12.
  WORK="$BATS_TEST_TMPDIR/work/fleet-001"
  git init -q "$WORK"
  git -C "$WORK" -c user.email=fleet@example.invalid -c user.name=fleet commit -q --allow-empty -m init
  git -C "$WORK" checkout -q -b feat/wave-7-12

  CFG="$BATS_TEST_TMPDIR/e2e.config.sh"
  cat > "$CFG" <<EOF
PROJECT="$PROJECT"
GH_REPO="acme/widgets"
GH_CONFIG_DIR="$GH_CONFIG_DIR"
DEFAULT_BRANCH="main"
AGENT_WORKDIR_TEMPLATE="$BATS_TEST_TMPDIR/work/%s"
AGENT_PANES=("fleet-001|fleet-001:0.0|$WORK")
EOF
  export PR_SIGNAL_BASE_FETCH=0 PR_MERGE_WAVE_INTER_PR_SLEEP=0
}

# column <tsv> <header-name> -> 1-based index of the column in the TSV header
column() {
  printf '%s\n' "$1" | head -n 1 | awk -F'\t' -v want="$2" '{ for (i = 1; i <= NF; i++) if ($i == want) { print i; exit } }'
}

@test "the proof environment has no gh binary on PATH and selects the fake adapter" {
  run command -v gh
  [ "$status" -ne 0 ]
  run bash -c 'source "$TK/lib/ordo_provider_adapter.sh" && ordo_provider auth_status'
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.forge + ":" + .login')" = "fake:octo-bot" ]
}

@test "agent_pool_status.sh --tsv joins the fleet with the fake pr_list (no gh)" {
  run --separate-stderr bash "$TK/scripts/agent_pool_status.sh" "$CFG" --tsv
  [ "$status" -eq 0 ]
  local branch_col pr_col state_col
  branch_col=$(column "$output" branch)
  pr_col=$(column "$output" pr)
  state_col=$(column "$output" pr_state)
  [ -n "$branch_col" ] && [ -n "$pr_col" ] && [ -n "$state_col" ]
  local row
  row=$(printf '%s\n' "$output" | awk -F'\t' -v b="$branch_col" -v p="$pr_col" -v s="$state_col" \
    'NR > 1 && $1 == "fleet-001" { print $b "|" $p "|" $s }')
  [ "$row" = "feat/wave-7-12|12|CLEAN" ]
}

@test "pr_block_signals.sh --json surfaces the fake PRs, checks and owners (no gh)" {
  run --separate-stderr bash "$TK/scripts/pr_block_signals.sh" "$CFG" --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    def row($n): map(select(.pr == $n))[0];
    (map(.pr) | sort) == ["12", "13"]
    and row("12").agent == "fleet-001"
    and row("12").merge_state == "CLEAN" and row("12").mergeable == "MERGEABLE" and row("12").review == "APPROVED"
    and row("12").ci_status == "fail" and row("12").ci_rollup.aggregate == "failed_or_cancelled"
    and row("12").ci_failed_check_names == ["bats"]
    and row("12").ci_actionable_state == "checks_failed"
    and row("13").agent == ""
    and row("13").merge_state == "DIRTY" and row("13").mergeable == "CONFLICTING" and row("13").review == "REVIEW_REQUIRED"
    and row("13").ci_rollup.aggregate == "no_checks"
  ' >/dev/null
}

@test "dispatch_plan.sh --tsv and --atomize --dry-run plan against the fake issues and PRs (no gh, no mutation)" {
  run --separate-stderr bash "$TK/scripts/dispatch_plan.sh" "$CFG" --tsv
  [ "$status" -eq 0 ]
  [[ "$output" == *$'issue\tpriority\tscore\tstatus'* ]]
  local status_col signals_col rows
  status_col=$(column "$output" status)
  signals_col=$(column "$output" signals)
  rows=$(printf '%s\n' "$output" | awk -F'\t' -v s="$status_col" -v g="$signals_col" 'NR > 1 { print $1 "|" $s "|" $g }')
  [[ "$rows" == *"8|ready|"* ]]
  [[ "$rows" == *"10|ready|"* ]]
  [[ "$rows" == *"11|ready|"* ]]
  [[ "$rows" == *"7|blocked|"*"open_pr:#12"* ]]

  run --separate-stderr bash "$TK/scripts/dispatch_plan.sh" "$CFG" --atomize --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *$'issue\tpriority\tscore\tstatus'* ]]
  [ ! -f "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" ]
}

@test "pr_merge_wave.sh --dry-run walks the fake wave without merging (no gh, no mutation)" {
  run bash "$TK/scripts/pr_merge_wave.sh" "$CFG" wave7 '^feat/wave-7' --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"WAVE_MERGE start project=$PROJECT wave=wave7 regex=^feat/wave-7 matched=2"* ]]
  [[ "$output" == *"WAVE_MERGE step #12 branch=feat/wave-7-12 mergeable=MERGEABLE state=CLEAN"* ]]
  [[ "$output" == *"WAVE_MERGE step #13 branch=feat/wave-7-13 mergeable=CONFLICTING state=DIRTY"* ]]
  [[ "$output" == *"WAVE_MERGE end wave=wave7"* ]]
  [ ! -f "$ORDO_FAKE_ADAPTER_DIR/mutations.jsonl" ]
  # the fake pr_get fixtures are untouched: nothing was merged
  [ "$(jq -r .state "$ORDO_FAKE_ADAPTER_DIR/pr_get/12.json")" = "open" ]
}
