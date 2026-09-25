#!/bin/sh
# Index des conversations Claude présentes sur la machine, une ligne par
# session, champs séparés par des tabulations :
#
#   kind \t id \t cwd \t mtime \t fichier \t titre
#
#   kind    « cli » (Claude Code) ou « desktop » (Claude Desktop)
#   cwd     le répertoire de *départ* de la session — c'est lui qui décide du
#           dossier de rangement, donc ce que `claude --resume` retrouve
#   fichier le JSONL, vide côté desktop (format et emplacement différents)
#
# Tout tient en quatre processus quelle que soit la quantité de sessions :
# stat, head, tail, awk. La version naïve (une poignée de grep/jq par fichier)
# coûtait 3 s pour 48 sessions — le prix des forks, pas celui du disque.
# Celle-ci tient en ~50 ms.
#
# On ne lit que les deux bouts de chaque JSONL : le cwd est posé dès les
# premiers enregistrements, le titre est réécrit jusqu'au dernier.

# Le programme awk passe par un heredoc et non par une chaîne entre
# apostrophes : les commentaires ci-dessous en contiennent.
prog=$(cat <<'AWK'
  # Les lignes de stat, préfixées pour ne pas être confondues avec du JSONL.
  /^S[0-9]+\t/ { split($0, a, "\t"); mt[a[3]] = substr(a[1], 2); sz[a[3]] = a[2]; next }

  # Chaque fichier passe deux fois : une en tête, une en queue. Sa deuxième
  # apparition marque le début de la phase « queue » — pas besoin de sentinelle
  # dans le flux, qui serait forgeable par le contenu (une session qui parle de
  # ce script contient le texte de ce script).
  /^==> .* <==$/ {
    p = substr($0, 5, length($0) - 8); dup = (p in seen)
    if (phase2) flush()
    cur = p
    if (dup) { phase2 = 1; ttl = ""; lp = ""; skip = (sz[cur] > 65536) }
    else     { seen[p] = 1; phase2 = 0 }
    next
  }

  cur == "" { next }
  # La fenêtre de queue commence au milieu d'une ligne : on la jette.
  skip { skip = 0; next }

  # Phase tête : le premier cwd rencontré, et rien d'autre.
  !phase2 {
    if (!(cur in cw) && match($0, /"cwd":"[^"]*"/)) cw[cur] = substr($0, RSTART + 7, RLENGTH - 8)
    next
  }

  # Phase queue : le dernier titre gagne. Le titre généré prime sur le dernier
  # prompt, qui n'est qu'un repli.
  /"type":"ai-title"/    && match($0, /"aiTitle":"[^"]*"/)    { ttl = substr($0, RSTART + 11, RLENGTH - 12) }
  /"type":"last-prompt"/ && match($0, /"lastPrompt":"[^"]*"/) { lp  = substr($0, RSTART + 14, RLENGTH - 15) }

  END { if (phase2) flush() }

  function flush(   t, d, n, a) {
    if (cur == "") return
    d = cw[cur]
    # Aucun cwd dans le fichier (session avortée) : le nom du dossier de
    # rangement est le cwd slugifié. Le repli se trompe sur un chemin qui
    # contient de vrais tirets, ce qui vaut mieux que pas de chemin du tout.
    if (d == "") { n = split(cur, a, "/"); d = a[n - 1]; gsub(/-/, "/", d) }
    # Extraction naïve : un titre contenant un guillemet échappé est tronqué
    # là. Il est de toute façon écourté à l'affichage.
    t = (ttl != "" ? ttl : lp); gsub(/\\n|\\t|\\r/, " ", t)
    printf "cli\t%s\t%s\t%s\t%s\t%s\n", base(cur), d, mt[cur], cur, t
  }
  function base(p,   n, a) { n = split(p, a, "/"); sub(/\.jsonl$/, "", a[n]); return a[n] }
AWK
)

set -- "$HOME"/.claude/projects/*/*.jsonl
if [ -e "$1" ]; then
    # head -c coupe au milieu d'une ligne et ne termine pas par un saut de
    # ligne : sans ce printf, le premier en-tête de tail se collerait à la
    # dernière ligne de head, et ce fichier-là manquerait à l'appel.
    { stat -c 'S%Y	%s	%n' -- "$@"
      head -v -c 65536 -- "$@"
      printf '\n'
      tail -v -c 65536 -- "$@"
    } | awk "$prog"
fi

# Claude Desktop. Ces sessions n'apparaissent qu'une fois les « OS entry
# points » activés dans l'application, et n'ont pas de transcript lisible ici :
# elles restent cherchables, mais le mode IA du dock ne les affiche pas.
for f in "$HOME"/.config/Claude/claude-code-sessions/*/*/local_*.json; do
    [ -e "$f" ] || continue
    jq -r '["desktop", .sessionId, (.cwd // ""), ((.lastActivityAt // 0) | tostring), "",
            ((.title // "") | gsub("[\n\t]"; " "))] | @tsv' "$f" 2>/dev/null
done
