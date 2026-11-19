import QtQuick
import QtQuick.Layouts
import "../services"

// Le volet « énergie » de la barre, sous la batterie : son niveau, ce
// qu'elle fait (sur secteur, pleine dans…, encore…), puis la luminosité de
// l'écran. L'optimisation de la consommation est laissée au système : pas
// de profil à choisir ici.
ColumnLayout {
    id: root

    spacing: 8

    // Une durée lisible : « 45 min », « 2 h », « 2 h 15 min ».
    function duration(s) {
        var m = Math.round(s / 60);
        var h = Math.floor(m / 60);
        m = m % 60;
        if (h === 0)
            return I18n.tr("time.minutes", { n: Math.max(1, m) });
        if (m === 0)
            return I18n.tr("time.hours", { n: h });
        return I18n.tr("time.hours", { n: h }) + " " + I18n.tr("time.minutes", { n: m });
    }

    readonly property string doing: {
        switch (Battery.status) {
        case "Charging":
            return Battery.secondsLeft > 0 ? I18n.tr("battery.untilFull", { time: root.duration(Battery.secondsLeft) })
                                           : I18n.tr("battery.charging");
        case "Discharging":
            return Battery.secondsLeft > 0 ? I18n.tr("battery.untilEmpty", { time: root.duration(Battery.secondsLeft) })
                                           : I18n.tr("battery.estimating");
        case "Full":
            return I18n.tr("battery.full");
        case "Not charging":
            return I18n.tr("battery.notCharging");
        default:
            return "";
        }
    }

    RowLayout {
        visible: Battery.present
        Layout.fillWidth: true
        Text {
            text: I18n.tr("battery.app")
            font.family: "Inter"
            font.pixelSize: 11
            font.weight: Font.DemiBold
            font.letterSpacing: 0.8
            font.capitalization: Font.AllUppercase
            color: Theme.textDim
        }
        Item { Layout.fillWidth: true }
        Text {
            text: root.doing
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.textSecondary
        }
    }

    PopSlider {
        visible: Battery.present
        Layout.fillWidth: true
        icon: "battery.svg"
        value: Battery.percent / 100
        fill: Battery.status === "Charging" || Battery.status === "Full" ? Theme.colorSuccess
            : Battery.percent <= Battery.lowAt ? Theme.colorDanger : Theme.textSecondary
        enabled: false
    }

    Text {
        visible: Brightness.present
        Layout.topMargin: Battery.present ? 6 : 0
        text: I18n.tr("settings.screen")
        font.family: "Inter"
        font.pixelSize: 11
        font.weight: Font.DemiBold
        font.letterSpacing: 0.8
        font.capitalization: Font.AllUppercase
        color: Theme.textDim
    }

    PopSlider {
        visible: Brightness.present
        Layout.fillWidth: true
        icon: "brightness.svg"
        value: Brightness.level
        fill: Theme.accentColor
        onMoved: (v) => Brightness.set(v)
    }
}
