---
title: Backend
group: Structure
summary: Le daemon Rust anna — thème, stats matérielles et audio (accordeur, chromagramme, métronome).
links: [widgets, audio-tools, ai, architecture]
---

# Backend (`anna`)

Tout le backend est un **daemon Rust unique**, `anna` (dossier `anna/`). Un seul
daemon par session : s'il trouve le socket déjà servi, il refuse de démarrer au
lieu de le voler. Plus de backend bash/python : les widgets parlent à `anna` via
un **socket Unix**
(`$XDG_RUNTIME_DIR/anna.sock`) en JSON, une ligne par message.

## Services exposés

| Service | Commande | Rôle |
| --- | --- | --- |
| thème | `set` / `mode` / `palette-color` / `reset` / `get` / `watch` | Accent + palette base16, rendu des templates, live-reload. Les rafales (glisser, arc-en-ciel) sont fusionnées : seul l'état le plus récent est appliqué. |
| hwstats | `hwstats_get` / `hwstats_watch` | Stats matérielles (CPU/RAM/GPU/disques). |
| tuner | `tuner_watch` | Détection de hauteur — `{"pitch":<hz>}` par frame. |
| chroma | `chroma_watch` | Chromagramme 12 classes — `{"chroma":[…],"top":[…]}`. |
| metronome | `metronome` | Session de clic sample-accurate, `{"beat":<n>}`. BPM bornés à 20–300, temps par mesure à 1–16. |
| gestes | `gesture_get` / `gesture_set` / `gesture_toggle` / `gesture_watch` / `gesture_cameras` / `gesture_set_camera` | Contrôle par webcam (curseur, saisie de fenêtre, changement de workspace). **Désactivé par défaut**. |

## Audio natif

Les services audio utilisent [`cpal`](https://crates.io/crates/cpal) (capture micro
pour l'accordeur/chromagramme, lecture du clic pour le métronome) et
[`rustfft`](https://crates.io/crates/rustfft) pour la DSP. Toute la math de
fréquence est dérivée de la **fréquence réelle du périphérique** (souvent 48 kHz),
donc aucun rééchantillonnage n'est nécessaire. Chaque service audio ouvre sa
propre capture — le serveur audio (PipeWire) multiplexe les clients, comme le
faisaient les anciens `parec` concurrents.

## Conventions

- Un service « watch » garde la connexion ouverte et **pousse** des lignes JSON ;
  la capture micro correspondante ne tourne dans `anna` que tant que le socket
  est ouvert (le widget se connecte/déconnecte selon sa visibilité).
- Côté QML, on utilise le type `Socket` de `Quickshell.Io` (voir
  `widgets/HardwareStats.qml`, `widgets/Tuner.qml`, `widgets/ChromaGraph.qml`,
  `widgets/Metronome.qml`).
- Les outils audio sont détaillés dans [Outils musicaux](#audio-tools).
