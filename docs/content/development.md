---
title: Développement
group: Utilisation
summary: Valider le layout, lancer les tests, formater, et ce que vérifie la CI.
links: [installation, backend, architecture]
---

# Développement

## Valider le layout

```bash
nix build .#default     # assemble le paquet (~/.config/quickshell)
nix flake check         # layout + qmllint (zéro warning) + tests QML
```

## Tests

```bash
cd anna && cargo test   # daemon : thème, protocole, client, DSP, gestes
tests/run.sh            # QML (qmltestrunner, offscreen) — dans `nix develop`
```

Les tests QML ne couvrent que les singletons **purs** (QtQuick seul, comme
`Fuzzy`) : le plugin Quickshell ne se charge pas hors du binaire `quickshell`.
`tests/run.sh` les copie dans un dossier à part pour ne pas importer le reste de
`services/`.

## Formater

```bash
nix fmt                 # formate le flake.nix (nixfmt-rfc-style)
cd anna && cargo fmt    # formate le daemon
```

## Ce que vérifie la CI

- **`cargo fmt --check`**, **`cargo clippy -D warnings`** et **`cargo test`** sur
  le daemon `anna`
- **`nix flake check`** : layout, qmllint, tests QML

Voir le daemon dans [Backend](#backend), et les conventions QML dans
[Architecture](#architecture).
