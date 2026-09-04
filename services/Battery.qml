pragma Singleton
import QtQuick
import Quickshell.Io

// Battery state, polled from sysfs. A singleton because both the LeftBar's
// bottom indicator and the QuickControls popup read it — one poll, two views.
QtObject {
    id: battery

    property bool   present: false
    property int    percent: 0
    property string status:  ""

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
