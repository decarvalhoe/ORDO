#!/usr/bin/env bash
# test_brief_agents_validation_sufficiency.sh — issue #724.
#
# brief_agents.sh must invoke the validation_sufficiency gate after the
# brief's validation_command is assembled. The gate has three modes:
#   * `off`             -> gate is a no-op (legacy behavior).
#   * `auto-augment`    -> default; prepends the canonical class
#                          invocation to validation_command, emits one
#                          BRIEF_VALIDATION_AUTO_AUGMENTED audit row per
#                          missing class, and the augmented command
#                          appears 1:1 in the rendered brief.
#   * `enforce`         -> refuses the dispatch with exit 88, a clear
#                          stderr blocker, and a BRIEF_VALIDATION_INSUFFICIENT
#                          audit row when scope classes are uncovered.
#
# Briefs are exempted in two situations:
#   * `validation_policy != dispatch-provided` (CI-delegated and
#     require-local-validators briefs are covered by other guardrails).
#   * The source body declares `- validation-policy-exception: <reason>`
#     in the same shape as `- external-pr-mutations: <scopes>`.
#
# This test pins all four acceptance-criteria cases from #724:
#   (i)   clean shell scope already covered by shellcheck     -> no augment, no refusal
#   (ii)  shell scope without shellcheck under enforce        -> exit 88 refusal
#   (iii) shell scope without shellcheck under auto-augment   -> brief augmented, audit row emitted
#   (iv)  validation-policy-exception waiver in source body   -> gate bypassed
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
SANITIZED_ROOT="$TEST_TMP/toolkit"

cleanup() { rm -rf "$TEST_TMP"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }

mkdir -p "$TEST_TMP/logs" "$TEST_TMP/repos/claude" "$TEST_TMP/bin"
# Seed the worker workdir with real files that match each scope_files
# entry, so brief_agents' scope-path warning helper does not spam the
# stderr we assert against.
: > "$TEST_TMP/repos/claude/lib_validation_sufficiency.sh"
: > "$TEST_TMP/repos/claude/scripts_brief_agents.sh"
: > "$TEST_TMP/repos/claude/src_bar.py"

# Fast `gh` stub so the source-substance fetch returns immediately and
# does not eat the 15s timeout on every invocation.
cat > "$TEST_TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
chmod +x "$TEST_TMP/bin/gh"
export PATH="$TEST_TMP/bin:$PATH"

# shellcheck source=../lib/test_sanitize.sh
source "$ROOT/lib/test_sanitize.sh"
sanitize_toolkit_copy "$SANITIZED_ROOT" \
  scripts/brief_agents.sh \
  templates/dispatch-canonical.md.tpl
chmod +x "$SANITIZED_ROOT/scripts/brief_agents.sh"

cat > "$TEST_TMP/test.config.sh" <<EOF
#!/usr/bin/env bash
PROJECT="brief-validation-sufficiency"
GH_REPO="RBOKproject/ORDO"
GH_CONFIG_DIR="$TEST_TMP/gh"
DEFAULT_BRANCH="main"
AGENT_SESSION_PREFIX=""
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
SUPERVISOR_REPO="origin"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
EOF

audit_log="$TEST_TMP/logs/brief-validation-sufficiency.log"

run_brief() {
  local agent=$1; shift
  local ticket=$1; shift
  ORCH_LOG_DIR="$TEST_TMP/logs" \
  ORCH_SOURCE_FETCH_TIMEOUT_SEC=2 \
  bash "$SANITIZED_ROOT/scripts/brief_agents.sh" \
    "$TEST_TMP/test.config.sh" \
    "$agent" "$ticket" \
    "$@"
}

# --- Case (i): clean shell-scope brief with shellcheck token present -----

clean_out="$TEST_TMP/clean.md"
clean_err="$TEST_TMP/clean.err"
run_brief claude 7241 \
  summary="clean shell scope already covered" \
  scope_files="lib_validation_sufficiency.sh" \
  validation="timeout 60 shellcheck lib_validation_sufficiency.sh" \
  > "$clean_out" 2> "$clean_err"

