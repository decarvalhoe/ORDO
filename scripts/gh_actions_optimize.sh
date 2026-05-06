#!/usr/bin/env bash
# gh_actions_optimize.sh — audit/scaffold GitHub Actions for CI throughput.
#
# Usage:
#   gh_actions_optimize.sh <project_short|config_path> [--audit|--scaffold] [--repo-root PATH] [--dry-run]
#
# The audit mode is intentionally heuristic and conservative. It surfaces
# workflow smells that often slow or destabilize multi-agent delivery, but it
# never rewrites project workflows.
set -euo pipefail

TK=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

source "$TK/lib/dry_run.sh"
source "$TK/lib/config_resolver.sh"

dry_run_parse_args "$@"
set -- "${DRY_RUN_ARGS[@]}"

CFG_ARG=${1:?usage: gh_actions_optimize.sh <project> [--audit|--scaffold] [--repo-root PATH] [--dry-run]}
shift

MODE="audit"
REPO_ROOT_ARG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --audit)
      MODE="audit"
      shift
      ;;
    --scaffold)
      MODE="scaffold"
      shift
      ;;
    --repo-root)
      REPO_ROOT_ARG=${2:?--repo-root requires a path}
      shift 2
      ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

load_project_config "$CFG_ARG"

source "$TK/lib/audit_log.sh"

: "${PROJECT:?}" "${DEFAULT_BRANCH:=main}"
: "${GHA_OPT_OVERWRITE:=0}"

