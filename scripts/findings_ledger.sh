#!/usr/bin/env bash
# scripts/findings_ledger.sh - keep live findings ledgers outside worktrees.
#
# Usage:
#   findings_ledger.sh <project> path [--run-id <id>]
#   findings_ledger.sh <project> append [--ledger <path>] [--run-id <id>] --code <id> --summary <text> [fields...]
#   findings_ledger.sh <project> curate-issue --ledger <path> --code <id> [--title <text>] [--label <label>] [--dry-run]
#   findings_ledger.sh <project> curate-pr --ledger <path> --code <id> --head <branch> --docs-impact <outcome> [--docs-impact-note <text>] [--docs-impact-followup <ref>] [--base <branch>] [--title <text>] [--dry-run]
#
# Live ledgers default to ${XDG_STATE_HOME:-$HOME/.local/state}/ordo/findings-ledgers
# so normal capture does not dirty active agent worktrees. Set
# ORCH_FINDINGS_LEDGER_DIR to use an operator-controlled location such as
# /var/log/orch/reports.
set -euo pipefail

TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/config_resolver.sh"
source "$TK/lib/gh_body_helpers.sh"
source "$TK/lib/docs_impact_gate.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: findings_ledger.sh <project> <path|append|curate-issue|curate-pr> [args]}
COMMAND=${2:?usage: findings_ledger.sh <project> <path|append|curate-issue|curate-pr> [args]}
shift 2

load_project_config "$CFG_ARG"
: "${PROJECT:?}"
: "${DEFAULT_BRANCH:=main}"

utc_now() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

safe_name() {
  local raw=${1:?usage: safe_name <value>}
  printf '%s\n' "${raw//[^A-Za-z0-9_.-]/_}"
}

ledger_root() {
  if [[ -n "${ORCH_FINDINGS_LEDGER_DIR:-}" ]]; then
    printf '%s\n' "$ORCH_FINDINGS_LEDGER_DIR"
  elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
    printf '%s\n' "$XDG_STATE_HOME/ordo/findings-ledgers"
  elif [[ -n "${HOME:-}" ]]; then
    printf '%s\n' "$HOME/.local/state/ordo/findings-ledgers"
  else
    printf '%s\n' "/tmp/ordo-findings-ledgers"
  fi
}

default_run_id() {
  date -u +'%Y%m%dT%H%M%SZ'
}

default_ledger_path() {
  local run_id=${1:-$(default_run_id)}
  local root project_safe
  root=$(ledger_root)
  project_safe=$(safe_name "$PROJECT")
  printf '%s/%s/ordo-run-findings-%s.md\n' "$root" "$project_safe" "$(safe_name "$run_id")"
}

ensure_parent_dir() {
  local path=${1:?usage: ensure_parent_dir <path>}
  mkdir -p "$(dirname "$path")"
}

