---
title: Développement
group: Utilisation
summary: Valider le layout, formater, et ce que vérifie la CI.
links: [installation, backend, architecture]
---

# Développement

## Valider le layout

```bash
nix build .#default     # assemble le paquet (~/.config/quickshell)
nix flake check         # vérifie au minimum que le layout s'assemble
```

## Formater

```bash
nix fmt                 # formate le flake.nix (nixfmt-rfc-style)
```

## Ce que vérifie la CI

- **shellcheck** sur `backend/*.sh`
- **`py_compile`** sur les scripts `.py`
- **`nix build`** du paquet

Voir les scripts concernés dans [Backend](#backend), et les conventions QML dans
[Architecture](#architecture).
