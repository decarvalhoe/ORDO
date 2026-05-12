#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  bash scripts/windows_ssh_dispatch.sh --host <ssh-target> [--file <script>|-]
  bash scripts/windows_ssh_dispatch.sh --diagnose-output <log-file>

Run mode sends a local dispatch script to a remote bash through a CRLF
normalization filter:

  ssh <ssh-target> "tr -d '\r' | bash -s" < ./dispatch-script.sh

Diagnostic mode classifies logs that combine an ORDO unsupported-flag symptom
with CRLF evidence as:

  diagnostic=windows-crlf-argv-contamination
USAGE
}

fail() {
  printf 'windows_ssh_dispatch: %s\n' "$*" >&2
  exit 2
}

has_unknown_arg_flag() {
  local log_file=${1:?usage: has_unknown_arg_flag <log-file>}
  grep -Eq 'unknown arg:[[:space:]]+--[A-Za-z0-9][A-Za-z0-9_-]*' "$log_file"
}

has_crlf_evidence() {
  local log_file=${1:?usage: has_crlf_evidence <log-file>}

  LC_ALL=C grep -q $'\r' "$log_file" && return 0
  grep -Eiq 'CRLF|carriage return|\^M|\\r' "$log_file" && return 0
  if grep -Fq "\$'" "$log_file" && grep -Fq "\\r" "$log_file"; then
    return 0
  fi
  return 1
}

diagnose_output() {
  local log_file=${1:?usage: diagnose_output <log-file>}
  [[ -f "$log_file" ]] || fail "diagnostic log not found: $log_file"

  if has_unknown_arg_flag "$log_file" && has_crlf_evidence "$log_file"; then
    cat <<'DIAG'
diagnostic=windows-crlf-argv-contamination
impact=Windows-originated SSH bash snippets preserved carriage returns in argv/env values, making supported ORDO flags look unsupported.
remediation=Use scripts/windows_ssh_dispatch.sh --host <ssh-target> --file ./dispatch-script.sh or run ssh <ssh-target> "tr -d '\r' | bash -s" < ./dispatch-script.sh.
DIAG
    return 0
  fi

  cat <<'DIAG'
diagnostic=no-windows-crlf-argv-contamination
remediation=Investigate the unsupported flag or runtime mismatch directly; this log did not include both unknown-arg and CRLF evidence.
DIAG
}

ssh_target=""
script_file="-"
diagnose_file=""
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host|--target)
      ssh_target=${2:?missing value for $1}
      shift
      ;;
    --file)
      script_file=${2:?missing value for --file}
      shift
      ;;
    --diagnose-output)
      diagnose_file=${2:?missing value for --diagnose-output}
      shift
      ;;
    --dry-run)
      dry_run=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown arg: $1"
      ;;
  esac
  shift
done

if [[ -n "$diagnose_file" ]]; then
  diagnose_output "$diagnose_file"
  exit 0
fi

[[ -n "$ssh_target" ]] || fail "missing --host <ssh-target>"
if [[ "$script_file" != "-" && ! -f "$script_file" ]]; then
  fail "script file not found: $script_file"
fi

remote_command="tr -d '\\r' | bash -s"

if [[ "$dry_run" -eq 1 ]]; then
  printf 'DRY-RUN: ssh %q %q < %q\n' "$ssh_target" "$remote_command" "$script_file"
  exit 0
fi

if [[ "$script_file" == "-" ]]; then
  ssh "$ssh_target" "$remote_command"
else
  ssh "$ssh_target" "$remote_command" < "$script_file"
fi
