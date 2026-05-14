# Dispatch canonique — {{project}} agent: {{agent}}
# Ticket: #{{ticket}} {{summary}}

## Objectif

Livrer le ticket #{{ticket}} en restant strictement dans le scope defini et avec une validation finale qui passe.

{{scope_posture_block}}

## Regles ORDO injectees pour la flotte

- Contexte repo strict: avant toute mutation, verifier `pwd`, `git status --short --branch`, `git remote -v`, et la base `{{base_ref}}`; accepted immutable base: `{{base_ref}}` at `{{base_sha}}`. Apres `git fetch {{base_remote}}`, verifier que `{{base_sha}}` existe avec `git cat-file -e {{base_sha}}^{commit}` et que la tete rafraichie contient cette base avec `git merge-base --is-ancestor {{base_sha}} {{base_ref}}`. Si `{{base_ref}}` vaut exactement `{{base_sha}}`, continuer normalement; si `{{base_ref}}` a avance mais contient `{{base_sha}}`, rapporter `accepted-pinned-base-drift` et continuer depuis `{{base_sha}}`. Si `{{base_remote}}` n'existe pas dans ce clone, utiliser un remote equivalent seulement s'il pointe vers `{{gh_repo}}` et si `<remote>/{{default_branch}}` contient `{{base_sha}}`; rapporter le remote utilise. Stopper et rapporter `context-mismatch` si le repo cible, le workdir, le SHA accepte manquant, ou la relation d'ancetre ne correspondent pas.
- Isolation multi-produit: ne jamais modifier un autre workdir que `{{repo}}`. Ne pas utiliser de chemins relatifs vers un autre produit, meme si le contexte terminal a travaille sur ce produit avant.
- Scope strict: modifier uniquement les fichiers autorises. Si le ticket exige un fichier hors scope ou une dependance non documentee, stopper et demander clarification.
- Evidence obligatoire: rapporter base SHA, fichiers modifies, validation_policy, validation_command, allowed_focused_checks, resultat, et blockers. Ne pas presenter une validation non executee comme passante.
- Declaration de statut agent: quand `scripts/agent_status.sh` est present, emettre une declaration provider-neutral (`working`, `blocked`, `validating`, `finalizing`, `handoff_ready` ou `done`) avec `--project {{project}}`, `--agent {{agent}}`, `--target issue:{{ticket}}`, `--workdir {{repo}}`, `--status <state>`, et `--reason <court motif>`. Les declarations `handoff_ready` et `done` servent aussi de signal local no-SSH pour reveiller l'orchestrateur.
- Closeout final base guard: apres la validation et immediatement avant le rapport final ou handoff PR, refaire `git fetch {{base_remote}}` puis `git rev-parse {{base_ref}}`; comparer la valeur finale a la base initiale `{{base_sha}}`. Si `{{base_ref}}` a avance, ne pas presenter la branche comme courante: rapporter `stale-base` avec base initiale et finale, ou rebaser/rafraichir seulement si le dispatch l'autorise explicitement et sans mutation destructive.
- Findings opportunites: tout blocage operationnel, lenteur, manque de preflight, erreur auth/protocole, CI inutile, doc drift, ou workflow confus doit etre remonte dans le rapport final sous `opportunity_findings` avec finding, impact, signal de detection, remediation safe candidate, plan validation/POC, priorite, et evidence liee si disponible. Si tu peux corriger sans sortir du scope, corrige et valide; sinon laisse une proposition de remediation safe.
- Mutations interdites: pas de push, PR, merge, rebase force, reset destructif, stash destructif, secret en dur, ou commande de suppression large sans instruction explicite.
- External PR mutation gate (#268): pour tout PR gere par un tiers, le defaut est `audit-only`. Capture l'evidence locale sous `state_dir`/gate-evidence/ et stop. Pas de commentaire de PR, pas de changement draft/ready/reopen/close, pas d'edition de labels ou assignees, pas de merge — sauf si ce dispatch declare explicitement les scopes attendus via `- external-pr-mutations: <scopes>` ET que l'orchestrator a autorise les memes scopes via `ORCH_EXTERNAL_PR_MUTATIONS` ou `--external-pr-mutations`. Les scopes reconnus sont `audit_evidence`, `issue_pack_notify`, `pr_comment`, `pr_state`, `pr_labels`, `pr_assignees`, `pr_merge`. La regle est repo-neutral.

## Format de sortie attendu

- Branche locale: `{{branch_slug}}`
- Base de travail: `{{default_branch}}` a verifier sur accepted immutable base `{{base_sha}}`
- Commit convention: `feat({{ticket}}): <resume en une ligne>`
- Format du rapport final:

```text
{{ticket}} status:
  branch: {{branch_slug}}
  head: <sha>
  base: {{base_ref}} @ {{base_sha}} (initial verified; final rechecked after validation: <sha>; current|stale-base)
  files:
    <list of files modified/created with line counts>
  validation_policy={{validation_policy}}
  validation_command={{validation_command}}
  allowed_focused_checks:
{{allowed_focused_checks}}
  validation_result: PASS|FAIL|SKIPPED
  judgment calls: <list>
  opportunity_findings: none | <finding -> impact -> detection signal -> safe remediation candidate -> validation/POC plan -> priority -> linked evidence>
  blockers: none | <list>
```

## Tools / sources autorises

- `cd {{repo}}`
- `git fetch {{base_remote}}`
- `git rev-parse {{base_ref}}`
- `git cat-file -e {{base_sha}}^{commit}`
- `git merge-base --is-ancestor {{base_sha}} {{base_ref}}`
- `git checkout -B {{branch_slug}} {{base_sha}}`
- Si `{{base_remote}}` est absent mais qu'un remote equivalent existe pour `{{gh_repo}}`: `git fetch <remote>`, verifier que `<remote>/{{default_branch}}` contient `{{base_sha}}` avec `git merge-base --is-ancestor {{base_sha}} <remote>/{{default_branch}}`, puis `git checkout -B {{branch_slug}} {{base_sha}}`
- `git config user.name && git config user.email`
- configured issue-provider ticket view, for example `gh issue view {{ticket}} --repo {{gh_repo}}` when the GitHub adapter is used
- `{{project_meta_context}}` si present, pour contexte projet persistant
- validation_policy={{validation_policy}}
- validation_command={{validation_command}}
- allowed_focused_checks:
{{allowed_focused_checks}}
- Closeout: apres validation_command (ou SKIPPED explicite quand validation_command=none), refaire `git fetch {{base_remote}}` puis `git rev-parse {{base_ref}}` immediatement avant le rapport final ou handoff PR.

### Validation strategy

- require-local-validators: {{require_local_validators}}
- validation_policy={{validation_policy}}
- validation_command={{validation_command}}
- allowed_focused_checks:
{{allowed_focused_checks}}
- CI-delegated validation is encoded as `validation_policy=ci-delegated` with `validation_command=none`; do not run full local repository validators on the shared agent host unless this brief explicitly sets `require-local-validators: yes`.
- Cheap local smoke is allowed only when directly tied to changed files, listed under `allowed_focused_checks`, and run in foreground with a strict timeout.
- Full validation evidence should come from the configured PR check rollup after the branch is pushed.

## Boundaries / interdictions

- Fichiers autorises:

{{scope_files}}

- Fichiers interdits:

{{forbidden_files}}

- Interdictions absolues:
  - pas de `git push`
  - pas de PR
  - pas de `--no-verify`
  - pas de `--admin`
  - pas de modifications hors scope

- Process safety obligatoire (anti-runaway, anti-fork-bomb):
  - JAMAIS de scan filesystem global (`find /`, `bfs /`, `bfs ~`, `find ~ -type f`); toujours borner sur le clone (`find . -type f` ou path explicite)
  - Les validateurs complets du depot sont CI-delegated par defaut; ne pas les lancer localement sauf opt-in explicite `require-local-validators: yes`
  - Toute commande locale de validation/test DOIT etre en foreground et wrappee par un `timeout` strict
  - JAMAIS plus d'un test/validator simultanement; si une commande ne rend pas sa sortie en 5 min, la tuer (`kill <pid>`) et reporter `blocker: validator-hang`
  - JAMAIS relancer en boucle un meme bash background apres timeout/empty output; reporter le blocker au lieu de retry
  - JAMAIS spawner de Task sub-agent pour "running tests" sans timeout explicite; eviter les imbrications de monitors qui s'auto-multiplient
  - JAMAIS attendre plus de 5 min via Task Output, Monitor, `until grep`, `while`, ou polling d'un fichier de sortie; abandonner ce wait, tuer le process surveille si present, et continuer avec un blocker explicite

## Definition of Done verifiable

- [ ] La base `{{default_branch}}` a ete verifiee avant implementation
- [ ] L'identite git de l'agent a ete verifiee avant commit
- [ ] Le ticket du fournisseur configure a ete relu en entier avant implementation
- [ ] Le scope demande est couvert sans depasser sur des fichiers interdits
- [ ] La guidance de validation rendue est suivie et rapportee: validation_policy={{validation_policy}}, validation_command={{validation_command}}, resultat PASS|FAIL|SKIPPED
- [ ] La base `{{default_branch}}` a ete reverifiee apres validation et immediatement avant le rapport final ou handoff PR

## Preuves attendues

- Sortie de `git config user.name && git config user.email`
- Confirmation de la base acceptee `{{base_ref}}` sur `{{base_sha}}`, ou remote equivalent `<remote>/{{default_branch}}` contenant `{{base_sha}}` et repo `{{gh_repo}}`; rapporter `accepted-pinned-base-drift` si la tete distante finale a avance
- Sortie de validation_command si elle n'est pas `none`; sinon rapporter SKIPPED avec validation_policy={{validation_policy}} et les focused checks executes le cas echeant
- Sortie du recheck final de base: `git fetch {{base_remote}}` puis `git rev-parse {{base_ref}}`, avec statut `current` ou `stale-base`
- Liste des fichiers modifies avec line counts

{{source_substance_appendix}}
