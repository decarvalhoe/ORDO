# Dossier de preuves et de maturité — élément pour l'évaluation externe

> Langues : [EN](evidence-and-maturity.md) · **FR** · [DE](evidence-and-maturity.de.md)

> Ce document est un **élément neutre** destiné à une évaluation externe
> indépendante de l'état du projet ORDO. Il n'affirme **aucune valeur**
> (monétaire ou stratégique) et ne tire **aucune conclusion** sur la valeur du
> projet. Il présente des faits vérifiables : ce qui est réellement implémenté et
> testé, ce qui ne l'est pas, et les lacunes connues. L'analyste tire ses propres
> conclusions.
>
> Le contrat public d'affirmations fait foi : voir
> [public-claim-boundary.md](../public-claim-boundary.md). Les **éléments de
> valorisation** (cadres comptables et contexte de marché, sans verdict) sont
> isolés dans [valuation-inputs.fr.md](valuation-inputs.fr.md) afin que l'analyste
> les applique de manière indépendante.

## Comment lire ce dossier

- Chaque affirmation renvoie à une **preuve** : code, tests, configuration CI, un
  artefact généré ou une **lacune nommée**.
- Les métriques quantitatives ont été mesurées le **2026-05-27** au commit
  `d80e60c` (la tête d'`origin/main` au moment de la rédaction de ce dossier). Ce
  dossier est une modification documentaire uniquement ; il ne modifie pas le
  moteur ni les décomptes de tests ci-dessous, bien qu'il ajoute des fichiers
  Markdown au décompte de la documentation.
- Des commandes de reproduction sont fournies (section « Vérifiez par
  vous-même ») : rien ici ne demande à être pris sur parole.
- Périmètre : ce dossier décrit l'état **observé**. Il ne présente pas la feuille
  de route comme une capacité.

## 1. Ce qu'est ORDO aujourd'hui

ORDO est un **plan de contrôle « shell-first »** pour coordonner la livraison
logicielle multi-agents. C'est une base de code Bash qui pilote des outils
externes (`gh`, `git`, `jq`, `tmux`) — il n'y a ni binaire compilé ni service de
longue durée. Un opérateur invoque des scripts individuels de la forme `bash
scripts/<name>.sh <project-config> ...` sur un profil de projet détenu par
l'opérateur.

`examples/ordo.config.sh` est un chargeur qui **refuse de s'exécuter** tant que
`ORDO_PROJECT_PROFILE` ne pointe pas vers un profil détenu par l'opérateur ; les
noms de dépôts réels, les identifiants et les cibles tmux résident en dehors de
ce dépôt.

Surface de commandes / de workflows réellement présente sur le disque (tous les
points d'entrée ci-dessous ont été vérifiés comme existants) :

| Workflow | Point(s) d'entrée | Statut |
|---|---|---|
| État de la flotte | `agent_pool_status.sh`, `smart_poll_agents.sh` | implémenté |
| Planification du dispatch | `dispatch_plan.sh` | implémenté |
| Exécution du dispatch | `dispatch_ticket.sh`, `brief_agents.sh` | implémenté |
| Signaux de blocage de PR | `pr_block_signals.sh` | implémenté |
| Merge sous conditions | `lib/pr_merge.sh` | implémenté |
| Modes d'opérations PR | `pr_ops_queue.sh`, `dispatch_pr_ops.sh` (observe / centralized / delegated), `pr_ops_controller.sh` | implémenté ; mode dispatcher `autonomous` réservé |
| Exécuteur autonome d'opérations PR | `autonomous_pr_ops.sh` | implémenté ; **optionnel, désactivé par défaut** |
| Boucle d'orchestrateur autonome | `orch_loop.sh` | implémenté ; **optionnel (nécessite une confirmation explicite), désactivé par défaut** |
| Correction automatique CI | `ci_autofix.sh`, `sixsigma_autoupgrade.sh` | implémenté |
| Routage de portefeuille | `portfolio_session_start.sh`, `portfolio_status.sh` | implémenté |
| Santé de l'hôte / barrières de sécurité | `host_health_preflight.sh`, `lib/host_load_gate.sh`, `lib/process_safety.sh` | implémenté |
| Échafaudage du dossier CSV | `csv_dev_mode.sh` | implémenté ; **écrit uniquement des modèles provisoires** |
| Génération de documentation en aval | `docs_generate.sh` | implémenté |

## 2. Implémenté et testé

Le moteur est substantiel et est couvert par deux harnais de test (Bats et un
harnais shell `test_*.sh` sur mesure), tous deux intégrés à la CI. Les tests
vérifient la logique d'analyse, les conditions de refus et les transitions
d'état — pas seulement qu'une commande se termine avec le code zéro.

Métriques mesurées (commit `d80e60c`, 2026-05-27) :

| Mesure | Valeur |
|---|---:|
| Lignes shell hors tests (`lib/` + `scripts/`) | 51,862 |
| Scripts internes (`lib/` + `scripts/`) | 155 (74 + 81) |
| Fichiers de tests Bats / cas `@test` | 41 / 427 |
| Fichiers de tests shell (`test_*.sh`) | 169 |
| Lignes de tests (Bats + tests shell) | 48,177 |
| Documents Markdown suivis | 130 |
| Workflows CI conditionnant les PR vers `main` | 2 |

Capacités disposant d'une implémentation **et** de tests comportementaux
(représentatif, non exhaustif) :

- **Merge sous conditions** (`lib/pr_merge.sh`) : impose 11 codes de sortie
  distincts (`0` plus `2`–`11`) pour les chemins de refus CI en attente / en
  échec / en conflit / arbre sale / revue / réconciliation, avec une
  re-vérification finale de la head-SHA avant le merge. Exercé par
  `tests/test_pr_merge.sh`.
- **Refus de routage du dispatch** (`lib/dispatch_router.sh`) : refuse le
  dispatch avant qu'un brief ne soit rédigé lorsqu'une surface de routage (pane /
  nom de fichier / jeton du corps / cwd / identité git) est en désaccord.
  `tests/dispatch_router_route_mismatch.bats` (11 cas `@test`) modélise un
  incident de routage « Wave-23 » enregistré.
- **Refus de résilience** : un disjoncteur tmux (`lib/process_safety.sh`), des
  reprises/récupérations dans `lib/tmux_helpers.sh`, une barrière de charge hôte
  qui refuse le dispatch en cas de surcharge avec le code de sortie `75`
  (`lib/host_load_gate.sh`), et la détection de panne de classifieur
  (`lib/classifier_outage.sh`).
- **Jeu de barrières de l'exécuteur autonome d'opérations PR**
  (`scripts/autonomous_pr_ops.sh`) : évalué par rapport à une matrice de tests
  négatifs dans `tests/autonomous_pr_ops.bats` (23 cas `@test`).
- **Planification / atomisation du dispatch** (`scripts/dispatch_plan.sh`) :
  classification prêt / bloqué / assigné et atomisation des epics, avec plusieurs
  fichiers de tests dédiés.

Barrières CI (`.github/workflows/`) :

- `ci.yml` exécute `scripts/run_shellcheck.sh`, `scripts/run_shell_tests.sh` et
  `scripts/run_bats.sh` à chaque pull request vers `main`. C'est la barrière de
  merge.
- `docs-impact-gate.yml` exécute `scripts/docs_impact_gate.sh check` et fait
  échouer la PR lorsqu'une modification touche une surface visible par
  l'utilisateur sans mise à jour de la documentation ou trailer de déclaration
  explicite.

Aucun seuil formel de couverture de code n'est défini dans la CI.

## 3. Échafaudage / non automatisé à ce stade

À distinguer clairement du périmètre livré :

| Élément | État observé | Preuve |
|---|---|---|
| Dossier de validation CSV / GxP | **Échafaudage de modèles uniquement.** `csv_dev_mode.sh` écrit des modèles provisoires IQ/OQ/PQ (aperçu par défaut, `--apply` requis) estampillés `DRAFT TEMPLATE - NOT VALIDATED - NOT RELEASED`. Il « ne valide, ne livre, n'approuve, ni ne dispense » jamais un système. | `scripts/csv_dev_mode.sh` ; [docs/validation/](../validation/) |
| Boucle d'orchestrateur autonome | Implémentée mais **désactivée par défaut** : le démon nécessite un `ORCH_DAEMON_CONFIRM` explicite ; le défaut documenté est la session pilotée par l'opérateur `orch_manual_session.sh`. La boucle délègue les décisions par cycle à une CLI d'agent externe. | `scripts/orch_loop.sh` |
| Mode dispatcher `autonomous` | **Réservé / refusé** dans `dispatch_pr_ops.sh`. Les opérations PR autonomes sont fournies à la place par l'exécuteur optionnel distinct `autonomous_pr_ops.sh`. | `scripts/dispatch_pr_ops.sh` |
| Scripts d'échafaudage de projet Six Sigma | Documentés comme **planifiés / pas encore implémentés**. | [docs/sixsigma/README.md](../sixsigma/README.md) |
| Wrapper CLI de premier niveau | **Absent** ; les points d'entrée sont des scripts individuels. | [PRODUCT.md → Product Roadmap](../../PRODUCT.md#product-roadmap) |

## 4. Prouvé vs. non prouvé

- **Prouvé (borné aux scénarios testés).** La logique de refus et de barrières
  est vérifiée dans la CI : codes de sortie du merge sous conditions, refus de
  routage du dispatch (le modèle Wave-23), le jeu de barrières des opérations PR
  autonomes, et les refus de résilience tmux / charge hôte / classifieur. Ce sont
  des **assertions comportementales dans les suites de tests**, et non des
  garanties à l'échelle du terrain.
- **Non prouvé (au périmètre opérationnel / de terrain).** L'exploitation
  autonome soutenue d'une flotte multi-agents dans la durée ; la résilience à des
  modes de défaillance arbitraires SSH / hôte / réseau au-delà des cas tmux,
  charge hôte et classifieur qui sont testés ; la correction à des tailles de
  flotte au-delà de ce qu'un opérateur configure et a exercé ; et tout **usage
  validé** réglementé (le dossier le refuse).
- Les capacités étiquetées **optionnelles / désactivées par défaut** (la boucle
  autonome et l'exécuteur autonome d'opérations PR) sont implémentées et testées
  mais ne constituent pas le mode opératoire documenté par défaut.

## 5. Lacunes connues

(Reflète l'état observé et la feuille de route déclarée au moment de la mesure,
2026-05-27.)

- Pas de wrapper CLI de premier niveau ; les scripts sont invoqués
  individuellement ([feuille de route PRODUCT.md](../../PRODUCT.md#product-roadmap)).
- Un unique adaptateur de fournisseur (GitHub CLI / `gh`) ; l'abstraction de
  fournisseur au-delà est documentée comme feuille de route, non livrée.
- Certains gros scripts sont faiblement couverts (1–2 fichiers de tests chacun) :
  par ex. `runtime_freshness`, `prompt_unblock_policy`, `smart_poll_agents`,
  `ensure_alive`, `project_scaffold`.
- Aucun seuil formel de couverture dans la CI.
- Preuves CSV OQ/PQ incomplètes ; validation finale **livraison refusée**, avec
  les déviations ouvertes `DEV-OQ-001` et `DEV-PQ-001`
  ([docs/validation/csv-val-02-final-report.md](../validation/csv-val-02-final-report.md)).
- Aucun site de documentation statique généré, ni chemin d'installation/mise à
  niveau empaqueté, ni couche de tableau de bord (tout cela en feuille de route).

## 6. Vérifiez par vous-même

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

> Aucune valorisation dans ce document. Les cadres comptables et le contexte de
> marché (sans verdict) figurent dans
> [valuation-inputs.fr.md](valuation-inputs.fr.md), à appliquer par l'analyste.
