import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import "../services"

Item {
    id: root

    // Gate the analyzer process (typically bound to MusicPlayer.isPlaying)
    property bool active: true

    // 12 normalized chroma values C..B
    property var    chroma:   [0,0,0,0,0,0,0,0,0,0,0,0]
    property string topNote:  ""
    property string topNote2: ""
    property string topNote3: ""

    readonly property var noteNames:
        ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    implicitHeight: 86

    // ── Backend process ──────────────────────────────────────────────────
    Process {
        id: chromaProc
        running: root.active
        command: ["bash", "-c", "exec '" + Qt.resolvedUrl("../backend/chroma-analyzer.sh").toString().replace("file://", "") + "'"]

        stdout: SplitParser {
            onRead: (data) => {
                var line = data.trim();
                if (line.startsWith("CHROMA:")) {
                    var parts = line.substring(7).split(",");
                    if (parts.length !== 12) return;
                    var arr = [];
                    for (var i = 0; i < 12; i++) {
                        var v = parseFloat(parts[i]);
                        arr.push(isNaN(v) ? 0 : v);
                    }
                    root.chroma = arr;
                } else if (line.startsWith("TOP:")) {
                    var top = line.substring(4).split(",");
                    root.topNote  = top[0] || "";
                    root.topNote2 = top[1] || "";
                    root.topNote3 = top[2] || "";
                }
            }
        }
        stderr: SplitParser { onRead: (_) => { /* swallow */ } }

        onRunningChanged: if (!running) {
            root.chroma   = [0,0,0,0,0,0,0,0,0,0,0,0];
            root.topNote  = "";
            root.topNote2 = "";
            root.topNote3 = "";
        }
    }

    // ── Layout ───────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        spacing: 3

        // Bars
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 3

            Repeater {
                model: 12
                delegate: Item {
                    required property int index
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    // Boost gain so a typical 0.05–0.20 chroma fills the bar
                    readonly property real level:
                        Math.max(0, Math.min(1, (root.chroma[index] || 0) * 5.0))
                    readonly property bool isTop:
                        root.noteNames[index] === root.topNote
                    readonly property bool isSecondary:
                        root.noteNames[index] === root.topNote2 ||
                        root.noteNames[index] === root.topNote3

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 2 + parent.level * (parent.height - 4)
                        radius: 2
                        color: parent.isTop
                            ? Theme.accentColor
                            : (parent.isSecondary
                                ? Qt.rgba(Theme.accentColor.r,
                                          Theme.accentColor.g,
                                          Theme.accentColor.b, 0.65)
                                : Qt.rgba(Theme.accentColor.r,
                                          Theme.accentColor.g,
                                          Theme.accentColor.b, 0.30))
                        opacity: root.active ? (0.55 + parent.level * 0.45) : 0.20
                        Behavior on height  { NumberAnimation { duration: 70; easing.type: Easing.OutCubic } }
                        Behavior on color   { ColorAnimation  { duration: 200 } }
                        Behavior on opacity { NumberAnimation { duration: 200 } }
                    }
                }
            }
        }

        // Note labels
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredHeight: 12
            spacing: 3

            Repeater {
                model: 12
                delegate: Text {
                    required property int index
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: root.noteNames[index]
                    font.family: "JetBrains Mono"
                    font.pixelSize: 9
                    font.bold: root.noteNames[index] === root.topNote
                    color: root.noteNames[index] === root.topNote
                        ? Theme.accentColor
                        : Theme.textDim
                }
            }
        }
    }
}
