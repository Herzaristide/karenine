---
title: Widgets
group: Structure
summary: Le contenu des panneaux — stats, notes, contrôles, graphes et outils musicaux.
links: [panels, backend, audio-tools, theme, shell]
---

# Widgets (`widgets/`)

Le **contenu** affiché dans les [panneaux](#panels). Chaque widget est un
composant QML autonome.

| Widget | Rôle |
| --- | --- |
| `HardwareStats.qml` | Statistiques matérielles (CPU, RAM, …). |
| `NotesWidget.qml` | Prise de notes. |
| `QuickControls.qml` | Contrôles rapides. |
| `MusicPlayerWidget.qml` | Lecteur de musique. |
| `Tuner.qml` | Accordeur — voir [Outils musicaux](#audio-tools). |
| `Metronome.qml` | Métronome — voir [Outils musicaux](#audio-tools). |
| `ChromaGraph.qml` | Chromagramme — voir [Outils musicaux](#audio-tools). |
| `MiniGraph.qml` | Petit graphe réutilisable. |
| `Settings.qml` | Réglages (affiché dans `SettingsWindow`). |

## Relations

- Affichés par les [panneaux](#panels), sélectionnés via l'[IPC du shell](#shell).
- Les widgets musicaux (`Tuner`, `Metronome`, `ChromaGraph`) s'appuient sur des
  [scripts backend](#backend) — regroupés dans [Outils musicaux](#audio-tools).
- Leurs couleurs proviennent du [thème](#theme).
