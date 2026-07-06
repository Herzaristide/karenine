---
title: Outils musicaux
group: Fonctionnalités
summary: Accordeur, métronome et chromagramme — widgets QML + services audio natifs du daemon anna.
links: [widgets, backend, shell]
---

# Outils musicaux

karenine embarque une petite suite pour la pratique musicale, chaque outil étant
un [widget](#widgets) adossé à un service audio natif du daemon [`anna`](#backend).

## Accordeur (Tuner)

- Widget : `widgets/Tuner.qml` (panneau **Pitch**, widget N°3 via l'[IPC](#shell)).
- Backend : service `tuner` d'`anna` (`tuner_watch`) — détection de hauteur par
  autocorrélation FFT, une ligne `{"pitch":<hz>}` par frame.

## Chromagramme (ChromaGraph)

- Widget : `widgets/ChromaGraph.qml`.
- Backend : service `chroma` d'`anna` (`chroma_watch`) — chromagramme 12 classes,
  `{"chroma":[…],"top":[…]}` par frame.

## Métronome

- Widget : `widgets/Metronome.qml`.
- Backend : service `metronome` d'`anna` — flux de sortie `cpal` sample-accurate,
  piloté par des lignes `{"action":…}`, événements `{"beat":<n>}`.

## Principe commun

Les widgets se connectent au **socket** d'`anna` (`Quickshell.Io.Socket`) et
reçoivent des lignes JSON. La capture micro (accordeur, chromagramme) ne tourne
que tant que le widget est visible. Détails dans [Backend](#backend).
