#!/usr/bin/env sh
# Tests QML (qmltestrunner, sans écran).
#
# Les singletons testés vivent dans services/, à côté d'autres qui chargent le
# plugin Quickshell — introuvable hors du binaire quickshell. Un fichier QML
# importe implicitement tout son dossier : on copie donc les singletons purs
# (QtQuick seul) dans un dossier à part, avec leur propre qmldir.
#
# Usage : tests/run.sh [chemin des modules Qt]   (défaut : déduit de qmltestrunner)
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
qml=${1:-$(dirname "$(dirname "$(readlink -f "$(command -v qmltestrunner)")")")/lib/qt-6/qml}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir "$work/pure"
for s in Fuzzy; do
    cp "$root/services/$s.qml" "$work/pure/"
    echo "singleton $s 1.0 $s.qml" >> "$work/pure/qmldir"
done
cp "$root"/tests/tst_*.qml "$work/"

QT_QPA_PLATFORM=offscreen exec qmltestrunner -import "$qml" -input "$work"
