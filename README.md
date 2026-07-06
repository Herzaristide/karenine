# karenine

Interface [Quickshell](https://quickshell.outfoxxed.me/) (barre + panneaux latéraux +
chat IA + notes + stats matérielles + accordeur/métronome…).

Fichiers QML, scripts (bash/python) et assets. Le paquet `quickshell` amont et le
câblage NixOS (installation dans `~/.config/quickshell`) vivent dans la configuration
NixOS qui consomme ce dépôt comme input de flake.

## Placeholders

Deux jetons sont substitués par la glue NixOS au moment du build (laisser tels quels ici) :

- `@PRIMARY_MONITOR@` dans `shell.qml` — sortie Hyprland recevant la barre.
- `@PALETTE_ACCENT@` dans `Theme.qml` — couleur d'accent initiale.

## Usage hors NixOS

Copier/symlink le contenu dans `~/.config/quickshell/`, remplacer les deux placeholders,
et lancer `quickshell`.
