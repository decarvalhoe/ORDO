#!/usr/bin/env bash
# scripts/project_meta_context.sh - persistent low-cost project meta context.
#
# Usage:
#   project_meta_context.sh <project_short|config_path> [--print] [--force]
#   project_meta_context.sh <project_short|config_path> --path
#
# It builds a compact document index/rules summary from docs and repo metadata,
# stores it in orchestrator state, and only regenerates when the doc signature
# changes. This keeps cross-session project understanding cheap and stable.
set -euo pipefail
TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/config_resolver.sh"

CFG_ARG=${1:?usage: project_meta_context.sh <project> [--print|--path] [--force]}
PRINT=0
PATH_ONLY=0
FORCE=0
shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --print) PRINT=1 ;;
    --path) PATH_ONLY=1 ;;
    --force) FORCE=1 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

load_project_config "$CFG_ARG"
source "$TK/lib/audit_log.sh"
source "$TK/lib/state_persist.sh"
source "$TK/lib/agent_inventory.sh"

: "${DOC_META_MAX_FILES:=250}"
: "${DOC_META_MAX_RULE_LINES:=80}"
: "${DOC_META_MAX_DIFF_LINES:=120}"

repo_root() {
  if [ -n "${DOC_META_REPO:-}" ] && [ -d "$DOC_META_REPO" ]; then
    printf '%s\n' "$DOC_META_REPO"
    return 0
  fi
  if [ -n "${PROJECT_REPO_ROOT:-}" ] && [ -d "$PROJECT_REPO_ROOT" ]; then
    printf '%s\n' "$PROJECT_REPO_ROOT"
    return 0
  fi
  local label pane workdir
  while IFS='|' read -r label pane workdir; do
    if [ -d "$workdir/.git" ]; then
      printf '%s\n' "$workdir"
      return 0
    fi
  done < <(agent_inventory_entries 2>/dev/null || true)
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    git rev-parse --show-toplevel
    return 0
  fi
  return 1
}

doc_paths() {
  if [[ -n "${DOC_META_PATHS+x}" && "${#DOC_META_PATHS[@]}" -gt 0 ]]; then
    printf '%s\n' "${DOC_META_PATHS[@]}"
    return 0
  fi
  printf '%s\n' \
    AGENTS.md \
    README.md \
    INDEX.md \
    docs \
    .github/workflows \
    package.json \
    pyproject.toml \
    requirements.txt \
    backend/README.md \
    backend/requirements.txt \
    frontend/README.md \
    frontend/package.json
}

allowed_doc_file() {
  case "$1" in
    *.md|*.mdx|*.txt|*.rst|*.yml|*.yaml|*.json|*.toml|*.ini|*.cfg|*.config.sh)
      return 0
      ;;
  esac
  return 1
}

collect_files() {
  local repo=$1 path file
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -d "$repo/.git" ]; then
      git -C "$repo" ls-files -- "$path" 2>/dev/null || true
      git -C "$repo" ls-files --others --exclude-standard -- "$path" 2>/dev/null || true
    elif [ -d "$repo/$path" ]; then
      find "$repo/$path" -type f 2>/dev/null | sed "s|^$repo/||"
    elif [ -f "$repo/$path" ]; then
      printf '%s\n' "$path"
    fi
  done < <(doc_paths) \
    | while IFS= read -r file; do
        [ -f "$repo/$file" ] || continue
        allowed_doc_file "$file" || continue
        printf '%s\n' "$file"
      done \
    | sort -u \
    | head -n "$DOC_META_MAX_FILES"
}

build_manifest() {
  local repo=$1 out=$2 file sha bytes
  : > "$out"
  while IFS= read -r file; do
    sha=$(sha256sum "$repo/$file" | awk '{print $1}')
    bytes=$(wc -c < "$repo/$file" | tr -d ' ')
    printf '%s\t%s\t%s\n' "$file" "$sha" "$bytes" >> "$out"
  done < <(collect_files "$repo")
}

manifest_signature() {
  local manifest=$1
  sha256sum "$manifest" | awk '{print $1}'
}

manifest_diff() {
  local old=$1 new=$2
  if [ ! -s "$old" ]; then
    awk -F '\t' '{print "added\t" $1}' "$new"
    return 0
  fi
  awk -F '\t' 'NR==FNR { old[$1]=$2; next } !($1 in old) { print "added\t" $1 } ($1 in old && old[$1] != $2) { print "changed\t" $1 }' "$old" "$new"
  awk -F '\t' 'NR==FNR { newer[$1]=1; next } !($1 in newer) { print "removed\t" $1 }' "$new" "$old"
}

