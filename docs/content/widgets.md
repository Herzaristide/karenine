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
| `PhoneWidget.qml` | L'onglet « Téléphone » : le téléphone relié par KDE Connect (anna, `phone.rs`). Sa carte (batterie, réseau mobile ; « Écran » l'affiche dans une fenêtre scrcpy, faire sonner, fichiers, presse-papier ; un fichier déposé dessus lui est envoyé), et ses notifications à côté. Accepte ou refuse une demande d'appairage. |
| `ServersWidget.qml` | L'onglet « Network » : les autres appareils du réseau Tailscale, une tuile chacun. Linux en ligne : processeur, mémoire, disque par ssh (sans agent), trois icônes : terminal (une session ssh dans le terminal du système), redémarrer et éteindre (deux appuis ; sans sudo sans mot de passe, le terminal s'ouvre pour le taper). Hors ligne : allumer par Wake-on-LAN, une fois sa MAC relevée en ligne. Les autres : système, adresse, ou depuis quand ils sont hors ligne. |
| `GlassButton.qml` | Le bouton des widgets, dans le style de la barre (pilule translucide, teintée si `accent`). |
| `FocusRing.qml` | Le contour de ce qui a le clavier, partagé par tous les contrôles. |
| `MusicPlayerWidget.qml` | Lecteur de musique. |
| `Tuner.qml` | Accordeur — voir [Outils musicaux](#audio-tools). |
| `Metronome.qml` | Métronome — voir [Outils musicaux](#audio-tools). |
| `ChromaGraph.qml` | Chromagramme — voir [Outils musicaux](#audio-tools). |
| `MiniGraph.qml` | Petit graphe réutilisable. |
| `Settings.qml` | Réglages, en quatre colonnes : périphériques ; écran, accordeur (le la de référence, persisté par le singleton `Tuning` dans `tuner.json`) ; apparence ; palette (l'onglet Réglages de `WidgetHub`). |
| `DeviceSettings.qml` | Première colonne des réglages : sortie et entrée du son, webcam (nœuds PipeWire, `wpctl set-default`) ; la luminosité est dans la barre du haut (`HubTopBar`). |

## Clavier

Toute action d'un widget s'atteint sans la souris. Le contour à la teinte de
la barre (`FocusRing.qml`) montre ce qui a le clavier ; un clic ne le fait
pas apparaître.

| Touche | Effet |
| --- | --- |
| ↑ (champ vide) | Ouvre les widgets ; une seconde fois, passe sur les onglets. |
| ↑ (texte tapé, widgets fermés) | Ouvre l'onglet Recherche. |
| ↑ ↓ ← → (sur l'onglet Recherche) | Parcourent la grille des résultats (↑ y entre par la première tuile, en bas à gauche ; ↓ depuis la rangée du bas revient au champ). Entrée ouvre la tuile retenue ; Maj+← → règlent le volume ou l'accent retenu. |
| ↓ (dans le champ) | Referme les widgets. |
| Tab / Maj+Tab | Passe d'un contrôle à l'autre : barre du haut, widget, onglets, champ. |
| Entrée / Espace | Actionne le bouton, la tuile ou la pastille. |
| Maj+Entrée | Sur la capture : l'écran entier (comme le clic droit). |
| ← → / ↑ ↓ | Règlent les curseurs (volume, luminosité), la position du morceau (±5 s), le tempo, le la, les sélecteurs de couleur (Maj : pas plus grand). |
| ← → | Changent de widget : depuis le champ vide, les onglets, ou tout contrôle qui n'en fait rien d'autre. Ctrl+Tab aussi (Ctrl+Maj+Tab : en arrière). |
| Échap | Rend le clavier au champ ; dans le champ, abandonne la recherche en cours ; sur un bouton d'alimentation armé, renonce. |

Se déconnecter, redémarrer et éteindre demandent toujours deux appuis. La
carte flottante (contrôle gestuel) prend le clavier une fois cliquée ; Échap
la ferme.

## Relations

- Affichés par les [panneaux](#panels), sélectionnés via l'[IPC du shell](#shell).
- Les widgets musicaux (`Tuner`, `Metronome`, `ChromaGraph`) s'appuient sur des
  [scripts backend](#backend) — regroupés dans [Outils musicaux](#audio-tools).
- Leurs couleurs proviennent du [thème](#theme).
