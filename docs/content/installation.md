---
title: Installation
group: Utilisation
summary: Installer karenine via le flake (recommandé) ou manuellement hors NixOS.
links: [configuration, development, architecture]
---

# Installation

## Via le flake (recommandé)

`packages.default` assemble le layout prêt pour `~/.config/quickshell`. Dans la
configuration NixOS/Home-Manager qui consomme ce flake :

```nix
home.file.".config/quickshell".source = karenine.packages.${system}.default;
```

Le paquet copie `shell.qml`, `services`, `panels`, `widgets`, `ai`, `backend`,
`assets` dans `$out`, et rend `backend/*.sh` exécutables. C'est la **seule source
de vérité** du layout — plus de copie de fichiers bruts côté config.

## Manuel (hors NixOS)

1. Copier/symlink le contenu du dépôt dans `~/.config/quickshell/` (en préservant
   les sous-dossiers).
2. Rendre les scripts exécutables : `chmod +x backend/*.sh`.
3. Lancer `quickshell`.

Grâce aux chemins relatifs et à `Qt.resolvedUrl` (voir [Architecture](#architecture)),
aucun réglage de préfixe n'est nécessaire.

## Ensuite

- Ajuster les [réglages codés en dur](#configuration) (écran, accent).
- Pour contribuer, voir [Développement](#development).
