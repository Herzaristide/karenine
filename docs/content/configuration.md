---
title: Configuration
group: Utilisation
summary: Les deux valeurs par défaut codées en dur — écran de la barre et couleur d'accent.
links: [shell, theme, installation]
---

# Configuration

karenine a **deux valeurs par défaut codées en dur** :

## Écran de la barre

Dans `shell.qml` :

```qml
primaryScreen: "DP-1"
```

C'est la sortie qui reçoit la barre par défaut (voir [Le shell](#shell)) ; la
config Nix substitue cette ligne. Le réglage « Écran » de la fenêtre de
paramètres passe devant : il désigne l'écran par son **modèle** (stable d'une
machine à l'autre, contrairement au connecteur) et il est **persisté** dans
`~/.local/share/quickshell/by-shell/<id>/display.json`. Si l'écran choisi
est débranché, la barre retombe sur `primaryScreen`, puis sur le premier écran.

## Couleur d'accent par défaut

Dans `services/Theme.qml` :

```qml
// #5277c3
```

Cette couleur est **surchargée à chaud** par le daemon `anna` quand il
tourne ; sans lui, les defaults intégrés s'appliquent (voir [Thème](#theme)).

---

Pour installer et déployer le layout, voir [Installation](#installation).
