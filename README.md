# karenine

Interface [Quickshell](https://quickshell.org/) : barre + panneaux latéraux, chat IA,
notes, stats matérielles, accordeur / métronome / chromagramme, lecteur de musique.

QML + scripts (bash/python) + assets. Le paquet `quickshell` amont vit dans la
configuration NixOS qui consomme ce dépôt comme *input de flake*.

## Architecture

```
shell.qml            Point d'entrée Quickshell (barre + panneaux, IPC via FIFO)
services/            Singletons transverses
  Theme.qml            État de thème (lit le daemon paletted, defaults intégrés)
panels/              Chrome de haut niveau (fenêtres Wayland)
  BottomBar, SidePanel, RightPanel, SettingsWindow
widgets/             Contenu des panneaux
  HardwareStats, NotesWidget, Metronome, Tuner, MusicPlayerWidget,
  QuickControls, ChromaGraph, MiniGraph, Settings
ai/                  Cluster chat IA
  AIPanel (sélecteur), ClaudeChat, OllamaChat, OllamaTools
backend/             Scripts lancés par les widgets
  metronome.sh, tuner.py + tuner.sh, chroma-analyzer.py + chroma-analyzer.sh,
  voice-assistant.sh, mic-level.sh, mic-transcribe.sh
assets/              nixos.svg
```

Chaque sous-dossier a un `qmldir`. Les composants sont importés par chemin relatif
(`import "../services"`, `import "../widgets"`, …) — on n'utilise pas `import "root:/…"`
(déconseillé par Quickshell : casse le LSP et les singletons).

Les backends sont résolus **relativement** au fichier QML via
`Qt.resolvedUrl("../backend/…")` : aucun chemin n'est codé en dur, le dépôt est
donc relocalisable (fonctionne quel que soit le préfixe d'installation).

Les scripts Python lisent du PCM brut sur stdin ; leurs wrappers `.sh`
(`tuner.sh`, `chroma-analyzer.sh`) branchent `parec` dessus au bon format
(stéréo 44,1 kHz pour le tuner, mono 22,05 kHz pour le chromagramme).

## Configuration

Deux réglages sont codés en dur (pas de placeholder de build) :

- Écran de la barre : `primaryScreen: "DP-1"` dans `shell.qml`.
- Couleur d'accent par défaut : `#5277c3` dans `services/Theme.qml` (surchargée à
  chaud par le daemon `paletted` quand il tourne ; sans lui, les defaults intégrés
  s'appliquent).

## Installation

### Via le flake (recommandé)

`packages.default` assemble le layout prêt pour `~/.config/quickshell`. Dans la
configuration NixOS/Home-Manager qui consomme ce flake :

```nix
home.file.".config/quickshell".source = karenine.packages.${system}.default;
```

### Manuel (hors NixOS)

Copier/symlink le contenu du dépôt dans `~/.config/quickshell/` (en préservant les
sous-dossiers), rendre `backend/*.sh` exécutables, puis lancer `quickshell`.

## Développement

- `nix build .#default` (ou `nix flake check`) : valide que le layout s'assemble.
- `nix fmt` : formate le `flake.nix`.
- La CI lance shellcheck sur `backend/*.sh`, `py_compile` sur les `.py`, et `nix build`.
