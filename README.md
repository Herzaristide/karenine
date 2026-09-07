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
  Search.qml           Agrégateur de recherche + <Type>Source.qml (app, fichier,
                       web, paramètre, conversation), Fuzzy, DefaultApps, Audio
panels/              Chrome de haut niveau (fenêtres Wayland)
  BottomBar, SidePanel, RightPanel, SettingsWindow
  RightDock            Dock au survol du bord droit : navigation + recherche
  cards/               Cartes du dock, une par type de résultat
widgets/             Contenu des panneaux
  HardwareStats, NotesWidget, Metronome, Tuner, MusicPlayerWidget,
  QuickControls, ChromaGraph, MiniGraph, Settings, ConsoleWidget
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
`cpal` + `rustfft`, à la fréquence réelle du périphérique. (Le dock de droite,
lui, appelle quelques outils du système — voir *Dépendances externes* plus bas.)

### Console (widget 5)

`ConsoleWidget` est une **console de commandes**, pas un émulateur de terminal.
`Quickshell.Io.Process` est un `QProcess` — des tubes, pas de pty — donc les
commandes sortiraient sans couleurs et sans largeur connue. Le pty est obtenu en
passant par `script` (util-linux), qui en alloue un vrai même quand ses propres
entrée et sortie sont des tubes. La commande voyage dans `QS_CMD` plutôt que
d'être interpolée dans le wrapper : rien à échapper. Le wrapper dimensionne le
pty (`stty cols`) depuis la largeur du panneau, restaure le répertoire courant,
puis émet `\001<code>\001<cwd>\001` — c'est ainsi que `cd` persiste d'une
commande à l'autre et que le code de retour remonte.

Seul le SGR est interprété (couleurs 16 / 256 / 24 bits mappées sur la palette
base16, gras, italique, souligné) ; les autres séquences sont reconnues pour
être proprement ignorées. Il n'y a pas d'entrée standard ni d'adressage du
curseur : les programmes plein écran (`vim`, `htop`, `less`) ne fonctionnent pas
— `PAGER=cat` évite que les plus courants s'y invitent par accident, et `[stop]`
règle le reste. Un vrai terminal demande une machine à états VT et une grille de
cellules, ce qui relève d'`anna`, pas du QML.

## Dépendances externes

Le backend des widgets est entièrement `anna` (voir ci-dessus), mais le dock de
droite (`panels/RightDock.qml`) pilote des outils du système. Ils sont appelés par
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
