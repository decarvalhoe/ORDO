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

mkdir -p "$SANITIZED_ROOT/scripts" "$SANITIZED_ROOT/lib" "$TEST_TMP/configs" "$TEST_TMP/repos"

for rel in \
  scripts/portfolio_session_start.sh \
  lib/agent_inventory.sh \
  lib/config_resolver.sh \
  lib/dry_run.sh \
  lib/portfolio_config.sh
do
  tr -d '\r' < "$ROOT/$rel" > "$SANITIZED_ROOT/$rel"
done
chmod +x "$SANITIZED_ROOT/scripts/portfolio_session_start.sh"

configure_git() {
  local repo=$1
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name "Portfolio Session Test"
}

remote_repo="$TEST_TMP/remote.git"
seed_repo="$TEST_TMP/seed"
git init -q --bare "$remote_repo"
git init -q "$seed_repo"
configure_git "$seed_repo"
printf 'v1\n' > "$seed_repo/file.txt"
git -C "$seed_repo" add file.txt
git -C "$seed_repo" commit -q -m 'initial'
git -C "$seed_repo" branch -M main
git -C "$seed_repo" remote add origin "$remote_repo"
git -C "$seed_repo" push -q -u origin main
git -C "$remote_repo" symbolic-ref HEAD refs/heads/main

behind_clone="$TEST_TMP/repos/behind"
git clone -q "$remote_repo" "$behind_clone"
configure_git "$behind_clone"

printf 'v2\n' > "$seed_repo/file.txt"
git -C "$seed_repo" add file.txt
git -C "$seed_repo" commit -q -m 'update'
git -C "$seed_repo" push -q origin main

ready_clone="$TEST_TMP/repos/ready"
dirty_clone="$TEST_TMP/repos/dirty"
missing_clone="$TEST_TMP/repos/missing"
matrix_clone="$TEST_TMP/repos/matrix"
no_identity_clone="$TEST_TMP/repos/no_identity"
git clone -q "$remote_repo" "$ready_clone"
git clone -q "$remote_repo" "$dirty_clone"
git clone -q "$remote_repo" "$no_identity_clone"
configure_git "$ready_clone"
configure_git "$dirty_clone"
# no_identity_clone deliberately has no local user.name / user.email
git -C "$no_identity_clone" config --local --unset-all user.name 2>/dev/null || true
git -C "$no_identity_clone" config --local --unset-all user.email 2>/dev/null || true
printf 'dirty\n' > "$dirty_clone/dirty.txt"

cat > "$TEST_TMP/configs/product.config.sh" <<EOF
PROJECT="product"
GH_REPO=""
DEFAULT_BRANCH="main"
REPO_URL="$remote_repo"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_GIT_IDENTITY_NAME_TEMPLATE="ORDO Agent %s"
AGENT_GIT_IDENTITY_EMAIL_TEMPLATE="%s@noreply.test.invalid"
AGENT_GIT_IDENTITIES=(
  "ready|Override Ready|ready-override@noreply.test.invalid"
)
AGENT_PANES=(
  "ready|product-ready:0.0|$ready_clone"
  "behind|product-behind:0.0|$behind_clone"
  "dirty|product-dirty:0.0|$dirty_clone"
  "missing|product-missing:0.0|$missing_clone"
  "no_identity|product-no-identity:0.0|$no_identity_clone"
)
EOF

cat > "$TEST_TMP/configs/portfolio.config.sh" <<EOF
PORTFOLIO_NAME="test"
PORTFOLIO_PROJECTS=(
  "product|$TEST_TMP/configs/product.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "product=100"
)
PORTFOLIO_FLEET_AGENTS=(
  "ready|product-ready:0.0"
  "matrix|product-matrix:0.0"
)
EOF

json_output=$(
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/portfolio_session_start.sh" "$TEST_TMP/configs/portfolio.config.sh" --json
)
printf '%s\n' "$json_output" | jq -e '.[] | select(.alias == "product" and .priority == 100 and .priority_mode == "explicit")' >/dev/null \
  || fail "priority should be recorded: $json_output"
