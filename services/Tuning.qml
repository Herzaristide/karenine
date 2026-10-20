pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// La référence de l'accordeur (le la, A4), persistée : réglée dans les
// réglages, lue par le Tuner.
Singleton {
    id: tuning

    readonly property int minFreq: 400
    readonly property int maxFreq: 480

    // En Hz.
    readonly property real refFreq: prefs.refFreq // qmllint disable unqualified
    // L'accordeur écoute (le micro s'ouvre quand l'onglet Musique se montre),
    // ou il est coupé ; gardé d'une session à l'autre.
    readonly property bool on: prefs.on // qmllint disable unqualified

    FileView {
        path: Quickshell.dataPath("tuner.json")
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onAdapterUpdated: writeAdapter()

        JsonAdapter { // qmllint disable unresolved-type
            id: prefs
            property real refFreq: 440
            property bool on: true
        }
    }

    function setOn(v) {
        prefs.on = !!v; // qmllint disable unqualified
    }

    function setRefFreq(v) {
        if (isNaN(v))
            return;
        prefs.refFreq = Math.max(tuning.minFreq, Math.min(tuning.maxFreq, Math.round(v))); // qmllint disable unqualified
    }
}
