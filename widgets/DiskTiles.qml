pragma ComponentBehavior: Bound
import QtQuick
import "../services"

// Les disques en treemap : un bloc par machine, découpé en ses disques, le
// même dans l'Explorer (toutes les machines, leur nom au-dessus) et dans la
// flotte (une machine). La surface d'un disque suit la racine carrée de sa
// capacité, jamais moins de `floor` fois celle du plus gros de la rangée :
// le plus gros reste nettement le plus gros, une clé USB garde une case
// lisible. Les blocs se partagent la largeur d'après leurs disques. Chaque case se remplit de
// gauche à droite autant qu'il est plein, d'un aplat (rouge à 90 %).
//
//   ● GARY
//   ╭────────────────────────┬──────────────╮
//   │ MICRON 3400   ⌂A   43% │ WD RED       │
//   │▓▓▓▓▓▓▓▓▓▓▌             │▓▓▓▓▓▓▓▓▓▓▓▌  │
//   │ 412 / 954 Go           ├──────────────┤
//   │                        │ SANDISK    ⏏ │
//   ╰────────────────────────┴──────────────╯
//
// En haut à gauche l'icône de son type (NVMe, SSD, HDD, USB) et son nom,
// précédés d'une pastille s'il faut le surveiller
// (orange) ou si SMART le juge défaillant (rouge, et la case cerclée de
// rouge) ; en bas l'occupé sur le total, et au survol le pourcentage, sa
// température et son usure ; le pourcentage en grand quand la case est
// assez haute. En haut à droite, un bouton par dossier personnel qu'il porte
// (une maison et l'initiale, openedHome ; celui où l'on est, à l'accent), et
// l'éjection d'un disque amovible de cette machine (ou Ctrl+E). Un clic
// l'ouvre (opened). Celui où l'on est (current) est cerclé d'accent ; ceux
// dont la machine se monte (connecting) respirent.
//
// Les machines se rangent côte à côte tant que chaque disque y garde
// `minCellWidth` ; sinon elles passent à la rangée suivante. Une machine qui
// ne tient pas seule sur la largeur a un bloc plus haut, où ses disques
// s'empilent.
//
// `disks` : la forme de Disks.fromDrives, ceux d'une même machine à la suite.
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

    // La hauteur d'un bloc, sans l'intitulé de sa machine.
    property int blockHeight: 40
    property int minCellWidth: 96
    // Le poids minimal d'un disque, rapporté au plus gros de sa rangée.
    property real floor: 0.35
    // Entre deux blocs (deux machines), et entre deux disques d'un bloc :
    // un trait fin, le bloc reste d'un seul tenant.
    property int blockGap: 8
    property int cellGap: 2

    signal opened(var disk)
    // Le bouton d'un dossier personnel : son chemin sur la machine du disque.
    signal openedHome(var disk, string path)

    readonly property int headerH: root.showHost ? 16 : 0
    readonly property string currentKey: root.current >= 0 && root.current < (root.disks || []).length
                                         ? root.keyOf(root.disks[root.current]) : ""

    implicitHeight: root.plan.height

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

    // L'icône de son type : une barrette M.2, un circuit, un disque dur, une
    // prise USB.
    function iconOf(kind) {
        return kind === "NVMe" ? "../assets/icons/disk-nvme.svg"
             : kind === "SSD" ? "../assets/icons/disk-ssd.svg"
             : kind === "USB" ? "../assets/icons/disk-usb.svg"
             : "../assets/icons/disk.svg";
    }

    // ── La mise en page ──────────────────────────────────────────

    // Les disques par machine, dans l'ordre où ils arrivent.
    readonly property var groups: {
        var out = [], at = {};
        (root.disks || []).forEach(d => {
            if (at[d.machine] === undefined) {
                at[d.machine] = out.length;
                out.push({ machine: d.machine, label: d.hostLabel, disks: [] });
            }
            out[at[d.machine]].disks.push(d);
        });
        return out;
    }

    // Des poids ramenés à des parts (de somme 1), aucune sous `min` : celles
    // qui y tombent y sont fixées, les autres se partagent le reste.
    function shares(vals, min) {
        var n = vals.length;
        if (n === 0)
            return [];
        min = Math.min(min, 1 / n);
        var fixed = vals.map(() => false);
        var out = vals.map(() => 0);
        for (var pass = 0; pass < n; pass++) {
            var free = 0, nFixed = 0;
            for (var i = 0; i < n; i++) {
                if (fixed[i])
                    nFixed++;
                else
                    free += vals[i];
            }
            var rest = 1 - nFixed * min;
            var changed = false;
            for (var j = 0; j < n; j++) {
                if (fixed[j]) {
                    out[j] = min;
                    continue;
                }
                out[j] = free > 0 ? vals[j] / free * rest : rest / (n - nFixed);
                if (out[j] < min) {
                    fixed[j] = true;
                    changed = true;
                }
            }
            if (!changed)
                break;
        }
        return out;
    }

    // Le treemap « squarifié » (Bruls et al.) : les parts, des plus grandes
    // aux plus petites, rangées en colonnes ou en lignes le long du côté
    // court, tant que la pire proportion de la rangée s'améliore. Rend un
    // rectangle par part, dans l'ordre des parts.
    function squarify(sh, x, y, w, h) {
        var area = w * h;
        var items = sh.map((s, i) => ({ i: i, a: s * area })).sort((p, q) => q.a - p.a);
        var rects = sh.map(() => ({ x: x, y: y, w: 0, h: 0 }));
        var worst = (row, side) => {
            var s = 0, mx = 0, mn = Infinity;
            row.forEach(r => {
                s += r.a;
                mx = Math.max(mx, r.a);
                mn = Math.min(mn, r.a);
            });
            if (s <= 0 || mn <= 0)
                return Infinity;
            return Math.max(side * side * mx / (s * s), s * s / (side * side * mn));
        };
        var place = row => {
            var s = row.reduce((t, r) => t + r.a, 0);
            if (w >= h) {
                var cw = h > 0 ? s / h : 0;
                var cy = y;
                row.forEach(r => {
                    var rh = cw > 0 ? r.a / cw : 0;
                    rects[r.i] = { x: x, y: cy, w: cw, h: rh };
                    cy += rh;
                });
                x += cw;
                w -= cw;
            } else {
                var rh2 = w > 0 ? s / w : 0;
                var cx = x;
                row.forEach(r => {
                    var rw = rh2 > 0 ? r.a / rh2 : 0;
                    rects[r.i] = { x: cx, y: y, w: rw, h: rh2 };
                    cx += rw;
                });
                y += rh2;
                h -= rh2;
            }
        };
        var row = [];
        var k = 0;
        while (k < items.length) {
            var side = Math.min(w, h);
            if (row.length === 0 || worst(row.concat([items[k]]), side) <= worst(row, side)) {
                row.push(items[k]);
                k++;
            } else {
                place(row);
                row = [];
            }
        }
        if (row.length > 0)
            place(row);
        return rects;
    }

    // Le poids brut d'un disque : la racine carrée de sa capacité.
    function weight(d) {
        return Math.sqrt(Math.max(1, d.size));
    }

    // Où va chaque bloc (l'intitulé de sa machine) et chaque disque :
    //   { blocks: [{ machine, label, x, y, w }], cells: { clé: { x, y, w, h } }, height }
    readonly property var plan: {
        var W = root.width, G = root.groups;
        if (!(W > 0) || !isFinite(W) || G.length === 0)
            return { blocks: [], cells: {}, height: 0 };
        var g = root.cellGap, B = root.blockGap;
        // La largeur que demandent les disques d'une machine.
        var need = m => m.disks.length * root.minCellWidth + (m.disks.length - 1) * g;
        var rowsOf = [], cur = [], used = 0;
        G.forEach(m => {
            var n = need(m);
            if (cur.length > 0 && used + B + n > W) {
                rowsOf.push(cur);
                cur = [];
                used = 0;
            }
            used += (cur.length > 0 ? B : 0) + n;
            cur.push(m);
        });
        if (cur.length > 0)
            rowsOf.push(cur);
        var blocks = [], cells = {};
        var y = 0;
        rowsOf.forEach((slice, r) => {
            // Le plancher, d'après le plus gros disque de la rangée.
            var top = 0;
            slice.forEach(m => m.disks.forEach(d => top = Math.max(top, root.weight(d))));
            var wt = d => Math.max(root.weight(d), root.floor * top);
            var widths = root.shares(slice.map(m => m.disks.reduce((t, d) => t + wt(d), 0)), 0);
            var avail = W - B * (slice.length - 1);
            // Seule et trop large : plus haute, d'autant de fois.
            var bh = slice.length === 1 ? root.blockHeight * Math.max(1, Math.ceil(need(slice[0]) / W))
                                        : root.blockHeight;
            var x = 0;
            slice.forEach((m, i) => {
                var bw = avail * widths[i];
                blocks.push({ machine: m.machine, label: m.label, x: x, y: y, w: bw });
                // Le treemap dans le bloc élargi d'un demi-écart, chaque case
                // rentrée d'autant : un trait entre deux cases, aucun au bord.
                // Seuls les coins de case qui sont ceux du bloc s'arrondissent.
                var L = x - g / 2, T = y + root.headerH - g / 2, R = L + bw + g, Bt = T + bh + g;
                var rects = root.squarify(root.shares(m.disks.map(wt), 0), L, T, bw + g, bh + g);
                m.disks.forEach((d, j) => {
                    var c = rects[j];
                    var left = c.x <= L + 0.5, right = c.x + c.w >= R - 0.5;
                    var top = c.y <= T + 0.5, bottom = c.y + c.h >= Bt - 0.5;
                    cells[root.keyOf(d)] = {
                        x: c.x + g / 2, y: c.y + g / 2,
                        w: Math.max(0, c.w - g), h: Math.max(0, c.h - g),
                        tl: left && top, tr: right && top, bl: left && bottom, br: right && bottom
                    };
                });
                x += bw + B;
            });
            y += root.headerH + bh + B;
        });
        return { blocks: blocks, cells: cells, height: Math.max(0, y - B) };
    }

    // ── Les cases ────────────────────────────────────────────────
    // Elles suivent les disques par leur clé (machine/nom) : un relevé met à
    // jour celles qui restent sans les recréer (cf. KeyedModel). Le survol et
    // le focus tiennent, la barre glisse vers son nouveau niveau.
    property var byKey: ({})
    readonly property var blank: ({ machine: "", host: "", hostLabel: "", name: "", label: "", model: "",
                                    kind: "", used: 0, size: 0, mounted: false, main: "",
                                    removable: false, smart: null, homes: [] })
    readonly property var nowhere: ({ x: 0, y: 0, w: 0, h: 0, tl: true, tr: true, bl: true, br: true })
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

    // L'intitulé de chaque machine, au-dessus de son bloc (showHost) : sa
    // pastille respire pendant son montage.
    Repeater {
        model: root.showHost ? root.plan.blocks : []

        Row {
            id: head
            required property var modelData
            readonly property bool joining: root.connecting !== "" && root.connecting === head.modelData.machine
            x: head.modelData.x + 2
            y: head.modelData.y
            height: root.headerH
            spacing: 6
            Rectangle {
                id: headDot
                anchors.verticalCenter: parent.verticalCenter
                width: 6
                height: 6
                radius: 3
                color: Theme.accentColor
                SequentialAnimation on opacity {
                    running: head.joining
                    loops: Animation.Infinite
                    onStopped: headDot.opacity = 1
                    NumberAnimation { to: 0.25; duration: 500; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 1; duration: 500; easing.type: Easing.InOutSine }
                }
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, head.modelData.w - 16)
                text: head.modelData.label.toUpperCase()
                elide: Text.ElideRight
                font.family: "Inter"
                font.pixelSize: 10
                font.weight: Font.DemiBold
                font.letterSpacing: 1.4
                color: Theme.textSecondary
            }
        }
    }

    Repeater {
        model: tiles

        Rectangle {
            id: disk
            required property string key
            readonly property var modelData: root.byKey[disk.key] || root.blank
            readonly property var cell: root.plan.cells[disk.key] || root.nowhere

            readonly property real pct: disk.modelData.mounted && disk.modelData.size > 0
                                        ? Math.min(1, disk.modelData.used / disk.modelData.size) : 0
            readonly property var smart: disk.modelData.smart
            readonly property string health: Disks.health(disk.smart)
            readonly property bool failing: disk.health === "failing"
            readonly property color tone: disk.pct >= 0.9 || disk.failing ? Theme.colorDanger : Theme.accentColor
            readonly property bool here: root.currentKey === disk.key
            readonly property bool clickable: disk.modelData.main !== ""
            readonly property bool ejectable: Disks.canEject(disk.modelData)
            readonly property bool joining: root.connecting !== "" && root.connecting === disk.modelData.machine
            // Sur toute la case, boutons compris.
            readonly property bool hovered: tileHover.hovered
            readonly property var homes: disk.modelData.homes || []
            // Le chemin du dossier personnel survolé, "" : aucun.
            property string homeHint: ""
            // Assez haute pour deux lignes, et pour le pourcentage en grand.
            readonly property bool roomy: disk.height >= 34
            readonly property bool tall: disk.height >= 48 && disk.width >= 130
            // La marge du haut et du bas : resserrée dans une case basse.
            readonly property int pad: disk.height < 40 ? 4 : 6
            // Ce qu'occupent les boutons du coin droit.
            readonly property real corner: (disk.homes.length > 0 ? homesRow.width + 2 : 0)
                                         + (disk.ejectable ? 18 + 2 : 0)

            // Sa santé, en mots : température, usure, SMART.
            readonly property var details: (disk.smart && disk.smart.temp >= 0 ? [disk.smart.temp + " °C"] : [])
                .concat(disk.smart && disk.smart.wear >= 0 ? [I18n.tr("fleet.wear", { n: disk.smart.wear })] : [])
                .concat(disk.failing ? [I18n.tr("fleet.smartFailing")] : [])
            readonly property string bottomText: disk.homeHint !== "" ? disk.homeHint
                : disk.hovered && disk.modelData.mounted
                  ? [I18n.tr("common.percent", { n: Math.round(disk.pct * 100) })].concat(disk.details).join(" · ")
                : disk.hovered && disk.details.length > 0 ? disk.details.join(" · ")
                : root.usage(disk.modelData)

            // Glisse vers sa place quand la mise en page change, pas à sa
            // naissance.
            property bool placed: false
            Component.onCompleted: Qt.callLater(() => disk.placed = true)
            x: disk.cell.x
            y: disk.cell.y
            width: disk.cell.w
            height: disk.cell.h
            Behavior on x { enabled: disk.placed; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            Behavior on y { enabled: disk.placed; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            Behavior on width { enabled: disk.placed; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            Behavior on height { enabled: disk.placed; NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

            // Arrondie aux seuls coins du bloc.
            readonly property real round: Theme.radiusSmall + 2
            radius: 0
            topLeftRadius: disk.cell.tl ? disk.round : 0
            topRightRadius: disk.cell.tr ? disk.round : 0
            bottomLeftRadius: disk.cell.bl ? disk.round : 0
            bottomRightRadius: disk.cell.br ? disk.round : 0
            color: Qt.alpha(Theme.textPrimary, disk.hovered && disk.clickable || disk.activeFocus ? 0.09 : 0.05)
            border.width: disk.here ? 1.5 : disk.failing ? 1 : 0
            border.color: disk.here ? Theme.accentColor : Qt.alpha(Theme.colorDanger, 0.7)
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

            // L'occupation : un aplat de gauche à droite, fermé d'un trait
            // net. La case entière, de ses coins, coupée à son niveau : le
            // bord droit du remplissage reste droit.
            Item {
                id: fill
                property real level: disk.pct
                Behavior on level { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
                width: disk.width * fill.level
                height: disk.height
                clip: true
                visible: fill.level > 0.004

                Rectangle {
                    width: disk.width
                    height: disk.height
                    topLeftRadius: disk.topLeftRadius
                    topRightRadius: disk.topRightRadius
                    bottomLeftRadius: disk.bottomLeftRadius
                    bottomRightRadius: disk.bottomRightRadius
                    color: Qt.alpha(disk.tone, disk.here ? 0.42 : disk.hovered ? 0.36 : 0.28)
                    Behavior on color { ColorAnimation { duration: 140 } }
                }
                Rectangle {
                    visible: fill.level < 0.996
                    anchors.right: parent.right
                    width: 1.5
                    height: parent.height
                    color: Qt.alpha(disk.tone, 0.9)
                }
            }

            // Son nom, en petites capitales, précédé de sa pastille de santé.
            Row {
                id: title
                visible: disk.width >= 40
                // Placé par le calcul, pas par des ancres qui changeraient
                // selon la hauteur (elles ne se défont pas toujours).
                x: 8
                y: disk.roomy ? disk.pad : Math.round((disk.height - title.height) / 2)
                spacing: 5
                Rectangle {
                    visible: disk.health === "failing" || disk.health === "watch"
                    anchors.verticalCenter: parent.verticalCenter
                    width: 6
                    height: 6
                    radius: 3
                    color: disk.failing ? Theme.colorDanger : Theme.colorWarning
                }
                // Son type, en icône.
                NixIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    iconSize: 11
                    source: root.iconOf(disk.modelData.kind)
                    color: Theme.textSecondary
                }
                Text {
                    width: Math.max(0, Math.min(implicitWidth, disk.width - 16 - disk.corner
                                    - (disk.roomy ? 0 : bottom.width + 8) - 16
                                    - (disk.health === "failing" || disk.health === "watch" ? 11 : 0)))
                    text: disk.modelData.label.toUpperCase()
                    elide: Text.ElideRight
                    font.family: "Inter"
                    font.pixelSize: 9
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.1
                    color: Theme.textPrimary
                }
            }

            // L'occupé sur le total (au survol, le détail), en bas ; à droite
            // du nom quand la case n'a qu'une ligne.
            Text {
                id: bottom
                visible: disk.width >= 60
                x: disk.roomy ? 8 : disk.width - 8 - disk.corner - bottom.width
                y: disk.roomy ? disk.height - disk.pad - bottom.height : Math.round((disk.height - bottom.height) / 2)
                width: disk.roomy ? Math.min(implicitWidth, disk.width - 16 - (disk.tall ? big.width + 6 : 0))
                                  : Math.min(implicitWidth, (disk.width - 16 - disk.corner) / 2)
                text: disk.bottomText
                elide: Text.ElideRight
                font.family: "Inter"
                font.pixelSize: 10
                font.features: { "tnum": 1 }
                color: disk.hovered && disk.failing ? Theme.colorDanger : Theme.textSecondary
            }

            // Le pourcentage en grand, en bas à droite d'une case haute.
            Row {
                id: big
                visible: disk.tall && disk.modelData.mounted
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.rightMargin: 8
                anchors.bottomMargin: 2
                Text {
                    id: bigNumber
                    text: Math.round(disk.pct * 100)
                    font.family: "Inter Display"
                    font.pixelSize: 26
                    font.weight: Font.Light
                    font.letterSpacing: -1
                    font.features: { "tnum": 1 }
                    color: Theme.textPrimary
                }
                Text {
                    anchors.baseline: bigNumber.baseline
                    leftPadding: 2
                    text: "%"
                    font.family: "Inter Display"
                    font.pixelSize: 11
                    color: disk.tone
                }
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
            // de l'utilisateur, discrètes, nettes au survol ; celui où l'on
            // est, à l'accent. Au survol, la ligne du bas dit son chemin.
            Row {
                id: homesRow
                visible: disk.homes.length > 0 && disk.width >= 80
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: disk.roomy ? 3 : (disk.height - 18) / 2
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
                visible: disk.ejectable && disk.width >= 40
                readonly property bool busy: Disks.ejecting === disk.modelData.name
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: disk.roomy ? 3 : (disk.height - 18) / 2
                anchors.rightMargin: 3
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
                    opacity: ejectBtn.busy ? 1 : ejectMa.containsMouse ? 1 : disk.hovered ? 0.8 : 0.55
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

            FocusRing { radius: disk.round + gap }
        }
    }
}
