#!/usr/bin/env bash
# ci_autofix.sh — generate and dispatch a CI-failure remediation prompt for a PR.
#
# Usage:
#   ci_autofix.sh <project_short|config_path> <pr_number> <agent> [--dry-run]
#
# Behavior:
#   1. Inspect failed PR checks via `gh pr checks`.
#   2. Fetch failed run logs via `gh run view --log-failed`.
#   3. Build a canonical dispatch prompt with PR context + failure excerpts.
#   4. Re-dispatch the original agent.
#   5. Track retry count per PR (except in dry-run).
set -euo pipefail

TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/config_resolver.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: ci_autofix.sh <project> <pr#> <agent> [--dry-run]}
PR=${2:?missing pr number}
AGENT=${3:?missing agent}
shift 3
[ "$#" -eq 0 ] || { echo "unknown args: $*" >&2; exit 1; }

load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"
source "$TK/lib/state_persist.sh"

: "${GH_REPO:?}" "${GH_CONFIG_DIR:?}"
: "${CI_AUTOFIX_MAX_RETRIES:=3}"
: "${CI_AUTOFIX_LOG_TAIL_LINES:=240}"
: "${CI_AUTOFIX_AGENT_CAN_PUSH:=0}"

PROMPT_FILE="/tmp/dispatch-${AGENT}-autofix-pr-${PR}.md"
RETRY_STATE_NAME="ci_autofix_retries"
AUTOFIX_TICKET="${PR}"

current_retries=$(state_get "$RETRY_STATE_NAME" | jq -r --arg pr "$PR" '.[$pr] // 0')
if [ "$current_retries" -ge "$CI_AUTOFIX_MAX_RETRIES" ]; then
  audit "CI_AUTOFIX retry cap reached agent=$AGENT pr=$PR retries=$current_retries max=$CI_AUTOFIX_MAX_RETRIES"
  echo "retry cap reached for pr #$PR ($current_retries/$CI_AUTOFIX_MAX_RETRIES)" >&2
  exit 3
fi

pr_json=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr view "$PR" \
  --repo "$GH_REPO" \
  --json title,headRefName,baseRefName,changedFiles,files,url 2>/dev/null)

title=$(printf '%s' "$pr_json" | jq -r '.title')
head_branch=$(printf '%s' "$pr_json" | jq -r '.headRefName')
base_branch=$(printf '%s' "$pr_json" | jq -r '.baseRefName')
changed_files=$(printf '%s' "$pr_json" | jq -r '.changedFiles')
pr_url=$(printf '%s' "$pr_json" | jq -r '.url')
file_summary=$(printf '%s' "$pr_json" | jq -r '[.files[]?.path] | if length == 0 then "- (no files reported)" else .[] end')

checks_json=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh pr checks "$PR" \
  --repo "$GH_REPO" \
  --json name,state,bucket,link,workflow 2>/dev/null)

failed_checks=$(printf '%s' "$checks_json" | jq -r '.[] | select((.bucket // "") == "fail" or ((.state // "") | ascii_downcase) == "failure") | "\(.name)|\(.workflow // "unknown")|\(.link // "")"')

if [ -z "$failed_checks" ]; then
  audit "CI_AUTOFIX no failed checks agent=$AGENT pr=$PR"
  echo "no failed checks found for pr #$PR" >&2
  exit 0
fi

failed_count=$(printf '%s\n' "$failed_checks" | grep -c . || true)
audit "CI_AUTOFIX agent=$AGENT pr=$PR checks_failed=$failed_count"

if [ "$CI_AUTOFIX_AGENT_CAN_PUSH" = "1" ]; then
  push_scope="- commit et push autorises uniquement sur \`${head_branch}\`"
  push_boundary="  - push autorise uniquement vers \`${head_branch}\` apres validation locale pertinente"
  push_done="- [ ] Le commit correctif a ete pousse sur \`${head_branch}\` et les checks GitHub sont relances"
  git_tools_scope="- les commandes git locales necessaires pour commit et push sur la branche existante"
else
  push_scope="- commit local autorise; push interdit sauf instruction explicite de l'orchestrateur"
  push_boundary="  - pas de \`git push\`"
  push_done="- [ ] Le correctif est commite localement et attend validation/push par l'orchestrateur"
  git_tools_scope="- les commandes git locales necessaires pour commit sur la branche existante, sans push ni PR"
