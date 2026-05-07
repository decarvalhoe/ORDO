# Dispatch canonique — {{project}} agent: {{agent}}
# Ticket: #{{ticket}} {{summary}}

## Objectif

Livrer le ticket #{{ticket}} en restant strictement dans le scope defini et avec une validation finale qui passe.

## Regles ORDO injectees pour la flotte

- Contexte repo strict: avant toute mutation, verifier `pwd`, `git status --short --branch`, `git remote -v`, et la base `{{base_ref}}`. Si `{{base_remote}}` n'existe pas dans ce clone, utiliser un remote equivalent seulement s'il pointe vers `{{gh_repo}}` et si `<remote>/{{default_branch}}` resout `{{base_sha}}`; rapporter le remote utilise. Stopper et rapporter `context-mismatch` si le repo cible, le workdir, ou le SHA de base ne correspondent pas.
- Isolation multi-produit: ne jamais modifier un autre workdir que `{{repo}}`. Ne pas utiliser de chemins relatifs vers un autre produit, meme si le pane a travaille sur ce produit avant.
- Scope strict: modifier uniquement les fichiers autorises. Si le ticket exige un fichier hors scope ou une dependance non documentee, stopper et demander clarification.
- Evidence obligatoire: rapporter base SHA, fichiers modifies, validation executee, resultat, et blockers. Ne pas presenter une validation non executee comme passante.
- Findings opportunites: tout blocage operationnel, lenteur, manque de preflight, erreur auth/protocole, CI inutile, doc drift, ou workflow confus doit etre remonte dans le rapport final sous `opportunity_findings`. Si tu peux corriger sans sortir du scope, corrige et valide; sinon laisse une proposition de remediation safe.
- Mutations interdites: pas de push, PR, merge, rebase force, reset destructif, stash destructif, secret en dur, ou commande de suppression large sans instruction explicite.

## Format de sortie attendu

- Branche locale: `{{branch_slug}}`
- Base de travail: `{{default_branch}}` a verifier sur `{{base_sha}}`
- Commit convention: `feat({{ticket}}): <resume en une ligne>`
- Format du rapport final:

```text
{{ticket}} status:
  branch: {{branch_slug}}
  head: <sha>
  base: {{base_ref}} @ {{base_sha}} (verified; equivalent remote accepted by SHA if reported)
  files:
    <list of files modified/created with line counts>
  validation: {{validation}} — PASS|FAIL|SKIPPED
  judgment calls: <list>
  opportunity_findings: none | <finding -> impact -> suggested ORDO improvement>
  blockers: none | <list>
```

## Tools / sources autorises

- `cd {{repo}}`
- `git fetch {{base_remote}}`
- `git checkout -B {{branch_slug}} {{base_ref}}`
- Si `{{base_remote}}` est absent mais qu'un remote equivalent existe pour `{{gh_repo}}`: `git fetch <remote>`, verifier `git rev-parse <remote>/{{default_branch}}` == `{{base_sha}}`, puis `git checkout -B {{branch_slug}} <remote>/{{default_branch}}`
- `git config user.name && git config user.email`
- `gh issue view {{ticket}} --repo {{gh_repo}}`
- `{{project_meta_context}}` si present, pour contexte projet persistant
- `{{validation}}`

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
  - Toute commande de validation/test DOIT etre wrappee par `timeout 300` au minimum (`timeout 300 bash scripts/run_shell_tests.sh`)
  - JAMAIS plus d'un test/validator en background simultanement; si un background bash ne rend pas sa sortie en 5 min, le tuer (`kill <pid>`) et reporter `blocker: validator-hang`
  - JAMAIS relancer en boucle un meme bash background apres timeout/empty output; reporter le blocker au lieu de retry
  - JAMAIS spawner de Task sub-agent pour "running tests" sans timeout explicite; eviter les imbrications de monitors qui s'auto-multiplient

## Definition of Done verifiable

- [ ] La base `{{default_branch}}` a ete verifiee avant implementation
- [ ] L'identite git de l'agent a ete verifiee avant commit
- [ ] Le ticket GitHub a ete relu en entier avant implementation
- [ ] Le scope demande est couvert sans depasser sur des fichiers interdits
- [ ] La commande de validation `{{validation}}` est executee et son resultat est rapporte

## Preuves attendues

- Sortie de `git config user.name && git config user.email`
- Confirmation de la base `{{base_ref}}` sur `{{base_sha}}`, ou remote equivalent `<remote>/{{default_branch}}` avec meme SHA et repo `{{gh_repo}}`
- Sortie de la commande de validation `{{validation}}`
- Liste des fichiers modifies avec line counts
