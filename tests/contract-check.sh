#!/usr/bin/env sh
# Vérifie ce qui relie les morceaux du dépôt, qu'aucun compilateur ne voit :
#   - chaque commande que le QML écrit sur le socket d'anna ({"cmd":"…"})
#     existe dans anna/src/protocol.rs (enum Command, en snake_case) : sinon
#     anna répond « unknown variant » et le widget reste vide ;
#   - chaque entrée d'un qmldir pointe vers un fichier qui existe.
#
# Usage : tests/contract-check.sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
status=0

# Les commandes envoyées : `"cmd":"x"` (JSON littéral) ou `cmd: "x"` (objet JS).
find "$root" -name '*.qml' -not -path '*/tests/*' -not -path '*/.claude/*' \
        -not -path '*/target/*' -exec cat {} + \
    | grep -oE '"?cmd"? *: *"[a-z_]+"' \
    | sed -E 's/.*"([a-z_]+)"$/\1/' \
    | sort -u > "$work/sent"

# Les variantes de Command, CamelCase → snake_case (serde rename_all).
awk '/^pub enum Command/,/^}/' "$root/anna/src/protocol.rs" \
    | grep -oE '^    [A-Z][A-Za-z0-9]*' \
    | sed -E 's/^ +//; s/([a-z0-9])([A-Z])/\1_\2/g' \
    | tr 'A-Z' 'a-z' \
    | sort -u > "$work/known"

[ -s "$work/known" ] || { echo "aucune variante lue dans protocol.rs" >&2; exit 1; }
unknown=$(comm -23 "$work/sent" "$work/known")
if [ -n "$unknown" ]; then
    echo "Commandes envoyées par le QML mais inconnues d'anna :" >&2
    printf '  %s\n' $unknown >&2
    status=1
fi
[ $status = 0 ] && echo "$(wc -l < "$work/sent") commande(s) du QML, toutes connues d'anna"

# Les qmldir : `[singleton] Nom version Fichier.qml`.
for q in $(find "$root" -name qmldir -not -path '*/target/*' -not -path '*/.claude/*'); do
    dir=$(dirname "$q")
    for f in $(grep -oE '[^ ]+\.qml' "$q"); do
        [ -f "$dir/$f" ] || { echo "${q#"$root"/} : $f n'existe pas" >&2; status=1; }
    done
done

# Les icônes : chaque SVG nommé par le QML (`"play.svg"`, `glyph("file")`)
# existe, et chaque SVG de assets/icons vient de phosphor.list (cf. sync.sh).
icons="$root/assets/icons"
find "$root" -name '*.qml' -not -path '*/tests/*' -not -path '*/.claude/*' \
        -not -path '*/target/*' -exec cat {} + \
    | grep -oE '"[a-z0-9-]+\.svg"|glyph\("[a-z0-9-]+"\)' \
    | sed -E 's/^glyph\("([a-z0-9-]+)"\)$/\1.svg/; s/"//g' \
    | sort -u > "$work/icons"
for f in $(cat "$work/icons"); do
    [ -f "$icons/$f" ] || [ -f "$root/assets/$f" ] || { echo "icône introuvable : $f" >&2; status=1; }
done
grep -vE '^[[:space:]]*(#|$)' "$icons/phosphor.list" | awk '{ print $1 ".svg" }' | sort > "$work/listed"
for f in "$icons"/*.svg; do
    grep -qxF "$(basename "$f")" "$work/listed" \
        || { echo "assets/icons/$(basename "$f") n'est pas dans phosphor.list" >&2; status=1; }
done

exit $status
