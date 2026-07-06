---
title: Panneaux
group: Structure
summary: Le chrome de haut niveau — BottomBar, SidePanel, RightPanel, SettingsWindow.
links: [shell, widgets, ai, theme]
---

# Panneaux (`panels/`)

Le **chrome de haut niveau** : les fenêtres Wayland qui composent l'interface.
Elles hébergent les [widgets](#widgets) et sont pilotées par [le shell](#shell).

| Fichier | Rôle |
| --- | --- |
| `BottomBar.qml` | La barre inférieure (point d'ancrage principal). |
| `SidePanel.qml` | Le panneau latéral qui affiche le widget actif (Stats, IA, Notes, Pitch, Music). |
| `RightPanel.qml` | Le panneau de droite (`rightOpen`). |
| `SettingsWindow.qml` | La fenêtre de réglages (héberge le widget `Settings`). |

## Relations

- Ouverts/fermés selon l'état maintenu par [`shell.qml`](#shell) et les messages
  [IPC](#shell).
- Leur contenu vient des [widgets](#widgets) ; le panneau IA héberge le
  [cluster IA](#ai).
- Leur apparence suit le [thème](#theme).
