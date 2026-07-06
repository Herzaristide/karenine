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
anna/                Daemon Rust unique — thème, hwstats, tuner, chroma, métronome
assets/              nixos.svg
```

Chaque sous-dossier a un `qmldir`. Les composants sont importés par chemin relatif
(`import "../services"`, `import "../widgets"`, …) — on n'utilise pas `import "root:/…"`
(déconseillé par Quickshell : casse le LSP et les singletons).

Tout le backend est le daemon Rust `anna` : les widgets s'y connectent via un
**socket Unix** (`$XDG_RUNTIME_DIR/anna.sock`) et échangent du JSON ligne par
ligne (type `Quickshell.Io.Socket`). Plus aucun script bash/python ni dépendance
`parec`/`numpy`. L'audio (accordeur, chromagramme, métronome) est natif via
`cpal` + `rustfft`, à la fréquence réelle du périphérique.

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
sous-dossiers), builder `anna` (`cargo build --release` dans `anna/`, nécessite
`alsa-lib` + `pkg-config`) et le lancer en daemon, puis lancer `quickshell`.

## Développement

- `nix build .#default` (ou `nix flake check`) : valide que le layout s'assemble.
- `nix fmt` : formate le `flake.nix`.
- La CI build le daemon `anna` (`cargo`) et `nix build` le layout.
