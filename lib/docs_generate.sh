#!/usr/bin/env bash
# lib/docs_generate.sh — reusable documentation generator helpers.
#
# This library powers scripts/docs_generate.sh and is also reusable by
# downstream projects that want to call the generator non-interactively.
# It owns:
#   - input validation
#   - layer resolution (default normal-dev, optional gxp-grade and six-sigma)
#   - template discovery in templates/docs/
#   - placeholder substitution
#   - manifest construction
#
# The library has zero side effects on source. It does not touch state, logs,
# or audit channels. Callers wire those in. PROJECT is not required.

if [[ -n "${DOCS_GENERATE_LIB_LOADED:-}" ]]; then
  return 0
fi
DOCS_GENERATE_LIB_LOADED=1

_DOCS_GENERATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCS_GENERATE_TOOLKIT_ROOT="$(cd "$_DOCS_GENERATE_LIB_DIR/.." && pwd)"
DOCS_GENERATE_TEMPLATE_ROOT="$DOCS_GENERATE_TOOLKIT_ROOT/templates/docs"

# Layers that are always emitted regardless of grade selection.
# `index` and `maintenance` are root-level single-file layers; the others map
# to subdirectories of templates/docs/.
DOCS_GENERATE_DEFAULT_LAYERS=(
  index
  developer
  user
  operator
  integration
  validation
  maintenance
)

# Optional layers, only emitted when explicitly selected.
DOCS_GENERATE_OPTIONAL_LAYERS=(gxp sixsigma)

docs_generate_template_root() {
  local override=${DOCS_GENERATE_TEMPLATE_ROOT_OVERRIDE:-}
  if [[ -n "$override" && -d "$override" ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  printf '%s\n' "$DOCS_GENERATE_TEMPLATE_ROOT"
}

docs_generate_layer_dir_for() {
  local layer=$1
  case "$layer" in
    developer|user|operator|integration|validation|gxp|sixsigma)
      printf '%s/\n' "$layer"
      ;;
    index|maintenance)
      printf ''
      ;;
    *)
      return 2
      ;;
  esac
}

docs_generate_known_layer() {
  local layer=$1
  local known
  for known in "${DOCS_GENERATE_DEFAULT_LAYERS[@]}" "${DOCS_GENERATE_OPTIONAL_LAYERS[@]}"; do
    [[ "$layer" == "$known" ]] && return 0
  done
  return 1
}

docs_generate_optional_layer() {
  local layer=$1
  local known
  for known in "${DOCS_GENERATE_OPTIONAL_LAYERS[@]}"; do
    [[ "$layer" == "$known" ]] && return 0
  done
  return 1
}

# Compute the ordered list of layers to emit given GxP and Six Sigma flags.
# Echoes one layer name per line.
docs_generate_resolve_layers() {
  local gxp=${1:-0}
  local sixsigma=${2:-0}
  local layer
  for layer in "${DOCS_GENERATE_DEFAULT_LAYERS[@]}"; do
    printf '%s\n' "$layer"
  done
  if [[ "$gxp" == "1" ]]; then
    printf '%s\n' gxp
  fi
  if [[ "$sixsigma" == "1" ]]; then
    printf '%s\n' sixsigma
  fi
}

