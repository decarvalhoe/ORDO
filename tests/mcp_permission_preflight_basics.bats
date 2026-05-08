#!/usr/bin/env bats
# tests/mcp_permission_preflight_basics.bats — coverage for ORDO #342.
#
# `lib/mcp_permission_preflight.sh::mcp_preflight_for_dispatch` MUST:
#   - detect required MCPs from a Figma URL in the prompt body;
#   - detect required MCPs from an explicit `Required MCPs:` declaration
#     so the helper covers any future MCP, not just Figma;
#   - look up per-(workdir, mcp) grants from the structured ledger;
#   - prefer the universal CLI-agnostic resolver hook when configured;
#   - return decision=blocked with structured `blocking` list when any
#     required MCP is not granted;
#   - return decision=granted (rc=0) when every required MCP is granted.
#
# `scripts/dispatch_ticket.sh` MUST exit
# `ORCH_MCP_PERMISSION_BLOCKED_EXIT_CODE` (default 80) when the preflight
# blocks, so the wave dispatcher can record `denied` per-entry instead of
# stalling on an interactive grant prompt.

load './helpers.bash'

setup() {
  setup_orch_test
  toolkit_file lib/mcp_permission_preflight.sh >/dev/null
  # shellcheck disable=SC1091 # sourcing sanitized copy
  source "$SANITIZED_TK/lib/mcp_permission_preflight.sh"

  unset ORDO_MCP_PROMPT_PATTERNS
  unset ORDO_MCP_PROMPT_PATTERNS_EXTRA
  unset ORDO_MCP_PERMISSIONS_FILE
  unset ORDO_MCP_PERMISSION_RESOLVER
  unset ORDO_MCP_REQUIRED_FOR_PROJECT

  export ORDO_MCP_PERMISSIONS_FILE="$BATS_TEST_TMPDIR/mcp-permissions.json"
  cat > "$ORDO_MCP_PERMISSIONS_FILE" <<'JSON'
{
  "by_workdir": {
    "/repos/ordo/claude":  {"figma": "needs_operator_permission"},
    "/repos/ordo/copilot": {"figma": "granted"},
    "/repos/ordo/cursor":  {"figma": "granted", "canva": "needs_operator_permission"},
    "/repos/ordo/gemini":  {"figma": "granted", "n8n": "granted"}
  }
}
JSON

  cat > "$BATS_TEST_TMPDIR/prompt-figma.md" <<'EOF'
## Objectif
Audit the Figma file at https://www.figma.com/design/JjE4BI3JXEghjU4svSrf0R/audit-target?node-id=48-268
EOF

  cat > "$BATS_TEST_TMPDIR/prompt-explicit.md" <<'EOF'
## Objectif
Build the canva landing page.

Required MCPs: canva, n8n
EOF

  cat > "$BATS_TEST_TMPDIR/prompt-plain.md" <<'EOF'
## Objectif
Edit local shell helpers; no MCP tools required.
EOF
}

@test "figma URL in prompt body resolves to figma MCP" {
  run mcp_preflight_detect_required "$BATS_TEST_TMPDIR/prompt-figma.md"
  [ "$status" -eq 0 ]
  [ "$output" = "figma" ]
}

@test "explicit Required MCPs declaration drives detection (universal MCP)" {
  run mcp_preflight_detect_required "$BATS_TEST_TMPDIR/prompt-explicit.md"
  [ "$status" -eq 0 ]
  # Sorted output: canva then n8n.
  [ "${lines[0]}" = "canva" ]
  [ "${lines[1]}" = "n8n" ]
}

@test "no required MCPs when prompt mentions none" {
  run mcp_preflight_detect_required "$BATS_TEST_TMPDIR/prompt-plain.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "figma blocked: per-workdir lookup catches needs_operator_permission" {
  run mcp_preflight_for_dispatch "$BATS_TEST_TMPDIR/prompt-figma.md" claude /repos/ordo/claude
  [ "$status" -eq 1 ]
  decision=$(printf '%s' "$output" | jq -r '.decision')
  [ "$decision" = "blocked" ]
  blocking=$(printf '%s' "$output" | jq -c '.blocking')
  [ "$blocking" = '["figma:needs_operator_permission"]' ]
  remediation=$(printf '%s' "$output" | jq -r '.remediation')
  [[ "$remediation" == *"granted entries"* ]]
}

@test "figma granted: dispatch proceeds with rc=0" {
  run mcp_preflight_for_dispatch "$BATS_TEST_TMPDIR/prompt-figma.md" copilot /repos/ordo/copilot
  [ "$status" -eq 0 ]
  decision=$(printf '%s' "$output" | jq -r '.decision')
  [ "$decision" = "granted" ]
  blocking=$(printf '%s' "$output" | jq -c '.blocking')
  [ "$blocking" = '[]' ]
}

