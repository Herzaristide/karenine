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
services/            Singletons transverses (voir Thème) et sources de recherche
  Theme.qml, ClaudeSessions.qml
  claude-index.sh, claude-transcript.sh   (voir « Scripts » ci-dessous)
panels/              Chrome de haut niveau (fenêtres Wayland)
  TopBar, BottomDock, CardCarousel, SidePanel, RightPanel, SettingsWindow
widgets/             Contenu des panneaux
  HardwareStats, NotesWidget, Metronome, Tuner, MusicPlayerWidget,
  QuickControls, ChromaGraph, MiniGraph, Settings
ai/                  Cluster chat IA
  AIPanel (sélecteur), ClaudeChat, OllamaChat, OllamaTools,
  SessionTranscript
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

## Scripts shell embarqués

Le travail qui relève franchement du shell vit dans des fichiers `.sh` posés à
côté du QML qui les lance, et non dans une chaîne JavaScript échappée — un
programme awk entre apostrophes dans une chaîne QML n'est ni lisible ni
testable. Les deux actuels servent le mode IA du [dock](#panels) :

| Script | Rôle |
| --- | --- |
| `services/claude-index.sh` | L'index des conversations Claude de la machine, une ligne TSV par session. |
| `services/claude-transcript.sh` | Les derniers échanges d'une session, un objet JSON par ligne. |

L'indexeur ne lit que les deux bouts de chaque JSONL et tient en quatre
processus quelle que soit la quantité de sessions — la version naïve, une
poignée de `grep`/`jq` par fichier, coûtait 3 s là où celle-ci tient en 50 ms.
C'est le prix des forks, pas celui du disque.

Le QML les localise par `Qt.resolvedUrl`, donc ils suivent l'installation comme
le reste du layout.

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
