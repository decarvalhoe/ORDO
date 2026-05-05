#!/usr/bin/env bash
# preflight.sh — shared command availability checks for operator-facing scripts.

preflight_or_die() {
  local context=${1:?usage: preflight_or_die <context> <cmd> [cmd...]}
  shift

  local -a missing=()
  local -a found=()
  local cmd path

  for cmd in "$@"; do
    if path=$(command -v "$cmd" 2>/dev/null); then
      found+=("$cmd=$path")
    else
      missing+=("$cmd")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    audit "${context} PREFLIGHT FAIL — missing CLIs: ${missing[*]}"
    die "preflight failed: install missing CLIs and retry"
  fi

  audit "${context} PREFLIGHT OK — ${found[*]}"
}