@test "generic MCP (canva) blocked while figma granted on same workdir" {
  cat > "$BATS_TEST_TMPDIR/prompt-canva.md" <<'EOF'
## Objectif
Required MCPs: canva, figma
EOF
  run mcp_preflight_for_dispatch "$BATS_TEST_TMPDIR/prompt-canva.md" cursor /repos/ordo/cursor
  [ "$status" -eq 1 ]
  decision=$(printf '%s' "$output" | jq -r '.decision')
  [ "$decision" = "blocked" ]
  # Only canva blocks; figma is granted on this workdir.
  grants_figma=$(printf '%s' "$output" | jq -r '.grants.figma')
  grants_canva=$(printf '%s' "$output" | jq -r '.grants.canva')
  [ "$grants_figma" = "granted" ]
  [ "$grants_canva" = "needs_operator_permission" ]
  blocking=$(printf '%s' "$output" | jq -c '.blocking')
  [ "$blocking" = '["canva:needs_operator_permission"]' ]
}

@test "no required MCPs => decision=granted regardless of workdir" {
  run mcp_preflight_for_dispatch "$BATS_TEST_TMPDIR/prompt-plain.md" anyone /repos/ordo/claude
  [ "$status" -eq 0 ]
  decision=$(printf '%s' "$output" | jq -r '.decision')
  [ "$decision" = "granted" ]
  required=$(printf '%s' "$output" | jq -c '.required_mcps')
  [ "$required" = '[]' ]
}

@test "ORDO_MCP_PERMISSION_RESOLVER hook overrides ledger lookup" {
  # The resolver receives <workdir> <mcp>. Here we simulate a CLI-specific
  # introspector that always reports granted, regardless of the ledger
  # file (which says needs_operator_permission for /repos/ordo/claude).
  cat > "$BATS_TEST_TMPDIR/resolver" <<'EOF'
#!/usr/bin/env bash
printf 'granted'
EOF
  /usr/bin/chmod +x "$BATS_TEST_TMPDIR/resolver"
  ORDO_MCP_PERMISSION_RESOLVER="$BATS_TEST_TMPDIR/resolver" \
    run mcp_preflight_for_dispatch "$BATS_TEST_TMPDIR/prompt-figma.md" claude /repos/ordo/claude
  [ "$status" -eq 0 ]
  decision=$(printf '%s' "$output" | jq -r '.decision')
  [ "$decision" = "granted" ]
  grants_figma=$(printf '%s' "$output" | jq -r '.grants.figma')
  [ "$grants_figma" = "granted" ]
}

@test "ORDO_MCP_PROMPT_PATTERNS array fully replaces default catalog" {
  # An operator running in an environment without Figma can replace the
  # default catalog entirely. Figma URLs must NOT trigger detection in
  # that mode unless the operator declares the pattern themselves.
  ORDO_MCP_PROMPT_PATTERNS=("CUSTOM_TOOL_TRIGGER=custom_tool")
  run mcp_preflight_detect_required "$BATS_TEST_TMPDIR/prompt-figma.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  cat > "$BATS_TEST_TMPDIR/prompt-custom.md" <<'EOF'
Trigger: CUSTOM_TOOL_TRIGGER appears here.
EOF
  run mcp_preflight_detect_required "$BATS_TEST_TMPDIR/prompt-custom.md"
  [ "$status" -eq 0 ]
  [ "$output" = "custom_tool" ]
}

@test "ORDO_MCP_PROMPT_PATTERNS_EXTRA appends without dropping defaults" {
  ORDO_MCP_PROMPT_PATTERNS_EXTRA=("PROJECT_DOC_LINK=docsmcp")

  cat > "$BATS_TEST_TMPDIR/prompt-mixed.md" <<'EOF'
Audit Figma file https://www.figma.com/design/foo
PROJECT_DOC_LINK is here too.
EOF
  run mcp_preflight_detect_required "$BATS_TEST_TMPDIR/prompt-mixed.md"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "docsmcp" ]
  [ "${lines[1]}" = "figma" ]
}

@test "missing prompt file returns blocked decision (rc=2)" {
  run mcp_preflight_for_dispatch "/no/such/prompt.md" anyone /repos/ordo/claude
  [ "$status" -eq 2 ]
  decision=$(printf '%s' "$output" | jq -r '.decision')
  [ "$decision" = "blocked" ]
  err=$(printf '%s' "$output" | jq -r '.error')
  [ "$err" = "prompt_file_not_found" ]
}

@test "ledger absent => grants resolve to unknown and dispatch is blocked" {
  # Operator has not yet seeded the permissions file. Conservative
  # default: any required MCP without an explicit grant blocks dispatch.
  rm -f "$ORDO_MCP_PERMISSIONS_FILE"
  run mcp_preflight_for_dispatch "$BATS_TEST_TMPDIR/prompt-figma.md" claude /repos/ordo/claude
  [ "$status" -eq 1 ]
  decision=$(printf '%s' "$output" | jq -r '.decision')
  [ "$decision" = "blocked" ]
  blocking=$(printf '%s' "$output" | jq -c '.blocking')
  [ "$blocking" = '["figma:unknown"]' ]
}
