---
title: Configuration
group: Utilisation
summary: Les deux réglages codés en dur — écran de la barre et couleur d'accent par défaut.
links: [shell, theme, installation]
---

# Configuration

karenine a **deux réglages codés en dur** (pas de placeholder de build) :

## Écran de la barre

Dans `shell.qml` :

```qml
primaryScreen: "DP-1"
```

C'est la sortie qui reçoit la barre (voir [Le shell](#shell)). À adapter au
moniteur voulu.

## Couleur d'accent par défaut

Dans `services/Theme.qml` :

```qml
// #5277c3
```

Cette couleur est **surchargée à chaud** par le daemon `paletted` quand il
tourne ; sans lui, les defaults intégrés s'appliquent (voir [Thème](#theme)).

---

Pour installer et déployer le layout, voir [Installation](#installation).
