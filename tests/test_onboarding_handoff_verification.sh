#!/usr/bin/env bash
# tests/test_onboarding_handoff_verification.sh -- coverage for issue #256.
#
# Verifies the durable contract that ORDO's onboarding extensions, issue-pack
# handoff, and external-agent example configurations expose to operators:
#
#   1. Multi-config example fixtures source cleanly under the external-profile
#      contract and do not hardcode RBOK-specific topology.
#   2. Templates (dispatch, briefings, issue-pack) define the required
#      structural fields and contain no obvious secret material.
#   3. Documentation references for onboarding, dispatch planning, controlled
#      operations, and (when present) issue-pack handoff are reachable from
#      README.md or the docs index.
#   4. The local-agent standard flow stops after the orchestrator
#      notification: the issue-pack handoff doc, when present, codifies both
#      the "do not dispatch" boundary and a stop sentinel.
#   5. The existing guided-onboarding test anchors still exist as files so
#      future contributors do not silently delete them.
#
# Items 1, 2, 3 (always-applicable parts), and 5 always run.
# Items 4 and the issue-pack-specific parts of items 2 and 3 activate when the
# corresponding documentation/template files have landed on main, and are
# skipped with a clear "depends on" message otherwise.
#
# The test is intentionally CI-friendly: pure text/source checks, no external
# providers, no network, runs in well under the orch's 60-second smoke budget.
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

skip_note() {
  printf '#  skip: %s\n' "$*" >&2
}

# ----------------------------------------------------------------------------
# 5. Existing onboarding/handoff test anchors still exist.
# Catches the "silently deleted the existing test architecture" regression
# without re-running the heavy onboarding suites locally.
for anchor in \
  tests/test_guided_onboarding.sh \
  tests/test_onboarding_verification.sh \
  tests/test_fleet_provisioning.sh \
  tests/test_examples_config.sh \
  tests/test_portfolio_config.sh \
  scripts/run_shell_tests.sh
do
  [[ -f "$ROOT/$anchor" ]] || fail "missing onboarding test anchor: $anchor (acceptance #5)"
done

# ----------------------------------------------------------------------------
# 1. Multi-config example fixtures: every examples/*.config.sh sources
# cleanly under the external-profile contract pattern, and no example
# hardcodes RBOK-specific topology.
external_profile="$TEST_TMP/external-project.config.sh"
cat > "$external_profile" <<EOF
PROJECT="external-project"
GH_REPO="example-org/external-project"
DEFAULT_BRANCH="main"
GH_CONFIG_DIR="$TEST_TMP/gh"
AGENT_REPO_PREFIX="$TEST_TMP/repos/"
export AGENT_WORKDIR_TEMPLATE="$TEST_TMP/repos/%s"
AGENT_PANES=(
  "agent|agent:0.0|$TEST_TMP/repos/agent"
)
PROJECT_REPO_ROOT="$TEST_TMP/repos/orchestrator"
SUPERVISOR_REPO="$TEST_TMP/repos/orchestrator"
AUDIT_LOG_FILE="$TEST_TMP/external-project.log"
EOF

