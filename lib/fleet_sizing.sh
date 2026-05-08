#!/usr/bin/env bash
# fleet_sizing.sh - combine onboarding readiness reports into a fleet decision.

if [[ -n "${ORDO_FLEET_SIZING_LIB_LOADED:-}" ]]; then
  return 0
fi
ORDO_FLEET_SIZING_LIB_LOADED=1

: "${ORDO_FLEET_REQUIRED_REPOSITORY_CAPABILITIES:=identity_binding repository_access push_permission pr_review_capability issue_assignment_capability ci_status_visibility}"
: "${ORDO_FLEET_REQUIRED_PROVIDER_CAPABILITIES:=agent_execution workspace_access evidence_capture}"

fleet_sizing_uint_or_default() {
  local value=${1:-}
  local fallback=${2:?usage: fleet_sizing_uint_or_default <value> <fallback>}
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

fleet_sizing_missing_repository_report_json() {
  jq -nc '{
    status:"blocked",
    capabilities:{
      identity_binding:{ready:false,detail:"repository_platform_report_missing"},
      repository_access:{ready:false,detail:"repository_platform_report_missing"},
      push_permission:{ready:false,detail:"repository_platform_report_missing"},
      pr_review_capability:{ready:false,detail:"repository_platform_report_missing"},
      issue_assignment_capability:{ready:false,detail:"repository_platform_report_missing"},
      ci_status_visibility:{ready:false,detail:"repository_platform_report_missing"}
    },
    identity_bindings:[],
    blockers:["repository_platform_report_missing"]
  }'
}

fleet_sizing_missing_provider_report_json() {
  jq -nc '{
    status:"blocked",
    capacity:{available_agents:null},
    capabilities:{},
    role_capabilities:{},
    blockers:["provider_capability_report_missing"]
  }'
}

