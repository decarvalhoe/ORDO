# Valuation inputs — neutral frameworks for external assessment

> Languages: **EN** · [FR](valuation-inputs.fr.md) · [DE](valuation-inputs.de.md)

> This document gathers **neutral frameworks and reference points** an external
> analyst can apply themselves. It proposes **no value range**, no
> self-assessment, and does not place ORDO on any value scale. The market
> references cited are **category landmarks**, not direct comparables for ORDO
> at its current stage (an early-stage, pre-revenue toolkit — see
> [evidence-and-maturity.md](evidence-and-maturity.md)).
>
> For the actual product state, see [evidence-and-maturity.md](evidence-and-maturity.md).
> For claim limits, see [public-claim-boundary.md](../public-claim-boundary.md).

## Why this document is separate

Valuing an early-stage project depends on assumptions (maturity, revenue,
pilots, retention, reproducibility barriers, strategic value) that **only an
independent evaluator should make**. To preserve the impartiality of the
analysis, this repository provides the *inputs* but states no value verdict.

## 1. Accounting capitalization frameworks (input)

Development costs of an internally generated intangible asset may be capitalized
only when the applicable criteria are met: technical feasibility, intent to
complete, ability to use or sell, probable future economic benefit, available
resources, and reliable cost measurement. Standards:

- [IAS 38 — Intangible Assets](https://www.ifrs.org/issued-standards/list-of-standards/ias-38-intangible-assets/)
- [Swiss GAAP FER 10 — Intangible assets](https://www.fer.ch/en/standards/swiss-gaap-fer-10-immaterielle-werte/)

Potentially eligible items, for the analyst to assess: development time,
architecture, tests, documentation, CI configuration, and directly attributable
tooling. The corresponding factual inventory (lines of code, test counts, CI
gates) is in [evidence-and-maturity.md](evidence-and-maturity.md); the analyst
decides which items meet the criteria.

## 2. Market category context (input)

ORDO sits at the intersection of several software categories. These categories
situate the *domain*, not ORDO's value:

| Category | Description |
|---|---|
| Multi-agent / AI software-delivery orchestration | Coordinating several terminal-driven coding agents across issues, branches, and reviews. |
| CI/CD and delivery workflow orchestration | Sequencing build, test, check, and merge steps with gates. |
| DevOps automation and release governance | Policy-driven control over what may merge or release, with audit evidence. |

Category landmarks (public, mature, broad-market references — **not direct
comparables for an early-stage, pre-revenue, shell-first toolkit**; cited only
to situate the domain):

- [GitHub Actions](https://github.com/features/actions) — CI/CD and workflow automation.
- [GitLab CI/CD](https://docs.gitlab.com/ee/ci/) — integrated pipeline orchestration.
- [Temporal](https://temporal.io/) — durable workflow orchestration.
- [Apache Airflow](https://airflow.apache.org/) — workflow scheduling and orchestration.

> The scale and revenue of these mature, widely-adopted systems are **not
> transposable** to an early-stage project with no revenue. They are cited only
> to locate the category, not to imply equivalence or competition.

## 3. Valuation multiples (conditional input)

Public and private SaaS multiples (often expressed as a multiple of ARR) become
relevant only **once recurring revenue exists**, and vary widely with growth,
net revenue retention, gross margin, profitability, customer concentration, and
strategic value. General reference:
[SaaS Valuation Multiples](https://saasvaluationmultiple.com/).

> ORDO has, at this stage, **no recurring revenue**: ARR multiples are not
> applicable as-is. Context only.

## 4. Factors that would move a valuation

Without stating a number, the levers that usually structure this kind of asset:

- technical maturity and depth of proof (tested refusal logic → sustained
  field operation → multi-environment robustness);
- paid pilots, letters of intent, or adopted deployments;
- reproducibility barriers and defensible differentiation;
- recurring revenue and retention;
- closure of the open gaps (see
  [evidence-and-maturity.md](evidence-and-maturity.md), section 5), including
  the CSV validation deviations.

## 5. Notes for the analyst

- ORDO is **agent-, repo-, and provider-neutral** by design (see
  [PRODUCT.md](../../PRODUCT.md)); any assessment of switching cost or lock-in
  should account for that neutrality.
- The repository states **no validated-use or production claim** (see
  [public-claim-boundary.md](../public-claim-boundary.md)); regulated-use value,
  if any, depends on completing the validation dossier, which is currently
  refused.

---

> This document deliberately contains **no value range for ORDO**. Valuation is
> the external analyst's responsibility, based on
> [evidence-and-maturity.md](evidence-and-maturity.md) and the frameworks above.
