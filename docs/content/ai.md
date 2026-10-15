---
title: Cluster IA
group: Fonctionnalités
summary: Le dock IA (sessions Claude Code lancées, suivies et revues depuis l'interface), les sessions en direct dans la barre, les permissions, et l'ancien chat (ai/), mis de côté.
links: [panels, backend, widgets]
---

# Cluster IA

## Le dock IA

`panels/AiDock.qml` est la porte d'entrée de l'interface vers Claude. Il
remplace le dock du bas (`BottomDock`, mis de côté). Il sort de la **barre
des sessions** (`panels/SessionBar.qml`) : une bande toute noire contre le bord
gauche, sur toute la hauteur, toujours là (les fenêtres lui laissent sa place), avec un point par session vivante — ambre si elle
attend, à la teinte de l'accent (qui respire) si elle travaille, éteint au
repos. Survoler un point donne son nom et son état ; un clic ouvre le dock sur
cette session (et le referme si c'est déjà elle), un clic sur ✦ bascule le
dock. C'est aussi le widget « sessions », qu'ouvrent le pilote (outil
`widget`) ou la FIFO (`widget:sessions`, `savoir`). Le quotidien passe par la
barre de conversation (`panels/ConversationBar.qml`, voir [Panneaux](#panels)),
dont le dock reprend le verre, la teinte (`Theme.glow`), la police Inter et la
capsule de saisie.

```
╭──────────────────────────────────────────────────────────╮
│ ● karenine·fix-dock                          travaille    │  la session regardée
│ + nouvelle  ⟲ historique  ◈ savoir                        │
├──────────────────────────────────────────────────────────┤
│  la conversation de la session choisie                   │
│  worktree-… · 2 fichiers +14 −3   Zed Terminal Commit …   │  son travail
│ ( › écrire à Claude                                 (↑) ) │
╰──────────────────────────────────────────────────────────╯
```

- **+ nouvelle** : choisir où Claude travaille — la recherche (le coffre
  Obsidian, style « chercheur ») ou un dépôt — puis écrire la demande. Dans un
  dépôt, la session tourne par défaut dans une **copie isolée**
  (`claude --worktree` : `<dépôt>/.claude/worktrees/<nom>`, branche
  `worktree-<nom>`) : le code de travail ne bouge pas tant qu'on n'a pas
  fusionné.
- **Une session** : sa conversation se met à jour pendant qu'elle avance ; on
  lui répond dans le champ du bas. Une session ouverte dans un terminal se lit
  ici mais se poursuit là-bas (bouton Terminal), pour ne jamais faire écrire
  deux processus dans la même conversation.
- **Son travail** (copie isolée) : fichiers modifiés et lignes, commits à
  fusionner, puis **Commit**, **Fusionner** (dans la branche courante du dépôt,
  refusé s'il y a des changements non commités d'un côté ou de l'autre, annulé
  en cas de conflit), **Jeter** (deux clics), **Zed**, **Terminal** (la session
  y est reprise par `claude --resume`), **Arrêter**.
- **⟲ historique** : les anciennes conversations (index de `ClaudeSessions`) ;
  en choisir une la relit, lui écrire la reprend.

Clavier : ⏎ envoie, ⇧⏎ va à la ligne, Alt+←/→ change de session, Alt+N
ouvre une nouvelle session, Échap ferme.

Les sessions lancées d'ici tournent chez anna (`anna/src/claude/runner.rs`), pas
dans le QML : fermer le dock ou recharger le shell ne les interrompt pas. Elles
meurent en revanche avec anna (redémarrage, rebuild) — leur transcript reste, et
leur écrire les reprend. Leurs demandes de permission arrivent dans la bulle
de la barre, comme celles d'un terminal.

| Fichier | Rôle |
| --- | --- |
| `panels/AiDock.qml` | Le dock IA. |
| `services/ClaudeLive.qml` | Sessions vivantes, conversation suivie, commandes vers anna. |
| `anna/src/claude/runner.rs` | Lance, reprend, relance et arrête les sessions du dock ; ouvre Zed ou un terminal. |
| `anna/src/claude/transcript.rs` | Lit le JSONL d'une session et en suit la croissance. |
| `anna/src/claude/worktree.rs` | Revue, commit, fusion et suppression des copies isolées. |

## Le savoir

« ◈ savoir », dans le dock (ou `echo savoir > /tmp/qs-panel.fifo`), montre le
coffre Obsidian `~/v4ult` : notes de recherche, notes de projet, skills, lab, et
le journal des sessions qu'écrit le hook `claude-journal`.

- **Filtres** : tout, à relire, recherche, projets, skills, lab, journal, avec
  leur nombre. Ce qu'on tape dans le champ du bas affine la liste ; Entrée ouvre
  la première note.
- **Aperçu** à droite (Markdown, sans l'en-tête), avec **Relu** pour une note que
  Claude a rangée (`statut: relu`, `revu: <date du jour>`, écrit en place),
  **Session** pour rouvrir la conversation dont elle vient (champ `session`), et
  **Obsidian** pour l'ouvrir là-bas.
- **◈ Capitaliser**, dans la barre de travail d'une session lancée du dock, une
  fois son tour fini : lui envoie `/capitaliser`, qui range dans le coffre ce
  qu'elle a appris.

anna relit le coffre à chaque ouverture de la vue (`anna/src/claude/knowledge.rs`)
et en profite pour tenir les skills actives : chaque `Skills/<nom>/SKILL.md` est
lié dans `~/.claude/skills/`, et un lien dont la note a disparu est retiré. Rien
d'autre dans ce dossier n'est touché. Le pilote, lui, cherche dans les mêmes
notes avec `chercher_notes`.

## Le pilote

Le dock s'ouvre sur le **pilote** : une session Claude (Haiku par défaut) qu'anna
garde prête, à qui l'on dit ce qu'on veut en quelques mots.

- **Il agit sur le bureau** avec ses outils (`anna/src/claude/desk.rs`) :
  fenêtres et workspaces, son, luminosité, lecture média, applications, URL,
  projets (Zed, terminal), captures, couleur d'accent, notes du coffre, état du
  bureau, presse-papiers.
- **Il confie le travail de fond** — code, recherche — à une session complète
  (`lancer_session`), dans une copie isolée pour un dépôt. Elle apparaît en haut
  du dock et dans la barre.
- **Il demande avant l'irréversible** : fermer une fenêtre, lancer une commande
  shell, reconstruire NixOS passent par la bulle de la barre (Autoriser /
  Refuser), au nom d'une session « pilote » le temps de la question.

Une action confirmée en une phrase referme le dock ; la confirmation passe dans
la bulle (« ✦ pilote »). Une réponse plus longue, une question en retour ou une
erreur restent affichées. « joindre le presse-papiers » ajoute son texte à la
demande ; « oublier » repart d'une conversation vierge.

Mécanique : `claude -p` en stream-json, avec son propre prompt système
(`--system-prompt`), sans les outils intégrés de Claude Code (`--tools ""`),
avec pour seul serveur MCP `anna mcp` (`--strict-mcp-config`), sans les
réglages de l'utilisateur (`--setting-sources project` : ni hooks ni journal)
et sans transcript sur disque. Chaque demande porte un bloc de contexte : date,
fenêtre active, fenêtres ouvertes, son, sessions, projets. Le processus est
gardé entre deux demandes et relancé après 20 min d'inactivité ou 30 demandes.
Comptez environ 2 s pour une réponse directe, 4 s au premier appel avec un outil.

Réglages : `ANNA_PILOT_MODEL` (variable d'environnement d'anna) change le
modèle ; `~/.config/anna/pilote.md`, s'il existe, est ajouté au prompt (applis
préférées, habitudes, projets…).

| Fichier | Rôle |
| --- | --- |
| `anna/src/claude/pilot.rs` | Le processus du pilote, son prompt, le contexte, le fil des échanges. |
| `anna/src/claude/desk.rs` | Ses outils et leur exécution (Hyprland en dispatchers Lua). |
| `anna/src/claude/mcp.rs` | `anna mcp` : le serveur MCP (stdio) qui les lui présente. |

## La voix

Deux façons de parler, et dans les deux le texte s'écrit **pendant** qu'on
parle :

- **Super+V** (ou `anna voice`, `echo voix > /tmp/qs-panel.fifo`) : la phrase
  s'écrit en direct dans le champ de la barre de conversation (le flocon
  s'allume), puis part au pilote comme si on l'avait tapée. La réponse
  s'affiche au-dessus de la barre, sous la phrase comprise pour vérifier. Le
  mot « Karénine » et un clic sur le flocon font la même chose.
- **Espace maintenu dans le dock** : une dictée, comme dans Claude Code. On
  garde Espace enfoncé et on parle : le texte s'écrit en direct dans le champ
  (après ce qui y était déjà). Tant que la touche est tenue, les pauses ne
  coupent pas. Au relâchement, la transcription finale arrive (0,2 s environ)
  et **reste dans le champ** : on relit, on corrige, puis Entrée envoie. Un
  espace tapé normalement reste un espace : la dictée démarre quand Espace est
  tenu 0,35 s sans autre touche, et l'espace écrit à l'appui est alors retiré.
  Le 🎙 lance la même dictée à la souris ; elle s'arrête à la fin de la phrase.

Avec Super+V, la fin de la phrase arrête l'écoute (un second appui ou un clic sur la pastille
aussi). La pastille affiche « j'écoute… » tant que rien n'est compris, puis le
texte au fur et à mesure.

Tout est local : capture par anna (`cpal`), transcription par whisper.cpp
(modèle « small », français). Rien ne quitte la machine que le texte, qui va où
irait une demande tapée.

### Le texte en direct

Un serveur whisper.cpp reste chargé pendant qu'on parle, et ce qui a été dit
jusque-là est retranscrit toutes les demi-secondes ; la transcription finale,
sur l'enregistrement entier, remplace le texte provisoire.

- Il tourne sur la carte graphique dédiée (Vulkan), choisie d'après
  `vulkaninfo` : environ 0,1 s par phrase sur la RTX 3070, contre près de 2 s
  sur le processeur. Sans carte dédiée, le processeur prend le relais et le
  texte suit la voix de moins près.
- Il démarre avec le premier mot et s'arrête après 10 minutes sans usage, pour
  que la carte dédiée puisse se mettre en veille. Le tout premier démarrage
  d'une version de whisper.cpp compile ses shaders (une douzaine de secondes :
  pas de texte en direct cette fois-là, la transcription finale attend le
  serveur) ; ensuite le cache du pilote graphique ramène le démarrage sous la
  seconde.
- Si le serveur ne démarre pas, `whisper-cli` transcrit l'enregistrement à la
  fin, sans texte en direct.

Pour essayer sans parler : `anna voice simulate fichier.wav [--send|--hold]` fait
passer un enregistrement par exactement la même chaîne que le micro, en temps
réel (sans `--send`, rien ne part au pilote ; avec `--hold`, comme Espace
maintenu : l'écoute dure jusqu'à `anna voice release`).

### Le mot d'activation « Karénine »

Dire « Karénine » lance l'écoute, comme Super+V : « Karénine, baisse le son ».
On l'allume ou l'éteint par « ○ Karénine » dans le dock, ou `anna voice wake
[on|off]` ; le choix survit aux redémarrages. Allumé, le micro reste ouvert :
c'est pourquoi l'interrupteur est en vue.

- Toutes les 80 ms, trois petits modèles ONNX (openWakeWord, sur le
  processeur, environ 4 % d'un cœur) : un spectrogramme, un « embedding »
  commun à tous les mots d'activation, puis le modèle propre à « Karénine »
  (200 Ko), qui note la dernière seconde et demie entre 0 et 1.
- Au-dessus du seuil (0,6 ; `ANNA_WAKE_THRESHOLD`), les 2,5 dernières secondes
  passent devant la demande. **Whisper doit entendre « Karénine » au début**
  de la première transcription ; sinon le tour s'arrête sans bruit (une
  demi-seconde de pastille dans la barre). Confirmé, le mot est retiré de la
  demande.
- `anna wake-score fichier.wav` donne les scores pas à pas, pour régler le seuil.

Le modèle a été entraîné dans `~/ciph3r/lab/wakeword-karenine/` : la chaîne
officielle d'openWakeWord, mais nourrie d'exemples **français** générés par
Piper (voix tom, siwis, upmc, gilles, plus les 904 voix anglaises de libritts
lisant des phonèmes français), chacun vérifié par Whisper, et de mots voisins
à ne pas confondre (Karine, Catherine, carabine…). Sur des voix françaises de
synthèse jamais vues, il en reconnaît environ la moitié, pour un faux
déclenchement par heure de son ordinaire : il manque surtout des voix
réelles. Des enregistrements de la voix de l'utilisateur sont le prochain
progrès.

| Fichier | Rôle |
| --- | --- |
| `anna/src/claude/wake.rs` | Le détecteur et l'écoute continue. |
| `anna/models/wake/karenine.onnx` | Le modèle du mot (les deux autres viennent d'openWakeWord). |

### Fin de phrase et nettoyage

Le niveau sonore des premiers instants donne le bruit de la pièce ; la parole
est ce qui le dépasse nettement ; 1,2 s de silence après la parole termine la
demande. Sans parole en 6 s, l'écoute s'arrête sur « rien entendu ». Arrêtée à
la main avant toute parole, elle ne transcrit rien.

Whisper « entend » des choses dans le silence et le bruit : génériques de
sous-titres (« Sous-titres réalisés par… »), marqueurs comme `[BLANK_AUDIO]`,
`(musique)` ou `*Bip*`. Tout cela est écarté.

Le prompt initial de Whisper liste les noms des projets et quelques termes
(Zed, dock, Obsidian…) : sans lui, « karenine » devient « Carnine ».

Le modèle : `ANNA_WHISPER_MODEL`, sinon `~/.local/share/anna/whisper/ggml-small.bin`,
lié par la configuration NixOS. La dictée intégrée à Claude Code reste
disponible dans les sessions de terminal ; elle n'est pas utilisée ici : elle
n'existe que dans son interface, et passe par un service privé d'Anthropic.

| Fichier | Rôle |
| --- | --- |
| `anna/src/claude/voice.rs` | Écoute, fin de phrase, texte en direct, envoi au pilote. |
| `anna/src/claude/whisper.rs` | Le serveur whisper.cpp : choix de la carte, démarrage, arrêt. |

## L'ancien chat (`ai/`), mis de côté

Le **chat IA** d'origine — sélecteur Ollama / Claude dans le panneau latéral —
n'est plus chargé (`SidePanel.qml`, index 1), et le **volet de session** ne
servait qu'au mode IA du [dock du bas](#panels), lui aussi mis de côté. Les
fichiers restent en place.

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

## Sessions en direct

Toutes les sessions Claude Code de la machine — lancées dans un terminal ou
sans tête — se signalent à anna par leurs hooks (`anna hook`, déclaré dans la
configuration de Claude Code pour SessionStart, UserPromptSubmit, PostToolUse,
Notification, Stop, SessionEnd et PermissionRequest). Le module
`anna/src/claude/` en tient l'état ; `services/ClaudeLive.qml` le suit par
`claude_watch`.

- **La bulle** (`panels/SessionToast.qml`) apparaît en haut à droite quand une
  session attend, demande une permission, ou finit un tour de plus de 20 s.

| Fichier | Rôle |
| --- | --- |
| `anna/src/claude/mod.rs` | L'état des sessions : working / waiting / idle, alertes. |
| `anna/src/claude/hook.rs` | `anna hook` : transmet un événement réduit au strict nécessaire. |
| `anna/src/claude/permission.rs` | Les demandes de permission tenues jusqu'à la réponse de la bulle. |
| `anna/src/claude/focus.rs` | Retrouve la fenêtre d'une session dans l'arbre des processus. |

## Répondre aux permissions depuis la bulle

Quand Claude s'apprête à demander « je peux… ? », le hook PermissionRequest
passe la demande à anna et attend. La bulle montre l'outil et ce qu'il ferait
(la commande, le fichier, l'URL), avec quatre réponses :

| Bouton | Effet |
| --- | --- |
| Autoriser | L'outil tourne, cette fois. |
| Toujours | L'outil tourne, et la règle que Claude Code suggère (« ne plus redemander pour… ») est enregistrée, exactement comme depuis son propre dialogue. La bulle dit laquelle. |
| Refuser | Claude est prévenu du refus et poursuit. |
| Terminal | Pas de réponse ici : le dialogue du terminal s'affiche, et sa fenêtre passe devant. |

Le terminal garde la main dès que la barre ne peut pas aider : aucune barre ne
suit les sessions, la fenêtre de la session est déjà au premier plan (on est
devant), elle y passe pendant que la demande est ouverte, ou personne ne répond
en 5 minutes. Le hook ne dit alors rien, et Claude Code se comporte comme sans
lui.

Seul un résumé quitte Claude : l'outil, la commande ou le chemin, coupés à 300
caractères. Le contenu d'un fichier à écrire, par exemple, ne transite pas.

## Relations

- Hébergé par les [panneaux](#panels).
