#!/usr/bin/env bash
# api_rate_limiter.sh — fleet-wide API call shaping (#409).
#
# The 12-pane fleet's agent CLIs (`claude`, `codex`, `gemini`, …) each
# issue their own `/v1/messages` and classifier requests. ORDO does not
# call those endpoints itself, but it controls TWO things that
# meaningfully affect aggregate fleet QPS and the resulting Anthropic
# 429 storms:
#
#   1. WHEN dispatch fan-out begins per pane (`dispatch_ticket.sh`,
#      `portfolio_session_start.sh --apply`). Without jitter, twelve
#      panes start their first prompt within ~50ms of each other and
#      their agent CLIs fire concurrently against the same org limit.
#
#   2. WHEN orchestrator-side bookkeeping calls (status sweeps, planner
#      rehydration, classifier piggybacks) run. A token-bucket rate
#      limiter wrapping any future ORDO-direct API call keeps that
#      traffic under the per-org limit.
#
# This library exposes both controls plus a structured 429 audit sink so
# operators can verify the storm is gone after the fix lands.
#
# Public API
#   api_rate_limiter_jitter [min_ms] [max_ms]
#       Sleep for a random duration in [min_ms, max_ms]. Defaults are
#       50–250 ms (per #409). Sources of randomness, in order: $RANDOM,
#       /dev/urandom, current epoch ns. Always returns 0; never blocks
#       indefinitely.
#
#   api_rate_limiter_acquire [<scope>] [<rps>] [<burst>]
#       Token-bucket acquire. Sleeps until a token is available, then
#       returns 0. State is persisted at
#         $(api_rate_limiter_state_dir)/<scope>.bucket
#       so independent ORDO processes share the same bucket. Defaults:
#         rps   = ORDO_API_RATE_LIMIT_RPS   (default 5)
#         burst = ORDO_API_RATE_LIMIT_BURST (default 8)
#         scope = "default"
#       File-locked (flock) for safety under concurrent acquires.
#
#   api_rate_limiter_record_429 <session> <endpoint> <retry_after_sec>
#                               [<extra_kv>]
#       Append a structured line to the 429 audit log. The line is a
#       single key=value record terminated by `\n`, suitable for
#       `tail -F` and downstream log shipping. The log path is
#         ORDO_API_RATE_LIMIT_LOG (default $ORCH_LOG_DIR/api-rate-limit.log)
#       The function never fails: if the log file cannot be written it
#       falls back to stderr so the calling dispatch loop is never
#       blocked by an audit-side IO error.
#
#   api_rate_limiter_state_dir
#       Echo the directory that holds bucket state files (creates it on
#       demand). Defaults to $ORCH_STATE_BASE/api_rate_limiter, falling
#       back to $TMPDIR/ordo-api-rate-limiter when ORCH_STATE_BASE is
#       unset.
#
# Env vars (all optional; documented defaults are issue #409 targets)
#   ORDO_API_RATE_LIMIT_RPS    — steady-state requests per second. 5.
#   ORDO_API_RATE_LIMIT_BURST  — bucket capacity. 8.
#   ORDO_API_RATE_LIMIT_JITTER_MIN_MS — lower jitter bound. 50.
#   ORDO_API_RATE_LIMIT_JITTER_MAX_MS — upper jitter bound. 250.
#   ORDO_API_RATE_LIMIT_LOG    — destination for 429 audit lines.
#                                Default: $ORCH_LOG_DIR/api-rate-limit.log.
#   ORDO_API_RATE_LIMIT_DISABLE — when "1", every public function is a
#                                no-op (return 0 immediately). Used by
#                                tests, dry-runs, and operator escape
#                                hatches when the limiter itself causes
#                                problems.

set -uo pipefail

: "${ORDO_API_RATE_LIMIT_RPS:=5}"
: "${ORDO_API_RATE_LIMIT_BURST:=8}"
: "${ORDO_API_RATE_LIMIT_JITTER_MIN_MS:=50}"
: "${ORDO_API_RATE_LIMIT_JITTER_MAX_MS:=250}"
: "${ORDO_API_RATE_LIMIT_DISABLE:=0}"

_api_rate_limiter_disabled() {
  case "${ORDO_API_RATE_LIMIT_DISABLE:-0}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# Echo a single integer in [min_ms, max_ms]. Pure: no sleep, no IO.
# Exposed as a private helper so tests can pin the distribution bounds
# without exercising the real `sleep` call.
_api_rate_limiter_random_ms() {
  local min=${1:?usage: _api_rate_limiter_random_ms <min_ms> <max_ms>}
  local max=${2:?usage: _api_rate_limiter_random_ms <min_ms> <max_ms>}
  if [ "$max" -lt "$min" ]; then
    # Defensive: swap so the caller never gets a negative span.
    local tmp=$min; min=$max; max=$tmp
  fi
  local span=$((max - min + 1))
  local r
  if [ -n "${RANDOM:-}" ]; then
    r=$RANDOM
  elif [ -r /dev/urandom ]; then
    r=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' \n' || printf '0')
  else
    r=$(date +%N 2>/dev/null || printf '0')
  fi
  r=${r:-0}
  printf '%s\n' $((min + (r % span)))
}

