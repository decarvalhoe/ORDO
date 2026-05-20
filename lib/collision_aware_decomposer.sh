#!/usr/bin/env bash
# lib/collision_aware_decomposer.sh — proactive collision-aware dispatch
# decomposer (#771). Replaces "refuse the whole issue on any scope-file
# collision" with "split scope into the independent portion (dispatch
# immediately) + the colliding portion (defer, blocked on the in-flight
# work)".
#
# Hard boundary: this library is pure shell + jq. It does not call gh,
# it does not write to the filesystem, it does not assume orch_loop
# state. The decomposer takes an in-memory issue payload and the current
# in-flight scope-claim ledger and emits a structured payload describing
# the decomposition decision. Actual sub-issue creation and orch_loop
# wire-in are explicitly out of scope for this PR (see #771 source body:
# "Lib-only PR — wire-in into orch_loop dispatch step is filed as
# separate follow-up to avoid scope collision with #763").
#
# Inputs:
#
#   issue-json   JSON object describing the dispatchable parent issue.
#                Required keys:
#                  number       integer issue number (parent)
#                  title        parent title (used to derive sub-issue titles)
#                  body         parent body (used to filter Acceptance Criteria
#                               and "Allowed files" lines into each sub-issue)
#                  scope_files  array of repo-relative paths declared as the
#                               parent's allowed files (S in the proposal)
#                Optional keys:
#                  labels       array of strings or array of {name}; inherited
#                               (with theme:* and priority-* preserved) onto
#                               each sub-issue
#                  url          parent issue URL (echoed back in sub-issue
#                               trailers for filiation)
#
#   active-scope-claims-json
#                JSON object keyed by agent id, same shape as
#                <state_dir>/assignments_scope_claims.json (#721 sub-A):
#                  { "agent-001": { "agent": "...", "ticket": "...",
#                                    "branch": "...", "scope_files": [...],
#                                    "open_pr": "<optional PR number>" } }
#                The optional `open_pr` key, when present, is surfaced into
#                the colliding sub-issue's `blocked-on:open_pr:#<N>` label
#                and into its title trailer. When absent, the claim's
#                ticket number is used as the fallback blocker reference.
#
# Output (stdout): a single JSON object. Schema:
#
#   {
#     "decision":          "no-collision" | "auto-split-needed" | "defer-collision",
#     "parent": {
#       "number":          N,
#       "title":           "...",
#       "url":             "..."           # optional, echoed from input
#     },
#     "scope_files":       [ ... ],         # parent S, deduped + sorted
#     "active_claim_files":[ ... ],         # union(active_scope_claims), deduped + sorted
#     "independent_files": [ ... ],         # S \ active_claim_files
#     "colliding_files":   [ ... ],         # S ∩ active_claim_files
#     "colliding_claims":  [
#       { "agent": "...", "ticket": "...", "branch": "...",
#         "open_pr": "...",        # optional, propagated from input claim
#         "shared_files": [ ... ] }
#     ],
#     "sub_issues":        [ ... ]          # populated only on auto-split-needed
#   }
#
# Sub-issue payloads (sub_issues[]) carry the structured fields the
# downstream wire-in needs to call `gh issue create`. They are NOT created
# by this library:
#
#   {
#     "kind":         "independent" | "colliding",
#     "title":        "<parent-title> — independent module (auto-split from #N for parallel dispatch)" |
#                     "<parent-title> — colliding follow-up (auto-split from #N, blocked on PR #PR)",
#     "body":         filtered parent body (Allowed files line rewritten,
#                     Acceptance Criteria bullets filtered to the subset
#                     referencing files in this sub-issue's scope; parent
#                     filiation trailer appended)
#     "labels":       inherited theme:* and priority-* labels from parent,
#                     plus auto-split-child / auto-split-followup and
#                     parent:#N. For colliding: also blocked-on:open_pr:#PR
#                     (or blocked-on:ticket:#TICKET when open_pr is absent).
#     "scope_files":  subset of S assigned to this sub-issue (sorted)
#     "blocked_on": {                # only present on kind == "colliding"
#       "open_pr":    "<PR number>", # optional
#       "tickets":    [ "..." ]      # owning claim tickets that touch the
#                                    # colliding files
#     }
#   }
#
# Decision semantics (matches acceptance criteria in the issue body):
#   - colliding_files is empty                -> "no-collision"
#     (caller may dispatch the original issue directly; sub_issues is [])
#   - independent_files is empty AND colliding_files is non-empty
#                                             -> "defer-collision"
#     (caller falls back to the current behavior: defer until the in-flight
#     claim clears; sub_issues is [] so no auto-split is proposed)
#   - both subsets non-empty                  -> "auto-split-needed"
#     (caller dispatches the independent sub-issue immediately, files the
#     colliding sub-issue as a blocked follow-up, optionally closes the
#     parent as a tracking shell)
#
# Atomize-quality intent (#766 referenced but not yet landed): the sub-issue
# payload structurally honors INVEST + DoD + filiation + non-duplicate:
#   - Independent + colliding scopes are disjoint by construction, so no
#     two children carry the same scope_files entry (non-duplicate).
#   - Each child carries the parent's Acceptance Criteria filtered to its
#     own files, so the DoD is preserved per-child instead of duplicated
#     verbatim.
#   - Each child carries `parent:#N` label + a Parent / Auto-split trailer
#     in the body for filiation.
#   - Each child carries a focused single-purpose scope (small, testable).
#
# No bash strict-mode is set here. The library is sourced by callers that
# manage their own `set -euo pipefail` posture; toggling those flags in a
# sourced library would silently change caller behavior.

