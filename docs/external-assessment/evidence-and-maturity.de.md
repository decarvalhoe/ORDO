# Dossier zu Nachweisen und Reifegrad — Input für externe Beurteilung

> Sprachen: [EN](evidence-and-maturity.md) · [FR](evidence-and-maturity.fr.md) · **DE**

> Dieses Dokument ist ein **neutraler Input** für eine unabhängige externe
> Beurteilung des Stands des ORDO-Projekts. Es behauptet **keinen Wert**
> (monetär oder strategisch) und zieht **keine Schlussfolgerung** über den Wert
> des Projekts. Es präsentiert überprüfbare Fakten: was tatsächlich
> implementiert und getestet ist, was nicht, und die bekannten Lücken. Der
> Analyst zieht seine eigenen Schlüsse.
>
> Der öffentliche Behauptungs-Vertrag ist massgeblich: siehe
> [public-claim-boundary.md](../public-claim-boundary.md). **Bewertungs-Inputs**
> (Bilanzierungs-Rahmenwerke und Marktkontext, ohne Urteil) sind in
> [valuation-inputs.de.md](valuation-inputs.de.md) isoliert, zur unabhängigen
> Anwendung durch den Analysten.

## Wie dieses Dossier zu lesen ist

- Jede Aussage ist einem **Nachweis** zugeordnet: Code, Tests, CI-Konfiguration,
  ein generiertes Artefakt oder eine **benannte Lücke**.
- Quantitative Kennzahlen wurden am **2026-05-27** beim Commit `d80e60c`
  gemessen (die Spitze von `origin/main` zum Zeitpunkt der Erstellung dieses
  Dossiers). Dieses Paket ist eine reine Dokumentationsänderung; es verändert die
  Engine oder die nachstehenden Testzahlen nicht, fügt der Dokumentationszählung
  jedoch Markdown-Dateien hinzu.
- Reproduktionsbefehle werden bereitgestellt (Abschnitt «Überprüfen Sie es
  selbst»): nichts hier verlangt, auf Treu und Glauben hingenommen zu werden.
- Umfang: Dieses Dossier beschreibt den **beobachteten** Stand. Es stellt die
  Roadmap nicht als Fähigkeit dar.

## 1. Was ORDO heute ist

ORDO ist eine **shell-first-Steuerungsebene** zur Koordination einer
Multi-Agent-Softwareauslieferung. Es ist eine Bash-Codebasis, die externe Tools
(`gh`, `git`, `jq`, `tmux`) ansteuert — es gibt keine kompilierte Binärdatei und
keinen langlaufenden Dienst. Ein Operator ruft einzelne Skripte der Form `bash
scripts/<name>.sh <project-config> ...` gegen ein operator-eigenes Projektprofil
auf.

`examples/ordo.config.sh` ist ein Loader, der **die Ausführung verweigert**, bis
`ORDO_PROJECT_PROFILE` auf ein operator-eigenes Profil zeigt; reale
Repository-Namen, Zugangsdaten und tmux-Ziele liegen ausserhalb dieses
Repositorys.

Tatsächlich auf der Festplatte vorhandene Befehls-/Workflow-Oberfläche (alle
nachstehenden Einstiegspunkte wurden auf ihre Existenz überprüft):

| Workflow | Einstiegspunkt(e) | Status |
|---|---|---|
| Flottenstatus | `agent_pool_status.sh`, `smart_poll_agents.sh` | implementiert |
| Dispatch-Planung | `dispatch_plan.sh` | implementiert |
| Dispatch-Ausführung | `dispatch_ticket.sh`, `brief_agents.sh` | implementiert |
| PR-Blocker-Signale | `pr_block_signals.sh` | implementiert |
| Gesteuerter Merge | `lib/pr_merge.sh` | implementiert |
| PR-Operationsmodi | `pr_ops_queue.sh`, `dispatch_pr_ops.sh` (observe / centralized / delegated), `pr_ops_controller.sh` | implementiert; `autonomous`-Dispatcher-Modus reserviert |
| Autonomer PR-Ops-Runner | `autonomous_pr_ops.sh` | implementiert; **opt-in, standardmässig aus** |
| Autonome Orchestrator-Schleife | `orch_loop.sh` | implementiert; **opt-in (erfordert ausdrückliche Bestätigung), standardmässig aus** |
| CI-Autofix | `ci_autofix.sh`, `sixsigma_autoupgrade.sh` | implementiert |
| Portfolio-Routing | `portfolio_session_start.sh`, `portfolio_status.sh` | implementiert |
| Host-Gesundheits-/Sicherheitsschranken | `host_health_preflight.sh`, `lib/host_load_gate.sh`, `lib/process_safety.sh` | implementiert |
| CSV-Dossier-Gerüst | `csv_dev_mode.sh` | implementiert; **schreibt nur Entwurfsvorlagen** |
| Generierung nachgelagerter Dokumentation | `docs_generate.sh` | implementiert |

## 2. Implementiert und getestet

