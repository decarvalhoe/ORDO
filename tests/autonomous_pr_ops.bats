#!/usr/bin/env bats
# tests/autonomous_pr_ops.bats — universal coverage for the autonomous
# PR ops library and runner (#361). Two project profile fixtures
# ("project-a" with squash-only / strict reviews, "project-b" with
# rebase / reviews-not-required) prove the library is project-neutral
# and never hardcodes a single project's policy.

load './helpers.bash'

setup() {
  setup_orch_test
  TK="${TK:-$(cd "$BATS_TEST_DIRNAME/.." && pwd)}"
  export TK
  # Project fixture A — strict policy: squash, reviews required, narrow
  # allowed bases, business-scope exclusion lists business/.
  export PROJECT="project-a"
  export PROJECT_A_CONFIG="$BATS_TEST_TMPDIR/project-a.config.sh"
  cat >"$PROJECT_A_CONFIG" <<'CFG'
#!/usr/bin/env bash
PROJECT="project-a"
GH_REPO="example/project-a"
GH_CONFIG_DIR="$BATS_TEST_TMPDIR/gh-a"
DEFAULT_BRANCH="main"
AUTO_PR_OPS_ENABLED="1"
AUTO_PR_OPS_MODE="dry-run"
AUTO_PR_OPS_ALLOWED_BASES="main develop"
AUTO_PR_OPS_MERGE_STRATEGY="squash"
AUTO_PR_OPS_REQUIRE_REVIEWS="1"
AUTO_PR_OPS_RELEASE_GATE_LABELS="release,gxp,csv,docs-frozen"
AUTO_PR_OPS_BUSINESS_EXCLUDED_PATHS="business/,billing/"
CFG
  # Project fixture B — looser policy: rebase, reviews not required,
  # different allowed-base list, no business exclusions. Demonstrates
  # the library reads everything from profile state.
  export PROJECT_B_CONFIG="$BATS_TEST_TMPDIR/project-b.config.sh"
  cat >"$PROJECT_B_CONFIG" <<'CFG'
#!/usr/bin/env bash
PROJECT="project-b"
GH_REPO="example/project-b"
GH_CONFIG_DIR="$BATS_TEST_TMPDIR/gh-b"
DEFAULT_BRANCH="trunk"
AUTO_PR_OPS_ENABLED="1"
AUTO_PR_OPS_MODE="live"
AUTO_PR_OPS_ALLOWED_BASES="trunk"
AUTO_PR_OPS_MERGE_STRATEGY="rebase"
AUTO_PR_OPS_REQUIRE_REVIEWS="0"
AUTO_PR_OPS_RELEASE_GATE_LABELS=""
AUTO_PR_OPS_BUSINESS_EXCLUDED_PATHS=""
CFG
}


# Source the library directly under the projects' env vars.
load_lib_for_profile() {
  local cfg="${1:?usage: load_lib_for_profile <config-path>}"
  # shellcheck disable=SC1090
  source "$cfg"
  unset ORCH_AUTO_PR_OPS_LIB_LOADED
  # shellcheck disable=SC1091
  source "$TK/lib/autonomous_pr_ops.sh"
}


