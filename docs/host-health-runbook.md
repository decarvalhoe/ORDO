# Host Health Storm Runbook

This runbook is generic. Keep live hostnames, account names, repository paths,
tmux session names, and provider-specific CLI details in external operator
profiles, not in this repository.

## Detection

Run a bounded preflight before starting or expanding a monitoring wave:

```bash
timeout 10 bash scripts/host_health_preflight.sh
timeout 10 bash scripts/host_health_preflight.sh --refuse
```

The preflight reports thresholds for:

- `wtmp_mb`: current and rotated login accounting files under the configured log directory.
- `journal_mb`: persistent system journal size.
- `var_log_mb` and `var_log_pct`: total log directory size and filesystem usage.
- `host_sessions`: login session count from `loginctl` or a bounded fallback.

Warnings mean the operator should slow probes and capture evidence. Critical
metrics should stop new remote probes until the storm source is removed.

## Evidence Capture

Capture evidence before truncating or vacuuming logs. Keep each command bounded:

```bash
ts=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "evidence/host-health-$ts"
timeout 10 bash scripts/host_health_preflight.sh > "evidence/host-health-$ts/preflight.txt"
timeout 10 du -h /var/log/wtmp /var/log/wtmp.[0-9]* /var/log/journal /var/log \
  > "evidence/host-health-$ts/log-sizes.txt" 2>/dev/null || true
timeout 10 loginctl list-sessions --no-legend --no-pager \
  | head -100 > "evidence/host-health-$ts/sessions.txt" 2>/dev/null || true
timeout 10 journalctl --disk-usage \
  > "evidence/host-health-$ts/journal-disk-usage.txt" 2>/dev/null || true
```

If pane output is needed, capture only a small fixed tail. Prefer metadata,
state files, and GitHub data before pane content.

## Stop The Storm

Pause or remove the source of repeated one-command SSH probes before cleaning
logs. Preferred patterns are:

- one persistent SSH control connection reused by several checks;
- one batched remote command that returns all needed host/session metrics;
- a small remote collector with local log rotation;
- longer polling intervals and single-flight locks around diagnostics.

Do not add live topology, private account names, or per-host service names to
ORDO code or examples. Put those in the operator profile that invokes ORDO.

## Remediation

Only remediate after evidence exists and the probe source is stopped.

For login accounting files:

```bash
ts=$(date -u +%Y%m%dT%H%M%SZ)
sudo cp -a /var/log/wtmp "/var/log/wtmp.evidence.$ts" 2>/dev/null || true
sudo cp -a /var/log/wtmp.1 "/var/log/wtmp.1.evidence.$ts" 2>/dev/null || true
sudo truncate -s 0 /var/log/wtmp
sudo logrotate -f /etc/logrotate.conf
```

For persistent journal pressure:

```bash
sudo journalctl --disk-usage
sudo journalctl --vacuum-size=1G
sudo journalctl --vacuum-time=7d
```

For headless agent hosts, disable desktop/account services only after verifying
they are unnecessary for that host role:

```bash
sudo systemctl disable --now display-manager.service 2>/dev/null || true
sudo systemctl disable --now accounts-daemon.service 2>/dev/null || true
```

Re-run `scripts/host_health_preflight.sh --refuse` after remediation. Resume
monitoring only when critical signals are gone and the operator profile uses
batched or persistent probes.
