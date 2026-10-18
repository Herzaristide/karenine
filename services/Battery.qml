pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Battery state, polled from sysfs (a singleton: one poll for every reader).
// On battery, it warns once at `lowAt` and once more at `criticalAt`, through
// the desktop notification server (services/Notifications.qml, via
// notify-send); plugging the charger in closes those warnings and re-arms them.
// shell.qml creates it at startup, so it watches even with nothing open.
QtObject {
    id: battery

    property bool   present: false
    property int    percent: 0
    property string status:  ""

    readonly property int lowAt: 15
    readonly property int criticalAt: 5
    // The last warning given since the charger was unplugged: 0 none,
    // 1 low, 2 critical.
    property int warned: 0

    function check() {
        if (!battery.present)
            return;
        if (battery.status !== "Discharging") {
            if (battery.warned > 0)
                Notifications.closeFrom(I18n.tr("battery.app"));
            battery.warned = 0;
            return;
        }
        if (battery.percent <= battery.criticalAt && battery.warned < 2) {
            battery.warned = 2;
            battery.warn("critical", "battery-empty", I18n.tr("battery.critical"),
                         I18n.tr("battery.criticalBody", { n: battery.percent }));
        } else if (battery.percent <= battery.lowAt && battery.warned < 1) {
            battery.warned = 1;
            battery.warn("normal", "battery-caution", I18n.tr("battery.low"),
                         I18n.tr("battery.lowBody", { n: battery.percent }));
        }
    }

    function warn(urgency, icon, summary, body) {
        Quickshell.execDetached(["notify-send", "-a", I18n.tr("battery.app"), "-u", urgency,
                                 "-i", icon, summary, body]);
    }

    // "+" charging, "-" discharging, "=" full, "~" idle, "?" unknown.
    readonly property string symbol: {
        switch (status) {
            case "Charging":    return "+";
            case "Discharging": return "-";
            case "Full":        return "=";
            case "Not charging": return "~";
            default:            return "?";
        }
    }

    property Process poller: Process {
        id: batteryProc
        command: [
            "sh", "-c",
            "bat=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -n1); " +
            "if [ -n \"$bat\" ]; then " +
            "  cap=$(cat \"$bat/capacity\" 2>/dev/null); " +
            "  st=$(cat \"$bat/status\" 2>/dev/null); " +
            "  echo \"$cap|$st\"; " +
            "fi"
        ]
        stdout: StdioCollector { id: batteryOut }
        onRunningChanged: {
            if (running) return;
            const line = batteryOut.text.trim();
            if (line.length === 0) {
                battery.present = false;
                return;
            }
            const parts = line.split('|');
            battery.percent = parseInt(parts[0]);
            battery.status  = parts.length > 1 ? parts[1] : "";
            battery.present = !isNaN(battery.percent);
            battery.check();
        }
    }

    property Timer refresh: Timer {
        interval: 3000
        repeat:   true
        running:  true
        onTriggered: if (!batteryProc.running) batteryProc.running = true;
    }

    Component.onCompleted: batteryProc.running = true
}