# Write a synthetic gh pr view JSON payload to feed the evaluator.
write_payload() {
  local out="${1:?}"; shift
  local base="main"
  local draft="false"
  local mergeable="MERGEABLE"
  local merge_state="CLEAN"
  local review_decision="APPROVED"
  local check_status="pass"
  local labels=""
  local files=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      base=*) base="${1#base=}" ;;
      draft=*) draft="${1#draft=}" ;;
      mergeable=*) mergeable="${1#mergeable=}" ;;
      merge_state=*) merge_state="${1#merge_state=}" ;;
      review_decision=*) review_decision="${1#review_decision=}" ;;
      check_status=*) check_status="${1#check_status=}" ;;
      labels=*) labels="${1#labels=}" ;;
      files=*) files="${1#files=}" ;;
    esac
    shift
  done
  local labels_json="[]"
  if [[ -n "$labels" ]]; then
    labels_json=$(jq -nc --arg list "$labels" '
      ($list | split(",") | map(select(. != "") | { name: . })) // []
    ')
  fi
  local files_json="[]"
  if [[ -n "$files" ]]; then
    files_json=$(jq -nc --arg list "$files" '
      ($list | split(",") | map(select(. != "") | { path: . })) // []
    ')
  fi
  jq -nc \
    --arg base "$base" \
    --arg draft "$draft" \
    --arg mergeable "$mergeable" \
    --arg merge_state "$merge_state" \
    --arg review_decision "$review_decision" \
    --arg check_status "$check_status" \
    --argjson labels "$labels_json" \
    --argjson files "$files_json" \
    '{
      baseRefName: $base,
      isDraft: ($draft == "true"),
      mergeable: $mergeable,
      mergeStateStatus: $merge_state,
      reviewDecision: $review_decision,
      checkStatus: $check_status,
      labels: $labels,
      files: $files
    }' >"$out"
}


# ─── Policy / strategy ─────────────────────────────────────────────────────

@test "policy_enabled is false when AUTO_PR_OPS_ENABLED is not 1" {
  AUTO_PR_OPS_ENABLED=0 \
  PROJECT=project-a \
  ORCH_STATE_BASE="$BATS_TEST_TMPDIR/state-1" \
  ORCH_AUTO_PR_OPS_LIB_LOADED="" \
    bash -c "source '$TK/lib/autonomous_pr_ops.sh' && auto_pr_ops_policy_enabled" \
    || true
  run env AUTO_PR_OPS_ENABLED=0 PROJECT=project-a \
    bash -c "source '$TK/lib/autonomous_pr_ops.sh' && auto_pr_ops_policy_enabled && echo enabled || echo disabled"
  [ "$status" -eq 0 ]
  [[ "$output" == *"disabled"* ]]
}

@test "policy_enabled is true when AUTO_PR_OPS_ENABLED=1" {
  run env AUTO_PR_OPS_ENABLED=1 PROJECT=project-a \
    bash -c "source '$TK/lib/autonomous_pr_ops.sh' && auto_pr_ops_policy_enabled && echo enabled || echo disabled"
  [ "$status" -eq 0 ]
  [[ "$output" == *"enabled"* ]]
}

@test "merge_strategy_valid accepts squash / rebase / merge and rejects others" {
  for s in squash rebase merge; do
    run env AUTO_PR_OPS_MERGE_STRATEGY=$s \
      bash -c "source '$TK/lib/autonomous_pr_ops.sh' && auto_pr_ops_strategy_valid \"\$(auto_pr_ops_strategy)\" && echo ok"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok"* ]]
  done
  run env AUTO_PR_OPS_MERGE_STRATEGY=banana \
    bash -c "source '$TK/lib/autonomous_pr_ops.sh' && auto_pr_ops_strategy_valid \"\$(auto_pr_ops_strategy)\" && echo ok || echo refused"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refused"* ]]
}


# ─── Kill switch ───────────────────────────────────────────────────────────

@test "kill switch engage / status / release round-trip" {
  local switch_path="$BATS_TEST_TMPDIR/kill.json"
  run env ORCH_AUTO_PR_OPS_KILL_SWITCH_PATH="$switch_path" \
    bash -c "source '$TK/lib/autonomous_pr_ops.sh' && \
      auto_pr_ops_kill_switch_engage 'wave-pause' && \
      ([ -f '$switch_path' ] && echo engaged) && \
      auto_pr_ops_kill_switch_release && \
      ([ ! -f '$switch_path' ] && echo released)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"engaged"* ]]
  [[ "$output" == *"released"* ]]
}

