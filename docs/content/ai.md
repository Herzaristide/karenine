---
title: Cluster IA
group: Fonctionnalités
summary: Le chat IA — sélecteur AIPanel, ClaudeChat, OllamaChat, OllamaTools, et le volet de session SessionTranscript.
links: [panels, backend, widgets]
---

# Cluster IA (`ai/`)

Le **chat IA** de karenine, affiché dans le panneau IA (widget N°1 via
l'[IPC du shell](#shell)), et le **volet de session** du mode IA du
[dock du bas](#panels).

| Fichier | Rôle |
| --- | --- |
| `AIPanel.qml` | Sélecteur : bascule entre les fournisseurs de chat. |
| `ClaudeChat.qml` | Conversation avec Claude — une session neuve, ouverte par le panneau. |
| `OllamaChat.qml` | Conversation avec un modèle Ollama local. |
| `OllamaTools.qml` | Outillage associé à Ollama (tools / fonctions). |
| `SessionTranscript.qml` | Le volet du mode IA : les échanges de la session regardée, et de quoi la poursuivre. |

## Deux façons de parler à Claude

`ClaudeChat` **ouvre** une session neuve ; le mode IA du dock **reprend** une
session existante. Les deux parlent au même CLI dans le même mode headless —
une ligne JSON par événement dans les deux sens — mais le second passe
`--resume <id>`, donc ce qu'on y écrit s'ajoute à la conversation d'origine,
dans son propre fichier. Reprendre une session depuis le dock la modifie pour
de bon.

L'état de ce volet ne lui appartient pas : il vit dans le singleton
`ClaudeSessions` (voir [Architecture](#architecture)), qui tient l'index des
sessions, le transcript de celle qu'on regarde et le processus de reprise.
`SessionTranscript` ne fait que le rendre.

## Permissions

Le dock n'a pas de terminal pour répondre à une demande d'autorisation. La
reprise tourne donc en `acceptEdits` avec `--permission-prompts none` : les
modifications de fichiers passent, tout ce qui demanderait un accord est refusé
d'office plutôt que de laisser l'agent pendu. `ClaudeChat`, lui, est en
`bypassPermissions`. Le curseur se règle par la propriété `permissionMode`.

## Relations

- Hébergé par les [panneaux](#panels).
