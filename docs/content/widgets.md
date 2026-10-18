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
| `FileExplorer.qml` | L'onglet « Explorer » : les dossiers du PC. Les favoris à gauche (les dossiers du dossier personnel, cachés exceptés, puis `/etc/nixos`), le chemin cliquable segment par segment, le contenu en tuiles (les images en miniature). Comme dans un gestionnaire de fichiers, un clic sélectionne et un double clic entre dans un dossier ou ouvre un fichier (`xdg-open`, la barre s'efface) ; une tuile se glisse vers une autre application (Dolphin, navigateur, messagerie…), qui reçoit le fichier comme depuis un gestionnaire de fichiers. Sélection multiple : Ctrl+clic ajoute ou retire, Maj+clic prend une plage, un clic dans le vide désélectionne ; glisser une tuile sélectionnée emporte toute la sélection ; une pastille dit combien sont sélectionnés, et la vide ; les boutons montrent les fichiers cachés, ouvrent le dossier dans le gestionnaire de fichiers ou un terminal. Le dossier est gardé d'un onglet à l'autre. Au-dessus des favoris, un sélecteur passe de cette machine aux serveurs du tailnet (la liste d'`anna servers list`, ceux qu'on atteint par ssh) : le serveur est monté par `sshfs` (`host:/`, sous `$XDG_RUNTIME_DIR/karenine-sshfs/<nom>`, `BatchMode` : une clé ssh est nécessaire) et reste monté jusqu'au passage à une autre machine ; ses favoris sont les dossiers de son dossier personnel et sa config NixOS (la racine passe par le disque « / », le chemin ou ↑) ; le terminal y ouvre une session ssh dans le même dossier ; pas de miniatures à distance. En bas, sur toute la largeur, une pastille par disque physique de la machine montrée (`df -l` et `lsblk`, par ssh à distance), avec leur remplissage ; un clic va à leur point de montage principal. Un relevé raté (ssh) garde les disques affichés et réessaie 5 s plus tard. |
| `HardwareStats.qml` | L'onglet « Système » : processeur, mémoire et carte graphique (le pourcentage en grand, la courbe derrière). En haut, un sélecteur (`MachinePicker`) passe de cette machine à un serveur du tailnet : son relevé vient d'anna (`servers_watch`, par ssh, toutes les 3 s), carte graphique comprise (NVIDIA par `nvidia-smi` ; AMD par sysfs, la carte qui a le plus de VRAM : en veille, elle n'est pas lue pour ne pas la réveiller et la tuile dit « En veille » ; éveillée, elle est relue au plus toutes les 15 s, pour la laisser se rendormir) ; à droite, son nom, depuis quand il tourne et sa charge, ou l'erreur de ssh, puis ses actions : terminal (une session ssh dans le terminal du système), redémarrer et éteindre (deux appuis ; sans sudo sans mot de passe, le terminal s'ouvre pour le taper) ; hors ligne, allumer par Wake-on-LAN, une fois sa MAC relevée en ligne. Le choix de la machine est le même pour l'Explorer et l'onglet Système (`Widgets.machine`). |
| `NotesWidget.qml` | Prise de notes. |
| `PhoneWidget.qml` | L'onglet « Téléphone » : le téléphone relié par KDE Connect (anna, `phone.rs`). Sa carte (batterie, réseau mobile ; « Écran » l'affiche dans une fenêtre scrcpy, faire sonner, fichiers, presse-papier ; un fichier déposé dessus lui est envoyé), et ses notifications à côté. Accepte ou refuse une demande d'appairage. |
| `GlassButton.qml` | Le bouton des widgets, dans le style de la barre (pilule translucide, teintée si `accent`). |
| `MachinePicker.qml` | Le choix de la machine, partagé par l'Explorer et l'onglet Système : une pastille au nom de la machine montrée, qui déroule celle-ci et les serveurs du tailnet joignables par ssh (`anna servers list`), en ligne ou non. Le choix va dans `Widgets.machine`, le même pour tous les onglets ; chacun le suit (l'Explorer monte le serveur par sshfs en revenant à l'écran, et revient à la machine montée si le montage échoue). |
| `FocusRing.qml` | Le contour de ce qui a le clavier, partagé par tous les contrôles. |
| `MusicPlayerWidget.qml` | Lecteur de musique. |
| `Tuner.qml` | Accordeur — voir [Outils musicaux](#audio-tools). |
| `Metronome.qml` | Métronome — voir [Outils musicaux](#audio-tools). |
| `ChromaGraph.qml` | Chromagramme — voir [Outils musicaux](#audio-tools). |
| `MiniGraph.qml` | Petit graphe réutilisable. |
| `Settings.qml` | Réglages, en quatre colonnes : périphériques ; écran, accordeur (le la de référence, persisté par le singleton `Tuning` dans `tuner.json`), voix (le mot d'éveil « Karénine », via `ClaudeLive.voiceWakeToggle()` — anna le retient) ; apparence ; palette (l'onglet Réglages de `WidgetHub`). |
| `DeviceSettings.qml` | Première colonne des réglages : sortie et entrée du son, webcam (nœuds PipeWire, `wpctl set-default`) ; la luminosité est dans la barre du haut (`HubTopBar`). |

## Clavier

Toute action d'un widget s'atteint sans la souris. Le contour à la teinte de
la barre (`FocusRing.qml`) montre ce qui a le clavier ; un clic ne le fait
pas apparaître.

| Touche | Effet |
| --- | --- |
| ↑ (champ vide) | Ouvre les widgets ; une seconde fois, passe sur les onglets. |
| ↑ ↓ (texte tapé) | Parcourent les suggestions, au-dessus de la barre (↑ y entre par la meilleure, contre la barre ; ↓ depuis elle revient au champ). Entrée ouvre la suggestion retenue ; ← → règlent le volume ou l'accent retenu. |
| Flèches, Entrée, Retour arrière (dans l'Explorer) | Promènent le curseur dans le dossier, ouvrent le fichier ou entrent dans le dossier (Entrée sur plusieurs sélectionnés : les ouvre tous), remontent au parent. Maj+flèches étendent la sélection, Espace ajoute ou retire, Ctrl+A prend tout, Échap vide la sélection. Taper les premières lettres d'un nom y saute ; le bouton « précédent » de la souris remonte aussi. |
| ↓ (dans le champ) | Referme les widgets. |
| Tab / Maj+Tab | Passe d'un contrôle à l'autre : barre du haut, widget, onglets, champ. |
| Entrée / Espace | Actionne le bouton, la tuile ou la pastille. |
| Maj+Entrée | Sur la capture : l'écran entier (comme le clic droit). |
| ← → / ↑ ↓ | Règlent les curseurs (volume, luminosité), la position du morceau (±5 s), le tempo, le la, les sélecteurs de couleur (Maj : pas plus grand). |
| ← → | Changent de widget : depuis le champ vide, les onglets, ou tout contrôle qui n'en fait rien d'autre. Ctrl+Tab aussi (Ctrl+Maj+Tab : en arrière). |
| Échap | Rend le clavier au champ ; dans le champ, lâche la suggestion retenue, puis referme les widgets, puis la barre ; sur un bouton d'alimentation armé, renonce. |

Se déconnecter, redémarrer et éteindre demandent toujours deux appuis. La
carte flottante (contrôle gestuel) prend le clavier une fois cliquée ; Échap
la ferme.

## Relations

- Affichés par les [panneaux](#panels), sélectionnés via l'[IPC du shell](#shell).
- Les widgets musicaux (`Tuner`, `Metronome`, `ChromaGraph`) s'appuient sur des
  [scripts backend](#backend) — regroupés dans [Outils musicaux](#audio-tools).
- Leurs couleurs proviennent du [thème](#theme).