@test "kill switch active blocks not_kill_switched gate" {
  local switch_path="$BATS_TEST_TMPDIR/kill-blocks.json"
  printf '{"engaged_at":"now","reason":"test"}\n' >"$switch_path"
  run env ORCH_AUTO_PR_OPS_KILL_SWITCH_PATH="$switch_path" \
    bash -c "source '$TK/lib/autonomous_pr_ops.sh' && auto_pr_ops_gate_not_kill_switched"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ok":false'* ]]
  [[ "$output" == *"kill switch engaged"* ]]
}


# ─── Universal: gate evaluator runs against project-a (clean PR) ──────────

@test "project-a clean PR is eligible across every gate" {
  load_lib_for_profile "$PROJECT_A_CONFIG"
  local payload="$BATS_TEST_TMPDIR/payload-clean-a.json"
  write_payload "$payload" base=main
  AUTO_PR_OPS_TEST_PR_PAYLOAD="$payload" \
  ORCH_AUTO_PR_OPS_KILL_SWITCH_PATH="$BATS_TEST_TMPDIR/kill-a.json" \
    run bash -c "source '$PROJECT_A_CONFIG' && \
      source '$TK/lib/autonomous_pr_ops.sh' && \
      AUTO_PR_OPS_TEST_PR_PAYLOAD='$payload' \
      ORCH_AUTO_PR_OPS_KILL_SWITCH_PATH='$BATS_TEST_TMPDIR/kill-a.json' \
      auto_pr_ops_evaluate_pr example/project-a 42"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"eligible": true'* ]]
  [[ "$output" == *'"strategy": "squash"'* ]]
  [[ "$output" == *'"refused_reasons": []'* ]]
}

@test "project-b clean PR uses rebase strategy and is eligible without reviews" {
  load_lib_for_profile "$PROJECT_B_CONFIG"
  local payload="$BATS_TEST_TMPDIR/payload-clean-b.json"
  # PR has reviewDecision REVIEW_REQUIRED — but the profile sets
  # AUTO_PR_OPS_REQUIRE_REVIEWS=0 so this is acceptable.
  write_payload "$payload" base=trunk review_decision=REVIEW_REQUIRED
  run bash -c "source '$PROJECT_B_CONFIG' && \
    source '$TK/lib/autonomous_pr_ops.sh' && \
    AUTO_PR_OPS_TEST_PR_PAYLOAD='$payload' \
    ORCH_AUTO_PR_OPS_KILL_SWITCH_PATH='$BATS_TEST_TMPDIR/kill-b.json' \
    auto_pr_ops_evaluate_pr example/project-b 1"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"eligible": true'* ]]
  [[ "$output" == *'"strategy": "rebase"'* ]]
  [[ "$output" == *'"mode": "live"'* ]]
}


# ─── Negative tests for every gate ─────────────────────────────────────────

negative_case() {
  local name="$1"; shift
  local payload_args=("$@")
  local payload="$BATS_TEST_TMPDIR/$name.json"
  write_payload "$payload" "${payload_args[@]}"
  run bash -c "source '$PROJECT_A_CONFIG' && \
    source '$TK/lib/autonomous_pr_ops.sh' && \
    AUTO_PR_OPS_TEST_PR_PAYLOAD='$payload' \
    ORCH_AUTO_PR_OPS_KILL_SWITCH_PATH='$BATS_TEST_TMPDIR/kill.$name.json' \
    auto_pr_ops_evaluate_pr example/project-a 9"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"eligible": false'* ]]
}

@test "gate refusal: target_branch_allowed when base is not in profile list" {
  negative_case base-not-allowed base=feature/x
  [[ "$output" == *'target_branch_allowed'* ]]
  [[ "$output" == *'not in AUTO_PR_OPS_ALLOWED_BASES'* ]]
}

@test "gate refusal: not_draft when PR is draft" {
  negative_case is-draft draft=true
  [[ "$output" == *'not_draft'* ]]
  [[ "$output" == *'PR is draft'* ]]
}