[[ -s "$clean_out" ]] \
  || fail "case (i) clean scope must still render the brief"
! grep -Fq "auto-augmented for scope class" "$clean_out" \
  || fail "case (i) clean scope must NOT carry an auto-augmented annotation"
! grep -Fq "VALIDATION_AUTO_AUGMENTED ticket=#7241" "$audit_log" \
  || fail "case (i) clean scope must NOT emit BRIEF_VALIDATION_AUTO_AUGMENTED"
! grep -Fq "VALIDATION_INSUFFICIENT ticket=#7241" "$audit_log" \
  || fail "case (i) clean scope must NOT emit BRIEF_VALIDATION_INSUFFICIENT"
grep -Fq "timeout 60 shellcheck lib_validation_sufficiency.sh" "$clean_out" \
  || fail "case (i) clean scope must keep operator validation in the rendered brief"

# --- Case (ii): shell scope missing shellcheck under enforce -> refuse ---

enforce_out="$TEST_TMP/enforce.md"
enforce_err="$TEST_TMP/enforce.err"
set +e
run_brief claude 7242 \
  --validation-sufficiency=enforce \
  summary="refuse insufficient shell validation" \
  scope_files="lib_validation_sufficiency.sh" \
  validation="timeout 60 bash -n lib_validation_sufficiency.sh" \
  > "$enforce_out" 2> "$enforce_err"
enforce_rc=$?
set -e

[[ "$enforce_rc" -eq 88 ]] \
  || fail "case (ii) enforce mode must exit 88 on insufficient validation (got: $enforce_rc, stderr: $(cat "$enforce_err"))"
[[ ! -s "$enforce_out" ]] \
  || fail "case (ii) enforce mode must NOT render a brief when refusing"
grep -Fq "BRIEF_VALIDATION_INSUFFICIENT" "$enforce_err" \
  || fail "case (ii) enforce mode must surface BRIEF_VALIDATION_INSUFFICIENT on stderr"
grep -Fq "missing_classes=sh" "$enforce_err" \
  || fail "case (ii) enforce stderr must list the missing class"
grep -Fq "validation-policy-exception" "$enforce_err" \
  || fail "case (ii) enforce stderr must advertise the exception escape hatch"
grep -Fq "auto-augment" "$enforce_err" \
  || fail "case (ii) enforce stderr must advertise the --validation-sufficiency=auto-augment opt-out"
grep -Fq "BRIEF VALIDATION_INSUFFICIENT" "$audit_log" \
  || fail "case (ii) enforce must emit a BRIEF VALIDATION_INSUFFICIENT audit row"
grep -Fq "ticket=#7242" "$audit_log" \
  || fail "case (ii) audit row must name the refused ticket"
grep -Fq "missing_classes=sh" "$audit_log" \
  || fail "case (ii) audit row must record missing_classes"

# --- Case (iii): shell scope missing shellcheck under auto-augment -------

aug_out="$TEST_TMP/augment.md"
aug_err="$TEST_TMP/augment.err"
run_brief claude 7243 \
  --validation-sufficiency=auto-augment \
  summary="augment missing shell validation" \
  scope_files="lib_validation_sufficiency.sh" \
  validation="timeout 60 bash -n lib_validation_sufficiency.sh" \
  > "$aug_out" 2> "$aug_err"

[[ -s "$aug_out" ]] \
  || fail "case (iii) auto-augment must still render the brief"
grep -Fq "# brief_agents: auto-augmented for scope class sh" "$aug_out" \
  || fail "case (iii) auto-augment must annotate the inserted line with the canonical comment"
grep -Fq "shellcheck" "$aug_out" \
  || fail "case (iii) auto-augment must include the canonical sh invocation (shellcheck) in the rendered brief"
# The operator's original validation must still appear after the augment.
grep -Fq "timeout 60 bash -n lib_validation_sufficiency.sh" "$aug_out" \
  || fail "case (iii) auto-augment must preserve the operator's original validation"
