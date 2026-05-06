# Dispatch canonique — {{project}} agent: {{agent}}
# Ticket: #{{ticket}} {{summary}}

## Objectif

Livrer le ticket #{{ticket}} en restant strictement dans le scope defini et avec une validation finale qui passe.

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