Die Engine ist umfangreich und wird durch zwei Test-Harnesses (Bats und ein
eigenes `test_*.sh`-Shell-Harness) abgedeckt, die beide in die CI eingebunden
sind. Die Tests prüfen Parsing-Logik, Verweigerungsbedingungen und
Zustandsübergänge — nicht nur, dass ein Befehl mit null endet.

Gemessene Kennzahlen (Commit `d80e60c`, 2026-05-27):

| Mass | Wert |
|---|---:|
| Nicht-Test-Shell-Zeilen (`lib/` + `scripts/`) | 51,862 |
| Erstanbieter-Skripte (`lib/` + `scripts/`) | 155 (74 + 81) |
| Bats-Testdateien / `@test`-Fälle | 41 / 427 |
| Shell-Testdateien (`test_*.sh`) | 169 |
| Testzeilen (Bats + Shell-Tests) | 48,177 |
| Versionierte Markdown-Dokumente | 130 |
| CI-Workflows, die PRs auf `main` absichern | 2 |

Fähigkeiten mit Implementierung **und** Verhaltenstests (repräsentativ, nicht
erschöpfend):

- **Gesteuerter Merge** (`lib/pr_merge.sh`): erzwingt 11 unterschiedliche
  Exit-Codes (`0` plus `2`–`11`) für die Verweigerungspfade CI-ausstehend /
  fehlgeschlagen / konfliktbehaftet / verschmutzt / Review / Reconcile, mit
  einer abschliessenden Head-SHA-Neuverifizierung vor dem Merge. Geprüft durch
  `tests/test_pr_merge.sh`.
- **Verweigerungen beim Dispatch-Routing** (`lib/dispatch_router.sh`): verweigert
  den Dispatch, bevor ein Brief geschrieben ist, wenn eine beliebige
  Routing-Oberfläche (Pane / Dateiname / Body-Token / cwd / Git-Identität) nicht
  übereinstimmt. `tests/dispatch_router_route_mismatch.bats`
  (11 `@test`-Fälle) modelliert einen aufgezeichneten «Wave-23»-Routing-Vorfall.
- **Resilienz-Verweigerungen**: ein tmux-Schutzschalter (`lib/process_safety.sh`),
  Retry/Recovery in `lib/tmux_helpers.sh`, eine Host-Last-Schranke, die den
  Dispatch bei Überlastung mit Exit-Code `75` verweigert (`lib/host_load_gate.sh`),
  und eine Erkennung von Klassifizierer-Ausfällen (`lib/classifier_outage.sh`).
- **Schranken-Set des autonomen PR-Ops-Runners** (`scripts/autonomous_pr_ops.sh`):
  geprüft anhand einer Negativtest-Matrix in `tests/autonomous_pr_ops.bats`
  (23 `@test`-Fälle).
- **Dispatch-Planung / Atomisierung** (`scripts/dispatch_plan.sh`): Klassifikation
  ready / blocked / assigned und Epic-Atomisierung, mit mehreren dedizierten
  Testdateien.

CI-Schranken (`.github/workflows/`):

- `ci.yml` führt `scripts/run_shellcheck.sh`, `scripts/run_shell_tests.sh` und
  `scripts/run_bats.sh` bei jedem Pull Request auf `main` aus. Dies ist die
  Merge-Schranke.
- `docs-impact-gate.yml` führt `scripts/docs_impact_gate.sh check` aus und lässt
  den PR fehlschlagen, wenn eine Änderung eine nutzersichtbare Oberfläche berührt
  ohne eine Dokumentationsaktualisierung oder einen ausdrücklichen
  Deklarations-Trailer.

In der CI ist kein formaler Code-Coverage-Schwellenwert definiert.

## 3. Gerüst / in diesem Stadium nicht automatisiert

Klar vom gelieferten Umfang zu unterscheiden:

