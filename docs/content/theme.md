---
title: Thème
group: Fonctionnalités
summary: services/Theme.qml — état de thème, defaults intégrés et intégration avec le daemon anna.
links: [configuration, widgets, panels, architecture]
---

# Thème (`services/Theme.qml`)

`Theme.qml` est un **singleton** (dans `services/`) qui porte l'état de thème
partagé par tous les [widgets](#widgets) et [panneaux](#panels).

## Fonctionnement

- Lit `~/.config/accent/state.json`, que le daemon **`anna`** réécrit à chaque
  changement : l'accent change **à chaud**.
- Envoie les changements (accent, mode, couleur de palette, reset) via le client
  `anna`, une commande à la fois : une nouvelle valeur remplace celle qui
  attendait encore, le daemon n'applique que la plus récente.
- En son absence, des **valeurs par défaut intégrées** s'appliquent — dont la
  couleur d'accent `#5277c3` (voir [Configuration](#configuration)).

## Import

Comme les autres singletons, il est importé par chemin relatif :

```qml
import "../services"
```

(voir les conventions dans [Architecture](#architecture)).

> Le daemon `anna` est construit par ce dépôt (`anna/`, voir [Backend](#backend)) ;
> karenine reste fonctionnel sans lui, avec les couleurs par défaut.