@test "gate refusal: mergeable_known_clean when mergeable=CONFLICTING" {
  negative_case conflicting mergeable=CONFLICTING merge_state=DIRTY
  [[ "$output" == *'mergeable_known_clean'* ]]
  [[ "$output" == *'mergeable=CONFLICTING'* ]]
}

@test "gate refusal: mergeable_known_clean when mergeStateStatus=BLOCKED" {
  negative_case blocked merge_state=BLOCKED
  [[ "$output" == *'mergeable_known_clean'* ]]
  [[ "$output" == *'BLOCKED'* ]]
}

@test "gate refusal: required_checks_pass when checks pending" {
  negative_case checks-pending check_status=pending
  [[ "$output" == *'required_checks_pass'* ]]
  [[ "$output" == *'pending'* ]]
}

@test "gate refusal: required_checks_pass when checks failed" {
  negative_case checks-failed check_status=fail
  [[ "$output" == *'required_checks_pass'* ]]
  [[ "$output" == *'failed'* ]]
}

@test "gate refusal: required_checks_pass passes under not-applicable scope" {
  # The PR's check status is "not-applicable" (matches the
  # pr_merge.sh no-check-policy classification) — this ought to
  # PASS the required_checks_pass gate even though the rollup is
  # empty. Use a clean payload otherwise so this is a focused
  # positive case for the not-applicable branch.
  local payload="$BATS_TEST_TMPDIR/checks-not-applicable.json"
  write_payload "$payload" base=main check_status=not-applicable
  run bash -c "source '$PROJECT_A_CONFIG' && \
    source '$TK/lib/autonomous_pr_ops.sh' && \
    AUTO_PR_OPS_TEST_PR_PAYLOAD='$payload' \
    ORCH_AUTO_PR_OPS_KILL_SWITCH_PATH='$BATS_TEST_TMPDIR/kill.na.json' \
    auto_pr_ops_evaluate_pr example/project-a 9"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"eligible": true'* ]]
  [[ "$output" == *'no-check policy applied'* ]]
}

@test "gate refusal: required_reviews_satisfied when review pending under strict profile" {
  negative_case review-required review_decision=REVIEW_REQUIRED
  [[ "$output" == *'required_reviews_satisfied'* ]]
}

@test "gate refusal: no_release_gate_label fires when a release label is present" {
  negative_case release-label labels=release
  [[ "$output" == *'no_release_gate_label'* ]]
  [[ "$output" == *'release'* ]]
}

@test "gate refusal: no_release_gate_label fires for gxp / csv / docs-frozen too" {
  negative_case release-label-gxp labels=gxp
  [[ "$output" == *'release-gate labels present'* ]]
  negative_case release-label-csv labels=csv
  [[ "$output" == *'release-gate labels present'* ]]
  negative_case release-label-docs labels=docs-frozen
  [[ "$output" == *'release-gate labels present'* ]]
}

@test "gate refusal: no_business_scope_exclusion fires for business/ paths" {
  negative_case business-scope files=business/api.py,scripts/foo.sh
  [[ "$output" == *'no_business_scope_exclusion'* ]]
  [[ "$output" == *'business/api.py'* ]]
}

@test "gate refusal: kill-switch active refuses every PR (and is reported per-PR)" {
  local switch_path="$BATS_TEST_TMPDIR/kill-applied.json"
  printf '{"engaged_at":"now","reason":"manual pause"}\n' >"$switch_path"
  local payload="$BATS_TEST_TMPDIR/payload-killed.json"
  write_payload "$payload" base=main
  run bash -c "source '$PROJECT_A_CONFIG' && \
    source '$TK/lib/autonomous_pr_ops.sh' && \
    AUTO_PR_OPS_TEST_PR_PAYLOAD='$payload' \
    ORCH_AUTO_PR_OPS_KILL_SWITCH_PATH='$switch_path' \
    auto_pr_ops_evaluate_pr example/project-a 7"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"eligible": false'* ]]
  [[ "$output" == *'kill switch engaged'* ]]
}