api_rate_limiter_jitter() {
  if _api_rate_limiter_disabled; then
    return 0
  fi
  local min=${1:-${ORDO_API_RATE_LIMIT_JITTER_MIN_MS}}
  local max=${2:-${ORDO_API_RATE_LIMIT_JITTER_MAX_MS}}
  local ms
  ms=$(_api_rate_limiter_random_ms "$min" "$max")
  # `sleep` accepts fractional seconds on every shell ORDO targets
  # (coreutils sleep, BusyBox sleep, macOS sleep). Falls back to integer
  # seconds if the shell rejects fractions, which floors to a safer
  # higher delay rather than skipping the jitter altogether.
  local seconds
  seconds=$(awk -v ms="$ms" 'BEGIN { printf "%.3f", ms / 1000 }' 2>/dev/null || printf '0.1')
  if ! sleep "$seconds" 2>/dev/null; then
    sleep 1
  fi
  return 0
}

api_rate_limiter_state_dir() {
  local dir
  if [ -n "${ORCH_STATE_BASE:-}" ]; then
    dir="${ORCH_STATE_BASE}/api_rate_limiter"
  else
    dir="${TMPDIR:-/tmp}/ordo-api-rate-limiter"
  fi
  mkdir -p "$dir" 2>/dev/null || true
  printf '%s\n' "$dir"
}

# Internal: read bucket state, refill based on elapsed time, attempt a
# decrement, and write back the new state. Returns 0 when a token was
# acquired, 1 when the bucket was empty (caller should sleep + retry).
# State file format: "<float_tokens> <float_last_refill_epoch>".
_api_rate_limiter_try_acquire() {
  local state_file=$1 rps=$2 burst=$3
  local tokens last_refill now refilled new_tokens
  now=$(awk 'BEGIN { srand(); printf "%.6f", systime() + 0 }' 2>/dev/null || date +%s)
  if [ -s "$state_file" ]; then
    read -r tokens last_refill <"$state_file" || true
  fi
  tokens=${tokens:-$burst}
  last_refill=${last_refill:-$now}
  # Refill: tokens += elapsed * rps, capped at burst.
  refilled=$(awk -v t="$tokens" -v lr="$last_refill" -v n="$now" -v r="$rps" -v b="$burst" '
    BEGIN {
      elapsed = n - lr;
      if (elapsed < 0) elapsed = 0;
      v = t + elapsed * r;
      if (v > b) v = b;
      printf "%.6f", v;
    }')
  # Decision: do we have at least one token?
  if awk -v t="$refilled" 'BEGIN { exit !(t >= 1.0) }'; then
    new_tokens=$(awk -v t="$refilled" 'BEGIN { printf "%.6f", t - 1.0 }')
    printf '%s %s\n' "$new_tokens" "$now" >"$state_file"
    return 0
  fi
  # Persist the refilled (but un-decremented) state so a subsequent
  # acquire reflects the elapsed time we just measured.
  printf '%s %s\n' "$refilled" "$now" >"$state_file"
  return 1
}

api_rate_limiter_acquire() {
  if _api_rate_limiter_disabled; then
    return 0
  fi
  local scope=${1:-default}
  local rps=${2:-${ORDO_API_RATE_LIMIT_RPS}}
  local burst=${3:-${ORDO_API_RATE_LIMIT_BURST}}
  # Sanitize: rps and burst must be positive numbers; fall back to
  # documented defaults on garbage input rather than failing the caller.
  if ! awk -v v="$rps" 'BEGIN { exit !(v + 0 > 0) }'; then rps=5; fi
  if ! awk -v v="$burst" 'BEGIN { exit !(v + 0 > 0) }'; then burst=8; fi

  local dir state lock
  dir=$(api_rate_limiter_state_dir)
  # Sanitize scope to a safe filename.
  local safe_scope=${scope//[^A-Za-z0-9_.-]/-}
  state="$dir/${safe_scope}.bucket"
  lock="$state.lock"

  local attempts=0
  local max_attempts=120
  while [ "$attempts" -lt "$max_attempts" ]; do
    if (
      flock 9 || exit 1
      _api_rate_limiter_try_acquire "$state" "$rps" "$burst"
    ) 9>"$lock"; then
      return 0
    fi
    # No token. Sleep for the period of one token at the configured rps
    # (with a small floor so we never tight-loop on a misconfigured rps).
    local wait_secs
    wait_secs=$(awk -v r="$rps" 'BEGIN { v = 1.0 / r; if (v < 0.05) v = 0.05; printf "%.3f", v }')
    sleep "$wait_secs" 2>/dev/null || sleep 1
    attempts=$((attempts + 1))
  done
  # Fail-open after max_attempts so a stuck bucket cannot deadlock the
  # whole dispatch fan-out. The caller still gets the 429 audit trail
  # below if the API itself rate-limits.
  return 0
}

api_rate_limiter_record_429() {
  local session=${1:?usage: api_rate_limiter_record_429 <session> <endpoint> <retry_after_sec> [<extra_kv>]}
  local endpoint=${2:?usage: api_rate_limiter_record_429 <session> <endpoint> <retry_after_sec> [<extra_kv>]}
  local retry_after=${3:?usage: api_rate_limiter_record_429 <session> <endpoint> <retry_after_sec> [<extra_kv>]}
  local extra=${4:-}

  local ts log_path
  ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  log_path=${ORDO_API_RATE_LIMIT_LOG:-${ORCH_LOG_DIR:-/var/log/orch}/api-rate-limit.log}

  local line="ts=${ts} event=anthropic_429 session=${session} endpoint=${endpoint} retry_after_sec=${retry_after}"
  if [ -n "$extra" ]; then
    line="${line} ${extra}"
  fi

  mkdir -p "$(dirname "$log_path")" 2>/dev/null || true
  if ! printf '%s\n' "$line" >>"$log_path" 2>/dev/null; then
    printf 'api_rate_limiter_record_429: log_write_failed path=%s line=%s\n' \
      "$log_path" "$line" >&2
    return 0
  fi
  return 0
}
