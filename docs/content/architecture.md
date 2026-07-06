---
title: Architecture & conventions
group: Général
summary: Organisation du dépôt et règles d'import QML (qmldir, chemins relatifs, Qt.resolvedUrl).
links: [shell, panels, widgets, ai, backend, theme]
---

# Architecture & conventions

## Organisation du dépôt

```
shell.qml            Point d'entrée Quickshell (barre + panneaux, IPC via FIFO)
services/            Singletons transverses (voir Thème)
  Theme.qml
panels/              Chrome de haut niveau (fenêtres Wayland)
  BottomBar, SidePanel, RightPanel, SettingsWindow
widgets/             Contenu des panneaux
  HardwareStats, NotesWidget, Metronome, Tuner, MusicPlayerWidget,
  QuickControls, ChromaGraph, MiniGraph, Settings
ai/                  Cluster chat IA
  AIPanel (sélecteur), ClaudeChat, OllamaChat, OllamaTools
backend/             Scripts lancés par les widgets (voir Backend)
assets/              nixos.svg
```

Détail par couche : [le shell](#shell), [les panneaux](#panels),
[les widgets](#widgets), [le cluster IA](#ai), [les backends](#backend).

## Conventions QML

- **Chaque sous-dossier a un `qmldir`.** Les composants sont importés par
  **chemin relatif** (`import "../services"`, `import "../widgets"`, …).
- On **n'utilise pas** `import "root:/…"` — déconseillé par Quickshell : ça casse
  le LSP et les singletons.

## Relocalisable par conception

- Les backends sont résolus **relativement** au fichier QML via
  `Qt.resolvedUrl("../backend/…")` : aucun chemin absolu, le dépôt fonctionne
  quel que soit le préfixe d'installation.
- C'est ce qui permet les deux modes d'[installation](#installation) (flake ou
  manuel) sans génération de wrappers.

## Flux audio des scripts Python

Les scripts Python lisent du **PCM brut sur stdin** ; leurs wrappers `.sh`
branchent `parec` au bon format (stéréo 44,1 kHz pour l'accordeur, mono
22,05 kHz pour le chromagramme). Détails dans [Backend](#backend) et
[Outils musicaux](#audio-tools).
