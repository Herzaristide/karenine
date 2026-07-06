---
title: Thème
group: Fonctionnalités
summary: services/Theme.qml — état de thème, defaults intégrés et intégration avec le daemon paletted.
links: [configuration, widgets, panels, architecture]
---

# Thème (`services/Theme.qml`)

`Theme.qml` est un **singleton** (dans `services/`) qui porte l'état de thème
partagé par tous les [widgets](#widgets) et [panneaux](#panels).

## Fonctionnement

- Lit la couleur diffusée par le daemon **`paletted`** quand il tourne, ce qui
  permet de changer l'accent **à chaud**.
- En son absence, des **valeurs par défaut intégrées** s'appliquent — dont la
  couleur d'accent `#5277c3` (voir [Configuration](#configuration)).

## Import

Comme les autres singletons, il est importé par chemin relatif :

```qml
import "../services"
```

(voir les conventions dans [Architecture](#architecture)).

> Le daemon `paletted` provient de la configuration NixOS qui consomme karenine ;
> karenine reste fonctionnel sans lui.
