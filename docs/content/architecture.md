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
anna/                Daemon Rust unique (voir Backend)
assets/              nixos.svg
```

Détail par couche : [le shell](#shell), [les panneaux](#panels),
[les widgets](#widgets), [le cluster IA](#ai), [le backend](#backend).

## Conventions QML

- **Chaque sous-dossier a un `qmldir`.** Les composants sont importés par
  **chemin relatif** (`import "../services"`, `import "../widgets"`, …).
- On **n'utilise pas** `import "root:/…"` — déconseillé par Quickshell : ça casse
  le LSP et les singletons.

## Relocalisable par conception

- Les composants QML sont importés par **chemin relatif** : aucun chemin absolu,
  le layout fonctionne quel que soit le préfixe d'installation.
- Le backend est joint via le **socket** `$XDG_RUNTIME_DIR/anna.sock` (pas de
  chemin en dur), ce qui permet les deux modes d'[installation](#installation).

## Flux audio (daemon anna)

Le backend audio est natif : `anna` capture le micro et lit le clic via
[`cpal`](https://crates.io/crates/cpal), et fait la DSP via
[`rustfft`](https://crates.io/crates/rustfft). Toute la math est dérivée de la
**fréquence réelle du périphérique** (pas de rééchantillonnage). Détails dans
[Backend](#backend) et [Outils musicaux](#audio-tools).