fi

failed_summary=""
run_logs=""
declare -A seen_runs=()

while IFS='|' read -r check_name workflow link; do
  [ -z "$check_name" ] && continue
  failed_summary+="- ${check_name} (workflow: ${workflow})"$'\n'

  run_id=$(printf '%s' "$link" | sed -n 's#.*\/actions\/runs\/\([0-9][0-9]*\).*#\1#p')
  if [ -z "$run_id" ]; then
    run_logs+="### ${check_name}"$'\n'"No run id available from link: ${link}"$'\n\n'
    continue
  fi

  if [ -n "${seen_runs[$run_id]:-}" ]; then
    continue
  fi
  seen_runs[$run_id]=1

  run_log=$(GH_CONFIG_DIR="$GH_CONFIG_DIR" gh run view "$run_id" --log-failed --repo "$GH_REPO" 2>/dev/null \
    | tail -n "$CI_AUTOFIX_LOG_TAIL_LINES" || true)
  if [ -z "$run_log" ]; then
    run_log="No failed-step log returned for run ${run_id}."
  else
    run_log="[tail -n ${CI_AUTOFIX_LOG_TAIL_LINES} of failed log for run ${run_id}]"$'\n'"${run_log}"
  fi
  run_logs+="### Run ${run_id}"$'\n'"${run_log}"$'\n\n'
done <<<"$failed_checks"

cat > "$PROMPT_FILE" <<EOF
# CI autofix dispatch — ${PROJECT} agent: ${AGENT}
# PR: #${PR} ${title}

## Objectif

Corriger tous les checks CI en echec de la PR #${PR} sans elargir le scope au-dela de la branche \`${head_branch}\`.

## Format de sortie attendu

- Branche locale a reprendre: \`${head_branch}\`
- Base de reference: \`${base_branch}\`
- Commit convention: \`fix(pr-${PR}): <resume en une ligne>\`
- Politique git: ${push_scope}
- Rapport final attendu:

\`\`\`text
pr ${PR} autofix status:
  branch: ${head_branch}
  head: <sha>
  failed checks addressed:
${failed_summary}
  validation: <command(s) run> — PASS|FAIL|SKIPPED
  blockers: none | <list>
\`\`\`

## Tools / sources autorises

- \`gh pr view ${PR} --repo ${GH_REPO}\`
- \`gh pr checks ${PR} --repo ${GH_REPO}\`
- \`gh run view <run-id> --repo ${GH_REPO} --log-failed\`
- les commandes locales minimales necessaires pour reproduire et corriger les checks en echec
${git_tools_scope}

## Boundaries / interdictions

- Rester sur la branche PR existante: \`${head_branch}\`
- Fichiers touches par la PR actuelle (${changed_files}):
${file_summary}
- Interdictions absolues:
${push_boundary}
  - pas de nouvelle PR
  - pas de changement hors du scope de la PR
  - pas de \`--no-verify\`
  - pas de \`--admin\`

## Definition of Done verifiable

- [ ] Chaque check en echec de la PR #${PR} a ete traite explicitement
- [ ] Les logs CI ont ete relus avant correction
- [ ] Les changements restent confines au scope utile de la PR
- [ ] Une validation locale ou equivalente a ete relancee et son resultat est rapporte
- [ ] Le rapport final cite les checks corriges et les commandes executees
${push_done}

## Preuves attendues

- URL PR: ${pr_url}
- Liste des checks en echec:
${failed_summary}
- Extraits de logs CI ayant motive la correction
- Sortie des commandes de validation executees

## Failure context

${run_logs}
EOF

if dry_run_enabled; then
  dry_run_note "state_update ${RETRY_STATE_NAME} for pr ${PR}"
else
  state_update "$RETRY_STATE_NAME" ". + {\"${PR}\": ((.[\"${PR}\"] // 0) + 1)}"
fi

dispatch_args=("$CFG_ARG" "$AGENT" "$AUTOFIX_TICKET" "$PROMPT_FILE")
if dry_run_enabled; then
  dispatch_args+=(--dry-run)
fi

bash "$TK/scripts/dispatch_ticket.sh" "${dispatch_args[@]}"
