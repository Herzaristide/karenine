---
title: Le shell & l'IPC
group: Structure
summary: shell.qml, point d'entrée Quickshell, et le pilotage externe par FIFO.
links: [architecture, panels, widgets, configuration]
---

# Le shell & l'IPC

`shell.qml` est le **point d'entrée Quickshell** : il monte la barre de
conversation, les widgets flottants, la bulle des sessions et le dock IA.
Quels widgets sont ouverts, et où, vit dans le singleton `services/Widgets.qml`.

## Pilotage externe (IPC via FIFO)

Le shell écoute une **FIFO** `/tmp/qs-panel.fifo`, ce qui permet de le piloter
depuis n'importe quel script ou raccourci — et c'est par là qu'anna ouvre les
widgets quand le pilote appelle son outil MCP `widget` :

```bash
echo "widget:stats"          > /tmp/qs-panel.fifo   # bascule un widget
echo "widget:musique:ouvrir" > /tmp/qs-panel.fifo   # ouvrir | fermer | basculer
echo "widget:tout:fermer"    > /tmp/qs-panel.fifo   # referme tout
echo "dock"                  > /tmp/qs-panel.fifo   # fait monter / renvoie la barre
echo "voix"                  > /tmp/qs-panel.fifo   # parle au pilote
echo "close"                 > /tmp/qs-panel.fifo   # ferme tout
```

Les widgets :

| Nom | Widget |
| --- | --- |
| `stats` | Stats matérielles |
| `musique` | Lecteur |
| `metronome` | Métronome et accordeur |
| `son` | Volume, sorties et entrées audio |
| `camera` | Contrôle gestuel |
| `reglages` | Fenêtre de réglages |
| `sessions` | Dock IA (sessions Claude, savoir) |

Les anciens `widget:N` restent compris (0 = stats, 1 = sessions, 3 = metronome,
4 = musique), ainsi que `controls` (son) et `camera`.

En pratique, ces messages sont typiquement émis par des keybinds Hyprland dans
la configuration NixOS qui consomme karenine.

## Ce que monte le shell

- La barre de conversation et les widgets flottants : voir [Panneaux](#panels).
- Le contenu des widgets : voir [Widgets](#widgets).
- L'écran cible de la barre est un [réglage codé en dur](#configuration)
  (`primaryScreen`).
