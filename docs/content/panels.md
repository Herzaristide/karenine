---
title: Panneaux
group: Structure
summary: Le chrome de haut niveau — TopBar, BottomDock, SidePanel, RightPanel, SettingsWindow.
links: [shell, widgets, ai, theme]
---

# Panneaux (`panels/`)

Le **chrome de haut niveau** : les fenêtres Wayland qui composent l'interface.
Elles hébergent les [widgets](#widgets) et sont pilotées par [le shell](#shell).

| Fichier | Rôle |
| --- | --- |
| `TopBar.qml` | La barre supérieure horizontale (point d'ancrage principal). |
| `BottomDock.qml` | Le dock du bas : carrousel horizontal de navigation, recherche, et mode IA. |
| `CardCarousel.qml` | Le carrousel lui-même — la mécanique, partagée par les trois vues. |
| `SidePanel.qml` | Le panneau latéral qui affiche le widget actif (Stats, IA, Notes, Pitch, Music). |
| `RightPanel.qml` | Le panneau de droite (`rightOpen`). |
| `SettingsWindow.qml` | La fenêtre de réglages (héberge le widget `Settings`). |

## Les trois vues du dock

Une seule surface, trois contenus :

| Vue | Déclencheur | Contenu |
| --- | --- | --- |
| Navigation | requête vide | le dossier courant |
| Résultats | une requête | tous types mélangés, classés par pertinence |
| IA | le bouton `✦` | les conversations Claude de la machine |

Le contenu change, jamais la mécanique : `CardCarousel` reçoit une liste plate
de cartes et ne sait rien de leur type. C'est ce qui garantit qu'un fichier, un
réglage, une page web et une conversation se parcourent et s'activent
exactement de la même façon.

## Le carrousel

Il **tourne**. La carte retenue est clouée au milieu et n'en bouge pas : c'est
la bande qui défile dessous, et le tour boucle — après la dernière carte on
revient à la première sans buter. Les extrémités du chemin sont transparentes,
donc le raccord ne se voit pas.

**Seule la carte du centre agit.** Ses boutons sont les seuls affichés, et une
pression ailleurs ne lance rien : elle ramène la carte visée au milieu. Il faut
donc deux gestes pour ouvrir une carte lointaine — l'amener au centre, puis
l'activer — et c'est voulu : un seul « ici » à l'écran, une seule cible.

Cette bascule vit dans `CardFrame` (`primaryEnabled` / `focusRequested`), pas
dans chaque carte : c'est l'unique endroit qui décide entre « agir » et « venir
au centre ». Ce que *signifie* agir est décidé par le dock, en un seul endroit
lui aussi.

| Geste | Effet |
| --- | --- |
| ← → / molette | fait tourner le carrousel d'une colonne |
| `Entrée` | active la carte du centre |
| ↑ ↓ sur une carte réglable | modifient la valeur sur place |
| ↓ sinon | entre dans le dossier du centre |
| ↑ sinon, ou `Retour arr.` | remonte d'un dossier |
| `Tab` | change de rangée dans la colonne centrale (quadrillage) |
| clic sur une carte | l'amène au centre ; si elle y est déjà, l'active |

Les deux axes ne font pas le même travail : **gauche/droite fait tourner la
bande, haut/bas travaille en profondeur** — dans l'arborescence, ou dans la
valeur que porte la carte.

Activer, c'est ouvrir dans l'application par défaut : `xdg-open` traite fichier
et dossier pareil, donc `Entrée` sur un dossier l'ouvre dans le gestionnaire de
fichiers. Entrer dans un dossier est l'autre geste, ↓, qui ne quitte pas le
dock. Sur une carte de réglage, activer fait ce que le réglage sait faire —
basculer le thème, ouvrir les réglages, prendre la capture.

Une carte est « réglable » quand sa source le déclare (`adjust` dans la charge
utile) : le dock ne connaît pas les réglages un par un. Aujourd'hui, le volume
et la teinte de la couleur d'accent.

Le quadrillage n'est pas une autre mécanique : la liste est découpée en
colonnes de deux cartes, et c'est la colonne qui est le pas du défilement. La
dernière colonne est souvent incomplète — viser sa deuxième ligne se rabat sur
la première.

## Mode IA

La session au centre est celle qu'on lit dans le volet posé au-dessus : faire
tourner le carrousel change de conversation. Il n'y a pas d'arborescence ici,
donc `Entrée` et ↓ descendent tous deux dans le champ de reprise, et `Échap`
sort du mode. Le champ de recherche y filtre les
sessions au lieu de chercher sur le disque.

Seules les sessions Claude Code y figurent : celles de Claude Desktop n'ont pas
de transcript lisible localement, elles restent cherchables par la recherche.

## Relations

- Ouverts/fermés selon l'état maintenu par [`shell.qml`](#shell) et les messages
  [IPC](#shell).
- Leur contenu vient des [widgets](#widgets) ; le panneau IA héberge le
  [cluster IA](#ai).
- Leur apparence suit le [thème](#theme).
