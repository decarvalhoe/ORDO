# Dispatch canonique — {{project}} agent: {{agent}}
# Ticket: #{{ticket}} {{summary}}

## Objectif

Livrer le ticket #{{ticket}} en restant strictement dans le scope defini et avec une validation finale qui passe.

## Regles ORDO injectees pour la flotte

- Contexte repo strict: avant toute mutation, verifier `pwd`, `git status --short --branch`, `git remote -v`, et la base `{{orch_remote}}/{{default_branch}}`. Si le repo, la branche, ou le remote ne correspond pas a ce brief, stopper et rapporter `context-mismatch`.
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
  base: orchestrator/{{default_branch}} @ {{base_sha}} (verified)
  files:
    <list of files modified/created with line counts>
  validation: {{validation}} — PASS|FAIL|SKIPPED
  judgment calls: <list>
  opportunity_findings: none | <finding -> impact -> suggested ORDO improvement>
  blockers: none | <list>
```

## Tools / sources autorises

- `cd {{repo}}`
- `git fetch {{orch_remote}}`
- `git checkout -B {{branch_slug}} {{orch_remote}}/{{default_branch}}`
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

## Definition of Done verifiable

- [ ] La base `{{default_branch}}` a ete verifiee avant implementation
- [ ] L'identite git de l'agent a ete verifiee avant commit
- [ ] Le ticket GitHub a ete relu en entier avant implementation
- [ ] Le scope demande est couvert sans depasser sur des fichiers interdits
- [ ] La commande de validation `{{validation}}` est executee et son resultat est rapporte

## Preuves attendues

- Sortie de `git config user.name && git config user.email`
- Confirmation de la base `{{orch_remote}}/{{default_branch}}` sur `{{base_sha}}`
- Sortie de la commande de validation `{{validation}}`
- Liste des fichiers modifies avec line counts