fleet_sizing_report_json() {
  local requested=${1:-1}
  local current=${2:-}
  local host_report=${3:?usage: fleet_sizing_report_json <requested> <current> <host-json> <repository-json> <provider-json>}
  local repository_report=${4:?usage: fleet_sizing_report_json <requested> <current> <host-json> <repository-json> <provider-json>}
  local provider_report=${5:?usage: fleet_sizing_report_json <requested> <current> <host-json> <repository-json> <provider-json>}

  requested=$(fleet_sizing_uint_or_default "$requested" 1)
  if [[ -n "$current" ]]; then
    current=$(fleet_sizing_uint_or_default "$current" 0)
  fi

  jq -nc \
    --argjson requested "$requested" \
    --arg current "$current" \
    --argjson host "$host_report" \
    --argjson repository "$repository_report" \
    --argjson provider "$provider_report" \
    --arg required_repository_capabilities "$ORDO_FLEET_REQUIRED_REPOSITORY_CAPABILITIES" \
    --arg required_provider_capabilities "$ORDO_FLEET_REQUIRED_PROVIDER_CAPABILITIES" \
    '
      def current_agents:
        if $current == "" then null else ($current | tonumber) end;
      def required_repo_caps:
        ($required_repository_capabilities | split(" ") | map(select(length > 0)));
      def required_provider_caps:
        ($required_provider_capabilities | split(" ") | map(select(length > 0)));
      def bool_ready($value):
        if ($value | type) == "object" then ($value.ready == true)
        elif ($value | type) == "boolean" then $value
        else false end;
      def cap_value($obj):
        (
          $obj.capacity.estimated_agents //
          $obj.capacity.available_agents //
          $obj.capacity.agent_slots //
          $obj.capacity_agents //
          $obj.available_agent_slots //
          null
        );
      def host_capacity:
        ($host.capacity.estimated_agents // null);
      def provider_capacity:
        cap_value($provider);
      def identity_bindings:
        ($repository.identity_bindings // []);
      def identity_capacity:
        if (identity_bindings | length) > 0 then
          (identity_bindings | map(select((.status // "") == "bound" and (.identity // "") != "")) | length)
        else null end;
      def terminal:
        ($host.capabilities.terminal_multiplexer // {required:false,status:"not_configured"});
      def terminal_required_unavailable:
        ((terminal.required == true) and ((terminal.status // "") != "available"));
      def repo_cap_missing:
        required_repo_caps
        | map(select(bool_ready($repository.capabilities[.] // null) | not));
      def provider_cap_missing:
        required_provider_caps
        | map(select(bool_ready($provider.capabilities[.] // null) | not));
      def base_blockers:
        (
          (($repository.blockers // []) | map("repository:" + .)) +
          (($provider.blockers // []) | map("provider:" + .)) +
          (repo_cap_missing | map("repository_capability:" + .)) +
          (provider_cap_missing | map("provider_capability:" + .)) +
          (if ($repository.status // "blocked") != "ready" then ["repository_platform_not_ready"] else [] end) +
          (if ($provider.status // "blocked") != "ready" then ["provider_cli_not_ready"] else [] end) +
          (if terminal_required_unavailable then ["terminal_multiplexer_required_unavailable"] else [] end)
        ) | unique;
      def capacity_dimensions:
        {
          host:host_capacity,
          repository_identity:identity_capacity,
          provider_cli:provider_capacity,
          terminal_multiplexer:(if terminal_required_unavailable then 0 else null end)
        };
      def known_capacity_values:
        ([capacity_dimensions[]] | map(select(. != null)));
      def limiting_capacity:
        if (known_capacity_values | length) > 0 then (known_capacity_values | min) else $requested end;
      def has_blockers:
        (base_blockers | length) > 0;
      def target_agents:
        if has_blockers then 0
        elif limiting_capacity < 0 then 0
        elif limiting_capacity < $requested then limiting_capacity
        else $requested end;
      def capacity_blockers:
        [
          (if host_capacity != null and host_capacity < $requested then "host_capacity" else empty end),
          (if provider_capacity != null and provider_capacity < $requested then "provider_cli_capacity" else empty end),
          (if identity_capacity != null and identity_capacity < $requested then "repository_identity_capacity" else empty end),
          (if terminal_required_unavailable then "terminal_multiplexer_capacity" else empty end)
        ] | unique;
      def warnings:
        [
          (if ($host.environment_recommendation.suitability // "suitable") != "suitable" and (base_blockers | length) == 0 then "host_assessment:" + ($host.environment_recommendation.suitability // "unknown") else empty end),
          (if (terminal.required != true and ((terminal.status // "") == "unavailable_optional")) then "terminal_multiplexer_optional_unavailable" else empty end),
          (if provider_capacity == null and (($provider.status // "") == "ready") then "provider_capacity_unknown" else empty end),
          (if identity_capacity == null and (($repository.status // "") == "ready") then "repository_identity_capacity_unknown" else empty end)
        ] | unique;
      def role_mix($n):
        if $n <= 0 then []
        elif $n == 1 then [{role:"generalist",count:1}]
        elif $n == 2 then [{role:"implementation",count:1},{role:"review",count:1}]
        else [{role:"coordination",count:1},{role:"implementation",count:($n - 2)},{role:"review",count:1}]
        end;
      def resize_direction:
        if current_agents == null then "new"
        elif current_agents < target_agents then "up"
        elif current_agents > target_agents then "down"
        else "same" end;
      def decision:
        if has_blockers then "blocked"
        elif current_agents != null and current_agents < target_agents then "resize_up"
        elif current_agents != null and current_agents > target_agents then "resize_down"
        elif current_agents != null then "keep_current"
        elif target_agents < $requested then "provision_limited_fleet"
        else "provision" end;
      def rerun_reasons:
        (
          (if has_blockers then ["after_blocker_remediation"] else [] end) +
          (if (warnings | length) > 0 then ["after_warning_review"] else [] end) +
          (if resize_direction != "same" and resize_direction != "new" then ["after_resize_decision"] else [] end) +
          (if target_agents < $requested and (has_blockers | not) then ["when_capacity_changes"] else [] end)
        ) | unique;
      {
        schema_version:"ordo.fleet_sizing.v1",
        sizing_model:"minimum_viable_capacity",
        requested_fleet:{agents:$requested},
        current_fleet:{
          agents:current_agents,
          present:(current_agents != null)
        },
        inputs:{
          host_assessment:{
            schema_version:($host.schema_version // null),
            status:($host.environment_recommendation.suitability // "unknown"),
            decision:($host.environment_recommendation.decision // null),
            bottlenecks:($host.environment_recommendation.bottlenecks // [])
          },
          repository_platform:{
            status:($repository.status // "blocked"),
            blockers:($repository.blockers // []),
            required_capabilities:required_repo_caps
          },
          provider_cli:{
            status:($provider.status // "blocked"),
            blockers:($provider.blockers // []),
            required_capabilities:required_provider_caps
          },
          terminal_multiplexer:{
            required:(terminal.required // false),
            status:(terminal.status // "not_configured"),
            optional:((terminal.required // false) | not)
          }
        },
        constraints:[
          {name:"host_capacity",source:"host_assessment",capacity_agents:host_capacity,status:(if host_capacity == null then "unknown" elif host_capacity < $requested then "constraining" else "ok" end)},
          {name:"repository_identity_capacity",source:"repository_platform_readiness",capacity_agents:identity_capacity,status:(if identity_capacity == null then "unknown" elif identity_capacity < $requested then "constraining" else "ok" end)},
          {name:"provider_cli_capacity",source:"provider_cli_capabilities",capacity_agents:provider_capacity,status:(if provider_capacity == null then "unknown" elif provider_capacity < $requested then "constraining" else "ok" end)},
          {name:"terminal_multiplexer",source:"host_assessment",capacity_agents:(if terminal_required_unavailable then 0 else null end),status:(if terminal_required_unavailable then "blocked" elif (terminal.status // "") == "unavailable_optional" then "warning" else "ok" end)}
        ],
        recommendation:{
          decision:decision,
          recommended_agents:target_agents,
          requested_agents:$requested,
          role_mix:role_mix(target_agents),
          blockers:base_blockers,
          bottlenecks:capacity_blockers,
          warnings:warnings,
          explanation:(
            if has_blockers then
              "Fleet sizing is blocked until required repository, provider, identity, or terminal capability blockers are resolved."
            elif target_agents < $requested then
              "Recommended fleet is smaller than requested because one or more measured capacities is constraining."
            elif decision == "resize_up" then
              "Existing fleet can be increased to the current recommended size."
            elif decision == "resize_down" then
              "Existing fleet should be reduced to stay within current constraints."
            elif decision == "keep_current" then
              "Existing fleet matches the current recommendation."
            else
              "Requested fleet can be provisioned under the current constraints."
            end
          ),
          resize:{
            current_agents:current_agents,
            target_agents:target_agents,
            direction:resize_direction,
            required:(resize_direction == "up" or resize_direction == "down")
          },
          rerun:{
            recommended:((rerun_reasons | length) > 0),
            reasons:rerun_reasons
          }
        },
        provisioning:{
          schema_version:"ordo.provisioning.input.v1",
          requested_agent_count:target_agents,
          role_mix:role_mix(target_agents),
          identity_binding_required:true,
          candidate_identity_bindings:(identity_bindings | map(select((.status // "") == "bound")) | .[:target_agents]),
          required_capabilities:{
            repository_platform:required_repo_caps,
            provider_cli:required_provider_caps,
            terminal_multiplexer_required:(terminal.required // false)
          }
        },
        onboarding_state:{
          schema_version:"ordo.onboarding_state_patch.v1",
          fleet_sizing:{
            requested_agents:$requested,
            current_agents:current_agents,
            recommended_agents:target_agents,
            decision:decision,
            blockers:base_blockers,
            warnings:warnings,
            rerun_recommended:((rerun_reasons | length) > 0)
          }
        }
      }
    '
}
