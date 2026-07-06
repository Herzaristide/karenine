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

Le paquet copie `shell.qml`, `services`, `panels`, `widgets`, `ai`, `assets` dans
`$out`. C'est la **seule source de vérité** du layout — plus de copie de fichiers
bruts côté config. Le daemon `anna` est un paquet séparé
(`packages.anna`), à lancer en service utilisateur.

## Manuel (hors NixOS)

1. Copier/symlink le contenu du dépôt dans `~/.config/quickshell/` (en préservant
   les sous-dossiers).
2. Builder et lancer le daemon `anna` (`cargo build --release` dans `anna/`,
   nécessite `alsa-lib` + `pkg-config`).
3. Lancer `quickshell`.

Grâce aux chemins relatifs et au socket `anna` (voir [Architecture](#architecture)),
aucun réglage de préfixe n'est nécessaire.

## Ensuite

- Ajuster les [réglages codés en dur](#configuration) (écran, accent).
- Pour contribuer, voir [Développement](#development).