printf '%s\n' "$json_output" | jq -e '.[] | select(.label == "ready" and .status == "ready")' >/dev/null \
  || fail "ready clone should be ready: $json_output"
printf '%s\n' "$json_output" | jq -e '.[] | select(.label == "behind" and .status == "behind_default" and .behind == 1)' >/dev/null \
  || fail "behind clone should be detected: $json_output"
printf '%s\n' "$json_output" | jq -e '.[] | select(.label == "dirty" and .status == "dirty_worktree")' >/dev/null \
  || fail "dirty clone should be detected: $json_output"
printf '%s\n' "$json_output" | jq -e '.[] | select(.label == "missing" and .status == "missing_clone")' >/dev/null \
  || fail "missing clone should be detected: $json_output"
printf '%s\n' "$json_output" | jq -e '.[] | select(.label == "matrix" and .source == "portfolio_matrix" and .status == "missing_clone" and .safe_apply == 1 and .remediation_action == "clone" and (.remediation_command | contains("git clone")))' >/dev/null \
  || fail "matrix clone should be proposed with clone command: $json_output"
printf '%s\n' "$json_output" | jq -e '.[] | select(.label == "ready" and .identity_complete == 1 and .identity_name == "Portfolio Session Test")' >/dev/null \
  || fail "ready clone should report local identity: $json_output"
printf '%s\n' "$json_output" | jq -e '.[] | select(.label == "no_identity" and .status == "missing_git_identity" and .identity_complete == 0 and .safe_apply == 1 and .remediation_action == "set-git-identity" and (.remediation_command | contains("user.name")) and (.remediation_command | contains("user.email")) and .target_identity_name == "ORDO Agent no_identity" and .target_identity_email == "no_identity@noreply.test.invalid")' >/dev/null \
  || fail "no_identity clone should be detected with safe-apply identity remediation: $json_output"
printf '%s\n' "$json_output" | jq -e '.[] | select(.label == "ready" and .target_identity_name == "Override Ready" and .target_identity_email == "ready-override@noreply.test.invalid")' >/dev/null \
  || fail "ready clone target identity should reflect AGENT_GIT_IDENTITIES override: $json_output"
[[ -s "$TEST_TMP/state/_portfolio/session_start.json" ]] || fail "session start should persist latest report"
[[ -s "$TEST_TMP/state/_portfolio/clean_plan.json" ]] || fail "session start should persist clean plan"
[[ -s "$TEST_TMP/state/_portfolio/PREFLIGHT_CLEAN_PLAN.md" ]] || fail "session start should persist clean plan markdown"
[[ -s "$TEST_TMP/state/_portfolio/unblock_tasks.json" ]] || fail "session start should persist unblock tasks"
[[ -s "$TEST_TMP/state/_portfolio/ORCH_TASKS.md" ]] || fail "session start should persist orch tasks"
printf '%s\n' "$(cat "$TEST_TMP/state/_portfolio/clean_plan.json")" | jq -e '.[] | select(.label == "behind" and .unblock_code == "preflight-behind_default" and (.recommended_action | contains("pull --ff-only")))' >/dev/null \
  || fail "behind clone should be promoted into clean plan"
printf '%s\n' "$(cat "$TEST_TMP/state/_portfolio/clean_plan.json")" | jq -e '.[] | select(.label == "dirty" and .unblock_code == "preflight-dirty_worktree")' >/dev/null \
  || fail "dirty clone should be promoted into clean plan"
printf '%s\n' "$(cat "$TEST_TMP/state/_portfolio/clean_plan.json")" | jq -e '.[] | select(.label == "no_identity" and .unblock_code == "preflight-missing_git_identity" and (.recommended_action | contains("user.name")) and (.recommended_action | contains("user.email")))' >/dev/null \
  || fail "no_identity clone should be promoted into clean plan with user.name+user.email remediation"
grep -q 'preflight-dirty_worktree' "$TEST_TMP/state/_portfolio/ORCH_TASKS.md" \
  || fail "dirty preflight blocker should be visible in ORCH_TASKS"
