# Bewertungs-Inputs — neutrale Rahmenwerke für externe Beurteilung

> Sprachen: [EN](valuation-inputs.md) · [FR](valuation-inputs.fr.md) · **DE**

> Dieses Dokument bündelt **neutrale Rahmenwerke und Referenzpunkte**, die ein
> externer Analyst selbst anwenden kann. Es schlägt **keine Wertspanne** vor,
> keine Selbstbeurteilung, und ordnet ORDO auf keiner Wertskala ein. Die
> angeführten Marktreferenzen sind **Kategorie-Orientierungspunkte**, keine
> direkten Vergleichswerte für ORDO in seinem aktuellen Stadium (ein
> frühphasiges, vorumsatzliches Toolkit — siehe
> [evidence-and-maturity.de.md](evidence-and-maturity.de.md)).
>
> Für den tatsächlichen Produktstand siehe
> [evidence-and-maturity.de.md](evidence-and-maturity.de.md).
> Für die Grenzen der Behauptungen siehe
> [public-claim-boundary.md](../public-claim-boundary.md).

## Warum dieses Dokument separat ist

Die Bewertung eines frühphasigen Projekts hängt von Annahmen ab (Reifegrad,
Umsatz, Pilotprojekte, Bindung, Reproduzierbarkeitsbarrieren, strategischer
Wert), die **nur ein unabhängiger Bewerter treffen sollte**. Um die
Unparteilichkeit der Analyse zu wahren, stellt dieses Repository die *Inputs*
bereit, gibt aber kein Werturteil ab.

## 1. Bilanzierungs-Rahmenwerke zur Aktivierung (Input)

Entwicklungskosten eines selbst geschaffenen immateriellen Vermögenswerts dürfen
nur dann aktiviert werden, wenn die anwendbaren Kriterien erfüllt sind:
technische Realisierbarkeit, Absicht zur Fertigstellung, Fähigkeit zur Nutzung
oder zum Verkauf, wahrscheinlicher künftiger wirtschaftlicher Nutzen, verfügbare
Ressourcen und zuverlässige Kostenmessung. Standards:

- [IAS 38 — Intangible Assets](https://www.ifrs.org/issued-standards/list-of-standards/ias-38-intangible-assets/)
- [Swiss GAAP FER 10 — Intangible assets](https://www.fer.ch/en/standards/swiss-gaap-fer-10-immaterielle-werte/)

Potenziell anrechenbare Posten, zur Beurteilung durch den Analysten:
Entwicklungszeit, Architektur, Tests, Dokumentation, CI-Konfiguration und direkt
zurechenbares Tooling. Das entsprechende faktische Inventar (Codezeilen,
Testzahlen, CI-Schranken) befindet sich in
[evidence-and-maturity.de.md](evidence-and-maturity.de.md); der Analyst
entscheidet, welche Posten die Kriterien erfüllen.

## 2. Marktkategorie-Kontext (Input)

ORDO liegt an der Schnittstelle mehrerer Softwarekategorien. Diese Kategorien
verorten die *Domäne*, nicht den Wert von ORDO:

| Kategorie | Beschreibung |
|---|---|
| Multi-Agent-/KI-Software-Auslieferungsorchestrierung | Koordination mehrerer terminalgesteuerter Coding-Agenten über Issues, Branches und Reviews hinweg. |
| CI/CD- und Auslieferungs-Workflow-Orchestrierung | Sequenzierung von Build-, Test-, Prüf- und Merge-Schritten mit Schranken. |
| DevOps-Automatisierung und Release-Governance | Richtliniengesteuerte Kontrolle darüber, was gemergt oder freigegeben werden darf, mit Audit-Nachweisen. |

Kategorie-Orientierungspunkte (öffentliche, ausgereifte, breit am Markt
etablierte Referenzen — **keine direkten Vergleichswerte für ein frühphasiges,
vorumsatzliches, shell-first-Toolkit**; nur angeführt, um die Domäne zu
verorten):

- [GitHub Actions](https://github.com/features/actions) — CI/CD und
  Workflow-Automatisierung.
- [GitLab CI/CD](https://docs.gitlab.com/ee/ci/) — integrierte
  Pipeline-Orchestrierung.
- [Temporal](https://temporal.io/) — beständige Workflow-Orchestrierung.
- [Apache Airflow](https://airflow.apache.org/) — Workflow-Planung und
  -Orchestrierung.

> Der Massstab und der Umsatz dieser ausgereiften, weit verbreiteten Systeme
> sind **nicht übertragbar** auf ein frühphasiges Projekt ohne Umsatz. Sie
> werden nur angeführt, um die Kategorie zu verorten, nicht um Gleichwertigkeit
> oder Wettbewerb zu suggerieren.

## 3. Bewertungsmultiplikatoren (bedingter Input)

Öffentliche und private SaaS-Multiplikatoren (oft als Vielfaches des ARR
ausgedrückt) werden erst relevant, **sobald wiederkehrender Umsatz existiert**,
und variieren stark je nach Wachstum, Netto-Umsatzbindung, Bruttomarge,
Profitabilität, Kundenkonzentration und strategischem Wert. Allgemeine Referenz:
[SaaS Valuation Multiples](https://saasvaluationmultiple.com/).

> ORDO hat in diesem Stadium **keinen wiederkehrenden Umsatz**:
> ARR-Multiplikatoren sind unverändert nicht anwendbar. Nur Kontext.

## 4. Faktoren, die eine Bewertung bewegen würden

Ohne eine Zahl zu nennen, die Hebel, die diese Art von Vermögenswert üblicherweise
strukturieren:

- technischer Reifegrad und Tiefe des Nachweises (getestete Verweigerungslogik →
  anhaltender Feldbetrieb → Robustheit über mehrere Umgebungen hinweg);
- bezahlte Pilotprojekte, Absichtserklärungen oder eingeführte Deployments;
- Reproduzierbarkeitsbarrieren und verteidigbare Differenzierung;
- wiederkehrender Umsatz und Bindung;
- Schliessung der offenen Lücken (siehe
  [evidence-and-maturity.de.md](evidence-and-maturity.de.md), Abschnitt 5),
  einschliesslich der CSV-Validierungsabweichungen.

## 5. Hinweise für den Analysten

- ORDO ist konstruktionsbedingt **agnostisch gegenüber Agent, Repo und Provider**
  (siehe [PRODUCT.md](../../PRODUCT.md)); jede Beurteilung von Wechselkosten oder
  Lock-in sollte diese Neutralität berücksichtigen.
- Das Repository erhebt **keinen Anspruch auf validierte Nutzung oder
  Produktivbetrieb** (siehe
  [public-claim-boundary.md](../public-claim-boundary.md)); der Wert einer
  regulierten Nutzung, falls vorhanden, hängt von der Fertigstellung des
  Validierungsdossiers ab, die derzeit verweigert wird.

---

> Dieses Dokument enthält bewusst **keine Wertspanne für ORDO**. Die Bewertung
> liegt in der Verantwortung des externen Analysten, gestützt auf
> [evidence-and-maturity.de.md](evidence-and-maturity.de.md) und die obigen
> Rahmenwerke.
