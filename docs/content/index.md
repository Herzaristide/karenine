---
title: Accueil
group: Général
summary: karenine — interface Quickshell (barre, panneaux, chat IA, outils musicaux) en QML et scripts.
links: [architecture, shell, installation, widgets]
---

# karenine

**karenine** est une interface [Quickshell](https://quickshell.org/) : une barre,
des panneaux latéraux, un chat IA, des notes, des statistiques matérielles et une
suite d'outils musicaux (accordeur, métronome, chromagramme, lecteur de musique).

Le projet est fait de **QML** + **scripts** (bash/python) + assets. Le paquet
`quickshell` amont vit dans la configuration NixOS qui consomme ce dépôt comme
*input de flake*.

## Par où commencer

- 🧭 [Architecture & conventions](#architecture) — organisation et règles d'import.
- 🪟 [Le shell & l'IPC](#shell) — `shell.qml` et le pilotage par FIFO.
- 🧱 [Les panneaux](#panels) et [les widgets](#widgets).
- 📦 [Installation](#installation) — via le flake ou manuellement.

## Grandes fonctionnalités

- **Barre + panneaux** Wayland (voir [Panneaux](#panels)).
- **Chat IA** : Claude et Ollama (voir [Cluster IA](#ai)).
- **Outils musicaux** : accordeur, métronome, chromagramme (voir [Outils
  musicaux](#audio-tools)).
- **Thème dynamique** piloté par le daemon `paletted` (voir [Thème](#theme)).
- **Relocalisable** : aucun chemin codé en dur, les backends sont résolus
  relativement (voir [Architecture](#architecture)).
