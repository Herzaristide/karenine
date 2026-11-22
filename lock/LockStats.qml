pragma ComponentBehavior: Bound
import QtQuick
import Quickshell.Io
import "../services"

// Les stats de la machine pour le lockscreen, sans visuel : la surface les
// affiche en relevés dans le pied de sa carte.
//
// Même flux que widgets/HardwareStats (un snapshot JSON par seconde sur le
// socket du daemon anna, `hwstats_watch`), mais toujours cette machine-ci :
// ni choix d'un serveur, ni actions d'alimentation, rien à manipuler session
// fermée.
Item {
    id: stats

    // Abonné tant que c'est vrai.
    property bool active: false

    readonly property int historySize: 40

    property int cpu: -1
    property string cpuTemp: ""
    property list<int> cpuHistory: []

    property int ram: -1
    property real ramUsed: 0
    property real ramTotal: 0
    property list<int> ramHistory: []

    property bool gpuPresent: false
    property int gpu: -1
    property string gpuTemp: ""
    property list<int> gpuHistory: []

    function pushHistory(arr: list<int>, value: real): list<int> {
        const out = arr.slice(arr.length >= stats.historySize ? 1 : 0);
        out.push(Math.max(0, Math.min(100, Math.round(value))));
        return out;
    }

    function formatGiB(bytes: real): string {
        const gib = bytes / (1024 * 1024 * 1024);
        return gib.toLocaleString(I18n.locale, "f", 1);
    }

    function apply(s: var): void {
        stats.cpu = s.cpu_usage;
        stats.cpuHistory = stats.pushHistory(stats.cpuHistory, s.cpu_usage);
        stats.cpuTemp = s.cpu_temp > 0 ? s.cpu_temp + "°" : "";

        stats.ramUsed = s.ram_used;
        stats.ramTotal = s.ram_total;
        if (s.ram_total > 0) {
            stats.ram = Math.round(s.ram_used / s.ram_total * 100);
            stats.ramHistory = stats.pushHistory(stats.ramHistory, stats.ram);
        }

        stats.gpuPresent = s.gpu_present === true;
        stats.gpuTemp = s.gpu_temp > 0 ? s.gpu_temp + "°" : "";
        if (stats.gpuPresent) {
            stats.gpu = s.gpu_usage;
            stats.gpuHistory = stats.pushHistory(stats.gpuHistory, s.gpu_usage);
        } else {
            stats.gpu = -1;
        }
    }

    Socket {
        id: sock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    stats.apply(JSON.parse(line));
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
    // redémarré pendant) : on retente tant que c'est actif.
    Timer {
        interval: 2000
        running: stats.active
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!sock.connected)
            sock.connected = true
    }

    onActiveChanged: {
        if (!active)
            sock.connected = false;
    }
}