first_heading() {
  local repo=$1 file=$2 heading
  heading=$(grep -m1 -E '^(#|name:|title:)[[:space:]]*' "$repo/$file" 2>/dev/null || true)
  heading=${heading#\#}
  heading=${heading#\#}
  heading=${heading#\#}
  heading=${heading#\#}
  heading=${heading#\#}
  heading=${heading#\#}
  heading=${heading#name:}
  heading=${heading#title:}
  heading=$(printf '%s' "$heading" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  printf '%s\n' "${heading:-"(no heading)"}"
}

subheadings() {
  local repo=$1 file=$2
  grep -E '^#{2,3}[[:space:]]+' "$repo/$file" 2>/dev/null \
    | head -n 4 \
    | sed -E 's/^#{2,3}[[:space:]]+/- /' || true
}

rule_lines() {
  local repo=$1 manifest=$2 count=0 file
  while IFS=$'\t' read -r file _sha _bytes; do
    case "$file" in
      *.md|*.mdx|*.txt|*.rst|*.yml|*.yaml|*.toml|*.config.sh) ;;
      *) continue ;;
    esac
    while IFS= read -r line; do
      printf -- "- \`%s\`: %s\n" "$file" "$line"
      count=$((count + 1))
      [ "$count" -ge "$DOC_META_MAX_RULE_LINES" ] && return 0
    done < <(grep -inE 'jamais|never|must|required|obligatoire|toujours|always|pr target|default branch|develop|main|staging|ci|test|deploy|secret|capabilit|permission|conventional|scope|interdit|blocked|dependency|dependance' "$repo/$file" 2>/dev/null | sed -E 's/[[:space:]]+/ /g' | head -n 12)
  done < "$manifest"
  return 0
}

STATE_DOC=$(state_file project_meta_context.md)
STATE_SIG=$(state_file project_meta_context.sig)
STATE_MANIFEST=$(state_file project_meta_context.manifest.tsv)
STATE_JSON=$(state_file project_meta_context.json)

if [ "$PATH_ONLY" -eq 1 ]; then
  printf '%s\n' "$STATE_DOC"
  exit 0
fi

REPO=$(repo_root) || die "DOC_META repo not found project=$PROJECT"
tmp_manifest=$(mktemp)
tmp_doc=$(mktemp)
cleanup() {
  rm -f "$tmp_manifest" "$tmp_doc"
}
trap cleanup EXIT

build_manifest "$REPO" "$tmp_manifest"
signature=$(manifest_signature "$tmp_manifest")
previous_signature=$(cat "$STATE_SIG" 2>/dev/null || true)

if [ "$FORCE" -eq 0 ] && [ "$signature" = "$previous_signature" ] && [ -s "$STATE_DOC" ]; then
  audit "DOC_META unchanged project=$PROJECT signature=$signature path=$STATE_DOC"
  if [ "$PRINT" -eq 1 ]; then
    cat "$STATE_DOC"
  else
    printf '%s\n' "$STATE_DOC"
  fi
  exit 0
fi

generated_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
{
  printf '# Project Meta Context - %s\n\n' "$PROJECT"
  printf -- "- generated_at: \`%s\`\n" "$generated_at"
  printf -- "- repo: \`%s\`\n" "$REPO"
  printf -- "- doc_signature: \`%s\`\n" "$signature"
  printf -- "- files_indexed: \`%s\`\n" "$(wc -l < "$tmp_manifest" | tr -d ' ')"
  printf -- "- policy: regenerate only when the documentation signature changes, or with \`--force\`.\n\n"

  printf '## Documentation Diff Since Cached Context\n\n'
  diff_output=$(manifest_diff "$STATE_MANIFEST" "$tmp_manifest" | head -n "$DOC_META_MAX_DIFF_LINES")
  if [ -n "$diff_output" ]; then
    printf '%s\n' "$diff_output" | sed -E 's/^/- /'
  else
    printf -- '- initial build or no file-level diff available\n'
  fi
  printf '\n## Project Map\n\n'
  while IFS=$'\t' read -r file _sha bytes; do
    printf "### \`%s\` (%s bytes)\n\n" "$file" "$bytes"
    printf '%s\n\n' "$(first_heading "$REPO" "$file")"
    subheadings "$REPO" "$file"
    printf '\n'
  done < "$tmp_manifest"

  printf '## High-Signal Rules And Constraints\n\n'
  rules=$(rule_lines "$REPO" "$tmp_manifest")
  if [ -n "$rules" ]; then
    printf '%s\n' "$rules"
  else
    printf -- '- No high-signal rule lines matched the deterministic scanner.\n'
  fi
} > "$tmp_doc"

cp "$tmp_doc" "$STATE_DOC"
cp "$tmp_manifest" "$STATE_MANIFEST"
printf '%s\n' "$signature" > "$STATE_SIG"
jq -nc \
  --arg project "$PROJECT" \
  --arg repo "$REPO" \
  --arg generated_at "$generated_at" \
  --arg signature "$signature" \
  --arg path "$STATE_DOC" \
  --argjson files "$(wc -l < "$tmp_manifest" | tr -d ' ')" \
  '{project:$project,repo:$repo,generated_at:$generated_at,signature:$signature,path:$path,files:$files}' > "$STATE_JSON"

audit "DOC_META regenerated project=$PROJECT signature=$signature path=$STATE_DOC"
if [ "$PRINT" -eq 1 ]; then
  cat "$STATE_DOC"
else
  printf '%s\n' "$STATE_DOC"
fi
