pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import "../services"

// Les disques, en cases remplies d'un liquide autant qu'elles sont pleines :
// le même affichage dans l'Explorer (ceux de toutes les machines) et dans la
// flotte (ceux d'une machine). Ils se partagent la largeur à parts égales ;
// trop nombreux pour tenir sur une rangée (une case de moins de
// `minTileWidth`), ils passent sur plusieurs, équilibrées.
//
//   ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
//   │ zola · Micron│ │● gary · WD   │ │ gary · SanDi⏏│
//   │▓▓▓▓▓▓▓▓▓▓▓▓▓▓│ │              │ │▓▓▓▓▓▓▓▓▓▓▓▓▓▓│
//   │  412 / 954 Go│ │   1,2 / 4 To │ │    28 / 64 Go│
//   └──────────────┘ └──────────────┘ └──────────────┘
//
// En haut sa machine (showHost) et son nom, précédés d'une pastille s'il
// faut le surveiller (orange) ou si SMART le juge défaillant (rouge, et la
// case cerclée de rouge) ; en bas l'occupé sur le total, et au survol le
// pourcentage, sa température et son usure. Presque plein (90 %), le liquide
// passe au rouge. Un clic l'ouvre (opened) ; un disque amovible de cette
// machine s'éjecte de son bouton (ou Ctrl+E). Celui où l'on est (current)
// est cerclé d'accent ; celui dont la machine se monte (connecting) respire.
//
// Le disque qui porte des dossiers personnels (le disque système, ou
// celui de /home) a, en haut à droite, un bouton par utilisateur : une
// maison et son initiale, qui mène à son dossier (openedHome) ; celui où
// l'on est, à l'accent.
//
//   ┌────────────────────────┐
//   │  gary · Micron   ⌂A ⌂M │
//   │▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│
//   │     412 / 954 Go       │
//   └────────────────────────┘
//
// `disks` : la forme de Disks.fromDrives.
Item {
    id: root

    property var disks: []
    property bool showHost: false
    // L'index du disque où l'on est, -1 : aucun.
    property int current: -1
    // Le dossier montré, tel que le voit la machine du disque courant :
    // allume le bouton du dossier personnel où l'on est.
    property string currentPath: ""
    // La machine en cours de montage (son nom), "" : aucune.
    property string connecting: ""
    // Les vagues roulent : à couper quand on ne les voit pas.
    property bool running: root.visible

    property int tileHeight: 46
    property int minTileWidth: 110
    property int gap: 6

    signal opened(var disk)
    // Le bouton d'un dossier personnel : son chemin sur la machine du disque.
    signal openedHome(var disk, string path)


    // Le nombre de cases, celui du modèle : pendant une mise à jour, il
    // suit les insertions et retraits un à un, comme les index des délégués.
    readonly property int count: tiles.count
    readonly property int columns: root.count === 0 ? 1
        : Math.max(1, Math.min(root.count, Math.floor((root.width + root.gap) / (root.minTileWidth + root.gap))))
    readonly property int rows: root.count === 0 ? 0 : Math.ceil(root.count / root.columns)
    // Les rangées remplies également : 5 disques sur 4 colonnes, 3 + 2.
    readonly property int perRow: root.rows === 0 ? 1 : Math.ceil(root.count / root.rows)

    implicitHeight: root.rows * root.tileHeight + Math.max(0, root.rows - 1) * root.gap

    // « 300 / 954 Go » : l'occupé dans l'unité du total, entier (une
    // décimale sous 10) ; « 2 To » pour un disque sans système de fichiers.
    function usage(d) {
        var units = ["unit.bytes", "unit.kb", "unit.mb", "unit.gb", "unit.tb"];
        var i = 0, div = 1;
        while (d.size / div >= 1000 && i < units.length - 1) {
            div *= 1000;
            i++;
        }
        var fmt = v => i === 0 ? String(Math.round(v)) : v.toLocaleString(I18n.locale, "f", d.size / div < 10 ? 1 : 0);
        var total = I18n.tr(units[i], { n: fmt(d.size / div) });
        return d.mounted ? fmt(d.used / div) + " / " + total : total;
    }

    // Les cases suivent les disques par leur clé (machine/nom) : un relevé
    // met à jour celles qui restent sans les recréer (cf. KeyedModel). Le
    // survol et le focus tiennent, le liquide glisse vers son nouveau niveau.
    property var byKey: ({})
    readonly property var blank: ({ machine: "", host: "", hostLabel: "", name: "", label: "", model: "",
                                    kind: "", used: 0, size: 0, mounted: false, main: "",
                                    removable: false, smart: null, homes: [] })
    function keyOf(d) {
        return d.machine + "/" + d.name;
    }
    function sync() {
        var map = {};
        var keys = (root.disks || []).map(d => {
            var k = root.keyOf(d);
            map[k] = d;
            return k;
        });
        tiles.sync(keys, () => root.byKey = map);
    }
    onDisksChanged: root.sync()
    Component.onCompleted: root.sync()
    KeyedModel { id: tiles }

    function escapeHtml(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    Repeater {
        model: tiles

        Rectangle {
            id: disk
            required property string key
            required property int index
            readonly property var modelData: root.byKey[disk.key] || root.blank

            readonly property int row: Math.floor(disk.index / root.perRow)
            readonly property int inRow: Math.max(1, Math.min(root.perRow, root.count - disk.row * root.perRow))
            readonly property int col: disk.index - disk.row * root.perRow

            readonly property real pct: disk.modelData.mounted && disk.modelData.size > 0
                                        ? Math.min(1, disk.modelData.used / disk.modelData.size) : 0
            readonly property var smart: disk.modelData.smart
            readonly property string health: Disks.health(disk.smart)
            readonly property bool failing: disk.health === "failing"
            readonly property color tone: disk.pct >= 0.9 || disk.failing ? Theme.colorDanger : Theme.accentColor
            readonly property bool here: root.current === disk.index
            readonly property bool clickable: disk.modelData.main !== ""
            readonly property bool ejectable: Disks.canEject(disk.modelData)
            readonly property bool joining: root.connecting !== "" && root.connecting === disk.modelData.machine
            // Sur toute la case, boutons compris.
            readonly property bool hovered: tileHover.hovered
            readonly property var homes: disk.modelData.homes || []
            // Le chemin du dossier personnel survolé, "" : aucun.
            property string homeHint: ""
            // Ce qu'occupent les boutons du coin droit : le nom, centré, s'en
            // tient écarté des deux côtés.
            readonly property real corner: (disk.homes.length > 0 ? homesRow.width + 3 : 0)
                                         + (disk.ejectable ? 18 + 3 : 0)

            // Sa santé, en mots : température, usure, SMART.
            readonly property var details: (disk.smart && disk.smart.temp >= 0 ? [disk.smart.temp + " °C"] : [])
                .concat(disk.smart && disk.smart.wear >= 0 ? [I18n.tr("fleet.wear", { n: disk.smart.wear })] : [])
                .concat(disk.failing ? [I18n.tr("fleet.smartFailing")] : [])

            x: disk.col * (disk.width + root.gap)
            y: disk.row * (root.tileHeight + root.gap)
            width: (root.width - root.gap * (disk.inRow - 1)) / disk.inRow
            height: root.tileHeight
            radius: Theme.radiusSmall
            color: Qt.alpha(Theme.textPrimary, disk.hovered && disk.clickable || disk.activeFocus ? 0.09 : 0.05)
            border.width: disk.here ? 1.5 : 1
            border.color: disk.here ? Theme.accentColor
                        : disk.failing ? Qt.alpha(Theme.colorDanger, 0.7)
                        : Theme.dividerColor
            Behavior on color { ColorAnimation { duration: 140 } }

            Accessible.role: disk.clickable ? Accessible.Button : Accessible.StaticText
            Accessible.name: (root.showHost ? disk.modelData.hostLabel + " · " : "") + disk.modelData.model
                             + " · " + [disk.modelData.kind, disk.modelData.main].filter(x => x).join(" ")
                             + " · " + root.usage(disk.modelData)
                             + (disk.details.length > 0 ? " · " + disk.details.join(" · ") : "")

            // Au clavier aussi : Tab, puis Entrée ou Espace ; Ctrl+E éjecte.
            activeFocusOnTab: disk.clickable
            Keys.onPressed: (event) => {
                if ((event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                        && disk.clickable) {
                    root.opened(disk.modelData);
                    event.accepted = true;
                } else if (event.key === Qt.Key_E && (event.modifiers & Qt.ControlModifier) && disk.ejectable) {
                    Disks.eject(disk.modelData);
                    event.accepted = true;
                }
            }

            // Le liquide : deux vagues à la surface, qui roulent en sens
            // contraires, la plus claire derrière ; le niveau monte avec un
            // rebond (un ressort), la houle se creuse au survol. Peint opaque
            // dans une couche, puis découpé aux coins de la case et rendu
            // translucide d'un coup (sans recouvrement plus foncé entre la
            // vague et le corps).
            Item {
                id: liquid
                anchors.fill: parent
                visible: false
                layer.enabled: true

                property real level: disk.pct
                Behavior on level { SpringAnimation { spring: 2.2; damping: 0.16; epsilon: 0.002 } }
                // La surface, depuis le haut.
                readonly property real surface: liquid.height * (1 - liquid.level)
                property real amp: disk.hovered ? 5.5 : 3.5
                Behavior on amp { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                readonly property real period: 60
                readonly property bool wet: liquid.level > 0.004

                LiquidWave {
                    tone: Qt.lighter(disk.tone, 1.35)
                    duration: 3400
                    reversed: true
                    a: liquid.amp
                    p: liquid.period
                    y: liquid.surface - liquid.amp - 1
                    width: liquid.width + liquid.period
                    visible: liquid.wet
                    running: root.running
                }
                Rectangle {
                    visible: liquid.wet
                    y: liquid.surface + liquid.amp
                    width: liquid.width
                    height: Math.max(0, liquid.height - liquid.surface - liquid.amp)
                    color: disk.tone
                }
                LiquidWave {
                    tone: disk.tone
                    duration: 2200
                    a: liquid.amp
                    p: liquid.period
                    y: liquid.surface - liquid.amp
                    width: liquid.width + liquid.period
                    visible: liquid.wet
                    running: root.running
                }
            }
            Rectangle {
                id: diskShape
                anchors.fill: parent
                radius: disk.radius
                visible: false
                layer.enabled: true
            }
            MultiEffect {
                anchors.fill: parent
                source: liquid
                maskEnabled: true
                maskSource: diskShape
                maskThresholdMin: 0.5
                maskSpreadAtMin: 1.0
                opacity: disk.here ? 0.7 : 0.5
                Behavior on opacity { NumberAnimation { duration: 200 } }
            }

            Text {
                anchors.top: parent.top
                anchors.topMargin: 5
                anchors.horizontalCenter: parent.horizontalCenter
                // Centré, sans passer sous les boutons du coin.
                width: parent.width - 2 * Math.max(4, disk.corner + 2)
                horizontalAlignment: Text.AlignHCenter
                // « ● gary · Micron 3400 » : la pastille, sa machine en gras,
                // puis le disque.
                textFormat: Text.StyledText
                text: (disk.health === "failing" || disk.health === "watch"
                       ? "<font color='" + (disk.failing ? Theme.colorDanger : Theme.colorWarning) + "'>●</font> " : "")
                      + (root.showHost ? "<b>" + root.escapeHtml(disk.modelData.hostLabel) + "</b> · " : "")
                      + root.escapeHtml(disk.modelData.label)
                elide: Text.ElideRight
                font.family: "Inter"
                font.pixelSize: 10
                font.weight: Font.Medium
                color: Theme.textPrimary
            }
            Text {
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 5
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width - 4
                horizontalAlignment: Text.AlignHCenter
                text: disk.homeHint !== "" ? disk.homeHint
                      : disk.hovered && disk.modelData.mounted
                      ? [I18n.tr("common.percent", { n: Math.round(disk.pct * 100) })].concat(disk.details).join(" · ")
                      : disk.hovered && disk.details.length > 0 ? disk.details.join(" · ")
                      : root.usage(disk.modelData)
                elide: Text.ElideRight
                font.family: "Inter"
                font.pixelSize: 9
                font.features: { "tnum": 1 }
                color: disk.hovered && disk.failing ? Theme.colorDanger : Theme.textPrimary
                opacity: 0.8
            }

            // Le montage de sa machine : la case respire.
            SequentialAnimation on opacity {
                running: disk.joining
                loops: Animation.Infinite
                onStopped: disk.opacity = 1
                NumberAnimation { to: 0.45; duration: 500; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1; duration: 500; easing.type: Easing.InOutSine }
            }

            HoverHandler { id: tileHover }

            MouseArea {
                id: diskMa
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: disk.clickable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (disk.clickable) root.opened(disk.modelData)
            }

            // Les dossiers personnels qu'il porte, en haut à droite (à gauche
            // du bouton d'éjection s'il y en a un) : une maison et l'initiale
            // de l'utilisateur, discrètes comme l'éjection, nettes au survol ;
            // celui où l'on est, à l'accent. Au survol, la ligne du bas dit
            // son chemin.
            Row {
                id: homesRow
                visible: disk.homes.length > 0
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: 3
                anchors.rightMargin: disk.ejectable ? 3 + 18 + 1 : 3
                spacing: 1

                Repeater {
                    model: disk.homes

                    Rectangle {
                        id: homeBtn
                        required property var modelData
                        readonly property bool inside: disk.here && root.currentPath !== ""
                            && (root.currentPath === homeBtn.modelData.path
                                || root.currentPath.indexOf(homeBtn.modelData.path + "/") === 0)
                        readonly property color ink: homeBtn.inside ? Theme.accentColor : Theme.textPrimary
                        width: homeRow.implicitWidth + 8
                        height: 18
                        radius: Theme.radiusSmall
                        color: Qt.alpha(Theme.textPrimary, homeMa.containsMouse ? 0.16 : 0)
                        Behavior on color { ColorAnimation { duration: 120 } }

                        Accessible.role: Accessible.Button
                        Accessible.name: homeBtn.modelData.path

                        activeFocusOnTab: true
                        Keys.onPressed: (event) => {
                            if (event.key === Qt.Key_Space || event.key === Qt.Key_Return
                                    || event.key === Qt.Key_Enter) {
                                root.openedHome(disk.modelData, homeBtn.modelData.path);
                                event.accepted = true;
                            }
                        }

                        Row {
                            id: homeRow
                            anchors.centerIn: parent
                            spacing: 2
                            opacity: homeBtn.inside || homeMa.containsMouse || homeBtn.activeFocus ? 1
                                   : disk.hovered ? 0.8 : 0.55
                            Behavior on opacity { NumberAnimation { duration: 120 } }
                            NixIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                iconSize: 11
                                source: "../assets/icons/home.svg"
                                color: homeBtn.ink
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: homeBtn.modelData.user.charAt(0).toUpperCase()
                                font.family: "Inter"
                                font.pixelSize: 10
                                font.weight: Font.DemiBold
                                color: homeBtn.ink
                            }
                        }
                        MouseArea {
                            id: homeMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onContainsMouseChanged: disk.homeHint = homeMa.containsMouse ? homeBtn.modelData.path
                                                  : disk.homeHint === homeBtn.modelData.path ? "" : disk.homeHint
                            onClicked: root.openedHome(disk.modelData, homeBtn.modelData.path)
                        }
                        FocusRing { radius: homeBtn.radius + gap }
                    }
                }
            }

            // Éjecter, en haut à droite d'un disque amovible : discret, net
            // au survol ; il respire le temps de l'éjection.
            Rectangle {
                id: ejectBtn
                visible: disk.ejectable
                readonly property bool busy: Disks.ejecting === disk.modelData.name
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 3
                width: 18
                height: 18
                radius: Theme.radiusSmall
                color: Qt.alpha(Theme.textPrimary, ejectMa.containsMouse ? 0.16 : 0)
                Behavior on color { ColorAnimation { duration: 120 } }

                Accessible.role: Accessible.Button
                Accessible.name: I18n.tr("explorer.eject", { name: disk.modelData.label })

                NixIcon {
                    anchors.centerIn: parent
                    iconSize: 11
                    source: "../assets/icons/eject.svg"
                    color: Theme.textPrimary
                    opacity: ejectBtn.busy ? 1 : ejectMa.containsMouse ? 1 : diskMa.containsMouse ? 0.8 : 0.55
                    Behavior on opacity { NumberAnimation { duration: 120 } }
                    SequentialAnimation on opacity {
                        running: ejectBtn.busy
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.3; duration: 450; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1; duration: 450; easing.type: Easing.InOutSine }
                    }
                }
                MouseArea {
                    id: ejectMa
                    anchors.fill: parent
                    hoverEnabled: true
                    enabled: !ejectBtn.busy
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Disks.eject(disk.modelData)
                }
            }

            FocusRing { radius: disk.radius + gap }
        }
    }

    // Une vague de liquide : sur la largeur de la case et une période `p`
    // de plus, d'amplitude `a`, qui glisse d'une période en boucle : la
    // reprise ne se voit pas. Pleine sous la crête.
    component LiquidWave: Shape {
        id: wave
        property color tone
        property real a: 1.5
        property real p: 40
        property int duration: 2400
        property bool reversed: false
        property bool running: true
        height: wave.a * 2 + 2
        preferredRendererType: Shape.CurveRenderer
        NumberAnimation on x {
            from: wave.reversed ? -wave.p : 0
            to: wave.reversed ? 0 : -wave.p
            duration: wave.duration
            loops: Animation.Infinite
            running: wave.running && wave.visible
        }
        ShapePath {
            fillColor: wave.tone
            strokeWidth: -1
            PathSvg {
                path: {
                    var a = wave.a, h = wave.p / 2;
                    // Avant la mise en page, la largeur (donc la période)
                    // est nulle : la boucle ne finirait pas.
                    // Une largeur infinie (une division par zéro) ne la
                    // finirait pas non plus.
                    if (!(h >= 1) || !(wave.width > 0) || !isFinite(wave.width) || wave.width > 100000)
                        return "";
                    var d = "M 0 " + a + " Q " + (h / 2) + " " + (-a) + " " + h + " " + a;
                    for (var x = 2 * h; x <= wave.width + h; x += h)
                        d += " T " + x + " " + a;
                    return d + " L " + (wave.width + h) + " " + wave.height
                         + " L 0 " + wave.height + " Z";
                }
            }
        }
    }
}