repo_root="${REPO_ROOT_ARG:-${GHA_OPT_REPO_ROOT:-${PROJECT_REPO_ROOT:-${SUPERVISOR_REPO:-}}}}"
if [ -z "$repo_root" ] && [ -n "${AGENT_PANES+x}" ] && [ "${#AGENT_PANES[@]}" -gt 0 ]; then
  first_entry=${AGENT_PANES[0]}
  repo_root=${first_entry##*|}
fi

[ -n "$repo_root" ] || { echo "repo root unknown; set PROJECT_REPO_ROOT or --repo-root" >&2; exit 2; }
[ -d "$repo_root" ] || { echo "repo root not found: $repo_root" >&2; exit 2; }

workflow_dir="$repo_root/.github/workflows"

emit() {
  local severity=${1:?} code=${2:?} file=${3:?} message=${4:?}
  printf '%s\t%s\t%s\t%s\n' "$severity" "$code" "$file" "$message"
  audit "GHA_OPT severity=$severity code=$code file=$file message=$message"
}

has_workflows() {
  [ -d "$workflow_dir" ] && find "$workflow_dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | grep -q .
}

workflow_rel() {
  local file=${1:?}
  printf '%s\n' "${file#"$repo_root"/}"
}

audit_workflows() {
  local file rel content

  if ! has_workflows; then
    emit "WARN" "gha-no-workflows" ".github/workflows" \
      "No GitHub Actions workflows found; use --scaffold for a baseline CI."
    return 0
  fi

  while IFS= read -r file; do
    rel=$(workflow_rel "$file")
    content=$(tr -d '\r' < "$file")

    [[ "$content" == *"permissions:"* ]] || \
      emit "WARN" "gha-missing-permissions" "$rel" \
        "Add explicit least-privilege permissions; workflows using gh api need matching scopes."

    [[ "$content" == *"concurrency:"* ]] || \
      emit "WARN" "gha-missing-concurrency" "$rel" \
        "Add concurrency to collapse superseded runs and reduce duplicate CI load."

    if [[ "$content" == *"pull_request:"* && "$content" == *"push:"* ]]; then
      if [[ "$content" == *"feat/**"* || "$content" == *"fix/**"* || "$content" == *"feature/**"* ]]; then
        emit "WARN" "gha-pr-push-duplicate-risk" "$rel" \
          "Workflow runs on pull_request and feature/fix push; PR branches can produce duplicate check runs."
      fi
    fi

    if [[ "$content" == *"github.event_name"* && "$content" == *"push"* && "$content" == *"pytest"* && "$content" == *"--cov"* ]]; then
      emit "WARN" "gha-full-tests-on-any-push" "$rel" \
        "Full coverage tests appear keyed only to push; distinguish default-branch push from feature-branch push."
    fi

    if [[ "$content" == *"actions/workflows"* && "$content" == *"gh api"* && "$content" != *"actions: read"* ]]; then
      emit "ERROR" "gha-actions-read-missing" "$rel" \
        "Workflow calls the Actions API with gh api but does not grant GITHUB_TOKEN actions: read."
    fi

    if [[ "$content" == *"pytest"* && "$content" != *"paths-filter"* && "$content" != *"paths:"* ]]; then
      emit "INFO" "gha-no-path-filter" "$rel" \
        "Backend tests run without an obvious path/risk filter; consider impacted-test tiers."
    fi

    if [[ "$content" == *"actions/setup-python"* && "$content" != *"cache:"* ]]; then
      emit "INFO" "gha-python-cache-missing" "$rel" \
        "setup-python is used without dependency caching."
    fi

    if [[ "$content" == *"pytest"* && "$content" != *"-n auto"* && "$content" != *"--numprocesses"* ]]; then
      emit "INFO" "gha-pytest-xdist-missing" "$rel" \
        "pytest is used without visible xdist parallelization."
    fi
  done < <(find "$workflow_dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)
}

scaffold_ci() {
  local target="$workflow_dir/ci.yml"
  local has_backend=0 has_frontend=0

  if [ -f "$repo_root/backend/requirements.txt" ] || [ -f "$repo_root/backend/pyproject.toml" ] || [ -f "$repo_root/pyproject.toml" ]; then
    has_backend=1
  fi
  if [ -f "$repo_root/frontend/package.json" ] || [ -f "$repo_root/package.json" ]; then
    has_frontend=1
  fi

  if [ -f "$target" ] && [ "$GHA_OPT_OVERWRITE" != "1" ]; then
    emit "ERROR" "gha-scaffold-exists" ".github/workflows/ci.yml" \
      "Refusing to overwrite existing CI workflow; set GHA_OPT_OVERWRITE=1 to replace."
    return 1
  fi

  if dry_run_enabled; then
    dry_run_note "mkdir -p $workflow_dir"
    dry_run_note "write $target"
    emit "INFO" "gha-scaffold-dry-run" ".github/workflows/ci.yml" \
      "Would create baseline CI workflow for default branch $DEFAULT_BRANCH."
    return 0
  fi

  mkdir -p "$workflow_dir"
  cat > "$target" <<EOF
name: CI

on:
  pull_request:
    branches: ["$DEFAULT_BRANCH"]
  push:
    branches: ["$DEFAULT_BRANCH"]
  workflow_dispatch:
  schedule:
    - cron: "17 3 * * *"

concurrency:
  group: ci-\${{ github.workflow }}-\${{ github.ref }}
  cancel-in-progress: \${{ github.ref != 'refs/heads/$DEFAULT_BRANCH' }}

permissions:
  contents: read
  pull-requests: read

jobs:
  detect-changes:
    name: Detect changed areas
    runs-on: ubuntu-latest
    outputs:
      backend: \${{ steps.filter.outputs.backend }}
      frontend: \${{ steps.filter.outputs.frontend }}
      shared: \${{ steps.filter.outputs.shared }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: filter
        uses: dorny/paths-filter@v3
        with:
          filters: |
            backend:
              - "backend/**"
              - "pyproject.toml"
            frontend:
              - "frontend/**"
              - "package.json"
            shared:
              - ".github/workflows/**"
              - "scripts/**"
EOF

  if [ "$has_backend" -eq 1 ]; then
    cat >> "$target" <<'EOF'

  backend:
    name: Backend CI
    needs: [detect-changes]
    if: >-
      github.event_name == 'workflow_dispatch' ||
      github.event_name == 'schedule' ||
      github.ref_name == github.event.repository.default_branch ||
      needs.detect-changes.outputs.backend == 'true' ||
      needs.detect-changes.outputs.shared == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/setup-python@v5
        with:
          python-version: "3.11"
          cache: pip
          cache-dependency-path: |
            backend/requirements*.txt
            pyproject.toml
      - name: Install backend dependencies
        run: |
          if [ -f backend/requirements-test.txt ]; then
            pip install -r backend/requirements-test.txt
          elif [ -f backend/requirements.txt ]; then
            pip install -r backend/requirements.txt pytest pytest-xdist pytest-cov
          else
            pip install -e '.[test]' || pip install pytest pytest-xdist pytest-cov
          fi
      - name: Backend tests
        working-directory: ./backend
        run: |
          if [ "${{ github.event_name }}" = "pull_request" ]; then
            pytest -n auto -q --maxfail=1 --no-cov
          else
            pytest -n auto --cov=app --cov-report=term --cov-report=xml
          fi
EOF
  fi

  if [ "$has_frontend" -eq 1 ]; then
    cat >> "$target" <<'EOF'

  frontend:
    name: Frontend CI
    needs: [detect-changes]
    if: >-
      github.event_name == 'workflow_dispatch' ||
      github.event_name == 'schedule' ||
      github.ref_name == github.event.repository.default_branch ||
      needs.detect-changes.outputs.frontend == 'true' ||
      needs.detect-changes.outputs.shared == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "22"
          cache: npm
          cache-dependency-path: |
            package-lock.json
            frontend/package-lock.json
      - name: Install frontend dependencies
        run: |
          if [ -f frontend/package-lock.json ]; then
            npm ci --prefix frontend
          elif [ -f package-lock.json ]; then
            npm ci
          fi
      - name: Frontend tests
        run: |
          if [ -f frontend/package.json ]; then
            npm test --prefix frontend -- --runInBand
          elif [ -f package.json ]; then
            npm test -- --runInBand
          fi
EOF
  fi

  if [ "$has_backend" -ne 1 ] && [ "$has_frontend" -ne 1 ]; then
    cat >> "$target" <<'EOF'

  smoke:
    name: Repository smoke
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Diff hygiene
        run: git diff --check
EOF
  fi

  emit "INFO" "gha-scaffold-created" ".github/workflows/ci.yml" \
    "Created baseline CI workflow with path filters, concurrency, caches, and tiered PR/default-branch behavior."
}

case "$MODE" in
  audit)
    audit_workflows
    ;;
  scaffold)
    scaffold_ci
    ;;
  *)
    echo "unknown mode: $MODE" >&2
    exit 2
    ;;
esac
