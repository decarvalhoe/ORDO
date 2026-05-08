#!/usr/bin/env bats
# tests/dispatch_plan_hotspot_attribution.bats — coverage for ORDO #292.
#
# `lib/file_hotspots.sh::file_hotspots_pr_agent` must be profile-driven.
# ORDO is a general multi-agent toolkit, so deployments without RBOKCLI-style
# author logins must not be misclassified as single-owner. These tests
# exercise:
#
#   - non-RBOK agent identities resolved via configured prefix lists;
#   - shared authors plus `agent:<name>` PR labels (label wins);
#   - explicit author -> agent maps;
#   - the absence of any hardcoded RBOKCLI fallback;
#   - sentinel handling when neither author nor labels are present.

load './helpers.bash'

setup() {
  setup_orch_test
  toolkit_file lib/file_hotspots.sh >/dev/null
  # shellcheck disable=SC1091 # sourcing the sanitized copy
  source "$SANITIZED_TK/lib/file_hotspots.sh"

  # Each test starts from a clean attribution config: no prefixes, no maps.
  unset ORDO_FILE_HOTSPOT_LOGIN_PREFIX
  unset ORDO_FILE_HOTSPOT_LOGIN_PREFIXES
  unset ORDO_FILE_HOTSPOT_AUTHOR_AGENT_MAP
}

@test "non-RBOK agent identities resolve via configured prefix list" {
  # An ORDO deployment with its own bot login style — say MyOrgCLI*.
  # The operator declares the prefix; the helper strips it.
  ORDO_FILE_HOTSPOT_LOGIN_PREFIXES=("MyOrgCLI" "AltCLI-")
  run file_hotspots_pr_agent "MyOrgCLIalice" "type:docs"
  [ "$status" -eq 0 ]
  [ "$output" = "alice" ]

  # Second declared prefix matches.
  run file_hotspots_pr_agent "AltCLI-bob" ""
  [ "$status" -eq 0 ]
  [ "$output" = "bob" ]
}

@test "agent:<name> PR label always wins over author resolution" {
  # Two agents share the same GitHub author (e.g. a shared bot account that
  # opens PRs for several agents). The `agent:` label disambiguates which
  # agent owns a given PR — it MUST take precedence over any author-based
  # heuristic.
  ORDO_FILE_HOTSPOT_LOGIN_PREFIXES=("BotCLI")
  run file_hotspots_pr_agent "BotCLIshared" "type:docs,agent:planner,priority:P1"
  [ "$status" -eq 0 ]
  [ "$output" = "planner" ]

  run file_hotspots_pr_agent "BotCLIshared" "agent:builder"
  [ "$status" -eq 0 ]
  [ "$output" = "builder" ]

  # Case-insensitive label match.
  run file_hotspots_pr_agent "BotCLIshared" "Agent:reviewer"
  [ "$status" -eq 0 ]
  [ "$output" = "reviewer" ]
}

@test "explicit author->agent map overrides prefix-based resolution" {
  # Some authors do not follow any prefix convention; an operator can pin
  # them to a stable agent label via the explicit map.
  ORDO_FILE_HOTSPOT_LOGIN_PREFIXES=("RBOKCLI")
  ORDO_FILE_HOTSPOT_AUTHOR_AGENT_MAP=(
    "renovate-bot=renovate"
    "dependabot[bot] = dependabot"
  )
  run file_hotspots_pr_agent "renovate-bot" "type:deps"
  [ "$status" -eq 0 ]
  [ "$output" = "renovate" ]

  run file_hotspots_pr_agent "dependabot[bot]" ""
  [ "$status" -eq 0 ]
  [ "$output" = "dependabot" ]

  # An author NOT in the map but matching the prefix list still gets
  # prefix-stripped — the map is an override, not the only path.
  run file_hotspots_pr_agent "RBOKCLIcursor" ""
  [ "$status" -eq 0 ]
  [ "$output" = "cursor" ]
}

@test "no hardcoded RBOKCLI fallback when no prefix is configured" {
  # CRITICAL: with no profile-driven configuration, the helper must NOT
  # silently strip RBOKCLI. The raw author login is returned as-is so a
  # multi-agent ORDO deployment without RBOKCLI users is not misclassified.
  unset ORDO_FILE_HOTSPOT_LOGIN_PREFIX
  unset ORDO_FILE_HOTSPOT_LOGIN_PREFIXES

  run file_hotspots_pr_agent "RBOKCLIcursor" ""
  [ "$status" -eq 0 ]
  [ "$output" = "RBOKCLIcursor" ]

  run file_hotspots_pr_agent "alice" "type:feat"
  [ "$status" -eq 0 ]
  [ "$output" = "alice" ]
}

@test "transitional ORDO_FILE_HOTSPOT_LOGIN_PREFIX (singular) still works" {
  # The singular env var is retained for transitional compatibility with
  # operators that have already pinned a single prefix. It must behave as a
  # one-element prefix list.
  export ORDO_FILE_HOTSPOT_LOGIN_PREFIX="RBOKCLI"
  run file_hotspots_pr_agent "RBOKCLIcodex" ""
  [ "$status" -eq 0 ]
  [ "$output" = "codex" ]

  # Author that does not match the configured prefix is returned raw.
  run file_hotspots_pr_agent "external-contributor" ""
  [ "$status" -eq 0 ]
  [ "$output" = "external-contributor" ]
}

@test "first matching prefix in the list wins, in declared order" {
  # Multi-prefix order matters: a longer or more specific prefix should be
  # declared first when ambiguity is possible.
  ORDO_FILE_HOTSPOT_LOGIN_PREFIXES=("RBOKCLI-bot-" "RBOKCLI")
  run file_hotspots_pr_agent "RBOKCLI-bot-claude" ""
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]

  # A login that only matches the second entry still resolves.
  run file_hotspots_pr_agent "RBOKCLIcursor" ""
  [ "$status" -eq 0 ]
  [ "$output" = "cursor" ]
}

@test "missing author and missing labels resolve to the unknown sentinel" {
  run file_hotspots_pr_agent "" ""
  [ "$status" -eq 0 ]
  [ "$output" = "unknown" ]
}

@test "bare agent: label is skipped and resolution falls through to author" {
  # A bare `agent:` label (no name) is malformed and must not produce an
  # empty agent. The helper skips it and continues to author resolution.
  ORDO_FILE_HOTSPOT_LOGIN_PREFIXES=("RBOKCLI")
  run file_hotspots_pr_agent "RBOKCLIgemini" "type:docs,agent:"
  [ "$status" -eq 0 ]
  [ "$output" = "gemini" ]
}
