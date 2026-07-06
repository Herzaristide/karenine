pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
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

    // ── Backend ──────────────────────────────────────────────────────────
    // Native `anna` daemon: subscribe to the chroma service over the Unix
    // socket and receive one {"chroma":[12],"top":[…]} JSON line per frame.
    // anna captures the mic only while this connection is open (i.e. active).
    Socket {
        id: chromaSock
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/anna.sock"

        parser: SplitParser {
            onRead: (line) => {
                try {
                    var msg = JSON.parse(line);
                    if (Array.isArray(msg.chroma) && msg.chroma.length === 12) {
                        var arr = [];
                        for (var i = 0; i < 12; i++) {
                            var v = msg.chroma[i];
                            arr.push(typeof v === "number" ? v : 0);
                        }
                        root.chroma = arr;
                    }
                    if (Array.isArray(msg.top)) {
                        root.topNote  = msg.top[0] || "";
                        root.topNote2 = msg.top[1] || "";
                        root.topNote3 = msg.top[2] || "";
                    }
                } catch (e) { /* ignore malformed / partial line */ }
            }
        }

        onConnectedChanged: {
            if (connected) {
                write('{"cmd":"chroma_watch"}\n');
            } else {
                root.chroma   = [0,0,0,0,0,0,0,0,0,0,0,0];
                root.topNote  = "";
                root.topNote2 = "";
                root.topNote3 = "";
            }
        }
    }

    // Connect while active; retry every 2 s if the daemon isn't up yet.
    Timer {
        interval: 2000
        running: root.active
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!chromaSock.connected) chromaSock.connected = true
    }

    onActiveChanged: if (!active) chromaSock.connected = false

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
