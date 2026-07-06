---
title: Le shell & l'IPC
group: Structure
summary: shell.qml, point d'entrée Quickshell, et le pilotage externe par FIFO.
links: [architecture, panels, widgets, configuration]
---

# Le shell & l'IPC

`shell.qml` est le **point d'entrée Quickshell** : il monte la barre et les
panneaux, et maintient l'état global (`panelOpen`, `activeWidget`, `rightOpen`).

## Pilotage externe (IPC via FIFO)

Le shell écoute une **FIFO** `/tmp/qs-panel.fifo`, ce qui permet de piloter les
panneaux depuis n'importe quel script ou raccourci :

```bash
echo "widget:N" > /tmp/qs-panel.fifo   # bascule le widget N
echo "close"    > /tmp/qs-panel.fifo   # ferme le panel
```

Indices des widgets :

| N | Widget |
| --- | --- |
| 0 | Stats matérielles |
| 1 | IA (chat) |
| 2 | Notes |
| 3 | Pitch (accordeur) |
| 4 | Music (lecteur) |

En pratique, ces messages sont typiquement émis par des keybinds Hyprland dans
la configuration NixOS qui consomme karenine.

## Ce que monte le shell

- La barre et les panneaux : voir [Panneaux](#panels).
- Le contenu affiché dans les panneaux : voir [Widgets](#widgets).
- L'écran cible de la barre est un [réglage codé en dur](#configuration)
  (`primaryScreen`).
