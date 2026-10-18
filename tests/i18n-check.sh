#!/usr/bin/env sh
# Vérifie les dictionnaires de i18n/ :
#   - chaque clé appelée (I18n.tr/trn dans le QML, i18n::tr* dans anna) existe
#     dans en.json, la langue de repli : sinon l'interface afficherait la clé ;
#   - chaque autre langue est signalée pour les clés qui lui manquent (pas
#     d'échec : elles retombent sur l'anglais).
#
# Usage : tests/i18n-check.sh   (jq requis)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
dir="$root/i18n"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Les clés appelées. Le texte est mis sur une ligne : un appel peut en couvrir
# plusieurs (rustfmt). trn("x", n) lit x.one et x.other.
find "$root" -name '*.qml' -not -path '*/tests/*' -not -path '*/.claude/*' -exec cat {} + \
    | tr '\n' ' ' \
    | grep -oE '[Ii]18n\.trn?\( *"[^"]+"' \
    | sed -E 's/[Ii]18n\.tr\( *"([^"]+)"/\1/; s/[Ii]18n\.trn\( *"([^"]+)"/\1.one\n\1.other/' \
    > "$work/used"
find "$root/anna/src" -name '*.rs' -exec cat {} + \
    | tr '\n' ' ' \
    | grep -oE 'i18n::tr(_args)?\( *"[^"]+"|i18n::tr_in\( *[^,]+, *"[^"]+"' \
    | sed -E 's/.*"([^"]+)"$/anna.\1/' \
    >> "$work/used"
sort -u "$work/used" -o "$work/used"

jq -r 'keys[] | select(. != "_meta")' "$dir/en.json" | sort > "$work/en"

status=0
missing=$(comm -23 "$work/used" "$work/en")
if [ -n "$missing" ]; then
    echo "Clés appelées mais absentes de en.json :" >&2
    printf '  %s\n' $missing >&2
    status=1
fi

for f in "$dir"/*.json; do
    lang=$(basename "$f" .json)
    jq -e '._meta.name' "$f" >/dev/null || { echo "$lang.json : _meta.name manquant" >&2; status=1; }
    [ "$lang" = en ] && continue
    jq -r 'keys[] | select(. != "_meta")' "$f" | sort > "$work/$lang"
    todo=$(comm -23 "$work/en" "$work/$lang" | wc -l)
    [ "$todo" -gt 0 ] && echo "$lang : $todo clé(s) à traduire (repli sur l'anglais)"
done

unused=$(comm -13 "$work/used" "$work/en")
[ -n "$unused" ] && echo "en : clés que plus rien n'appelle :" $unused
exit $status