grep -q 'preflight-behind_default' "$TEST_TMP/state/_portfolio/ORCH_TASKS.md" \
  || fail "safe preflight blocker should be visible in ORCH_TASKS before apply"
grep -q 'preflight-missing_git_identity' "$TEST_TMP/state/_portfolio/ORCH_TASKS.md" \
  || fail "identity preflight blocker should be visible in ORCH_TASKS before apply"

cat > "$TEST_TMP/configs/no-priority.config.sh" <<EOF
PORTFOLIO_NAME="missing-priority"
PORTFOLIO_PROJECTS=(
  "product|$TEST_TMP/configs/product.config.sh"
)
EOF

set +e
missing_output=$(
  ORCH_STATE_BASE="$TEST_TMP/missing-state" \
  bash "$SANITIZED_ROOT/scripts/portfolio_session_start.sh" "$TEST_TMP/configs/no-priority.config.sh" --json 2>&1
)
missing_status=$?
set -e
[[ "$missing_status" -eq 14 ]] || fail "missing priorities should exit 14, got $missing_status: $missing_output"
[[ "$missing_output" == *'portfolio priorities are required'* ]] || fail "missing priority prompt not explicit: $missing_output"

yolo_json=$(
  ORCH_STATE_BASE="$TEST_TMP/yolo-state" \
  bash "$SANITIZED_ROOT/scripts/portfolio_session_start.sh" "$TEST_TMP/configs/no-priority.config.sh" --json --yolo-priority
)
printf '%s\n' "$yolo_json" | jq -e '.[] | select(.alias == "product" and .priority_mode == "yolo" and .priority == 10)' >/dev/null \
  || fail "yolo priority should be recorded: $yolo_json"

dry_err="$TEST_TMP/dry.err"
dry_json=$(
  ORCH_STATE_BASE="$TEST_TMP/dry-state" \
  bash "$SANITIZED_ROOT/scripts/portfolio_session_start.sh" "$TEST_TMP/configs/portfolio.config.sh" --json --apply --dry-run 2>"$dry_err"
)
printf '%s\n' "$dry_json" | jq -e '.[] | select(.label == "missing" and .applied == "clone")' >/dev/null \
  || fail "dry-run apply should report clone action: $dry_json"
printf '%s\n' "$dry_json" | jq -e '.[] | select(.label == "matrix" and .source == "portfolio_matrix" and .applied == "clone")' >/dev/null \
  || fail "dry-run apply should report matrix clone action: $dry_json"
printf '%s\n' "$dry_json" | jq -e '.[] | select(.label == "no_identity" and .applied == "set-git-identity" and .status == "ready")' >/dev/null \
  || fail "dry-run apply should report set-git-identity action for no_identity clone: $dry_json"
grep -q 'DRY-RUN: git clone' "$dry_err" || fail "dry-run should print clone remediation"
grep -q 'DRY-RUN: git -C .* config user.name' "$dry_err" \
  || fail "dry-run should print set-git-identity remediation: $(cat "$dry_err")"
[[ ! -e "$missing_clone" ]] || fail "dry-run should not create missing clone"
[[ ! -e "$matrix_clone" ]] || fail "dry-run should not create matrix clone"
[[ -z "$(git -C "$no_identity_clone" config --local user.name 2>/dev/null || true)" ]] \
  || fail "dry-run should not actually set user.name on no_identity clone"
[[ -z "$(git -C "$no_identity_clone" config --local user.email 2>/dev/null || true)" ]] \
  || fail "dry-run should not actually set user.email on no_identity clone"
[[ ! -e "$TEST_TMP/dry-state/_portfolio/session_start.json" ]] || fail "dry-run should not persist session report"
[[ ! -e "$TEST_TMP/dry-state/_portfolio/clean_plan.json" ]] || fail "dry-run should not persist clean plan"