# Discover template files for a layer.
# Echoes lines: <relative-output-path>\t<template-source-path>\t<layer>
docs_generate_layer_files() {
  local layer=$1
  local template_root
  template_root=$(docs_generate_template_root)
  local layer_dir tpl rel out
  layer_dir=$(docs_generate_layer_dir_for "$layer") || return 2
  if [[ -n "$layer_dir" ]]; then
    [[ -d "$template_root/$layer_dir" ]] || return 0
    for tpl in "$template_root/${layer_dir}"*.md.tpl; do
      [[ -f "$tpl" ]] || continue
      rel=${tpl#"$template_root/"}
      out=${rel%.tpl}
      printf '%s\t%s\t%s\n' "$out" "$tpl" "$layer"
    done
  else
    tpl="$template_root/${layer}.md.tpl"
    [[ -f "$tpl" ]] || return 0
    rel="${layer}.md"
    printf '%s\t%s\t%s\n' "$rel" "$tpl" "$layer"
  fi
}

# Render a template with ${TOKEN} substitution. Tokens are passed via
# environment when calling this function. The list of supported tokens is
# fixed and documented in docs/docs-generate.md.
#
# Tokens (all required, may be empty strings):
#   DG_PROJECT_NAME, DG_PROJECT_INTENT, DG_TARGET_DIR, DG_GENERATED_AT,
#   DG_OUTPUT_DIR, DG_LAYERS_LIST, DG_GXP_ENABLED, DG_SIXSIGMA_ENABLED,
#   DG_OPERATOR_CONTEXT, DG_REPO_METADATA_SIGNATURE.
docs_generate_render_template() {
  local src=${1:?usage: docs_generate_render_template <src> <dest>}
  local dest=${2:?usage: docs_generate_render_template <src> <dest>}

  local tokens=(
    DG_PROJECT_NAME
    DG_PROJECT_INTENT
    DG_TARGET_DIR
    DG_GENERATED_AT
    DG_OUTPUT_DIR
    DG_LAYERS_LIST
    DG_GXP_ENABLED
    DG_SIXSIGMA_ENABLED
    DG_OPERATOR_CONTEXT
    DG_REPO_METADATA_SIGNATURE
  )

  local content
  content=$(cat "$src")

  local token value placeholder
  for token in "${tokens[@]}"; do
    value=${!token-}
    placeholder="\${${token}}"
    content=${content//"$placeholder"/$value}
  done

  printf '%s' "$content" > "$dest"
}

# Detect repository metadata signals used as inputs. Echoes lines:
#   <signal_key>\t<signal_value>
docs_generate_repo_metadata_signals() {
  local target=$1
  [[ -d "$target" ]] || return 0
  local signal
  for signal in README.md PRODUCT.md AGENTS.md INDEX.md package.json pyproject.toml \
    requirements.txt docs install.sh Makefile CHANGELOG.md docker-compose.yml \
    composer.json go.mod Cargo.toml; do
    if [[ -e "$target/$signal" ]]; then
      printf '%s\tpresent\n' "$signal"
    fi
  done
}

# Build a stable signature over detected repo signals (path + size).
docs_generate_repo_metadata_signature() {
  local target=$1
  [[ -d "$target" ]] || {
    printf 'no-target-directory\n'
    return 0
  }
  local manifest
  manifest=$(mktemp)
  local rel size
  while IFS=$'\t' read -r rel _; do
    if [[ -f "$target/$rel" ]]; then
      size=$(wc -c < "$target/$rel" | tr -d ' ')
    elif [[ -d "$target/$rel" ]]; then
      size=$(find "$target/$rel" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
    else
      size=0
    fi
    printf '%s\t%s\n' "$rel" "$size" >> "$manifest"
  done < <(docs_generate_repo_metadata_signals "$target")
  if [[ -s "$manifest" ]]; then
    sha256sum "$manifest" | awk '{print $1}'
  else
    printf 'no-known-signals\n'
  fi
  rm -f "$manifest"
}

# Build the JSON file plan. Echoes a single JSON array suitable for piping
# into jq. Requires jq.
docs_generate_files_json() {
  local gxp=${1:-0}
  local sixsigma=${2:-0}
  local tmp
  tmp=$(mktemp)
  local layer rel src
  while IFS= read -r layer; do
    while IFS=$'\t' read -r rel src layer_name; do
      [[ -n "$rel" ]] || continue
      jq -nc \
        --arg path "$rel" \
        --arg layer "$layer_name" \
        --arg source "$src" \
        '{path:$path,layer:$layer,source:$source}' >> "$tmp"
    done < <(docs_generate_layer_files "$layer")
  done < <(docs_generate_resolve_layers "$gxp" "$sixsigma")
  jq -s '.' "$tmp"
  rm -f "$tmp"
}

# Compose the layers list as a markdown bullet block for templates.
docs_generate_layers_markdown() {
  local gxp=${1:-0}
  local sixsigma=${2:-0}
  local layer
  while IFS= read -r layer; do
    case "$layer" in
      index)      printf -- "- index (entry point and pack overview)\n" ;;
      gxp)        printf -- "- gxp-grade (controlled doc, validation evidence, audit trail, deviation/CAPA, traceability, approval handoff)\n" ;;
      sixsigma)   printf -- "- six-sigma (DMAIC, CTQ, metric evidence ledger, control plan, improvement backlog)\n" ;;
      developer)  printf -- "- developer (architecture overview, contribution flow)\n" ;;
      user)       printf -- "- user (end-user guide skeleton)\n" ;;
      operator)   printf -- "- operator (runbook, oncall expectations)\n" ;;
      integration) printf -- "- integration (interface contracts and integration notes)\n" ;;
      validation) printf -- "- validation (evidence index; minimal placeholder unless gxp-grade selected)\n" ;;
      maintenance) printf -- "- maintenance (update policy, ownership, freshness expectations)\n" ;;
    esac
  done < <(docs_generate_resolve_layers "$gxp" "$sixsigma")
}

# Compute follow-up gaps from inputs. Echoes one gap per line.
docs_generate_follow_up_gaps() {
  local intent=$1
  local context_file=$2
  local target=$3
  if [[ -z "$intent" ]]; then
    printf 'product_intent_not_supplied\n'
  fi
  if [[ -z "$context_file" || ! -s "$context_file" ]]; then
    printf 'operator_context_not_supplied\n'
  fi
  if [[ -d "$target" ]]; then
    [[ -e "$target/README.md" ]] || printf 'target_readme_missing\n'
    [[ -d "$target/docs" ]] || printf 'target_docs_dir_missing\n'
    if ! find "$target" -maxdepth 1 -name 'package.json' -o -name 'pyproject.toml' \
      -o -name 'go.mod' -o -name 'Cargo.toml' -o -name 'composer.json' 2>/dev/null \
      | grep -q .; then
      printf 'target_runtime_manifest_unknown\n'
    fi
  else
    printf 'target_directory_missing\n'
  fi
}
