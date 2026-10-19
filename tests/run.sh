#!/usr/bin/env sh
# Tests QML (qmltestrunner, sans écran).
#
# Les fichiers testés vivent dans services/, à côté d'autres qui chargent le
# plugin Quickshell — introuvable hors du binaire quickshell. Un fichier QML
# importe implicitement tout son dossier : on copie donc ceux qui n'importent
# que QtQuick dans un dossier à part (`pure`), avec leur propre qmldir. Ce dont
# ils dépendent et qui touche au système (I18n, Theme, DefaultApps, les
# sources de recherche) y est remplacé par les doublures de tests/stubs.
#
# Usage : tests/run.sh [chemin des modules Qt]   (défaut : déduit de qmltestrunner)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
qml=${1:-$(dirname "$(dirname "$(readlink -f "$(command -v qmltestrunner)")")")/lib/qt-6/qml}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir "$work/pure"
# Les vrais fichiers testés.
for s in Fuzzy DragState Search; do
    cp "$root/services/$s.qml" "$work/pure/"
    echo "singleton $s 1.0 $s.qml" >> "$work/pure/qmldir"
done
cp "$root/services/WebSource.qml" "$work/pure/"
echo "WebSource 1.0 WebSource.qml" >> "$work/pure/qmldir"
# Les doublures.
for s in I18n Theme DefaultApps; do
    cp "$root/tests/stubs/$s.qml" "$work/pure/"
    echo "singleton $s 1.0 $s.qml" >> "$work/pure/qmldir"
done
for t in StubSource AppSource FileSource SettingSource WallpaperSource NoteSource; do
    cp "$root/tests/stubs/$t.qml" "$work/pure/"
    echo "$t 1.0 $t.qml" >> "$work/pure/qmldir"
done
cp "$root"/tests/tst_*.qml "$work/"

QT_QPA_PLATFORM=offscreen exec qmltestrunner -import "$qml" -input "$work"
