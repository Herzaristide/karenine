---
title: Cluster IA
group: Fonctionnalités
summary: Le chat IA — sélecteur AIPanel, ClaudeChat, OllamaChat et OllamaTools.
links: [panels, backend, widgets]
---

# Cluster IA (`ai/`)

Le **chat IA** de karenine, affiché dans le panneau IA (widget N°1 via
l'[IPC du shell](#shell)).

| Fichier | Rôle |
| --- | --- |
| `AIPanel.qml` | Sélecteur : bascule entre les fournisseurs de chat. |
| `ClaudeChat.qml` | Conversation avec Claude. |
| `OllamaChat.qml` | Conversation avec un modèle Ollama local. |
| `OllamaTools.qml` | Outillage associé à Ollama (tools / fonctions). |

## Relations

- Hébergé par les [panneaux](#panels).