@test "gate refusal: invalid merge strategy refuses regardless of PR shape" {
  local payload="$BATS_TEST_TMPDIR/payload-bad-strategy.json"
  write_payload "$payload" base=main
  # Source the profile, then explicitly override the strategy in the
  # environment after sourcing so the override is in effect when the
  # gate evaluator reads AUTO_PR_OPS_MERGE_STRATEGY.
  run bash -c "source '$PROJECT_A_CONFIG'; \
    export AUTO_PR_OPS_MERGE_STRATEGY=banana; \
    source '$TK/lib/autonomous_pr_ops.sh'; \
    AUTO_PR_OPS_TEST_PR_PAYLOAD='$payload' \
    ORCH_AUTO_PR_OPS_KILL_SWITCH_PATH='$BATS_TEST_TMPDIR/kill-bad.json' \
    auto_pr_ops_evaluate_pr example/project-a 11"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"eligible": false'* ]]
  [[ "$output" == *'merge_strategy_valid'* ]]
  [[ "$output" == *'banana'* ]]
}


# ─── Evidence renderer ────────────────────────────────────────────────────

@test "render_evidence emits a one-line audit summary for an eligible PR" {
  local payload="$BATS_TEST_TMPDIR/payload-evidence.json"
  write_payload "$payload" base=main
  run bash -c "source '$PROJECT_A_CONFIG' && \
    source '$TK/lib/autonomous_pr_ops.sh' && \
    AUTO_PR_OPS_TEST_PR_PAYLOAD='$payload' \
    ORCH_AUTO_PR_OPS_KILL_SWITCH_PATH='$BATS_TEST_TMPDIR/kill-evi.json' \
    eval_json=\$(auto_pr_ops_evaluate_pr example/project-a 42); \
    auto_pr_ops_render_evidence \"\$eval_json\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"AUTONOMOUS_PR_OPS evaluation"* ]]
  [[ "$output" == *"repo=example/project-a"* ]]
  [[ "$output" == *"pr=42"* ]]
  [[ "$output" == *"strategy=squash"* ]]
  [[ "$output" == *"eligible=true"* ]]
}

@test "render_evidence summarizes refused reasons" {
  local payload="$BATS_TEST_TMPDIR/payload-evidence-refused.json"
  write_payload "$payload" base=main draft=true
  run bash -c "source '$PROJECT_A_CONFIG' && \
    source '$TK/lib/autonomous_pr_ops.sh' && \
    AUTO_PR_OPS_TEST_PR_PAYLOAD='$payload' \
    ORCH_AUTO_PR_OPS_KILL_SWITCH_PATH='$BATS_TEST_TMPDIR/kill-evi-r.json' \
    eval_json=\$(auto_pr_ops_evaluate_pr example/project-a 42); \
    auto_pr_ops_render_evidence \"\$eval_json\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"eligible=false"* ]]
  [[ "$output" == *"refused="* ]]
  [[ "$output" == *"not_draft"* ]]
}


# ─── Gate key ordering is stable ──────────────────────────────────────────

@test "ORCH_AUTO_PR_OPS_GATE_KEYS lists every gate in stable order" {
  run bash -c "source '$TK/lib/autonomous_pr_ops.sh' && \
    printf '%s\n' \"\${ORCH_AUTO_PR_OPS_GATE_KEYS[@]}\""
  [ "$status" -eq 0 ]
  expected="policy_enabled
not_kill_switched
merge_strategy_valid
target_branch_allowed
not_draft
mergeable_known_clean
required_checks_pass
required_reviews_satisfied
no_release_gate_label
no_business_scope_exclusion"
  [[ "$output" == "$expected" ]]
}