apply_json=$(
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/portfolio_session_start.sh" "$TEST_TMP/configs/portfolio.config.sh" --json --apply
)
printf '%s\n' "$apply_json" | jq -e '.[] | select(.label == "missing" and .status == "ready" and (.applied | contains("clone")) and .safe_apply == 0 and .remediation_action == null)' >/dev/null \
  || fail "apply should clone missing workdir: $apply_json"
printf '%s\n' "$apply_json" | jq -e '.[] | select(.label == "matrix" and .source == "portfolio_matrix" and .status == "ready" and (.applied | contains("clone")) and .safe_apply == 0 and .remediation_action == null)' >/dev/null \
  || fail "apply should clone missing matrix workdir: $apply_json"
printf '%s\n' "$apply_json" | jq -e '.[] | select(.label == "behind" and .status == "ready" and (.applied | contains("pull-ff-only")) and .safe_apply == 0 and .remediation_action == null)' >/dev/null \
  || fail "apply should fast-forward behind clone: $apply_json"
printf '%s\n' "$apply_json" | jq -e '.[] | select(.label == "no_identity" and .status == "ready" and .applied == "set-git-identity" and .identity_complete == 1 and .identity_name == "ORDO Agent no_identity" and .identity_email == "no_identity@noreply.test.invalid" and .safe_apply == 0 and .remediation_action == null)' >/dev/null \
  || fail "apply should set local git identity on no_identity clone: $apply_json"
printf '%s\n' "$apply_json" | jq -e '.[] | select(.label == "missing" and (.applied | contains("set-git-identity")) and .identity_complete == 1)' >/dev/null \
  || fail "apply should also set identity on freshly-cloned missing workdir: $apply_json"
[[ -d "$missing_clone/.git" ]] || fail "apply should create missing clone"
[[ -d "$matrix_clone/.git" ]] || fail "apply should create missing matrix clone"
git -C "$behind_clone" merge-base --is-ancestor origin/main HEAD \
  || fail "behind clone should be fast-forwarded"
[[ "$(git -C "$no_identity_clone" config --local user.name)" == "ORDO Agent no_identity" ]] \
  || fail "apply should set user.name locally on no_identity clone"
[[ "$(git -C "$no_identity_clone" config --local user.email)" == "no_identity@noreply.test.invalid" ]] \
  || fail "apply should set user.email locally on no_identity clone"
printf '%s\n' "$(cat "$TEST_TMP/state/_portfolio/clean_plan.json")" | jq -e '.[] | select(.label == "dirty" and .unblock_code == "preflight-dirty_worktree")' >/dev/null \
  || fail "dirty blocker should remain in clean plan after safe apply"
if printf '%s\n' "$(cat "$TEST_TMP/state/_portfolio/clean_plan.json")" | jq -e '.[] | select(.label == "behind")' >/dev/null; then
  fail "behind clone should leave clean plan after safe apply"
fi
if printf '%s\n' "$(cat "$TEST_TMP/state/_portfolio/clean_plan.json")" | jq -e '.[] | select(.label == "no_identity")' >/dev/null; then
  fail "no_identity clone should leave clean plan after safe apply"
fi

# --- no-template identity scenario ---
no_template_clone="$TEST_TMP/repos/no_template"
git clone -q "$remote_repo" "$no_template_clone"
git -C "$no_template_clone" config --local --unset-all user.name 2>/dev/null || true
git -C "$no_template_clone" config --local --unset-all user.email 2>/dev/null || true

cat > "$TEST_TMP/configs/no-template.product.config.sh" <<EOF
PROJECT="no_template_product"
GH_REPO=""
DEFAULT_BRANCH="main"
REPO_URL="$remote_repo"
AGENT_PANES=(
  "no_template|no-template-product:0.0|$no_template_clone"
)
EOF

cat > "$TEST_TMP/configs/no-template.portfolio.config.sh" <<EOF
PORTFOLIO_NAME="no_template_test"
PORTFOLIO_PROJECTS=(
  "no_template_product|$TEST_TMP/configs/no-template.product.config.sh"
)
PORTFOLIO_PRIORITIES=(
  "no_template_product=100"
)
EOF

