#!/usr/bin/env sh
# Régénère les SVG de ce dossier depuis Phosphor, d'après phosphor.list.
#
# La version est figée (et vérifiée par sa somme) : relancer le script donne
# toujours les mêmes fichiers. Les SVG sont versionnés dans le dépôt, si bien
# que karenine marche tel quel depuis la copie de travail comme depuis le
# paquet Nix ; ce script ne sert qu'à en ajouter ou à en changer.
#
# Chaque icône est réécrite en blanc (Phosphor dessine en currentColor, que Qt
# rendrait en noir) : NixIcon la recolore ensuite au thème. Un SVG qui n'est
# plus dans la liste est supprimé.
#
# Usage : sh assets/icons/sync.sh
# Pour monter de version : changer VERSION et SHA256 (la somme du .tgz npm).
set -eu

VERSION=2.1.1
SHA256=313332be6190b724da24107addd781799b48bf76b13963f24501112ffe1baadd
URL="https://registry.npmjs.org/@phosphor-icons/core/-/core-$VERSION.tgz"

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsSL -o "$work/core.tgz" "$URL"
echo "$SHA256  $work/core.tgz" | sha256sum -c --quiet -
tar -xzf "$work/core.tgz" -C "$work"
assets="$work/package/assets"

: > "$work/kept"
grep -vE '^[[:space:]]*(#|$)' "$here/phosphor.list" | while read -r name weight icon; do
    case $weight in
        regular) src="$assets/regular/$icon.svg" ;;
        thin|light|bold|fill|duotone) src="$assets/$weight/$icon-$weight.svg" ;;
        *) echo "$name : graisse inconnue « $weight »" >&2; exit 1 ;;
    esac
    [ -f "$src" ] || { echo "$name : $icon ($weight) n'existe pas dans Phosphor $VERSION" >&2; exit 1; }
    sed 's/currentColor/#ffffff/g' "$src" > "$here/$name.svg"
    echo "$name.svg" >> "$work/kept"
done

for f in "$here"/*.svg; do
    grep -qxF "$(basename "$f")" "$work/kept" || { rm "$f"; echo "supprimé : $(basename "$f")"; }
done

cp "$work/package/LICENSE" "$here/LICENSE"
echo "$(wc -l < "$work/kept") icône(s) Phosphor $VERSION"
