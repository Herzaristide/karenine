#!/bin/sh
# Transcript d'une session Claude Code, lu depuis son JSONL ($1).
#
# Sortie : un objet JSON compact par ligne, prêt à être avalé un par un côté
# QML. La première annonce le total, les suivantes sont les messages :
#
#   {"kind":"count","n":47}
#   {"kind":"msg","role":"user","text":"…","tools":[]}
#   {"kind":"msg","role":"assistant","text":"…","tools":["Bash","Read"]}
#
# On ne garde que la fin de la conversation : le dock en montre les derniers
# échanges, pas l'intégralité — et certains transcripts pèsent 10 Mo.
#
# Sont écartés : les sidechains (sous-agents), les enregistrements internes,
# les résultats d'outils (contenu sans bloc texte), et les tours utilisateur
# qui ne sont qu'une balise de commande ou un rappel système.

f="$1"
[ -e "$f" ] || exit 0

pat='"type":"user"\|"type":"assistant"'

n=$(grep -ac "$pat" "$f" 2>/dev/null)
printf '{"kind":"count","n":%s}\n' "${n:-0}"

grep -a "$pat" "$f" | tail -n 200 | jq -c '
  select((.isSidechain // false) | not)
  | select((.isMeta // false) | not)
  | (if (.message.content | type) == "string" then .message.content
     else [.message.content[]? | select(.type == "text") | .text] | join("\n") end) as $t
  | { kind:  "msg",
      role:  .type,
      text:  (($t // "") | .[0:1200]),
      tools: [.message.content[]? | select(.type == "tool_use") | .name] }
  | select((.text | length) > 0 or (.tools | length) > 0)
  | select(.role == "assistant" or ((.text | startswith("<")) | not))
' 2>/dev/null