no_template_json=$(
  ORCH_STATE_BASE="$TEST_TMP/no-template-state" \
  bash "$SANITIZED_ROOT/scripts/portfolio_session_start.sh" "$TEST_TMP/configs/no-template.portfolio.config.sh" --json
)
printf '%s\n' "$no_template_json" | jq -e '.[] | select(.label == "no_template" and .status == "missing_git_identity_no_template" and .safe_apply == 0 and .target_identity_name == null and .target_identity_email == null and .remediation_action == "configure-identity-template")' >/dev/null \
  || fail "no-template scenario should report missing_git_identity_no_template with safe_apply=0: $no_template_json"

no_template_apply_err="$TEST_TMP/no-template-apply.err"
no_template_apply_json=$(
  ORCH_STATE_BASE="$TEST_TMP/no-template-state" \
  bash "$SANITIZED_ROOT/scripts/portfolio_session_start.sh" "$TEST_TMP/configs/no-template.portfolio.config.sh" --json --apply 2>"$no_template_apply_err"
)
printf '%s\n' "$no_template_apply_json" | jq -e '.[] | select(.label == "no_template" and .status == "missing_git_identity_no_template" and .applied == null)' >/dev/null \
  || fail "apply without templates must refuse to set identity: $no_template_apply_json"
[[ -z "$(git -C "$no_template_clone" config --local user.name 2>/dev/null || true)" ]] \
  || fail "apply without templates must not set user.name"
[[ -z "$(git -C "$no_template_clone" config --local user.email 2>/dev/null || true)" ]] \
  || fail "apply without templates must not set user.email"
printf '%s\n' "$(cat "$TEST_TMP/no-template-state/_portfolio/clean_plan.json")" | jq -e '.[] | select(.label == "no_template" and .unblock_code == "preflight-missing_git_identity_no_template" and (.recommended_action | contains("AGENT_GIT_IDENTITY_NAME_TEMPLATE")))' >/dev/null \
  || fail "no-template blocker should appear in clean plan with configure guidance"

mkdir -p "$TEST_TMP/state/product"
cat > "$TEST_TMP/state/product/assignments.json" <<'JSON'
{
  "stale-agent": {
    "ticket": "9999",
    "issue": 9999,
    "branch": "feat/issue-9999",
    "workdir": "/tmp/stale-agent",
    "repo_root": "/tmp/stale-agent",
    "prompt_file": "/tmp/dispatch-stale-agent-9999.md",
    "dispatched_at": "2024-01-01T00:00:00Z"
  }
}
JSON

stale_json=$(
  ORCH_STATE_BASE="$TEST_TMP/state" \
  bash "$SANITIZED_ROOT/scripts/portfolio_session_start.sh" "$TEST_TMP/configs/portfolio.config.sh" --json
)
printf '%s\n' "$stale_json" | jq -e '
  .[]
  | select(.label == "stale-agent"
      and .source == "stale_matrix_assignment"
      and .status == "stale_matrix_assignment"
      and .ready == 0
      and .ticket == "9999"
      and (.remediation | contains("assignments.json")))
' >/dev/null \
  || fail "stale matrix assignment should surface in unified report: $stale_json"

printf '%s\n' "$(cat "$TEST_TMP/state/_portfolio/clean_plan.json")" | jq -e '
  .[]
  | select(.label == "stale-agent"
      and .unblock_code == "preflight-stale_matrix_assignment")
' >/dev/null \
  || fail "stale matrix assignment should appear in clean plan"

grep -q 'preflight-stale_matrix_assignment' "$TEST_TMP/state/_portfolio/ORCH_TASKS.md" \
  || fail "stale matrix assignment should appear in ORCH_TASKS"

printf '%s\n' "$stale_json" | jq -e '.[] | select(.label == "ready" and .source == "configured" and .status == "ready")' >/dev/null \
  || fail "configured ready clone should remain visible alongside stale assignments: $stale_json"

printf 'ok - portfolio_session_start audits and remediates clone readiness\n'
