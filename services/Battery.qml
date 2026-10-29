pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.UPower

// Battery state, from UPower (a singleton: one source for every reader).
// UPower pushes each change over D-Bus: no polling, no process.
// On battery, it warns once at `lowAt` and once more at `criticalAt`, through
// the desktop notification server (services/Notifications.qml, via
// notify-send); plugging the charger in closes those warnings and re-arms them.
// shell.qml creates it at startup, so it watches even with nothing open.
QtObject {
    id: battery

    // The aggregate of the machine's batteries, as UPower exposes it.
    readonly property var device: UPower.displayDevice

    readonly property bool   present: battery.device !== null && battery.device.ready
                                      && battery.device.isLaptopBattery && battery.device.isPresent
    // UPower gives 0–1 (an older Quickshell gave 0–100).
    readonly property int    percent: {
        if (!battery.present)
            return 0;
        var p = battery.device.percentage;
        return Math.round(p <= 1 ? p * 100 : p);
    }
    // The sysfs names the readers expect: "Charging", "Discharging", "Full",
    // "Not charging".
    readonly property string status: {
        if (!battery.present)
            return "";
        switch (battery.device.state) {
            case UPowerDeviceState.Charging:         return "Charging";
            case UPowerDeviceState.Discharging:      return "Discharging";
            case UPowerDeviceState.Empty:            return "Discharging";
            case UPowerDeviceState.FullyCharged:     return "Full";
            case UPowerDeviceState.PendingCharge:    return "Not charging";
            case UPowerDeviceState.PendingDischarge: return "Not charging";
            default:                                 return "Unknown";
        }
    }

    // Le temps avant la batterie vide (en décharge) ou pleine (en charge), en
    // secondes ; 0 tant qu'on ne peut pas l'estimer. UPower le donne ; à
    // défaut (il lui faut quelques minutes de mesures), on le calcule de
    // l'énergie restante et de la puissance tirée (Wh et W).
    readonly property int secondsLeft: {
        if (!battery.present)
            return 0;
        var d = battery.device;
        if (battery.status === "Discharging") {
            if (d.timeToEmpty > 0)
                return d.timeToEmpty;
            return d.changeRate > 0 ? Math.round(d.energy / d.changeRate * 3600) : 0;
        }
        if (battery.status === "Charging") {
            if (d.timeToFull > 0)
                return d.timeToFull;
            return d.changeRate > 0
                ? Math.round((d.energyCapacity - d.energy) / d.changeRate * 3600) : 0;
        }
        return 0;
    }

    onPercentChanged: battery.check()
    onStatusChanged: battery.check()

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

    Component.onCompleted: battery.check()
}