grep -Fq "BRIEF VALIDATION_AUTO_AUGMENTED" "$audit_log" \
  || fail "case (iii) auto-augment must emit a BRIEF VALIDATION_AUTO_AUGMENTED audit row"
grep -Fq "scope_class=sh added=shellcheck" "$audit_log" \
  || fail "case (iii) audit row must follow the scope_class=<class> added=<cmd> format"
grep -Fq "ticket=#7243" "$audit_log" \
  || fail "case (iii) audit row must name the augmented ticket"

# Cross-check: the augmented validation_command in the rendered brief
# 1:1 reflects what the gate inserted (acceptance criterion 4). The
# rendered single-line form joins the annotation comment, the inserted
# canonical invocation, and the operator's original validation with `&&`.
grep -Fq 'validation_command=# brief_agents: auto-augmented for scope class sh && shellcheck $(git ls-files "*.sh" "*.bash") && timeout 60 bash -n lib_validation_sufficiency.sh' "$aug_out" \
  || fail "case (iii) rendered validation_command must reflect the augmentation 1:1"

# --- Case (iv): source-body waiver bypasses the gate ---------------------

# Stub `gh issue view` to return a body containing a validation-policy-
# exception declaration so brief_agents picks it up via
# brief_prepare_source_substance.
cat > "$TEST_TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
# minimal stub: emit a JSON object with a body that carries the waiver.
cat <<'JSON'
{
  "title": "ticket with waiver",
  "url": "https://github.com/RBOKproject/ORDO/issues/7244",
  "body": "Implementation note:\n\n- validation-policy-exception: legacy shell file is third-party\n\nProceed without shellcheck."
}
JSON
GH
chmod +x "$TEST_TMP/bin/gh"

waiver_out="$TEST_TMP/waiver.md"
waiver_err="$TEST_TMP/waiver.err"
run_brief claude 7244 \
  --validation-sufficiency=enforce \
  summary="waiver bypass under enforce" \
  scope_files="lib_validation_sufficiency.sh" \
  validation="timeout 60 bash -n lib_validation_sufficiency.sh" \
  > "$waiver_out" 2> "$waiver_err"

[[ -s "$waiver_out" ]] \
  || fail "case (iv) waiver must let enforce mode render the brief"
! grep -Fq "BRIEF_VALIDATION_INSUFFICIENT" "$waiver_err" \
  || fail "case (iv) waiver must suppress the insufficient-validation refusal"
grep -Fq "BRIEF VALIDATION_POLICY_EXCEPTION" "$audit_log" \
  || fail "case (iv) waiver must emit a BRIEF VALIDATION_POLICY_EXCEPTION audit row"
grep -Fq "ticket=#7244" "$audit_log" \
  || fail "case (iv) waiver audit row must name the ticket"
grep -Fq "reason=source_body_declaration" "$audit_log" \
  || fail "case (iv) waiver audit row must record the waiver source"

# --- Case (v): off mode is a true no-op (regression guard) ---------------

off_out="$TEST_TMP/off.md"
off_err="$TEST_TMP/off.err"
run_brief claude 7245 \
  --validation-sufficiency=off \
  summary="off mode is a no-op" \
  scope_files="lib_validation_sufficiency.sh" \
  validation="timeout 60 bash -n lib_validation_sufficiency.sh" \
  > "$off_out" 2> "$off_err"

[[ -s "$off_out" ]] \
  || fail "case (v) off mode must let the brief render"
! grep -Fq "auto-augmented" "$off_out" \
  || fail "case (v) off mode must NOT inject augmentation"
! grep -Fq "BRIEF VALIDATION_AUTO_AUGMENTED ticket=#7245" "$audit_log" \
  || fail "case (v) off mode must NOT emit auto-augmentation audit"
! grep -Fq "BRIEF VALIDATION_INSUFFICIENT ticket=#7245" "$audit_log" \
  || fail "case (v) off mode must NOT emit refusal audit"

printf 'ok - brief_agents validation_sufficiency gate covers #724 acceptance criteria (clean, enforce, auto-augment, waiver, off)\n'
