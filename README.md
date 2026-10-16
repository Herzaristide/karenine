# karenine

Interface [Quickshell](https://quickshell.org/) : barre + panneaux latéraux, chat IA,
notes, stats matérielles, accordeur / métronome / chromagramme, lecteur de musique.

QML + scripts (bash/python) + assets. Le paquet `quickshell` amont vit dans la
configuration NixOS qui consomme ce dépôt comme *input de flake*.

## Architecture

```
shell.qml            Point d'entrée Quickshell (barre de conversation + widgets, IPC via FIFO)
services/            Singletons transverses
  Anna.qml             Chemin du socket du daemon anna (partagé par les widgets)
  Theme.qml            État de thème (lit state.json écrit par anna, defaults intégrés)
  Display.qml          Choix de l'écran de l'interface (persisté) + workspaces qui le suivent
  Gesture.qml          Contrôle gestuel par webcam (piloté par anna)
  Search.qml           Agrégateur de recherche + <Type>Source.qml (app, fichier,
                       web, paramètre, conversation), Fuzzy, DefaultApps, Audio
panels/              Chrome de haut niveau (fenêtres Wayland)
  ConversationBar      Barre du bas : flocon (voix) + champ qui parle au pilote, réponse au-dessus
  WidgetHub            Widgets à onglets dans la capsule de la barre, que le flocon agrandit
  FloatingWidgets      Carte flottante du contrôle gestuel (WidgetCard), ouverte par anna
  SessionToast         Alertes des sessions Claude
  AiDock               Dock IA (widget « sessions ») : sessions Claude, conversation, revue
  BottomDock           Ancien dock du bas (navigation + recherche), mis de côté
  cards/               Cartes du dock, une par type de résultat
widgets/             Contenu des widgets flottants
  HardwareStats, NotesWidget, Metronome, Tuner, MusicPlayerWidget,
  QuickControls, GestureControls, ChromaGraph, MiniGraph, Settings
ai/                  Cluster chat IA
  AIPanel (sélecteur), ClaudeChat, OllamaChat, OllamaTools
lock/                Écran de verrouillage (lock.qml) : horloge, musique, stats
anna/                Daemon Rust unique — thème, hwstats, serveurs (ssh), tuner, chroma, métronome,
                     gestes webcam, sessions Claude Code (barre, permissions, dock IA),
                     pilote (outils du bureau servis en MCP), voix (whisper.cpp)
tests/               Tests QML (qmltestrunner) — `tests/run.sh`
assets/              nixos.svg, icons/
```

Chaque sous-dossier a un `qmldir`. Les composants sont importés par chemin relatif
(`import "../services"`, `import "../widgets"`, …) — on n'utilise pas `import "root:/…"`
(déconseillé par Quickshell : casse le LSP et les singletons).

Tout le backend est le daemon Rust `anna` : les widgets s'y connectent via un
**socket Unix** (`$XDG_RUNTIME_DIR/anna.sock`) et échangent du JSON ligne par
ligne (type `Quickshell.Io.Socket`). Plus de backend bash/python ni de dépendance
`parec`/`numpy` (seuls restent deux petits scripts d'indexation des sessions
Claude, `services/claude-*.sh`). L'audio (accordeur, chromagramme, métronome) est natif via
`cpal` + `rustfft`, à la fréquence réelle du périphérique. (Le dock du bas,
lui, appelle quelques outils du système — voir *Dépendances externes* plus bas.)

## Dépendances externes

Le backend des widgets est entièrement `anna` (voir ci-dessus), mais le dock du
bas (`panels/BottomDock.qml`) pilote des outils du système. Ils sont appelés par
leur nom dans le `$PATH` ; aucun n'est requis pour démarrer le shell, chacun ne
désactive que sa propre fonction s'il manque.

| Outil | Utilisé par | Sans lui |
| --- | --- | --- |
| `fd` | `services/FileSource.qml` | la recherche de fichiers ne renvoie rien |
| `jq` | `services/ClaudeSource.qml` | les conversations Claude ne sont pas indexées |
| `wpctl` (wireplumber) | `services/Audio.qml` | la carte volume n'affiche ni ne règle rien |
| `grimblast` | `services/SettingSource.qml` | la carte capture d'écran ne fait rien |
| `xdg-mime`, `xdg-open` (xdg-utils) | `services/DefaultApps.qml`, `FileSource` | les rôles retombent sur le premier outil connu du `$PATH` |
| `claude-desktop` | `services/ClaudeSource.qml` | les sessions Claude Desktop ne s'ouvrent pas (celles du CLI, si) |

L'éditeur, l'explorateur, le terminal et le navigateur ne sont **jamais** des noms
en dur : `DefaultApps` les résout depuis `xdg-mime` et `$TERMINAL`, avec un repli
sur le premier candidat connu trouvé dans le `$PATH`.

## Configuration

Deux valeurs par défaut sont codées en dur :

- Écran de la barre par défaut : `primaryScreen: "DP-1"` dans `shell.qml` (substitué
  par la config Nix). Le réglage « Écran » (onglet Réglages des widgets) passe devant
  et est persisté dans `~/.local/share/quickshell/by-shell/<id>/display.json`.
- Couleur d'accent par défaut : `#5277c3` dans `services/Theme.qml` (surchargée à
  chaud par le daemon `anna` quand il tourne ; sans lui, les defaults intégrés
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

- `nix flake check` : assemble le layout, passe tout le QML à qmllint (zéro
  warning toléré) et lance les tests QML (`tests/run.sh`, qmltestrunner).
- `cd anna && cargo test` : tests du daemon (thème, protocole, client, DSP de
  l'accordeur et du chromagramme, reconnaissance des gestes…).
- `nix fmt` : formate le `flake.nix` ; `cargo fmt` dans `anna/`.
- La CI vérifie `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`
  et `nix flake check`.
