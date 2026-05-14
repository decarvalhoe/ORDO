# Windows SSH Dispatch

Use this runbook when an operator launches ORDO dispatch commands from a
Windows Codex, PowerShell, or terminal session into a remote Linux tmux host.
Windows-originated snippets can carry CRLF line endings into remote bash. If
those bytes reach ORDO argv or env values, supported flags such as `--dry-run`
or `--soft-route` can be misreported as unsupported.

## Safe Dispatch Pattern

For one-off remote snippets, normalize carriage returns on the remote side
before bash parses the script:

```bash
ssh <ssh-target> "tr -d '\r' | bash -s" < ./remote-dispatch.sh
```

The committed helper wraps that pattern:

```bash
bash scripts/windows_ssh_dispatch.sh \
  --host <ssh-target> \
  --file ./remote-dispatch.sh
```

`--file -` reads from stdin, so generated snippets can be piped without
creating a temporary file:

```bash
generate_dispatch_snippet | \
  bash scripts/windows_ssh_dispatch.sh --host <ssh-target> --file -
```

## Diagnostic Classification

When a failed remote run shows both of these signals:

- `unknown arg: --<flag>` for a flag expected to exist in the deployed ORDO
  runtime.
- CRLF evidence such as literal carriage returns, `\r`, `^M`, or bash xtrace
  strings like `$'...\r'`.

Classify the incident as:

```text
windows-crlf-argv-contamination
```

Run the helper diagnostic against the captured stderr/stdout:

```bash
bash scripts/windows_ssh_dispatch.sh --diagnose-output ./remote-run.log
```

The remediation is to rerun through the helper or through
`ssh <target> "tr -d '\r' | bash -s" < ./remote-dispatch.sh`. Do not treat
this signature as proof that ORDO lacks the flag until the CRLF-safe path has
been tried.
