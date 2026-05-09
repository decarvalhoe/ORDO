#!/usr/bin/env bash
# tests/test_docs_index_drift.sh — guard against docs/*.md drift from
# docs/INDEX.md. Implements issue #425 (parent epic #257).
#
# What this asserts:
#   Every top-level Markdown file under docs/ (i.e. docs/*.md, NOT
#   subdirectories like docs/runbooks/, docs/validation/, docs/architecture/)
#   must be referenced at least once from docs/INDEX.md. The convention is
#   already documented in docs/INDEX.md → "When to update this page"; this
#   test enforces it mechanically so a contributor cannot land an orphaned
#   top-level doc.
#
# What this does NOT assert:
#   - Subdirectory docs (docs/runbooks/, docs/validation/, docs/architecture/,
#     docs/cli/, docs/design/, docs/templates/) — those have their own
#     indexing conventions (per-folder README, per-issue runbook naming).
#   - That every link target inside INDEX.md exists on disk. A reverse-drift
#     guard could cover that too, but it is out of scope for #425.
#
# Exit codes:
#   0  — no orphans
#   1  — at least one orphan; the orphan list is printed to stderr
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEX="$ROOT/docs/INDEX.md"

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

[ -s "$INDEX" ] || fail "docs/INDEX.md is missing or empty"

# Enumerate top-level docs/*.md files, excluding INDEX.md itself.
mapfile -t docs < <(
  find "$ROOT/docs" -maxdepth 1 -mindepth 1 -type f -name '*.md' -printf '%f\n' \
    | grep -vx 'INDEX.md' \
    | sort
)

[ "${#docs[@]}" -gt 0 ] || fail "no top-level docs/*.md files found"

# Extract every link target ending in .md from INDEX.md. We accept three
# patterns the file actually uses:
#   1. Markdown links:                  [label](path/to/file.md)
#   2. Markdown links with anchors:     [label](file.md#section)
#   3. Code-fence-styled link labels:   [`path/to/file.md`](path/to/file.md)
# We then keep only paths that resolve to docs/<name>.md (top level), so
# subdirectory references and external links do not pollute the link set.
mapfile -t linked < <(
  grep -oE '\(([^)]*\.md)(#[^)]*)?\)' "$INDEX" \
    | sed -E 's/^\(//; s/\)$//; s/#.*$//' \
    | sort -u
)

is_linked() {
  local target=$1
  local entry
  for entry in "${linked[@]}"; do
    # Bare top-level reference, e.g. (foo.md)
    if [ "$entry" = "$target" ]; then
      return 0
    fi
    # Explicit `docs/` prefix, e.g. (docs/foo.md) — INDEX.md does not use
    # this form today but the test accepts it so a future restructure
    # remains backwards-compatible.
    if [ "$entry" = "docs/$target" ]; then
      return 0
    fi
  done
  return 1
}

orphans=()
for doc in "${docs[@]}"; do
  if ! is_linked "$doc"; then
    orphans+=("$doc")
  fi
done

if [ "${#orphans[@]}" -gt 0 ]; then
  printf 'docs/INDEX.md is missing entries for %d top-level doc(s):\n' \
    "${#orphans[@]}" >&2
  for doc in "${orphans[@]}"; do
    printf '  - docs/%s\n' "$doc" >&2
  done
  # shellcheck disable=SC2016  # `[label](%s)` is a Markdown template printed verbatim, not a shell expression.
  printf '\nAdd a Markdown link `[label](%s)` (or under an explicit `docs/` prefix) to docs/INDEX.md.\n' "$doc" >&2
  exit 1
fi

printf 'ok - test_docs_index_drift (%d top-level docs, all linked from INDEX.md)\n' \
  "${#docs[@]}"
