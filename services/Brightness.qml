pragma Singleton
import QtQuick
import Quickshell.Io

// Le rétroéclairage de l'écran du portable (brightnessctl). Le noyau émet un
// événement udev à chaque écriture de la luminosité, quelle qu'en soit la
// source (touches du clavier, anna, ce shell) : on l'écoute et on relit la
// valeur, sans sondage.
QtObject {
    id: root

    // 0–1 ; -1 : pas de rétroéclairage.
    property real level: -1
    readonly property bool present: root.level >= 0

    property Process readProc: Process {
        command: ["brightnessctl", "-m", "-c", "backlight"]
        running: true
        stdout: StdioCollector {
            // « intel_backlight,backlight,96000,100%,96000 »
            onStreamFinished: {
                var f = text.trim().split("\n")[0].split(",");
                root.level = f.length >= 5 && parseInt(f[4]) > 0
                             ? parseInt(f[2]) / parseInt(f[4]) : -1;
            }
        }
        onRunningChanged: {
            if (!running && root._reread) {
                root._reread = false;
                running = true;
            }
        }
    }

    // Un événement reçu pendant une lecture en relance une autre à la fin :
    // la dernière valeur n'est jamais perdue.
    property bool _reread: false

    function refresh() {
        if (root.readProc.running)
            root._reread = true;
        else
            root.readProc.running = true;
    }

    property Process monitor: Process {
        command: ["udevadm", "monitor", "--kernel", "--subsystem-match=backlight"]
        running: true
        stdout: SplitParser {
            onRead: (line) => { if (line.indexOf(" change ") >= 0) root.refresh(); }
        }
        // S'il s'arrête (udevadm absent, tué), on retente plus tard.
        onRunningChanged: if (!running) root.restart.start()
    }

    property Timer restart: Timer {
        interval: 5000
        onTriggered: root.monitor.running = true
    }

    // Même principe que pour la lecture : un réglage demandé pendant qu'un
    // autre s'applique attend son tour, seul le dernier compte.
    property real _pending: -1

    property Process writeProc: Process {
        onRunningChanged: {
            if (!running && root._pending >= 0)
                root._write();
        }
    }

    function _write() {
        root.writeProc.command = ["brightnessctl", "-q", "-c", "backlight", "set",
                             Math.round(root._pending * 100) + "%"];
        root._pending = -1;
        root.writeProc.running = true;
    }

    // Jamais tout à fait noir : 5 % au minimum. Le niveau affiché suit tout de
    // suite ; l'événement udev le confirme ensuite.
    function set(v) {
        if (!root.present)
            return;
        v = Math.max(0.05, Math.min(1, v));
        root.level = v;
        root._pending = v;
        if (!root.writeProc.running)
            root._write();
    }
}
