---
title: Backend
group: Structure
summary: Les scripts bash/python lancés par les widgets — audio, micro, assistant vocal.
links: [widgets, audio-tools, ai, architecture]
---

# Backend (`backend/`)

Les **scripts** lancés par les [widgets](#widgets). Ils sont résolus
relativement via `Qt.resolvedUrl("../backend/…")` (voir [Architecture](#architecture)),
ce qui rend le dépôt relocalisable.

| Script | Rôle |
| --- | --- |
| `tuner.py` + `tuner.sh` | Détection de hauteur pour l'accordeur (stéréo 44,1 kHz). |
| `chroma-analyzer.py` + `chroma-analyzer.sh` | Analyse chromatique (mono 22,05 kHz). |
| `metronome.sh` | Génération du clic du métronome. |
| `mic-level.sh` | Niveau du micro. |
| `mic-transcribe.sh` | Transcription micro. |
| `voice-assistant.sh` | Assistant vocal. |

## Conventions

- Les scripts Python lisent du **PCM brut sur stdin** ; les wrappers `.sh`
  branchent `parec` au bon format d'échantillonnage.
- Les `.sh` doivent être **exécutables** (`chmod +x backend/*.sh`) — c'est fait
  automatiquement par le paquet du flake (voir [Installation](#installation)).
- Les outils audio sont détaillés dans [Outils musicaux](#audio-tools) ; les
  scripts micro/voix servent le [cluster IA](#ai).
