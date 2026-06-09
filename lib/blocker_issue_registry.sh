#!/usr/bin/env bash
# lib/blocker_issue_registry.sh - helpers for durable ORDO blocker issues.

blocker_issue_require_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf 'blocker_issue_registry: jq is required\n' >&2
    return 2
  }
}

blocker_issue_require_value() {
  local name=${1:?usage: blocker_issue_require_value <name> <value>}
  local value=${2:-}
  [[ -n "$value" ]] || {
    printf 'blocker_issue_registry: missing %s\n' "$name" >&2
    return 2
  }
}

blocker_issue_no_newline() {
  local name=${1:?usage: blocker_issue_no_newline <name> <value>}
  local value=${2:-}
  case "$value" in
    *$'\n'*|*$'\r'*)
      printf 'blocker_issue_registry: %s must be single-line\n' "$name" >&2
      return 2
      ;;
  esac
}

blocker_issue_key() {
  local project=${1:?usage: blocker_issue_key <project> <kind> <resource>}
  local blocker_kind=${2:?usage: blocker_issue_key <project> <kind> <resource>}
  local resource=${3:?usage: blocker_issue_key <project> <kind> <resource>}
  blocker_issue_no_newline "project" "$project" || return $?
  blocker_issue_no_newline "blocker kind" "$blocker_kind" || return $?
  blocker_issue_no_newline "resource" "$resource" || return $?
  printf '%s:%s:%s\n' "$project" "$blocker_kind" "$resource"
}

blocker_issue_json_array() {
  jq -nc '$ARGS.positional' --args "$@"
}

blocker_issue_gh() {
  if [[ -n "${GH_CONFIG_DIR:-}" ]]; then
    GH_CONFIG_DIR="$GH_CONFIG_DIR" gh "$@"
  else
    gh "$@"
  fi
}

blocker_issue_search_json() {
  local repo=${1:?usage: blocker_issue_search_json <repo> <dedupe-key>}
  local dedupe_key=${2:?usage: blocker_issue_search_json <repo> <dedupe-key>}
  blocker_issue_gh issue list \
    --repo "$repo" \
    --state all \
    --search "$dedupe_key" \
    --json number,state,url,title,body \
    --limit 20
}

blocker_issue_pick_match() {
  local issues_json=${1:?usage: blocker_issue_pick_match <issues-json> <dedupe-key>}
  local dedupe_key=${2:?usage: blocker_issue_pick_match <issues-json> <dedupe-key>}
  blocker_issue_require_jq || return $?
  jq -c --arg dedupe_key "$dedupe_key" '
    if type != "array" then
      empty
    else
      (
        map(select(((.body // "") | contains($dedupe_key)) or ((.title // "") | contains($dedupe_key))))
        | (map(select((.state // "") == "OPEN")) + map(select((.state // "") != "OPEN")))
        | .[0] // empty
      )
    end
  ' <<< "$issues_json"
}

blocker_issue_markdown_list() {
  local empty_label=${1:?usage: blocker_issue_markdown_list <empty-label> [items...]}
  shift || true
  local item
  if [[ "$#" -eq 0 ]]; then
    printf -- '- %s\n' "$empty_label"
    return 0
  fi
  for item in "$@"; do
    printf -- '- %s\n' "$item"
  done
}

blocker_issue_report_body() {
  local dedupe_key=${1:?} project=${2:?} blocker_kind=${3:?} resource=${4:?}
  local profile=${5:?} command_text=${6:?} output_summary=${7:?}
  local next_action=${8:?} owner=${9:?} severity=${10:?}
  local artifact_json=${11:?} impacted_ref_json=${12:?}
  local created_at=${13:?}
  local artifact_lines impacted_lines
  mapfile -t artifact_lines < <(jq -r '.[]' <<< "$artifact_json")
  mapfile -t impacted_lines < <(jq -r '.[]' <<< "$impacted_ref_json")
  cat <<EOF
## ORDO Blocker

Blocker-Key: \`${dedupe_key}\`

- Project: \`${project}\`
- Blocker kind: \`${blocker_kind}\`
- Resource: \`${resource}\`
- Profile: \`${profile}\`
- Command: \`${command_text}\`
- Severity: \`${severity}\`
- Suggested owner: \`${owner}\`
- Next action: \`${next_action}\`
- First observed: \`${created_at}\`

### Synthetic Output

${output_summary}

### Artifacts

$(blocker_issue_markdown_list "none supplied" "${artifact_lines[@]}")

### Impacted PRs / Issues

$(blocker_issue_markdown_list "none supplied" "${impacted_lines[@]}")

### Dedupe Contract

Consecutive ORDO runs update this same issue when they report the same stable
key: \`${dedupe_key}\`.
EOF
}

blocker_issue_update_comment() {
  local dedupe_key=${1:?} profile=${2:?} command_text=${3:?}
  local output_summary=${4:?} next_action=${5:?} owner=${6:?}
  local severity=${7:?} artifact_json=${8:?} impacted_ref_json=${9:?}
  local observed_at=${10:?}
  local artifact_lines impacted_lines
  mapfile -t artifact_lines < <(jq -r '.[]' <<< "$artifact_json")
  mapfile -t impacted_lines < <(jq -r '.[]' <<< "$impacted_ref_json")
  cat <<EOF
## ORDO Blocker Update

Blocker-Key: \`${dedupe_key}\`

- Profile: \`${profile}\`
- Command: \`${command_text}\`
- Severity: \`${severity}\`
- Suggested owner: \`${owner}\`
- Next action: \`${next_action}\`
- Observed: \`${observed_at}\`

### Synthetic Output

${output_summary}

### Artifacts

$(blocker_issue_markdown_list "none supplied" "${artifact_lines[@]}")

### Impacted PRs / Issues

$(blocker_issue_markdown_list "none supplied" "${impacted_lines[@]}")
EOF
}

blocker_issue_resolution_comment() {
  local dedupe_key=${1:?} resolution_summary=${2:?} policy=${3:?} resolved_at=${4:?}
  cat <<EOF
## ORDO Blocker Resolved

Blocker-Key: \`${dedupe_key}\`

- Resolution policy: \`${policy}\`
- Resolved: \`${resolved_at}\`

### Resolution Summary

${resolution_summary}
EOF
}

blocker_issue_json_result() {
  local decision=${1:?} repo=${2:?} dedupe_key=${3:?} issue_number=${4:-}
  local blocker_issue_url=${5:-} resolution_policy=${6:-}
  jq -nc \
    --arg decision "$decision" \
    --arg repo "$repo" \
    --arg dedupe_key "$dedupe_key" \
    --arg issue_number "$issue_number" \
    --arg blocker_issue_url "$blocker_issue_url" \
    --arg resolution_policy "$resolution_policy" \
    '{
      decision: $decision,
      repo: $repo,
      dedupe_key: $dedupe_key,
      issue_number: (if $issue_number == "" then null else ($issue_number | tonumber) end),
      blocker_issue_url: (if $blocker_issue_url == "" then null else $blocker_issue_url end),
      status_hint: (if $blocker_issue_url == "" then null else "blocker_issue_url=" + $blocker_issue_url end)
    } + (if $resolution_policy == "" then {} else {resolution_policy: $resolution_policy} end)'
}