write_header_if_missing() {
  local ledger=${1:?usage: write_header_if_missing <ledger>}
  if [[ -s "$ledger" ]]; then
    return 0
  fi
  cat > "$ledger" <<EOF
# ORDO Run Findings Ledger

- Project: ${PROJECT}
- Created: $(utc_now)
- Storage policy: live ledger outside active worktrees by default.

Curate durable findings into tracked issues or PRs with:

\`\`\`bash
bash scripts/findings_ledger.sh <project> curate-issue --ledger "$ledger" --code <finding-code>
bash scripts/findings_ledger.sh <project> curate-pr --ledger "$ledger" --code <finding-code> --head <branch> --docs-impact <outcome>
\`\`\`

EOF
}

require_value() {
  local name=${1:?usage: require_value <name> <value>}
  local value=${2:-}
  [[ -n "$value" ]] || {
    printf 'findings_ledger: missing %s\n' "$name" >&2
    exit 2
  }
}

format_entry() {
  local code=${1:?} summary=${2:?} source=${3:-} severity=${4:-} finding=${5:-}
  local impact=${6:-} remediation=${7:-} validation=${8:-} priority=${9:-}
  cat <<EOF
## ${code} - ${summary}

- Source: ${source:-unspecified}
- Severity: ${severity:-unspecified}
- Finding: ${finding:-$summary}
- Impact: ${impact:-unspecified}
- Detection signal: ${source:-unspecified}
- Safe remediation candidate: ${remediation:-unspecified}
- Validation or POC plan: ${validation:-unspecified}
- Priority: ${priority:-unspecified}

EOF
}

extract_entry() {
  local ledger=${1:?usage: extract_entry <ledger> <code>}
  local code=${2:?usage: extract_entry <ledger> <code>}
  [[ -f "$ledger" ]] || {
    printf 'findings_ledger: ledger not found: %s\n' "$ledger" >&2
    return 1
  }
  awk -v code="$code" '
    BEGIN { heading = "## " code }
    index($0, heading) == 1 { found = 1; print; next }
    found && /^## / { exit }
    found { print }
    END { if (!found) exit 1 }
  ' "$ledger"
}

entry_title() {
  local entry=${1:?usage: entry_title <entry> <fallback>}
  local fallback=${2:-"fix(findings): curated finding"}
  local heading summary
  heading=$(printf '%s\n' "$entry" | awk 'NR == 1 { print; exit }')
  summary=$heading
  summary=${summary#'## '}
  summary=${summary#*' - '}
  [[ -n "$summary" && "$summary" != "$heading" ]] || summary=$fallback
  printf 'fix(findings): %s\n' "$summary"
}

entry_body() {
  local ledger=${1:?usage: entry_body <ledger> <code> <entry>}
  local code=${2:?usage: entry_body <ledger> <code> <entry>}
  local entry=${3:?usage: entry_body <ledger> <code> <entry>}
  local docs_impact_decl=${4:-}
  cat <<EOF
## Curated ORDO Finding

- Project: ${PROJECT}
- Finding code: ${code}
- Source ledger: ${ledger}

${entry}
EOF
  if [[ -n "$docs_impact_decl" ]]; then
    cat <<EOF

## Docs-Impact Declaration

${docs_impact_decl}
EOF
  fi
}

render_docs_impact_declaration() {
  local outcome=${1:-} note=${2:-} followup=${3:-}
  require_value "--docs-impact" "$outcome"
  if ! docs_gate_outcome_is_valid "$outcome"; then
    printf 'findings_ledger: --docs-impact must be one of: %s\n' \
      "${DOCS_GATE_VALID_OUTCOMES[*]}" >&2
    exit 2
  fi
  case "$outcome" in
    no-docs-needed)
      require_value "--docs-impact-note" "$note"
      ;;
    follow-up)
      require_value "--docs-impact-followup" "$followup"
      ;;
  esac

  printf 'Docs-Impact: %s\n' "$outcome"
  if [[ -n "$note" ]]; then
    printf 'Docs-Impact-Note: %s\n' "$note"
  fi
  if [[ -n "$followup" ]]; then
    printf 'Docs-Impact-Followup: %s\n' "$followup"
  fi
}

cmd_path() {
  local run_id=${ORCH_FINDINGS_RUN_ID:-}
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --run-id)
        run_id=${2:?missing value for --run-id}
        shift 2
        ;;
      --run-id=*)
        run_id=${1#--run-id=}
        shift
        ;;
      *)
        printf 'findings_ledger path: unknown arg: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done
  run_id=${run_id:-$(default_run_id)}
  local ledger
  ledger=$(default_ledger_path "$run_id")
  ensure_parent_dir "$ledger"
  printf '%s\n' "$ledger"
}

cmd_append() {
  local ledger="" run_id=${ORCH_FINDINGS_RUN_ID:-} code="" summary="" source="" severity=""
  local finding="" impact="" remediation="" validation="" priority=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --ledger) ledger=${2:?missing value for --ledger}; shift 2 ;;
      --run-id) run_id=${2:?missing value for --run-id}; shift 2 ;;
      --code) code=${2:?missing value for --code}; shift 2 ;;
      --summary) summary=${2:?missing value for --summary}; shift 2 ;;
      --source) source=${2:?missing value for --source}; shift 2 ;;
      --severity) severity=${2:?missing value for --severity}; shift 2 ;;
      --finding) finding=${2:?missing value for --finding}; shift 2 ;;
      --impact) impact=${2:?missing value for --impact}; shift 2 ;;
      --remediation) remediation=${2:?missing value for --remediation}; shift 2 ;;
      --validation) validation=${2:?missing value for --validation}; shift 2 ;;
      --priority) priority=${2:?missing value for --priority}; shift 2 ;;
      *)
        printf 'findings_ledger append: unknown arg: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done

  require_value "--code" "$code"
  require_value "--summary" "$summary"
  ledger=${ledger:-$(default_ledger_path "${run_id:-$(default_run_id)}")}
  ensure_parent_dir "$ledger"
  write_header_if_missing "$ledger"
  format_entry "$code" "$summary" "$source" "$severity" "$finding" \
    "$impact" "$remediation" "$validation" "$priority" >> "$ledger"
  printf '%s\n' "$ledger"
}

cmd_curate_issue() {
  local ledger="" code="" title="" repo=${GH_REPO:-}
  local -a labels=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --ledger) ledger=${2:?missing value for --ledger}; shift 2 ;;
      --code) code=${2:?missing value for --code}; shift 2 ;;
      --title) title=${2:?missing value for --title}; shift 2 ;;
      --repo) repo=${2:?missing value for --repo}; shift 2 ;;
      --label) labels+=("--label" "$2"); shift 2 ;;
      *)
        printf 'findings_ledger curate-issue: unknown arg: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done

  require_value "--ledger" "$ledger"
  require_value "--code" "$code"
  require_value "GH_REPO or --repo" "$repo"
  local entry body
  entry=$(extract_entry "$ledger" "$code") || {
    printf 'findings_ledger: finding not found: %s\n' "$code" >&2
    exit 1
  }
  title=${title:-$(entry_title "$entry")}
  body=$(entry_body "$ledger" "$code" "$entry")
  if dry_run_enabled; then
    dry_run_note "gh issue create --repo $repo --title $title"
    printf '%s\n' "$body"
    return 0
  fi
  printf '%s' "$body" | gh_issue_create_body_file --repo "$repo" --title "$title" "${labels[@]}"
}

cmd_curate_pr() {
  local ledger="" code="" title="" repo=${GH_REPO:-} base=${DEFAULT_BRANCH:-main} head=""
  local docs_impact="" docs_impact_note="" docs_impact_followup=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --ledger) ledger=${2:?missing value for --ledger}; shift 2 ;;
      --code) code=${2:?missing value for --code}; shift 2 ;;
      --title) title=${2:?missing value for --title}; shift 2 ;;
      --repo) repo=${2:?missing value for --repo}; shift 2 ;;
      --base) base=${2:?missing value for --base}; shift 2 ;;
      --head) head=${2:?missing value for --head}; shift 2 ;;
      --docs-impact|--docs-impact-outcome) docs_impact=${2:?missing value for --docs-impact}; shift 2 ;;
      --docs-impact-note|--docs-impact-rationale) docs_impact_note=${2:?missing value for --docs-impact-note}; shift 2 ;;
      --docs-impact-followup) docs_impact_followup=${2:?missing value for --docs-impact-followup}; shift 2 ;;
      *)
        printf 'findings_ledger curate-pr: unknown arg: %s\n' "$1" >&2
        exit 2
        ;;
    esac
  done

  require_value "--ledger" "$ledger"
  require_value "--code" "$code"
  require_value "GH_REPO or --repo" "$repo"
  require_value "--head" "$head"
  local entry body docs_impact_decl
  entry=$(extract_entry "$ledger" "$code") || {
    printf 'findings_ledger: finding not found: %s\n' "$code" >&2
    exit 1
  }
  title=${title:-$(entry_title "$entry")}
  docs_impact_decl=$(render_docs_impact_declaration \
    "$docs_impact" "$docs_impact_note" "$docs_impact_followup")
  body=$(entry_body "$ledger" "$code" "$entry" "$docs_impact_decl")
  if dry_run_enabled; then
    dry_run_note "gh pr create --repo $repo --base $base --head $head --title $title"
    printf '%s\n' "$body"
    return 0
  fi
  printf '%s' "$body" | gh_pr_create_body_file \
    --repo "$repo" \
    --base "$base" \
    --head "$head" \
    --title "$title"
}

case "$COMMAND" in
  path) cmd_path "$@" ;;
  append) cmd_append "$@" ;;
  curate-issue) cmd_curate_issue "$@" ;;
  curate-pr) cmd_curate_pr "$@" ;;
  *)
    printf 'findings_ledger: unknown command: %s\n' "$COMMAND" >&2
    exit 2
    ;;
esac
