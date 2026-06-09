#!/usr/bin/env bats
# tests/docs_generator_smoke.bats — verification for the ORDO documentation
# system and downstream docs generator (#263 under epic #257).
#
# Acceptance coverage:
#   - top-level documentation links resolve (README.md Documentation Map);
#   - generator output is deterministic when the generator exists (#261);
#   - generated output is free of obvious secrets or live private paths.
#
# Skip-when-absent: features under sibling tickets (#258 docs architecture,
# #259 install/integration/usage guides, #261 docs generator) may not yet
# be present in the tree this test runs against. Each block detects the
# feature and either verifies it or `skip`s with a documented reason, so
# this file activates naturally as those tickets land on the default
# branch. It must always pass on the orch baseline at c790a6c.

load './helpers.bash'

setup() {
  setup_orch_test
  ROOT="${ROOT:-$(cd "$BATS_TEST_DIRNAME/.." && pwd)}"
  export ROOT
}

# detect_real_repo_root echoes the path to the real repository root and
# returns 0 when reachable, or returns 1 (without printing) when running
# inside a sanitized-mirror context where README.md, PRODUCT.md, and
# docs/ are not present.
#
# Callers must use the standard pattern:
#
#   repo=$(detect_real_repo_root) || skip "..."
#
# `skip` cannot be called from inside this helper because the helper
# runs in a $(...) subshell and bats' skip signal does not propagate
# out of subshells.
#
# Why this exists (PR #319 autofix): scripts/run_bats.sh and the
# nested scripts/run_shell_tests.sh both mirror only config/examples/
# lib/scripts/templates/tests (and a few extras) into a temporary
# toolkit dir before invoking bats. The repo-root README.md and
# PRODUCT.md, plus the docs/ tree under run_bats.sh's mirror, are
# therefore unreachable at the test's BATS_TEST_DIRNAME/.. path. Tests
# that assert against those files must detect the sanitized-mirror
# context and skip rather than fail spuriously. The CI failure on PR
# #319 was exactly this pattern; the underlying fact (the README map
# is well-formed) is already verified by the test in isolated mode.
detect_real_repo_root() {
  local candidate="${ORCH_TOOLKIT_ROOT:-${ROOT:-}}"
  if [[ -n "$candidate" && -f "$candidate/README.md" && -f "$candidate/scripts/run_bats.sh" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

docs_generator_smoke_config() {
  local cfg="$BATS_TEST_TMPDIR/docs-smoke.config.sh"
  cat > "$cfg" <<'EOF'
PROJECT="docs-smoke"
DEFAULT_BRANCH="main"
EOF
  printf '%s\n' "$cfg"
}

docs_generator_target_dir() {
  local target="$BATS_TEST_TMPDIR/docs-smoke-target"
  mkdir -p "$target"
  printf '# docs smoke target\n' > "$target/README.md"
  printf '%s\n' "$target"
}

install_fixed_date_stub() {
  local bin_dir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "-u +%Y-%m-%dT%H:%M:%SZ" ]]; then
  printf '%s\n' "2026-01-02T03:04:05Z"
  exit 0
fi
exec /usr/bin/date "$@"
EOF
  chmod +x "$bin_dir/date"
  printf '%s\n' "$bin_dir"
}

@test "README documentation map lists ORDO topic anchors" {
  local repo
  repo=$(detect_real_repo_root) \
    || skip "running in sanitized mirror; README.md not reachable from ${ROOT:-<unset>}"
  local readme="$repo/README.md"
  [ -f "$readme" ]
  run grep -q '^## Documentation Map' "$readme"
  [ "$status" -eq 0 ]
  # Every doc category required by the issue's acceptance criterion #1
  # (install, integration, usage, user docs, developer docs) maps to one
  # of the existing topic anchors in the table. Until #258/#259 split
  # those into dedicated rows, accept any of the established topic anchors
  # so this test does not break the baseline.
  local expected
  for expected in \
    "PRODUCT.md" \
    "docs/universal-fleet-manual.md" \
    "docs/dispatch-planning.md" \
    "docs/host-health-runbook.md" \
    "docs/validation/README.md"
  do
    run grep -Fq "$expected" "$readme"
    [ "$status" -eq 0 ]
  done
}

@test "every README documentation map link resolves to a real file" {
  local repo
  repo=$(detect_real_repo_root) \
    || skip "running in sanitized mirror; README.md not reachable from ${ROOT:-<unset>}"
  local readme="$repo/README.md"
  local missing=0
  local target
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    case "$target" in
      http*://*) continue ;;
      "#"*) continue ;;
    esac
    if [ ! -e "$repo/$target" ]; then
      printf 'broken docs map link: %s\n' "$target" >&3
      missing=$((missing + 1))
    fi
  done < <(awk '
    /^## Documentation Map/ { in_map = 1; next }
    in_map && /^## / { in_map = 0 }
    in_map {
      while (match($0, /\[[^]]+\]\(([^)]+)\)/, m)) {
        # m[1] is the captured URL/path; gawk-only.
        $0 = substr($0, RSTART + RLENGTH)
      }
    }
  ' "$readme")
  # The awk approach above does not work with mawk; use a simple grep
  # fallback that extracts every (target) inside parentheses on the
  # documentation map rows.
  if [ "$missing" -eq 0 ]; then
    while IFS= read -r line; do
      target=${line#*\(}
      target=${target%%\)*}
      [ -n "$target" ] || continue
      case "$target" in
        http*://*) continue ;;
      esac
      if [ ! -e "$repo/$target" ]; then
        printf 'broken docs map link: %s\n' "$target" >&3
        missing=$((missing + 1))
      fi
    done < <(awk '/^## Documentation Map/{flag=1; next} /^## /{flag=0} flag' "$readme" \
              | grep -oE '\([^)]+\)' \
              | tr -d '()')
  fi
  [ "$missing" -eq 0 ]
}

