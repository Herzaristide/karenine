---
title: Outils musicaux
group: Fonctionnalités
summary: Accordeur, métronome et chromagramme — widgets QML + analyse audio en Python.
links: [widgets, backend, shell]
---

# Outils musicaux

karenine embarque une petite suite pour la pratique musicale, chaque outil étant
un [widget](#widgets) adossé à un [script backend](#backend).

## Accordeur (Tuner)

- Widget : `widgets/Tuner.qml` (panneau **Pitch**, widget N°3 via l'[IPC](#shell)).
- Backend : `backend/tuner.py` (détection de hauteur) + `backend/tuner.sh` qui
  branche `parec` en **stéréo 44,1 kHz** sur son stdin.

## Chromagramme (ChromaGraph)

- Widget : `widgets/ChromaGraph.qml`.
- Backend : `backend/chroma-analyzer.py` + `backend/chroma-analyzer.sh` qui
  fournit du **mono 22,05 kHz**.

## Métronome

- Widget : `widgets/Metronome.qml`.
- Backend : `backend/metronome.sh`.

## Principe commun

Les analyseurs Python lisent du **PCM brut sur stdin** ; le wrapper `.sh`
correspondant s'occupe de la capture au bon format (voir [Backend](#backend) et
les conventions dans [Architecture](#architecture)).
