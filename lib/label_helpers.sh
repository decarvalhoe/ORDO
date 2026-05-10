#!/usr/bin/env bash
# Shared GitHub label helpers for dispatch planning.

label_helpers_normalize_labels() {
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$1"
  else
    cat
  fi \
    | tr ',;' '\n' \
    | awk '{$1=$1; if ($0 != "") print}'
}

label_helpers_has_label() {
  local available=${1:-}
  local needle=${2:?usage: label_helpers_has_label <available-labels> <label>}
  label_helpers_normalize_labels "$available" | grep -Fqx "$needle"
}

label_helpers_priority_score() {
  case "${1:-}" in
    P0) printf '1000\n' ;;
    P1) printf '800\n' ;;
    P2) printf '600\n' ;;
    P3) printf '400\n' ;;
    P4) printf '100\n' ;;
    *) printf '300\n' ;;
  esac
}

label_helpers_priority_rank_from_labels() {
  local labels=${1:-}
  local lower
  lower=${labels,,}
  case "$lower" in
    *priority:p0*|*priority-p0*|*p0*) printf 'P0\n' ;;
    *priority:p1*|*priority-p1*|*p1*) printf 'P1\n' ;;
    *priority:p2*|*priority-p2*|*p2*) printf 'P2\n' ;;
    *priority:p3*|*priority-p3*|*p3*) printf 'P3\n' ;;
    *priority:p4*|*priority-p4*|*p4*) printf 'P4\n' ;;
    *) return 1 ;;
  esac
}

label_helpers_priority_for_labels() {
  local labels=${1:-}
  local available=${2:-}
  local rank score label

  if ! rank=$(label_helpers_priority_rank_from_labels "$labels"); then
    printf 'none|300|P3|unlabeled\n'
    return 0
  fi

  score=$(label_helpers_priority_score "$rank")
  label="priority:${rank}"

  if [ -n "$(label_helpers_normalize_labels "$available")" ] \
    && ! label_helpers_has_label "$available" "$label"; then
    printf 'none|%s|%s|unsupported\n' "$score" "$rank"
    return 0
  fi

  printf '%s|%s|%s|supported\n' "$rank" "$score" "$rank"
}

label_helpers_missing_labels() {
  local available=${1:-}
  local required=${2:-}
  local label

  while IFS= read -r label; do
    [ -n "$label" ] || continue
    if ! label_helpers_has_label "$available" "$label"; then
      printf '%s\n' "$label"
    fi
  done < <(label_helpers_normalize_labels "$required" | awk '!seen[$0]++')
}