@test "docs generator produces deterministic output when present (#261)" {
  if [ ! -x "$ROOT/scripts/docs_generate.sh" ]; then
    skip "docs generator (#261) not yet present at this base"
  fi
  local cfg target fixed_bin
  cfg=$(docs_generator_smoke_config)
  target=$(docs_generator_target_dir)
  fixed_bin=$(install_fixed_date_stub)
  local out_dir="$BATS_TEST_TMPDIR/gen"
  mkdir -p "$out_dir"
  run env PATH="$fixed_bin:$PATH" timeout 30 bash "$ROOT/scripts/docs_generate.sh" "$cfg" \
    --target-dir "$target" --output-dir "$out_dir" --intent "Docs smoke" \
    --apply --overwrite --json
  [ "$status" -eq 0 ]
  local snapshot_a snapshot_b
  snapshot_a=$(find "$out_dir" -type f -print0 | sort -z | xargs -0 sha256sum)
  run env PATH="$fixed_bin:$PATH" timeout 30 bash "$ROOT/scripts/docs_generate.sh" "$cfg" \
    --target-dir "$target" --output-dir "$out_dir" --intent "Docs smoke" \
    --apply --overwrite --json
  [ "$status" -eq 0 ]
  snapshot_b=$(find "$out_dir" -type f -print0 | sort -z | xargs -0 sha256sum)
  [ "$snapshot_a" = "$snapshot_b" ]
}

@test "generated docs do not embed secrets or live private paths" {
  if [ ! -x "$ROOT/scripts/docs_generate.sh" ]; then
    skip "docs generator (#261) not yet present at this base"
  fi
  local cfg target fixed_bin
  cfg=$(docs_generator_smoke_config)
  target=$(docs_generator_target_dir)
  fixed_bin=$(install_fixed_date_stub)
  local out_dir="$BATS_TEST_TMPDIR/gen-secrets"
  mkdir -p "$out_dir"
  run env PATH="$fixed_bin:$PATH" timeout 30 bash "$ROOT/scripts/docs_generate.sh" "$cfg" \
    --target-dir "$target" --output-dir "$out_dir" --intent "Docs smoke" \
    --apply --overwrite --json
  [ "$status" -eq 0 ]
  # Forbidden patterns: GitHub tokens, env-leaked home paths, private
  # gh auth files, raw .env exposure.
  local pattern hits=0
  for pattern in \
    'ghp_[A-Za-z0-9]{20,}' \
    'github_pat_[A-Za-z0-9]{20,}' \
    'AKIA[0-9A-Z]{16}' \
    '/home/rbok(/|$)' \
    '\.env[^.]'
  do
    if grep -rEq "$pattern" "$out_dir" 2>/dev/null; then
      printf 'forbidden pattern in generated docs: %s\n' "$pattern" >&3
      hits=$((hits + 1))
    fi
  done
  [ "$hits" -eq 0 ]
}

@test "secret/private-path no-leak applies to the toolkit's own docs" {
  local repo
  repo=$(detect_real_repo_root) \
    || skip "running in sanitized mirror; tracked docs tree not reachable from ${ROOT:-<unset>}"
  # Even before the generator (#261) lands, this assertion guards the
  # documentation already shipping in the repo. Live private paths
  # (`/home/rbok`) and obvious secret prefixes must not leak into the
  # tracked docs tree.
  local pattern
  for pattern in \
    'ghp_[A-Za-z0-9]{20,}' \
    'github_pat_[A-Za-z0-9]{20,}' \
    'AKIA[0-9A-Z]{16}' \
    '/home/rbok(/|$)'
  do
    run grep -rEq "$pattern" "$repo/docs" "$repo/README.md" "$repo/PRODUCT.md"
    [ "$status" -ne 0 ] || {
      printf 'forbidden pattern in tracked docs: %s\n' "$pattern" >&3
      return 1
    }
  done
}
