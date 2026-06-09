# Éléments de valorisation — cadres neutres pour l'évaluation externe

> Langues : [EN](valuation-inputs.md) · **FR** · [DE](valuation-inputs.de.md)

> Ce document rassemble des **cadres neutres et des points de référence** qu'un
> analyste externe peut appliquer lui-même. Il ne propose **aucune fourchette de
> valeur**, aucune auto-évaluation, et ne place ORDO sur aucune échelle de
> valeur. Les références de marché citées sont des **repères de catégorie**, et
> non des comparables directs pour ORDO à son stade actuel (une boîte à outils en
> phase précoce, pré-revenu — voir
> [evidence-and-maturity.fr.md](evidence-and-maturity.fr.md)).
>
> Pour l'état réel du produit, voir
> [evidence-and-maturity.fr.md](evidence-and-maturity.fr.md). Pour les limites
> d'affirmation, voir [public-claim-boundary.md](../public-claim-boundary.md).

## Pourquoi ce document est séparé

Valoriser un projet en phase précoce dépend d'hypothèses (maturité, revenu,
pilotes, rétention, barrières de reproductibilité, valeur stratégique) que **seul
un évaluateur indépendant devrait poser**. Pour préserver l'impartialité de
l'analyse, ce dépôt fournit les *éléments* mais n'émet aucun verdict de valeur.

## 1. Cadres de capitalisation comptable (élément)

Les coûts de développement d'une immobilisation incorporelle générée en interne
ne peuvent être capitalisés que lorsque les critères applicables sont remplis :
faisabilité technique, intention d'achever, capacité d'utiliser ou de vendre,
avantage économique futur probable, ressources disponibles et mesure fiable des
coûts. Normes :

- [IAS 38 — Intangible Assets](https://www.ifrs.org/issued-standards/list-of-standards/ias-38-intangible-assets/)
- [Swiss GAAP FER 10 — Intangible assets](https://www.fer.ch/en/standards/swiss-gaap-fer-10-immaterielle-werte/)

Éléments potentiellement éligibles, à apprécier par l'analyste : temps de
développement, architecture, tests, documentation, configuration CI et outillage
directement attribuable. L'inventaire factuel correspondant (lignes de code,
décomptes de tests, barrières CI) figure dans
[evidence-and-maturity.fr.md](evidence-and-maturity.fr.md) ; l'analyste décide
quels éléments satisfont aux critères.

## 2. Contexte de catégorie de marché (élément)

ORDO se situe à l'intersection de plusieurs catégories de logiciels. Ces
catégories situent le *domaine*, et non la valeur d'ORDO :

| Catégorie | Description |
|---|---|
| Orchestration multi-agents / livraison logicielle par IA | Coordonner plusieurs agents de codage pilotés par terminal à travers issues, branches et revues. |
| Orchestration de workflows CI/CD et de livraison | Séquencer les étapes de build, test, vérification et merge avec des barrières. |
| Automatisation DevOps et gouvernance des releases | Contrôle piloté par des politiques de ce qui peut être mergé ou livré, avec preuves d'audit. |

Repères de catégorie (références publiques, matures, à large marché — **non des
comparables directs pour une boîte à outils en phase précoce, pré-revenu,
shell-first** ; citées uniquement pour situer le domaine) :

- [GitHub Actions](https://github.com/features/actions) — automatisation CI/CD et de workflows.
- [GitLab CI/CD](https://docs.gitlab.com/ee/ci/) — orchestration de pipelines intégrée.
- [Temporal](https://temporal.io/) — orchestration de workflows durables.
- [Apache Airflow](https://airflow.apache.org/) — planification et orchestration de workflows.

> L'échelle et le revenu de ces systèmes matures et largement adoptés **ne sont
> pas transposables** à un projet en phase précoce sans revenu. Ils sont cités
> uniquement pour localiser la catégorie, et non pour suggérer une équivalence ou
> une concurrence.

## 3. Multiples de valorisation (élément conditionnel)

Les multiples SaaS publics et privés (souvent exprimés comme un multiple de
l'ARR) ne deviennent pertinents qu'**une fois qu'un revenu récurrent existe**, et
varient largement selon la croissance, la rétention nette du revenu, la marge
brute, la rentabilité, la concentration de la clientèle et la valeur stratégique.
Référence générale :
[SaaS Valuation Multiples](https://saasvaluationmultiple.com/).

> ORDO n'a, à ce stade, **aucun revenu récurrent** : les multiples d'ARR ne sont
> pas applicables en l'état. Contexte uniquement.

## 4. Facteurs qui feraient évoluer une valorisation

Sans énoncer de chiffre, les leviers qui structurent habituellement ce type
d'actif :

- la maturité technique et la profondeur de la preuve (logique de refus testée →
  exploitation soutenue sur le terrain → robustesse multi-environnements) ;
- les pilotes payants, les lettres d'intention ou les déploiements adoptés ;
- les barrières de reproductibilité et une différenciation défendable ;
- le revenu récurrent et la rétention ;
- la résorption des lacunes ouvertes (voir
  [evidence-and-maturity.fr.md](evidence-and-maturity.fr.md), section 5), y
  compris les déviations de validation CSV.

## 5. Notes pour l'analyste

- ORDO est **neutre vis-à-vis de l'agent, du dépôt et du fournisseur** par
  conception (voir [PRODUCT.md](../../PRODUCT.md)) ; toute évaluation du coût de
  changement ou du verrouillage devrait tenir compte de cette neutralité.
- Le dépôt n'émet **aucune affirmation d'usage validé ou de production** (voir
  [public-claim-boundary.md](../public-claim-boundary.md)) ; la valeur d'usage
  réglementé, le cas échéant, dépend de l'achèvement du dossier de validation,
  actuellement refusé.

---

> Ce document ne contient délibérément **aucune fourchette de valeur pour ORDO**.
> La valorisation relève de la responsabilité de l'analyste externe, sur la base
> de [evidence-and-maturity.fr.md](evidence-and-maturity.fr.md) et des cadres
> ci-dessus.
