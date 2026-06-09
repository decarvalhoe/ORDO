# Paket für externe Beurteilung — ORDO

> Sprachen: [EN](README.md) · [FR](README.fr.md) · **DE**

> Dieser Ordner bündelt **neutrale Inputs** für eine unabhängige externe
> Beurteilung des Stands und des Werts des ORDO-Projekts. Er ist so verfasst,
> dass er eine **unparteiische** Analyse ermöglicht: überprüfbare Fakten,
> Nachweise und bekannte Lücken. Das Repository **gibt kein Werturteil ab** und
> versucht nicht, die Schlussfolgerung des Analysten zu lenken.

## Grundsatz der Unparteilichkeit

1. **Fakten, keine Überzeugungsarbeit.** Jede Aussage ist einem Nachweis
   zugeordnet: Code, Tests, CI, ein generiertes Artefakt oder eine benannte
   Lücke — gemäss der Regel «jede Behauptung ist einem Nachweis zugeordnet» von
   [public-claim-boundary.md](../public-claim-boundary.md).
2. **Keine Selbstbeurteilung.** Das Repository quantifiziert seinen eigenen Wert
   nicht und ordnet sich nicht auf einer Wertskala ein. Bewertungs-Inputs werden
   als neutrale Rahmenwerke bereitgestellt, zur Anwendung durch den Analysten.
3. **Reproduzierbar.** Kennzahlen sind datiert, an einen Commit verankert und
   von Verifikationsbefehlen begleitet.
4. **Weder über- noch untertrieben dargestellt.** Der Massstab ist die Wahrheit;
   der gelieferte Umfang wird klar vom zukunftsgerichteten Umfang (Roadmap)
   unterschieden.

## Inhalt

| Dokument | Rolle |
|---|---|
| [evidence-and-maturity.de.md](evidence-and-maturity.de.md) | Was tatsächlich gebaut und getestet ist, was bewiesen ist und was nicht, sowie die bekannten Lücken — mit reproduzierbaren Nachweisen. **Einstiegspunkt.** |
| [valuation-inputs.de.md](valuation-inputs.de.md) | Neutrale Bilanzierungs-Rahmenwerke und Marktkontext, ohne Werturteil, zur Anwendung durch den Analysten. |

## Massgebliche Referenzen

- [public-claim-boundary.md](../public-claim-boundary.md) — was ORDO behaupten
  darf und was nicht (die Nachweisregel, reservierte Statuskennzeichnungen).
- [docs/validation/README.md](../validation/README.md) — die massgebliche
  Disposition der CSV-Validierung (`NOT RELEASED` / `NOT PRODUCTION READY`).
- [docs/INDEX.md](../INDEX.md) — vollständiges Dokumentationsverzeichnis.

---

Kennzahlen verankert an Commit `d80e60c`, 2026-05-27.
