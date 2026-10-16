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
| `ServersWidget.qml` | Les serveurs suivis par anna (ssh, sans agent) : une tuile chacun (état, processeur, mémoire, disque, « Fichiers » en sftp dans Dolphin). Les ajouter ou les retirer se fait dans les réglages (`ServerSettings`). |
| `GlassButton.qml` | Le bouton des widgets, dans le style de la barre (pilule translucide, teintée si `accent`). |
| `MusicPlayerWidget.qml` | Lecteur de musique. |
| `Tuner.qml` | Accordeur — voir [Outils musicaux](#audio-tools). |
| `Metronome.qml` | Métronome — voir [Outils musicaux](#audio-tools). |
| `ChromaGraph.qml` | Chromagramme — voir [Outils musicaux](#audio-tools). |
| `MiniGraph.qml` | Petit graphe réutilisable. |
| `Settings.qml` | Réglages, en quatre colonnes : périphériques ; écran, accordeur (le la de référence, persisté par le singleton `Tuning` dans `tuner.json`) et serveurs ; apparence ; palette (l'onglet Réglages de `WidgetHub`). |
| `DeviceSettings.qml` | Première colonne des réglages : sortie et entrée du son, webcam (nœuds PipeWire, `wpctl set-default`) ; la luminosité est dans la barre du haut (`HubTopBar`). |
| `ServerSettings.qml` | Section Serveurs des réglages : la liste des serveurs suivis par anna, les retirer, en ajouter (`servers_list` / `servers_add` / `servers_remove`). |

## Relations

- Affichés par les [panneaux](#panels), sélectionnés via l'[IPC du shell](#shell).
- Les widgets musicaux (`Tuner`, `Metronome`, `ChromaGraph`) s'appuient sur des
  [scripts backend](#backend) — regroupés dans [Outils musicaux](#audio-tools).
- Leurs couleurs proviennent du [thème](#theme).
