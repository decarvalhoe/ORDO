#!/usr/bin/env bash
# debug_audit_watchdog.sh — primitives for the live debug-audit loop watchdog (#541).
#
# Why this exists:
#   During the 2026-05-10 live RBOK debug audit, the per-tick log at
#   /var/log/orch/rbok-ordo-debug-audit-loop.log had not been updated for
#   ~4h while the rest of the orchestrator (rbok.log, ordo.log,
#   portfolio-longrun.log) kept ticking. `pgrep -af debug-audit` showed
#   no dedicated loop process, so the audit had silently died and the
#   operator only noticed by manual inspection. The watchdog turns that
#   manual check into a structured signal the orchestrator (or a smart
#   poller) can act on.
#
# Public surface (all sourceable in isolation, no PROJECT/GH_REPO
# dependency — the CLI wrapper in `scripts/debug_audit_watchdog.sh` is
# responsible for loading the active project config first):
#   debug_audit_log_default_path <project>
#   debug_audit_log_age_sec <path>
#   debug_audit_log_is_stale <path> <max_age_sec>
#   debug_audit_loop_pid_for_pattern <pattern>
#   debug_audit_loop_is_sample_config <project> <gh_repo>
#   debug_audit_loop_relaunch_record <config_path> <project> <prev_pid> <new_pid>
#
# Knobs (env, all optional):
#   ORCH_DEBUG_AUDIT_STALE_AFTER_SEC   default 900 (15 min)
#   ORCH_DEBUG_AUDIT_SAMPLE_PROJECTS   whitespace-separated PROJECT names
#                                      that must never run live orchestration
#                                      (default: project-a project-b sample)
#   ORCH_DEBUG_AUDIT_SAMPLE_REPOS_RE   ERE matched against GH_REPO
#                                      (default: ^example-org/)
#   ORCH_DEBUG_AUDIT_PGREP_OVERRIDE    test hook — when set, returned verbatim
#                                      in place of a real pgrep call

: "${ORCH_DEBUG_AUDIT_STALE_AFTER_SEC:=900}"
: "${ORCH_DEBUG_AUDIT_SAMPLE_PROJECTS:=project-a project-b sample}"
: "${ORCH_DEBUG_AUDIT_SAMPLE_REPOS_RE:=^example-org/}"

# debug_audit_log_default_path <project>
#   Echo the canonical log path the operator's audit loop is expected to
#   tick into. Honors $ORCH_LOG_DIR so test fixtures can pin a tmpdir.
debug_audit_log_default_path() {
  local project=${1:?usage: debug_audit_log_default_path <project>}
  local dir=${ORCH_LOG_DIR:-/var/log/orch}
  printf '%s/%s-debug-audit-loop.log\n' "$dir" "$project"
}

# debug_audit_log_age_sec <path>
#   Echo age in seconds since the file's last mtime. When the file is
#   absent, echo -1 so callers can branch on "never wrote a tick" vs.
#   "wrote a tick a long time ago". Works on GNU and BSD stat.
debug_audit_log_age_sec() {
  local path=${1:?usage: debug_audit_log_age_sec <path>}
  if [ ! -e "$path" ]; then
    printf '%s\n' -1
    return 0
  fi
  local mtime now
  mtime=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null || printf '0')
  now=$(date +%s)
  printf '%s\n' "$((now - mtime))"
}

# debug_audit_log_is_stale <path> <max_age_sec>
#   Exit 0 (stale) when the file is absent OR its age >= max_age_sec.
#   Exit 1 (fresh) otherwise.
debug_audit_log_is_stale() {
  local path=${1:?usage: debug_audit_log_is_stale <path> <max_age_sec>}
  local max_age=${2:?usage: debug_audit_log_is_stale <path> <max_age_sec>}
  local age
  age=$(debug_audit_log_age_sec "$path")
  if [ "$age" -lt 0 ]; then
    return 0
  fi
  [ "$age" -ge "$max_age" ]
}

# debug_audit_loop_pid_for_pattern <pattern>
#   Echo the first PID matching `pgrep -f <pattern>`; empty when no match
#   or pgrep is unavailable. Honors ORCH_DEBUG_AUDIT_PGREP_OVERRIDE so
#   tests can stub the result without spawning sentinel processes.
debug_audit_loop_pid_for_pattern() {
  local pattern=${1:?usage: debug_audit_loop_pid_for_pattern <pattern>}
  if [ -n "${ORCH_DEBUG_AUDIT_PGREP_OVERRIDE+x}" ]; then
    printf '%s\n' "$ORCH_DEBUG_AUDIT_PGREP_OVERRIDE"
    return 0
  fi
  command -v pgrep >/dev/null 2>&1 || return 0
  pgrep -f -- "$pattern" 2>/dev/null | head -n 1 || true
}

# debug_audit_loop_is_sample_config <project> <gh_repo>
#   Exit 0 (is sample) when the (project, gh_repo) pair matches a known
#   placeholder from examples/*.config.sh. Exit 1 otherwise. The CLI
#   wrapper uses this to fail fast before relaunching a loop that would
#   point at sample topology — the root cause noted in #541, where the
#   live RBOK audit would otherwise quietly fall back to `project-a`.
debug_audit_loop_is_sample_config() {
  local project=${1:-}
  local gh_repo=${2:-}
  local sample
  for sample in $ORCH_DEBUG_AUDIT_SAMPLE_PROJECTS; do
    if [ "$project" = "$sample" ]; then
      return 0
    fi
  done
  if [ -n "$gh_repo" ] && [[ "$gh_repo" =~ $ORCH_DEBUG_AUDIT_SAMPLE_REPOS_RE ]]; then
    return 0
  fi
  return 1
}

# debug_audit_loop_relaunch_record <config_path> <project> <prev_pid> <new_pid>
#   Compose the canonical single-line k=v relaunch record. All four
#   fields are required by the #541 acceptance criteria; missing values
#   are coerced to literal `none` so downstream parsers can rely on the
#   key being present.
debug_audit_loop_relaunch_record() {
  local config_path=${1:-unknown}
  local project=${2:-unknown}
  local prev_pid=${3:-none}
  local new_pid=${4:-none}
  [ -n "$config_path" ] || config_path=unknown
  [ -n "$project" ] || project=unknown
  [ -n "$prev_pid" ] || prev_pid=none
  [ -n "$new_pid" ] || new_pid=none
  printf 'config_path=%s project=%s previous_pid=%s new_pid=%s\n' \
    "$config_path" "$project" "$prev_pid" "$new_pid"
}
