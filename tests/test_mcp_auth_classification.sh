#!/usr/bin/env bash
# tests/test_mcp_auth_classification.sh — coverage for ORDO #670.
#
# `lib/mcp_permission_preflight.sh::mcp_preflight_classify_startup_log`
# MUST distinguish nonblocking MCP auth noise from runtime-fatal tool
# failures. Codex startup on the remote fleet currently emits a
# Cloudflare MCP `invalid_token` / `AuthRequired` line from the rmcp
# transport worker that looks fatal but is nonblocking when the active
# assignment does not need Cloudflare:
#
#   ERROR rmcp::transport::worker: worker quit with fatal
#     { code: 0, message: "AuthRequired" }
#     source=https://mcp.cloudflare.com/sse error=invalid_token
#
# This test asserts the classifier can:
#   - extract the MCP server name from the rmcp/AuthRequired line by
#     parsing the mcp.<host>. URL;
#   - extract names from Codex `<name> MCP server is not logged in.`
#     lines and the aggregate `MCP startup incomplete (failed: ...)`
#     line, deduplicating across both;
#   - mark severity=nonblocking when the failing MCP is not in any
#     required/degraded list, severity=degraded when it is in the
#     degraded list, and severity=blocking when it is in the required
#     list (case-insensitive);
#   - return exit 1 only when at least one failure maps to
#     severity=blocking, so the orch_loop can audit nonblocking noise
#     without treating it as a fleet-fatal startup failure.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

# shellcheck source=lib/mcp_permission_preflight.sh
source "$ROOT/lib/mcp_permission_preflight.sh"

# --- Fixtures ---------------------------------------------------------------

cat > "$TEST_TMP/cloudflare.log" <<'LOG'
INFO codex: starting
ERROR rmcp::transport::worker: worker quit with fatal { code: 0, message: "AuthRequired" } source=https://mcp.cloudflare.com/sse error=invalid_token
INFO codex: continuing
LOG

cat > "$TEST_TMP/codex.log" <<'LOG'
The cloudflare-api MCP server is not logged in. Run codex mcp login cloudflare-api.
MCP startup incomplete (failed: cloudflare-api, gmail)
LOG

cat > "$TEST_TMP/mixed.log" <<'LOG'
ERROR rmcp::transport::worker: worker quit with fatal AuthRequired source=https://mcp.cloudflare.com/sse error=invalid_token
The figma MCP server is not logged in. Run codex mcp login figma.
MCP startup incomplete (failed: figma)
LOG

cat > "$TEST_TMP/clean.log" <<'LOG'
INFO codex: starting
INFO codex: ready
LOG

# --- Detection --------------------------------------------------------------

got=$(mcp_preflight_detect_auth_failure_lines "$TEST_TMP/cloudflare.log")
[[ "$got" == "cloudflare" ]] \
  || fail "expected detection=cloudflare for rmcp/AuthRequired log, got: $got"

got=$(mcp_preflight_detect_auth_failure_lines "$TEST_TMP/codex.log")
got_csv=$(printf '%s' "$got" | tr '\n' ',')
[[ "$got_csv" == "cloudflare-api,gmail" ]] \
  || fail "expected detection=cloudflare-api,gmail (sorted, dedup) for codex log, got: $got_csv"

got=$(mcp_preflight_detect_auth_failure_lines "$TEST_TMP/clean.log")
[[ -z "$got" ]] || fail "expected no detections for clean log, got: $got"

got=$(mcp_preflight_detect_auth_failure_lines "/no/such/log")
[[ -z "$got" ]] || fail "expected no detections for missing log, got: $got"

# --- Severity classifier ----------------------------------------------------

sev=$(mcp_preflight_classify_auth_severity cloudflare "cloudflare,figma" "")
[[ "$sev" == "blocking" ]] || fail "expected severity=blocking for required mcp, got: $sev"

sev=$(mcp_preflight_classify_auth_severity cloudflare "" "cloudflare")
[[ "$sev" == "degraded" ]] || fail "expected severity=degraded for degraded-list mcp, got: $sev"

sev=$(mcp_preflight_classify_auth_severity cloudflare "" "")
[[ "$sev" == "nonblocking" ]] || fail "expected severity=nonblocking when not listed, got: $sev"

sev=$(mcp_preflight_classify_auth_severity Cloudflare "CLOUDFLARE" "")
[[ "$sev" == "blocking" ]] \
  || fail "expected case-insensitive required-list match, got: $sev"

sev=$(mcp_preflight_classify_auth_severity cloudflare "figma, cloudflare ,gmail" "")
[[ "$sev" == "blocking" ]] \
  || fail "expected whitespace-tolerant required csv match, got: $sev"

# Required dominates degraded: when an MCP is in BOTH lists, the
# stricter classification wins so blocked assignments are not silently
# downgraded to degraded.
sev=$(mcp_preflight_classify_auth_severity cloudflare "cloudflare" "cloudflare")
[[ "$sev" == "blocking" ]] \
  || fail "expected required to dominate degraded, got: $sev"

# --- Startup classifier: nonblocking only -----------------------------------

set +e
out=$(mcp_preflight_classify_startup_log "$TEST_TMP/cloudflare.log" "" "")
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "expected rc=0 for nonblocking-only classification, got rc=$rc"
[[ "$out" == *"mcp=cloudflare severity=nonblocking source=startup"* ]] \
  || fail "expected nonblocking record, got: $out"

# --- Startup classifier: blocking when required -----------------------------

set +e
out=$(mcp_preflight_classify_startup_log "$TEST_TMP/cloudflare.log" "cloudflare" "")
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "expected rc=1 when blocking present, got rc=$rc"
[[ "$out" == *"mcp=cloudflare severity=blocking source=startup"* ]] \
  || fail "expected blocking record, got: $out"

# --- Startup classifier: mixed log, only figma required --------------------

set +e
out=$(mcp_preflight_classify_startup_log "$TEST_TMP/mixed.log" "figma" "")
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "expected rc=1 (figma is blocking), got rc=$rc"
[[ "$out" == *"mcp=cloudflare severity=nonblocking source=startup"* ]] \
  || fail "expected cloudflare nonblocking line in mixed output, got: $out"
[[ "$out" == *"mcp=figma severity=blocking source=startup"* ]] \
  || fail "expected figma blocking line in mixed output, got: $out"

# --- Startup classifier: clean log -----------------------------------------

set +e
out=$(mcp_preflight_classify_startup_log "$TEST_TMP/clean.log" "cloudflare,figma" "")
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "expected rc=0 for clean log, got rc=$rc"
[[ -z "$out" ]] || fail "expected no records for clean log, got: $out"

# --- Startup classifier: degraded record surfaces in output ----------------

cat > "$TEST_TMP/degraded.log" <<'LOG'
ERROR rmcp::transport::worker: worker quit with fatal AuthRequired source=https://mcp.cloudflare.com/sse error=invalid_token
LOG
set +e
out=$(mcp_preflight_classify_startup_log "$TEST_TMP/degraded.log" "" "cloudflare")
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "expected rc=0 for degraded-only classification, got rc=$rc"
[[ "$out" == *"mcp=cloudflare severity=degraded source=startup"* ]] \
  || fail "expected degraded severity record, got: $out"

# --- Startup classifier: missing log file is a no-op ------------------------

set +e
out=$(mcp_preflight_classify_startup_log "/no/such/log" "cloudflare" "")
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "expected rc=0 for missing log, got rc=$rc"
[[ -z "$out" ]] || fail "expected no records for missing log, got: $out"

printf 'ok - mcp_auth_classification distinguishes nonblocking noise from runtime-fatal failures\n'