example_count=0
for cfg in "$ROOT"/examples/*.config.sh; do
  [[ -f "$cfg" ]] || continue
  example_count=$((example_count + 1))
  base=$(basename "$cfg")
  sanitized="$TEST_TMP/$base"
  tr -d '\r' < "$cfg" > "$sanitized"
  set +u
  prefix_or_portfolio=$(
    unset AGENT_REPO_PREFIX PROJECT GH_REPO DEFAULT_BRANCH GH_CONFIG_DIR \
          AGENT_SESSION_PREFIX AGENT_WORKDIR_TEMPLATE AUDIT_LOG_FILE \
          PORTFOLIO_PROJECTS PORTFOLIO_NAME
    # shellcheck disable=SC1090
    ORDO_PROJECT_PROFILE="$external_profile" source "$sanitized" >/dev/null 2>&1 || {
      printf '__source_failed__'
      exit 0
    }
    if [[ -n "${PORTFOLIO_PROJECTS+x}" ]]; then
      printf '__portfolio__'
    else
      printf '%s' "${AGENT_REPO_PREFIX:-}"
    fi
  )
  set -u
  if [[ "$prefix_or_portfolio" == "__source_failed__" ]]; then
    fail "$base failed to source under the external-profile contract (acceptance #1)"
  fi
  [[ -n "$prefix_or_portfolio" ]] || \
    fail "$base did not expose AGENT_REPO_PREFIX or declare a portfolio (acceptance #1)"
done

[[ "$example_count" -ge 3 ]] || \
  fail "expected at least 3 example configs under examples/, found $example_count (acceptance #1)"

# RBOK-specific hardcoding scan across every example config.
rbok_hardcoded_pattern='RBOKproject|/root/repos|/root/rbokproject-fleet|(^|[^a-zA-Z0-9_-])RBOK-[A-Za-z0-9_-]+|(^|[^a-zA-Z0-9_-])rbok-(claude|codex|copilot|cursor|gemini)\b'
for cfg in "$ROOT"/examples/*.config.sh; do
  [[ -f "$cfg" ]] || continue
  if grep -Eq "$rbok_hardcoded_pattern" "$cfg"; then
    leak=$(grep -nE "$rbok_hardcoded_pattern" "$cfg" | head -3)
    fail "$(basename "$cfg") hardcodes RBOK-specific topology — must use neutral example values (acceptance #1):
$leak"
  fi
done

# Portfolio example must declare the durable portfolio fields, not live names.
portfolio_cfg="$ROOT/examples/portfolio.config.sh"
if [[ -f "$portfolio_cfg" ]]; then
  for required in PORTFOLIO_NAME PORTFOLIO_PROJECTS PORTFOLIO_FLEET_AGENTS; do
    grep -q "^$required=" "$portfolio_cfg" || \
      grep -q "^$required\b" "$portfolio_cfg" || \
      fail "portfolio.config.sh missing required field: $required (acceptance #1)"
  done
fi

# ----------------------------------------------------------------------------
# 2. Templates: secret hygiene + structural required-fields for the existing
# briefing/dispatch templates, plus issue-pack templates when present.
secret_pattern='ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|ghu_[A-Za-z0-9]{20,}|ghs_[A-Za-z0-9]{20,}|ghr_[A-Za-z0-9]{20,}|xox[abp]-[A-Za-z0-9-]{10,}|sk-(live|test)_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|Bearer[[:space:]]+ey[A-Za-z0-9._-]{20,}|BEGIN[[:space:]]+(RSA|OPENSSH|EC|DSA|PGP)[[:space:]]+PRIVATE[[:space:]]+KEY'

template_count=0
while IFS= read -r tpl; do
  [[ -f "$tpl" ]] || continue
  template_count=$((template_count + 1))
  if grep -Eq "$secret_pattern" "$tpl"; then
    fail "$(basename "$tpl") contains an obvious secret pattern (acceptance #3)"
  fi
done < <(find "$ROOT/templates" -type f \( -name '*.md' -o -name '*.tpl' \) 2>/dev/null)

[[ "$template_count" -ge 1 ]] || \
  fail "expected at least one template under templates/, found none (acceptance #3)"

# Existing briefing/dispatch templates must keep their identity-verification
# and base-SHA-verification rules. These are the durable contract that the
# orch enforces; deleting them would silently weaken every dispatch.
canonical_dispatch="$ROOT/templates/dispatch-canonical.md.tpl"
if [[ -f "$canonical_dispatch" ]]; then
  grep -q 'git config user.name' "$canonical_dispatch" || \
    fail "templates/dispatch-canonical.md.tpl must require git identity verification (acceptance #3)"
  grep -qE 'base[[:space:]]*SHA|base[[:space:]]+ref|base_sha' "$canonical_dispatch" || \
    fail "templates/dispatch-canonical.md.tpl must require base SHA verification (acceptance #3)"
fi

agent_briefing="$ROOT/templates/agent_briefing.md"
if [[ -f "$agent_briefing" ]]; then
  grep -qiE 'git[[:space:]]+identity|user\.name' "$agent_briefing" || \
    fail "templates/agent_briefing.md must reference git-identity verification (acceptance #3)"
fi

# Issue-pack templates (PR #274 / issue #251). When the directory exists, the
# three canonical templates must be present and each must declare the
# required structural fields without leaking secrets. When the directory is
# absent, skip with a clear note so reviewers can see the dependency.
issue_pack_dir="$ROOT/templates/issue-pack"
if [[ -d "$issue_pack_dir" ]]; then
  for required in nuclear-epic.md child-issue.md issue-pack-ready.md; do
    [[ -f "$issue_pack_dir/$required" ]] || \
      fail "templates/issue-pack/$required missing (acceptance #2 + #3)"
  done

  grep -qE 'audit_id|handoff' "$issue_pack_dir/nuclear-epic.md" || \
    fail "templates/issue-pack/nuclear-epic.md must declare a handoff audit_id field (acceptance #3)"
  grep -qE 'Parent epic|parent[[:space:]]+epic' "$issue_pack_dir/child-issue.md" || \
    fail "templates/issue-pack/child-issue.md must declare the Parent epic field (acceptance #3)"
  grep -qiE 'NEW ISSUE PACK READY' "$issue_pack_dir/issue-pack-ready.md" || \
    fail "templates/issue-pack/issue-pack-ready.md must include the NEW ISSUE PACK READY notification token (acceptance #2)"
  grep -qE 'ORCH_NOTIFY_TARGET|notify_target|notification target' "$issue_pack_dir/issue-pack-ready.md" || \
    fail "templates/issue-pack/issue-pack-ready.md must declare a configurable notification target (acceptance #2)"
else
  skip_note "templates/issue-pack/ not yet on main — depends on issue #251 (PR landing)"
fi

# ----------------------------------------------------------------------------
# 3. Documentation references for the always-on docs are reachable from
# README.md or the docs index. Always-on docs:
#   - docs/dispatch-planning.md
#   - docs/universal-fleet-manual.md
#   - docs/controlled-operations.md
docs_index="$ROOT/docs/INDEX.md"
readme="$ROOT/README.md"

doc_reachable() {
  local target=$1
  if grep -q "$target" "$readme" 2>/dev/null; then
    return 0
  fi
  if [[ -f "$docs_index" ]] && grep -q "$target" "$docs_index" 2>/dev/null; then
    return 0
  fi
  return 1
}

for required_doc in \
  docs/dispatch-planning.md \
  docs/universal-fleet-manual.md \
  docs/controlled-operations.md
do
  [[ -f "$ROOT/$required_doc" ]] || \
    fail "required documentation file missing: $required_doc (acceptance #2)"
  doc_reachable "$required_doc" || \
    fail "$required_doc not reachable from README.md or docs/INDEX.md (acceptance #2)"
done

# ----------------------------------------------------------------------------
# 4. Local-agent flow stops after orchestrator notification.
# When docs/issue-pack-handoff.md is present, it must codify both the
# "do not dispatch" boundary and a stop sentinel, and it must be reachable
# from README.md or docs/INDEX.md so an operator can find it without chat
# history.
handoff_doc="$ROOT/docs/issue-pack-handoff.md"
if [[ -f "$handoff_doc" ]]; then
  grep -qiE 'must not dispatch|do not dispatch|never[[:space:]]+dispatch' "$handoff_doc" || \
    fail "docs/issue-pack-handoff.md must codify the 'do not dispatch' boundary (acceptance #4)"
  grep -qE '(^|[^A-Za-z])[Ss]top[\.[:space:]]' "$handoff_doc" || \
    fail "docs/issue-pack-handoff.md must include a stop sentinel after notification (acceptance #4)"
  grep -qE 'NEW ISSUE PACK READY|notification|notify' "$handoff_doc" || \
    fail "docs/issue-pack-handoff.md must reference the orchestrator notification step (acceptance #4)"
  doc_reachable "docs/issue-pack-handoff.md" || \
    fail "docs/issue-pack-handoff.md exists but is not reachable from README.md or docs/INDEX.md (acceptance #2)"
else
  skip_note "docs/issue-pack-handoff.md not yet on main — local-agent stop check depends on issue #251 (PR landing)"
fi

# ----------------------------------------------------------------------------
# Final summary line.
printf 'ok - onboarding/handoff/multi-config examples verification (#256): %d example configs, %d templates checked\n' \
  "$example_count" "$template_count"
