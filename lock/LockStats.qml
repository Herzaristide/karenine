pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../services"
import "../widgets"

// Stats matérielles compactes pour le lockscreen.
//
// S'abonne au même flux que widgets/HardwareStats (un snapshot JSON par
// seconde sur le socket du daemon anna), mais n'en garde que CPU / RAM / GPU
// et une sparkline par série — le panneau complet (disques, températures,
// noms de composants) n'a pas sa place sur un écran verrouillé.
RowLayout {
    id: statsRoot

    spacing: 28

    readonly property int histLen: 40

    property int cpuUsage: 0
    property int ramUsage: 0
    property int gpuUsage: 0
    property bool gpuPresent: false

    property list<int> cpuHistory: []
    property list<int> ramHistory: []
    property list<int> gpuHistory: []

    function pushHistory(arr: list<int>, value: int): list<int> {
        const out = arr.slice(arr.length >= statsRoot.histLen ? 1 : 0);
        out.push(value);
        return out;
    }

    function applyStats(s: var) {
        statsRoot.cpuUsage = s.cpu_usage;
        statsRoot.cpuHistory = statsRoot.pushHistory(statsRoot.cpuHistory, s.cpu_usage);

        if (s.ram_total > 0) {
            statsRoot.ramUsage = Math.round((s.ram_used / s.ram_total) * 100);
            statsRoot.ramHistory = statsRoot.pushHistory(statsRoot.ramHistory, statsRoot.ramUsage);
        }

        statsRoot.gpuPresent = s.gpu_present === true;
        if (statsRoot.gpuPresent) {
            statsRoot.gpuUsage = s.gpu_usage;
            statsRoot.gpuHistory = statsRoot.pushHistory(statsRoot.gpuHistory, s.gpu_usage);
        }
    }

    Socket {
        id: statsSock
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/run/user/1000") + "/anna.sock"
        parser: SplitParser {
            onRead: (line) => {
                try {
                    statsRoot.applyStats(JSON.parse(line));
                } catch (e) {
                    // ligne partielle / malformée — on ignore
                }
            }
        }
        onConnectedChanged: {
            if (connected)
                write('{"cmd":"hwstats_watch"}\n');
        }
    }

    // Le daemon peut ne pas être joignable au moment du verrouillage (ou être
    // redémarré pendant) : on retente tant que la surface est visible.
    Timer {
        interval: 2000
        running: statsRoot.visible
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!statsSock.connected)
            statsSock.connected = true
    }

    onVisibleChanged: {
        if (!visible)
            statsSock.connected = false;
    }

    component Stat: ColumnLayout {
        id: stat

        required property string label
        required property int value
        required property color seriesColor
        required property list<int> history

        spacing: 4

        RowLayout {
            spacing: 8

            Text {
                text: stat.label
                color: Theme.textDim
                font.family: "JetBrains Mono"
                font.pixelSize: 11
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
                text: stat.value + "%"
                color: stat.seriesColor
                font.family: "JetBrains Mono"
                font.pixelSize: 11
            }
        }

        MiniGraph {
            Layout.preferredWidth: 120
            Layout.preferredHeight: 28
            values: stat.history
            lineColor: stat.seriesColor
        }
    }

    Stat {
        label: "CPU"
        value: statsRoot.cpuUsage
        seriesColor: Theme.accentColor
        history: statsRoot.cpuHistory
    }

    Stat {
        label: "RAM"
        value: statsRoot.ramUsage
        seriesColor: Theme.colorRam
        history: statsRoot.ramHistory
    }

    Stat {
        visible: statsRoot.gpuPresent
        label: "GPU"
        value: statsRoot.gpuUsage
        seriesColor: Theme.colorGpu
        history: statsRoot.gpuHistory
    }
}