| Element | Beobachteter Stand | Nachweis |
|---|---|---|
| CSV-/GxP-Validierungsdossier | **Nur Vorlagen-Gerüst.** `csv_dev_mode.sh` schreibt IQ/OQ/PQ-Entwurfsvorlagen (standardmässig Vorschau, `--apply` erforderlich), gestempelt mit `DRAFT TEMPLATE - NOT VALIDATED - NOT RELEASED`. Es «validiert, gibt frei, genehmigt, erlässt niemals» ein System. | `scripts/csv_dev_mode.sh`; [docs/validation/](../validation/) |
| Autonome Orchestrator-Schleife | Implementiert, aber **standardmässig abgeschaltet**: der Daemon erfordert ein ausdrückliches `ORCH_DAEMON_CONFIRM`; der dokumentierte Standard ist die operator-gesteuerte `orch_manual_session.sh`. Die Schleife delegiert Entscheidungen pro Zyklus an eine externe Agent-CLI. | `scripts/orch_loop.sh` |
| `autonomous`-Dispatcher-Modus | **Reserviert / verweigert** in `dispatch_pr_ops.sh`. Autonome PR-Operationen werden stattdessen durch den separaten opt-in-Runner `autonomous_pr_ops.sh` bereitgestellt. | `scripts/dispatch_pr_ops.sh` |
| Six-Sigma-Projektgerüst-Skripte | Dokumentiert als **geplant / noch nicht implementiert**. | [docs/sixsigma/README.md](../sixsigma/README.md) |
| CLI-Wrapper auf oberster Ebene | **Nicht vorhanden**; Einstiegspunkte sind einzelne Skripte. | [PRODUCT.md → Product Roadmap](../../PRODUCT.md#product-roadmap) |

## 4. Bewiesen vs. nicht bewiesen

- **Bewiesen (begrenzt auf die getesteten Szenarien).** Die Verweigerungs- und
  Schrankenlogik wird in der CI geprüft: Exit-Codes des gesteuerten Merge,
  Verweigerungen beim Dispatch-Routing (das Wave-23-Modell), das Schranken-Set
  der autonomen PR-Ops und die Resilienz-Verweigerungen für tmux / Host-Last /
  Klassifizierer. Dies sind **Verhaltensprüfungen in den Test-Suites**, keine
  Garantien im Feldmassstab.
- **Nicht bewiesen (im operativen / Feldmassstab).** Anhaltender autonomer
  Multi-Agent-Flottenbetrieb über die Zeit; Resilienz gegenüber beliebigen
  SSH-/Host-/Netzwerk-Fehlermodi über die getesteten Fälle von tmux, Host-Last
  und Klassifizierer hinaus; Korrektheit bei Flottengrössen jenseits dessen, was
  ein Operator konfiguriert und erprobt hat; sowie jegliche regulierte
  **validierte Nutzung** (das Dossier verweigert sie).
- Als **opt-in / standardmässig aus** gekennzeichnete Fähigkeiten (die autonome
  Schleife und der autonome PR-Ops-Runner) sind implementiert und getestet, sind
  aber nicht der dokumentierte Standard-Betriebsmodus.

## 5. Bekannte Lücken

(Spiegelt den beobachteten Stand und die angegebene Roadmap zum Zeitpunkt der
Messung wider, 2026-05-27.)

- Kein CLI-Wrapper auf oberster Ebene; Skripte werden einzeln aufgerufen
  ([PRODUCT.md-Roadmap](../../PRODUCT.md#product-roadmap)).
- Ein einziger Provider-Adapter (GitHub CLI / `gh`); eine darüber hinausgehende
  Provider-Abstraktion ist als Roadmap dokumentiert, nicht geliefert.
- Einige grosse Skripte sind dünn abgedeckt (je 1–2 Testdateien): z. B.
  `runtime_freshness`, `prompt_unblock_policy`, `smart_poll_agents`,
  `ensure_alive`, `project_scaffold`.
- Kein formaler Coverage-Schwellenwert in der CI.
- CSV-OQ/PQ-Nachweise unvollständig; finale Validierungs-**Freigabe verweigert**,
  mit offenen Abweichungen `DEV-OQ-001` und `DEV-PQ-001`
  ([docs/validation/csv-val-02-final-report.md](../validation/csv-val-02-final-report.md)).
- Keine generierte statische Dokumentationsseite, kein paketierter
  Installations-/Upgrade-Pfad und keine Dashboard-Schicht (alles Roadmap).

## 6. Überprüfen Sie es selbst

```bash
# Anchor
git rev-parse HEAD            # expect d80e60c… when measured

# Engine size (non-test shell)
git ls-files | grep -E '^(lib|scripts)/.*\.sh$' | xargs wc -l | tail -1
git ls-files | grep -E '^lib/.*\.sh$'     | wc -l   # 74
git ls-files | grep -E '^scripts/.*\.sh$' | wc -l   # 81

# Tests
git ls-files | grep -E '^tests/.*\.bats$' | wc -l                              # 41
git ls-files | grep -E '^tests/.*\.bats$' | xargs grep -hcE '^\s*@test' \
  | awk '{s+=$1} END{print s}'                                                 # 427
git ls-files | grep -E '^tests/.*\.sh$'   | wc -l                              # 169

# Gated-merge exit codes and routing-incident model
grep -oE 'exit [0-9]+' lib/pr_merge.sh | sort -u
grep -cE '^\s*@test' tests/dispatch_router_route_mismatch.bats                 # 11

# Opt-in / off-by-default gates
grep -n 'ORCH_DAEMON_CONFIRM' scripts/orch_loop.sh
grep -n 'NOT VALIDATED' scripts/csv_dev_mode.sh

# CI gates
ls .github/workflows/

# Run the suites locally (the same entrypoints CI uses)
bash scripts/run_shellcheck.sh
bash scripts/run_shell_tests.sh
bash scripts/run_bats.sh
```

---

> Keine Bewertung in diesem Dokument. Die Bilanzierungs-Rahmenwerke und der
> Marktkontext (ohne Urteil) befinden sich in
> [valuation-inputs.de.md](valuation-inputs.de.md), zur Anwendung durch den
> Analysten.