# ---------------------------------------------------------------------------
# Pure helpers — operate on JSON via jq. Kept small and individually
# testable so the wire-in script can re-use them without taking the whole
# decompose_on_collision flow.
# ---------------------------------------------------------------------------

# Emit the deduped + sorted union of scope_files across every agent in the
# active-scope-claims-json blob. Empty/missing input => empty JSON array.
collision_aware_union_claim_files() {
  local claims_json=${1-}
  command -v jq >/dev/null 2>&1 || { printf '[]'; return 0; }
  if [ -z "$claims_json" ]; then
    printf '[]'
    return 0
  fi
  jq -c '
    [ (.. | objects | .scope_files? // empty) | arrays | .[] ]
    | map(select(type == "string" and length > 0))
    | unique
  ' <<<"$claims_json" 2>/dev/null || printf '[]'
}

# Set intersection of two JSON string-arrays, sorted + deduped.
collision_aware_intersect_arrays() {
  local a=${1:-[]}
  local b=${2:-[]}
  command -v jq >/dev/null 2>&1 || { printf '[]'; return 0; }
  jq -cn --argjson a "$a" --argjson b "$b" '
    ($a // []) as $aa
    | ($b // []) as $bb
    | $aa | map(select(. as $x | $bb | index($x))) | unique
  '
}

# Set difference (a \ b), sorted + deduped.
collision_aware_diff_arrays() {
  local a=${1:-[]}
  local b=${2:-[]}
  command -v jq >/dev/null 2>&1 || { printf '[]'; return 0; }
  jq -cn --argjson a "$a" --argjson b "$b" '
    ($a // []) as $aa
    | ($b // []) as $bb
    | $aa | map(select(. as $x | ($bb | index($x)) | not)) | unique
  '
}

# Echo (one per line) the agent records whose scope_files intersect the
# `files` array. Each record is emitted as a compact JSON object with
# {agent, ticket, branch, open_pr, shared_files}. `open_pr` is propagated
# verbatim from the claim when present (string or number), and elided
# from the output when the claim does not declare one.
collision_aware_colliding_claims() {
  local claims_json=${1-}
  local files_json=${2:-[]}
  command -v jq >/dev/null 2>&1 || return 0
  [ -n "$claims_json" ] || return 0
  jq -c --argjson files "$files_json" '
    ($files // []) as $f
    | to_entries
    | map(
        .value as $claim
        | ($claim.scope_files // []) as $sf
        | ($f | map(select(. as $x | $sf | index($x)))) as $shared
        | select(($shared | length) > 0)
        | {
            agent: ($claim.agent // .key),
            ticket: ($claim.ticket // ""),
            branch: ($claim.branch // ""),
            open_pr: ($claim.open_pr // null),
            shared_files: ($shared | unique)
          }
        | with_entries(select(.value != null))
      )
    | .[]
  ' <<<"$claims_json" 2>/dev/null || true
}

# Filter a markdown bullet list (one bullet per line, starting with `- ` or
# `- [ ]`/`- [x]`) so only bullets that textually reference at least one
# of the given files are kept. Matching is word-bounded: a file (or its
# basename) is considered "referenced" only when it appears in the bullet
# with non-alphanumeric/underscore characters (or end of line) on both
# sides. This avoids spurious substring hits like "a" matching inside
# "general" while still matching "file-a" because `-` is non-word.
collision_aware_filter_bullets() {
  local text=${1-}
  local files_json=${2:-[]}
  command -v jq >/dev/null 2>&1 || { printf '%s' "$text"; return 0; }
  local files_lines
  files_lines=$(jq -r '.[]?' <<<"$files_json" 2>/dev/null || true)
  [ -n "$files_lines" ] || { printf ''; return 0; }
  printf '%s\n' "$text" | awk -v files="$files_lines" '
    function regex_escape(s,    out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (index("\\.*+?^$|()[]{}/", c) > 0) {
          out = out "\\" c
        } else {
          out = out c
        }
      }
      return out
    }
    BEGIN {
      n = split(files, arr, "\n")
      pat = ""
      for (i = 1; i <= n; i++) {
        f = arr[i]
        if (f == "") continue
        e = regex_escape(f)
        pat = (pat == "" ? e : pat "|" e)
        b = f
        sub(/.*\//, "", b)
        if (b != "" && b != f) {
          eb = regex_escape(b)
          pat = pat "|" eb
        }
      }
      if (pat == "") full = ""
      else full = "(^|[^A-Za-z0-9_])(" pat ")([^A-Za-z0-9_]|$)"
    }
    full == "" { next }
    /^[[:space:]]*-[[:space:]]/ {
      if (match($0, full)) { print }
      next
    }
    { next }
  '
}

# Render the rewritten parent body for a single sub-issue. The rewrite is
# deliberately conservative: it preserves headings the dispatch brief
# renderer relies on (Acceptance Criteria, Allowed files) while replacing
# the per-line allowed-files content and pruning Acceptance Criteria
# bullets that do not reference any file in `child_files_json`.
collision_aware_render_child_body() {
  local parent_body=${1-}
  local child_files_json=${2:-[]}
  local parent_number=${3:-}
  local parent_url=${4:-}
  local kind=${5:-independent}
  local timestamp=${6:-}
  command -v jq >/dev/null 2>&1 || { printf '%s' "$parent_body"; return 0; }

  local files_csv
  files_csv=$(jq -r '. | join(" ")' <<<"$child_files_json" 2>/dev/null || true)

  # Awk reflow: rewrite `scope_files=...` to the child subset, swap any
  # `## Allowed files` body to the child subset, and filter Acceptance
  # Criteria bullets to those referencing the child's files. Other
  # sections are passed through unchanged.
  local child_files_lines
  child_files_lines=$(jq -r '.[]?' <<<"$child_files_json" 2>/dev/null || true)

  local filtered
  filtered=$(printf '%s\n' "$parent_body" | awk -v files="$child_files_lines" -v files_csv="$files_csv" '
    function regex_escape(s,    out, i, c) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (index("\\.*+?^$|()[]{}/", c) > 0) {
          out = out "\\" c
        } else {
          out = out c
        }
      }
      return out
    }
    function file_matches(line) {
      if (full_pat == "") return 0
      return match(line, full_pat)
    }
    BEGIN {
      keep_list = files
      n = split(keep_list, arr, "\n")
      pat = ""
      for (i = 1; i <= n; i++) {
        f = arr[i]
        if (f == "") continue
        e = regex_escape(f)
        pat = (pat == "" ? e : pat "|" e)
        b = f
        sub(/.*\//, "", b)
        if (b != "" && b != f) {
          eb = regex_escape(b)
          pat = pat "|" eb
        }
      }
      if (pat == "") full_pat = ""
      else full_pat = "(^|[^A-Za-z0-9_])(" pat ")([^A-Za-z0-9_]|$)"
    }
    {
      line = $0
      if (line ~ /^[[:space:]]*scope_files=/) {
        sub(/scope_files=.*/, "scope_files=" files_csv, line)
        print line
        next
      }
      if (line ~ /^##[[:space:]]+(Allowed files|Allowed Files)([[:space:]]|$)/) {
        print line
        print ""
        print "scope_files=" files_csv
        in_allowed = 1
        skip_blanks = 1
        next
      }
      if (in_allowed && line ~ /^##[[:space:]]/) {
        in_allowed = 0
      } else if (in_allowed) {
        next
      }
      if (line ~ /^##[[:space:]]+(Acceptance Criteria|Definition of Done|Acceptance criteria|Definition of done)([[:space:]]|$)/) {
        print line
        in_ac = 1
        next
      }
      if (in_ac) {
        if (line ~ /^##[[:space:]]/) {
          in_ac = 0
          print line
          next
        }
        if (line ~ /^[[:space:]]*-[[:space:]]/) {
          if (file_matches(line)) { print line }
          next
        }
        print line
        next
      }
      print line
    }
  ')

  local trailer
  if [ "$kind" = "colliding" ]; then
    trailer=$'\n---\n\nParent: #'"${parent_number}"
    [ -n "$parent_url" ] && trailer="${trailer}"$'\n'"Parent URL: ${parent_url}"
    trailer="${trailer}"$'\n'"Auto-split: ${timestamp:-unset} (colliding follow-up)"
  else
    trailer=$'\n---\n\nParent: #'"${parent_number}"
    [ -n "$parent_url" ] && trailer="${trailer}"$'\n'"Parent URL: ${parent_url}"
    trailer="${trailer}"$'\n'"Auto-split: ${timestamp:-unset} (independent module)"
  fi

  printf '%s%s\n' "$filtered" "$trailer"
}

# Render the inherited label list for a child sub-issue. Theme:* and
# priority-* labels are inherited from the parent; auto-split-child /
# auto-split-followup + parent:#N are added per spec; blocked-on:open_pr:#PR
# (or blocked-on:ticket:#T fallback) is appended on colliding children.
collision_aware_render_child_labels() {
  local parent_labels_json=${1:-[]}
  local parent_number=${2:-}
  local kind=${3:-independent}
  local blocker_pr=${4:-}
  local blocker_tickets_json=${5:-[]}
  command -v jq >/dev/null 2>&1 || { printf '[]'; return 0; }

  jq -cn \
    --argjson parent_labels "$parent_labels_json" \
    --arg parent_number "$parent_number" \
    --arg kind "$kind" \
    --arg blocker_pr "$blocker_pr" \
    --argjson blocker_tickets "$blocker_tickets_json" '
    def to_names:
      if type == "array" then
        map(if type == "string" then . elif type == "object" then (.name // "") else "" end)
      else [] end;
    ($parent_labels | to_names) as $names
    | ($names | map(select(test("^(theme:|priority-)"; "i")))) as $inherited
    | (if $kind == "independent" then ["auto-split-child"] else ["auto-split-followup"] end) as $kind_label
    | ($inherited + $kind_label + ["parent:#" + $parent_number]) as $base
    | (if $kind == "colliding" then
         (if ($blocker_pr | length) > 0 then
            $base + ["blocked-on:open_pr:#" + $blocker_pr]
          else
            $base + (
              ($blocker_tickets // [])
              | map(select(type == "string" and length > 0))
              | map("blocked-on:ticket:#" + .)
            )
          end)
       else $base end)
    | unique
  '
}

# ---------------------------------------------------------------------------
# Public entrypoint.
# ---------------------------------------------------------------------------

# decompose_on_collision <issue-json> <active-scope-claims-json>
#
# Emit (stdout) the decomposition payload described at the top of this file.
# Exit codes:
#   0  - payload emitted (decision is one of the three documented values)
#   1  - inputs missing or jq unavailable
#
# The function is deterministic: arrays are sorted + deduped, and the
# timestamp embedded in sub-issue trailers honors the COLLISION_AWARE_NOW
# environment variable (falling back to `date -u`). Callers that need a
# pinned timestamp for fixture tests set COLLISION_AWARE_NOW.
decompose_on_collision() {
  local issue_json=${1-}
  local claims_json=${2-}
  command -v jq >/dev/null 2>&1 || return 1
  [ -n "$issue_json" ] || return 1
  [ -n "$claims_json" ] || claims_json='{}'

  local parent_number parent_title parent_body parent_url parent_labels scope_files
  parent_number=$(jq -r '(.number // empty) | tostring' <<<"$issue_json" 2>/dev/null)
  parent_title=$(jq -r '.title // ""' <<<"$issue_json" 2>/dev/null)
  parent_body=$(jq -r '.body // ""' <<<"$issue_json" 2>/dev/null)
  parent_url=$(jq -r '.url // ""' <<<"$issue_json" 2>/dev/null)
  parent_labels=$(jq -c '.labels // []' <<<"$issue_json" 2>/dev/null)
  scope_files=$(jq -c '(.scope_files // []) | map(select(type == "string" and length > 0)) | unique' <<<"$issue_json" 2>/dev/null)

  [ -n "$parent_number" ] || return 1

  local claim_union colliding independent
  claim_union=$(collision_aware_union_claim_files "$claims_json")
  colliding=$(collision_aware_intersect_arrays "$scope_files" "$claim_union")
  independent=$(collision_aware_diff_arrays "$scope_files" "$claim_union")

  local colliding_len independent_len
  colliding_len=$(jq -r 'length' <<<"$colliding")
  independent_len=$(jq -r 'length' <<<"$independent")

  local colliding_claims_array='[]'
  if [ "$colliding_len" -gt 0 ]; then
    local lines
    lines=$(collision_aware_colliding_claims "$claims_json" "$colliding")
    if [ -n "$lines" ]; then
      colliding_claims_array=$(printf '%s\n' "$lines" | jq -s -c '.')
    fi
  fi

  local decision sub_issues='[]'
  if [ "$colliding_len" -eq 0 ]; then
    decision="no-collision"
  elif [ "$independent_len" -eq 0 ]; then
    decision="defer-collision"
  else
    decision="auto-split-needed"
    local timestamp
    timestamp=${COLLISION_AWARE_NOW:-$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || printf 'unset')}

    local indep_body indep_labels indep_title
    indep_body=$(collision_aware_render_child_body "$parent_body" "$independent" "$parent_number" "$parent_url" "independent" "$timestamp")
    indep_labels=$(collision_aware_render_child_labels "$parent_labels" "$parent_number" "independent" "" "[]")
    indep_title="${parent_title} — independent module (auto-split from #${parent_number} for parallel dispatch)"

    local blocker_pr blocker_tickets
    blocker_pr=$(jq -r '[.[].open_pr // empty] | map(tostring) | map(select(length > 0)) | .[0] // ""' <<<"$colliding_claims_array")
    blocker_tickets=$(jq -c '[.[].ticket // empty] | map(tostring) | map(select(length > 0)) | unique' <<<"$colliding_claims_array")

    local coll_body coll_labels coll_title coll_blocker_suffix
    coll_body=$(collision_aware_render_child_body "$parent_body" "$colliding" "$parent_number" "$parent_url" "colliding" "$timestamp")
    coll_labels=$(collision_aware_render_child_labels "$parent_labels" "$parent_number" "colliding" "$blocker_pr" "$blocker_tickets")
    if [ -n "$blocker_pr" ]; then
      coll_blocker_suffix=", blocked on PR #${blocker_pr}"
    else
      local first_ticket
      first_ticket=$(jq -r '.[0] // ""' <<<"$blocker_tickets")
      if [ -n "$first_ticket" ]; then
        coll_blocker_suffix=", blocked on #${first_ticket}"
      else
        coll_blocker_suffix=""
      fi
    fi
    coll_title="${parent_title} — colliding follow-up (auto-split from #${parent_number}${coll_blocker_suffix})"

    sub_issues=$(jq -cn \
      --arg indep_title "$indep_title" \
      --arg indep_body "$indep_body" \
      --argjson indep_labels "$indep_labels" \
      --argjson indep_scope "$independent" \
      --arg coll_title "$coll_title" \
      --arg coll_body "$coll_body" \
      --argjson coll_labels "$coll_labels" \
      --argjson coll_scope "$colliding" \
      --arg blocker_pr "$blocker_pr" \
      --argjson blocker_tickets "$blocker_tickets" '
      [
        {
          kind: "independent",
          title: $indep_title,
          body: $indep_body,
          labels: $indep_labels,
          scope_files: $indep_scope
        },
        ({
          kind: "colliding",
          title: $coll_title,
          body: $coll_body,
          labels: $coll_labels,
          scope_files: $coll_scope,
          blocked_on: (
            (if ($blocker_pr | length) > 0 then {open_pr: $blocker_pr} else {} end)
            + {tickets: $blocker_tickets}
          )
        })
      ]
    ')
  fi

  jq -cn \
    --arg decision "$decision" \
    --arg number "$parent_number" \
    --arg title "$parent_title" \
    --arg url "$parent_url" \
    --argjson scope_files "$scope_files" \
    --argjson active_claim_files "$claim_union" \
    --argjson independent_files "$independent" \
    --argjson colliding_files "$colliding" \
    --argjson colliding_claims "$colliding_claims_array" \
    --argjson sub_issues "$sub_issues" '
    {
      decision: $decision,
      parent: ({number: ($number | tonumber? // $number), title: $title}
               + (if ($url | length) > 0 then {url: $url} else {} end)),
      scope_files: $scope_files,
      active_claim_files: $active_claim_files,
      independent_files: $independent_files,
      colliding_files: $colliding_files,
      colliding_claims: $colliding_claims,
      sub_issues: $sub_issues
    }
  '
}
