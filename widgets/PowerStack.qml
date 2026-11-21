pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "../services"

// L'alimentation, au-dessus de son bouton dans la barre du bas : une
// colonne d'icônes qui sort de la barre (BarStack) — verrouiller, mettre en
// veille, quitter, redémarrer, éteindre, de bas en haut. Redémarrer et
// éteindre demandent un second clic dans les trois secondes : le premier
// arme le bouton (en rouge) et la question s'écrit au-dessus.
BarStack {
    id: root

    // Avant de verrouiller ou de dormir : la barre se vide (champ, volets).
    signal leaving()

    readonly property var items: ({
        lock: { leave: true, command: ["loginctl", "lock-session"] },
        suspend: { leave: true, command: ["systemctl", "suspend"] },
        logout: { command: ["hyprctl", "dispatch", "hl.dsp.exit()"] },
        reboot: { confirm: "power.rebootConfirm", command: ["systemctl", "reboot"] },
        off: { confirm: "power.offConfirm", command: ["systemctl", "poweroff"] }
    })

    actions: [
        { name: "lock", glyph: "lock.svg" },
        { name: "suspend", glyph: "suspend.svg" },
        { name: "logout", glyph: "logout.svg" },
        { name: "reboot", glyph: "reboot.svg" },
        { name: "off", glyph: "power.svg" }
    ]

    message: root.armed !== "" ? I18n.tr(root.items[root.armed].confirm) : ""
    messageColor: Theme.colorDanger

    Timer {
        running: root.armed !== ""
        interval: 3000
        onTriggered: root.armed = ""
    }
    // Refermée, plus rien n'attend.
    onShownChanged: if (!root.shown) root.armed = ""

    onTriggered: (name) => {
        var item = root.items[name];
        if (item.confirm && root.armed !== name) {
            root.armed = name;
            return;
        }
        root.armed = "";
        if (item.leave)
            root.leaving();
        Quickshell.execDetached(item.command);
    }
}
