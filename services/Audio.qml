pragma Singleton
import QtQuick
import Quickshell.Services.Pipewire

// Le volume de la sortie par défaut, lu et réglé par Pipewire. Ses propriétés
// suivent PipeWire en direct : un changement venu d'ailleurs (touches du
// clavier, anna, pavucontrol) s'affiche aussitôt, sans sondage.
QtObject {
    id: root

    readonly property PwNode sink: Pipewire.defaultAudioSink
    readonly property bool ready: root.sink !== null && root.sink.ready && root.sink.audio !== null

    readonly property real level: root.ready ? root.sink.audio.volume : 0.0
    readonly property bool muted: root.ready && root.sink.audio.muted
    readonly property int percent: Math.round(level * 100)

    // Sans suivi, les propriétés audio d'un nœud ne sont jamais renseignées.
    property PwObjectTracker tracker: PwObjectTracker {
        objects: [root.sink]
    }

    // Plafonné à 100 % : au-delà, PipeWire amplifie en logiciel et sature.
    function set(v) {
        if (root.ready)
            root.sink.audio.volume = Math.max(0, Math.min(1, v));
    }
    function up()         { set(root.level + 0.05); }
    function down()       { set(root.level - 0.05); }
    function toggleMute() {
        if (root.ready)
            root.sink.audio.muted = !root.sink.audio.muted;
    }
}
