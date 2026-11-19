pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// L'onglet « Agenda » : les agendas et les tâches du compte Google, lus par
// anna (services/Agenda.qml), sur une vue heure par heure, en trois modes :
// un jour, trois jours (aujourd'hui et les deux suivants), ou la semaine.
//
//   ╭ 19 – 21 nov. 2026                 ‹ › Aujourd'hui ╮
//   │ [Jour | 3 jours | Semaine]                         │
//   │        jeu. 19      ven. 20      sam. 21         │
//   │ Journée ☐ Acheter…  ▇ Congés ▇                    │  journées entières
//   │  09:00 ┃ Point   ┃                                │  et tâches du jour
//   │  10:00 ┃         ┃            ┃ Dentiste ┃        │
//
// Chaque rendez-vous à sa place et à sa durée ; les journées entières et les
// tâches datées (Google ne leur garde pas d'heure) dans la bande du haut, une
// case à cocher devant chaque tâche : la cocher la coche chez Google. Pas de
// liste de tâches à part : seules celles d'un jour affiché se voient.
//
// Tout s'y crée et s'y modifie (AgendaEditor, écrit chez Google par
// Agenda) : un clic dans le vide de la grille crée un événement à cette
// heure, dans la bande une tâche ce jour-là ; un clic sur un rendez-vous ou
// une tâche l'ouvre. Glisser un rendez-vous le déplace au quart d'heure et
// d'un jour à l'autre, tirer son bord bas change sa fin ; glisser une tâche
// ou une journée entière la change de jour.
//
// Sans compte connecté, l'onglet propose de le connecter (GoogleAccount).
Item {
    id: root

    // "day", "three" ou "week".
    property string view: "three"
    // Combien de jours la vue montre.
    readonly property int count: root.view === "day" ? 1 : root.view === "three" ? 3 : 7
    // Le jour de référence : le premier jour montré, sauf en vue Semaine où
    // c'est un jour de la semaine montrée.
    property date anchor: root.midnight(new Date())
    // Aujourd'hui, à minuit : relu toutes les minutes (passer minuit).
    property date today: root.midnight(new Date())
    // L'heure, pour le trait rouge de la vue Semaine.
    property date now: new Date()

    // Le premier jour montré : le début de la semaine (au jour de la langue),
    // ou le jour de référence lui-même.
    readonly property date rangeStart: {
        var a = root.anchor;
        if (root.view !== "week")
            return a;
        var back = (a.getDay() - I18n.locale.firstDayOfWeek % 7 + 7) % 7;
        return new Date(a.getFullYear(), a.getMonth(), a.getDate() - back);
    }

    function midnight(d) {
        return new Date(d.getFullYear(), d.getMonth(), d.getDate());
    }

    function addDays(d, n) {
        return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
    }

    function sameDay(a, b) {
        return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
    }

    function capitalize(s) {
        return s.charAt(0).toUpperCase() + s.slice(1);
    }

    // Les jours montrés tiennent toujours dans les six semaines lues pour le
    // mois de leur premier jour (Agenda.load).
    function load() {
        if (!Google.connected)
            return;
        Agenda.load(root.rangeStart.getFullYear(), root.rangeStart.getMonth());
    }

    // ‹ › : autant de jours que la vue en montre.
    function step(delta) {
        root.anchor = root.addDays(root.anchor, root.count * delta);
    }

    function goToday() {
        root.today = root.midnight(new Date());
        root.anchor = root.today;
    }

    onAnchorChanged: root.load()
    onViewChanged: root.load()
    Component.onCompleted: root.load()

    Connections {
        target: Google
        function onConnectedChanged() { root.load(); }
    }

    // Les événements changent ailleurs (le téléphone) : relus toutes les
    // cinq minutes tant que l'onglet est affiché.
    Timer {
        interval: 5 * 60 * 1000
        repeat: true
        running: root.visible && Google.connected
        onTriggered: root.load()
    }
    Timer {
        interval: 60000
        repeat: true
        running: root.visible
        onTriggered: {
            root.now = new Date();
            root.today = root.midnight(root.now);
        }
    }

    // « 14:00 » d'une Date, à la mode de la langue.
    function time(d) {
        return I18n.locale.toString(d, "HH:mm");
    }

    // Une journée entière, ou un rendez-vous d'au moins vingt-quatre heures :
    // dans la bande du haut.
    function isBand(e) {
        return e.allDay || e.endDate - e.startDate >= 24 * 3600 * 1000;
    }

    // `d` décalé de `days` jours et `mins` minutes, à l'heure locale (un
    // changement d'heure ne décale pas l'horaire).
    function shift(d, days, mins) {
        var out = new Date(d.getTime());
        out.setDate(out.getDate() + days);
        out.setMinutes(out.getMinutes() + mins);
        return out;
    }

    // Une tâche (de Google Tasks), pas un rendez-vous.
    function isTask(item) {
        return item.due !== undefined;
    }

    // La case d'une tâche : cliquée, elle la coche (ou la décoche).
    component TaskCheck: Rectangle {
        id: check
        required property var task
        width: 10
        height: 10
        radius: 2
        color: check.task.done ? Theme.glow(0) : "transparent"
        border.color: Theme.glow(0)
        border.width: 1.5

        Text {
            anchors.centerIn: parent
            visible: check.task.done
            text: "✓"
            font.pixelSize: 8
            font.weight: Font.Bold
            color: Theme.bgDeep
        }

        MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            cursorShape: Qt.PointingHandCursor
            onClicked: Agenda.setDone(check.task, !check.task.done)
        }
    }

    // ── Sans compte ──────────────────────────────────────────────
    Column {
        anchors.centerIn: parent
        width: Math.min(460, root.width - 40)
        spacing: 14
        visible: Google.known && !Google.connected

        Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: I18n.tr("agenda.connectTitle")
            font.family: "Inter"
            font.pixelSize: 14
            font.weight: Font.DemiBold
            color: Theme.textPrimary
            wrapMode: Text.Wrap
        }

        GoogleAccount {
            width: parent.width
        }
    }

    // ── L'en-tête ────────────────────────────────────────────────
    RowLayout {
        id: header
        visible: Google.connected
        width: parent.width
        height: 30
        spacing: 4

        Text {
            Layout.fillWidth: true
            // « jeudi 19 novembre 2026 », ou « 19 – 21 nov. 2026 ».
            text: {
                var a = root.rangeStart;
                if (root.count === 1)
                    return root.capitalize(I18n.locale.toString(a, "dddd d MMMM yyyy"));
                var b = root.addDays(a, root.count - 1);
                var from = a.getMonth() === b.getMonth() ? I18n.locale.toString(a, "d")
                         : a.getFullYear() === b.getFullYear() ? I18n.locale.toString(a, "d MMM")
                         : I18n.locale.toString(a, "d MMM yyyy");
                return from + " – " + I18n.locale.toString(b, "d MMM yyyy");
            }
            elide: Text.ElideRight
            font.family: "Inter"
            font.pixelSize: 14
            font.weight: Font.DemiBold
            color: Theme.textPrimary
        }

        GlassButton { implicitWidth: 26; implicitHeight: 26; fontSize: 13; text: "‹"; onClicked: root.step(-1) }
        GlassButton { implicitWidth: 26; implicitHeight: 26; fontSize: 13; text: "›"; onClicked: root.step(1) }
        GlassButton { implicitHeight: 26; fontSize: 11; text: I18n.tr("agenda.today"); onClicked: root.goToday() }
    }

    // Les modes, puis ce qui se passe : la lecture, ou ce qui a échoué.
    RowLayout {
        id: modes
        visible: Google.connected
        anchors.top: header.bottom
        anchors.topMargin: 6
        width: parent.width
        height: 30
        spacing: 10

        Rectangle {
            implicitWidth: modeRow.implicitWidth + 6
            implicitHeight: 30
            radius: Theme.radiusSmall + 2
            color: Theme.bgElevated

            Row {
                id: modeRow
                anchors.centerIn: parent
                spacing: 2

                Repeater {
                    model: [{ v: "day", k: "agenda.day" }, { v: "three", k: "agenda.threeDays" },
                            { v: "week", k: "agenda.week" }]

                    Rectangle {
                        id: mode
                        required property var modelData
                        readonly property bool active: root.view === mode.modelData.v
                        width: modeText.implicitWidth + 22
                        height: 24
                        radius: Theme.radiusSmall
                        color: mode.active ? Theme.bgDeep : modeMa.containsMouse ? Theme.hoverOverlay : "transparent"

                        Text {
                            id: modeText
                            anchors.centerIn: parent
                            text: I18n.tr(mode.modelData.k)
                            font.family: "Inter"
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            color: mode.active ? Theme.textPrimary : Theme.textSecondary
                        }
                        MouseArea {
                            id: modeMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.view = mode.modelData.v
                        }
                    }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            text: Agenda.error !== "" ? Agenda.error
                : Agenda.tasksError !== "" ? Agenda.tasksError
                : Agenda.loading ? I18n.tr("common.loading")
                : ""
            font.family: "Inter"
            font.pixelSize: 10
            color: Agenda.error !== "" || Agenda.tasksError !== "" ? Theme.colorDanger : Theme.textDim
            elide: Text.ElideRight
        }
    }

    // ── Les jours, heure par heure ───────────────────────────────
    Item {
        id: weekPane
        visible: Google.connected
        anchors.top: modes.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        readonly property int gutter: 44
        readonly property real colW: (weekPane.width - weekPane.gutter) / root.count
        readonly property int hourH: 48
        readonly property var days: {
            var out = [];
            for (var i = 0; i < root.count; i++)
                out.push(root.addDays(root.rangeStart, i));
            return out;
        }
        // Par jour, les journées entières, puis les rendez-vous placés :
        // ceux qui se chevauchent se partagent la largeur, comme des colonnes.
        readonly property var bands: weekPane.days.map(d => Agenda.tasksOn(d).concat(Agenda.on(d).filter(e => root.isBand(e))))
        readonly property var placed: weekPane.days.map(d => weekPane.layout(d, Agenda.on(d).filter(e => !root.isBand(e))))
        // Quatre rangs au plus : les heures gardent la place.
        readonly property int bandRows: Math.min(4, Math.max(1, Math.max.apply(null, weekPane.bands.map(b => b.length))))

        // [{ e, top, height, col, cols }] d'un jour, en heures depuis minuit.
        function layout(day, events) {
            var from = +day, to = +root.addDays(day, 1);
            var items = events.map(e => {
                var s = Math.max(+e.startDate, from), t = Math.min(+e.endDate, to);
                return { e: e, s: s, t: Math.max(t, s + 30 * 60000), col: 0, cols: 1 };
            }).sort((a, b) => a.s - b.s || b.t - a.t);
            // Des grappes de rendez-vous qui se touchent ; dans chacune, la
            // première colonne libre.
            var cluster = [], ends = [], clusterEnd = 0;
            function close() {
                cluster.forEach(i => i.cols = ends.length);
                cluster = [];
                ends = [];
            }
            items.forEach(i => {
                if (i.s >= clusterEnd)
                    close();
                var c = ends.findIndex(end => end <= i.s);
                if (c < 0) {
                    c = ends.length;
                    ends.push(0);
                }
                ends[c] = i.t;
                i.col = c;
                cluster.push(i);
                clusterEnd = Math.max(clusterEnd, i.t);
            });
            close();
            return items.map(i => ({
                e: i.e, col: i.col, cols: i.cols,
                top: (i.s - from) / 3600000, height: (i.t - i.s) / 3600000
            }));
        }

        // Les jours : le nom, et le numéro dans une pastille aujourd'hui.
        Row {
            id: dayHeads
            x: weekPane.gutter
            height: 40

            Repeater {
                model: weekPane.days

                Item {
                    id: head
                    required property date modelData
                    readonly property bool isToday: root.sameDay(head.modelData, root.today)
                    width: weekPane.colW
                    height: dayHeads.height

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: I18n.locale.toString(head.modelData, "ddd")
                        font.family: "Inter"
                        font.pixelSize: 10
                        color: head.isToday ? Theme.glow(0) : Theme.textDim
                    }
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 2
                        width: 24
                        height: 24
                        radius: 12
                        color: head.isToday ? Theme.glow(0) : "transparent"

                        Text {
                            anchors.centerIn: parent
                            text: head.modelData.getDate()
                            font.family: "Inter"
                            font.pixelSize: 13
                            font.weight: head.isToday ? Font.DemiBold : Font.Normal
                            color: head.isToday ? Theme.bgDeep : Theme.textPrimary
                        }
                    }
                }
            }
        }

        // La bande des journées entières.
        Item {
            id: bandRow
            anchors.top: dayHeads.bottom
            anchors.topMargin: 4
            width: parent.width
            height: weekPane.bandRows * 16 + 4

            Text {
                width: weekPane.gutter - 6
                y: 2
                horizontalAlignment: Text.AlignRight
                text: I18n.tr("agenda.allDay")
                font.family: "Inter"
                font.pixelSize: 9
                color: Theme.textDim
                elide: Text.ElideRight
            }

            // Un clic dans le vide d'un jour : une nouvelle tâche ce jour-là.
            Repeater {
                model: root.count

                MouseArea {
                    required property int index
                    x: weekPane.gutter + index * weekPane.colW
                    width: weekPane.colW
                    height: bandRow.height
                    cursorShape: Qt.PointingHandCursor
                    onClicked: editor.openNewTask(weekPane.days[index])
                }
            }

            Repeater {
                model: root.count

                Column {
                    id: bandCol
                    required property int index
                    readonly property var items: weekPane.bands[bandCol.index]
                    // Trop pour la bande : le dernier rang dit combien manquent.
                    readonly property int shown: bandCol.items.length > weekPane.bandRows ? weekPane.bandRows - 1
                                                                                         : bandCol.items.length
                    x: weekPane.gutter + bandCol.index * weekPane.colW + 2
                    y: 2
                    width: weekPane.colW - 4
                    spacing: 2

                    Repeater {
                        model: bandCol.items.slice(0, bandCol.shown)

                        Rectangle {
                            id: band
                            required property var modelData
                            readonly property bool task: root.isTask(band.modelData)
                            // Pendant un glisser : son décalage.
                            property real dx: 0
                            width: bandCol.width
                            height: 14
                            radius: 3
                            z: band.dx !== 0 ? 10 : 0
                            transform: Translate { x: band.dx }
                            // Une tâche : sa case et son titre, sans aplat.
                            color: band.task ? "transparent" : Qt.alpha(Agenda.color(band.modelData.calendar), 0.85)

                            // Un clic : la modifier. Glisser : la changer de
                            // jour. Sous la case, qui garde ses clics.
                            MouseArea {
                                id: bandMa
                                property real px: 0
                                property bool moved: false
                                anchors.fill: parent
                                preventStealing: true
                                cursorShape: bandMa.moved ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                                onPressed: (mouse) => {
                                    bandMa.px = bandMa.mapToItem(null, mouse.x, mouse.y).x;
                                    bandMa.moved = false;
                                }
                                onPositionChanged: (mouse) => {
                                    band.dx = bandMa.mapToItem(null, mouse.x, mouse.y).x - bandMa.px;
                                    if (Math.abs(band.dx) > 6)
                                        bandMa.moved = true;
                                }
                                onReleased: {
                                    var days = Math.round(band.dx / weekPane.colW);
                                    band.dx = 0;
                                    var item = band.modelData;
                                    if (!bandMa.moved) {
                                        if (band.task)
                                            editor.openTask(item);
                                        else
                                            editor.openEvent(item);
                                        return;
                                    }
                                    bandMa.moved = false;
                                    if (days === 0)
                                        return;
                                    if (band.task)
                                        Agenda.updateTask(item, { due: Agenda.dayKey(root.shift(Agenda._parse(item.due), days, 0)) });
                                    else
                                        Agenda.updateEvent(item, { start: root.shift(item.startDate, days, 0),
                                                                   end: root.shift(item.endDate, days, 0),
                                                                   allDay: item.allDay });
                                }
                            }

                            TaskCheck {
                                visible: band.task
                                task: band.modelData
                                x: 1
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                                x: band.task ? 15 : 4
                                width: parent.width - x - 2
                                anchors.verticalCenter: parent.verticalCenter
                                text: band.modelData.title || I18n.tr("agenda.untitled")
                                font.family: "Inter"
                                font.pixelSize: 10
                                font.weight: band.task ? Font.Normal : Font.Medium
                                font.strikeout: band.task && band.modelData.done
                                color: !band.task ? "white"
                                     : band.modelData.done ? Theme.textInactive : Theme.textPrimary
                                elide: Text.ElideRight
                            }
                        }
                    }

                    Text {
                        visible: bandCol.shown < bandCol.items.length
                        x: 3
                        height: 14
                        verticalAlignment: Text.AlignVCenter
                        text: I18n.tr("agenda.more", { n: bandCol.items.length - bandCol.shown })
                        font.family: "Inter"
                        font.pixelSize: 10
                        font.weight: Font.Medium
                        color: Theme.textSecondary
                    }
                }
            }

            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.dividerColor }
        }

        // Les heures, qui défilent ; à l'ouverture, un peu avant maintenant.
        Flickable {
            id: hours
            anchors.top: bandRow.bottom
            anchors.bottom: parent.bottom
            width: parent.width
            clip: true
            contentHeight: 24 * weekPane.hourH + 8
            boundsBehavior: Flickable.StopAtBounds

            function scrollToNow() {
                var h = Math.max(0, root.now.getHours() - 2);
                hours.contentY = Math.min(h * weekPane.hourH, Math.max(0, hours.contentHeight - hours.height));
            }
            Component.onCompleted: hours.scrollToNow()
            Connections {
                target: weekPane
                function onVisibleChanged() { if (weekPane.visible) hours.scrollToNow(); }
            }

            Item {
                y: 6
                width: hours.width
                height: 24 * weekPane.hourH

                // Une ligne et son heure par heure.
                Repeater {
                    model: 24

                    Item {
                        id: hourLine
                        required property int index
                        y: hourLine.index * weekPane.hourH
                        width: parent.width

                        Text {
                            visible: hourLine.index > 0
                            width: weekPane.gutter - 8
                            y: -height / 2
                            horizontalAlignment: Text.AlignRight
                            text: I18n.locale.toString(new Date(2000, 0, 1, hourLine.index), "HH:mm")
                            font.family: "Inter"
                            font.pixelSize: 9
                            font.features: { "tnum": 1 }
                            color: Theme.textDim
                        }
                        Rectangle {
                            x: weekPane.gutter
                            width: parent.width - weekPane.gutter
                            height: 1
                            color: Theme.dividerColor
                        }
                    }
                }

                // Les colonnes, et leurs rendez-vous.
                Repeater {
                    model: root.count

                    Item {
                        id: col
                        required property int index
                        readonly property date day: weekPane.days[col.index]
                        x: weekPane.gutter + col.index * weekPane.colW
                        width: weekPane.colW
                        height: parent.height

                        Rectangle { width: 1; height: parent.height; color: Theme.dividerColor }
                        Rectangle {
                            anchors.fill: parent
                            visible: root.sameDay(col.day, root.today)
                            color: Qt.alpha(Theme.glow(0), 0.04)
                        }

                        // Un clic dans le vide : un nouvel événement d'une
                        // heure, au quart d'heure cliqué.
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: (mouse) => {
                                var q = Math.floor(mouse.y / weekPane.hourH * 4);
                                var start = new Date(col.day.getFullYear(), col.day.getMonth(), col.day.getDate(),
                                                     Math.floor(q / 4), (q % 4) * 15);
                                editor.openNewEvent(start, new Date(start.getTime() + 3600000), false);
                            }
                        }

                        Repeater {
                            model: weekPane.placed[col.index]

                            Rectangle {
                                id: block
                                required property var modelData
                                readonly property var e: block.modelData.e
                                readonly property real slot: (col.width - 4) / block.modelData.cols
                                readonly property color tint: Agenda.color(block.e.calendar)

                                // Pendant un glisser : son décalage, et ce que
                                // gagne sa fin quand on l'étire.
                                property real dx: 0
                                property real dy: 0
                                property real dh: 0

                                x: 2 + block.modelData.col * block.slot
                                y: block.modelData.top * weekPane.hourH + 1
                                width: block.slot - 2
                                height: Math.max(14, block.modelData.height * weekPane.hourH - 2 + block.dh)
                                z: block.dx !== 0 || block.dy !== 0 || block.dh !== 0 ? 10 : 0
                                opacity: block.dx !== 0 || block.dy !== 0 ? 0.85 : 1
                                transform: Translate { x: block.dx; y: block.dy }
                                radius: 4
                                clip: true
                                color: Qt.alpha(block.tint, 0.85)
                                border.color: Qt.alpha(Theme.bgDeep, 0.6)
                                border.width: block.modelData.cols > 1 ? 1 : 0

                                Column {
                                    x: 4
                                    y: 2
                                    width: parent.width - 6

                                    Text {
                                        width: parent.width
                                        text: block.e.title || I18n.tr("agenda.untitled")
                                        font.family: "Inter"
                                        font.pixelSize: 10
                                        font.weight: Font.Medium
                                        color: "white"
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        width: parent.width
                                        visible: block.height >= 28
                                        text: {
                                            var s = root.time(block.e.startDate);
                                            return +block.e.endDate === +block.e.startDate ? s
                                                 : s + " – " + root.time(block.e.endDate);
                                        }
                                        font.family: "Inter"
                                        font.pixelSize: 9
                                        font.features: { "tnum": 1 }
                                        color: Qt.alpha("white", 0.85)
                                        elide: Text.ElideRight
                                    }
                                    Text {
                                        width: parent.width
                                        visible: block.height >= 42 && block.e.location !== ""
                                        text: block.e.location.replace(/\n/g, ", ")
                                        font.family: "Inter"
                                        font.pixelSize: 9
                                        color: Qt.alpha("white", 0.75)
                                        elide: Text.ElideRight
                                    }
                                }

                                // Un clic : le modifier. Glisser : le déplacer,
                                // au quart d'heure et d'un jour à l'autre.
                                MouseArea {
                                    id: moveMa
                                    property real px: 0
                                    property real py: 0
                                    property bool moved: false
                                    anchors.fill: parent
                                    anchors.bottomMargin: 6
                                    preventStealing: true
                                    cursorShape: moveMa.moved ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                                    onPressed: (mouse) => {
                                        var p = moveMa.mapToItem(null, mouse.x, mouse.y);
                                        moveMa.px = p.x;
                                        moveMa.py = p.y;
                                        moveMa.moved = false;
                                    }
                                    onPositionChanged: (mouse) => {
                                        var p = moveMa.mapToItem(null, mouse.x, mouse.y);
                                        block.dx = p.x - moveMa.px;
                                        block.dy = p.y - moveMa.py;
                                        if (Math.abs(block.dx) + Math.abs(block.dy) > 6)
                                            moveMa.moved = true;
                                    }
                                    onReleased: {
                                        var mins = Math.round(block.dy / weekPane.hourH * 4) * 15;
                                        var days = Math.round(block.dx / weekPane.colW);
                                        block.dx = 0;
                                        block.dy = 0;
                                        if (!moveMa.moved) {
                                            editor.openEvent(block.e);
                                            return;
                                        }
                                        moveMa.moved = false;
                                        if (mins === 0 && days === 0)
                                            return;
                                        Agenda.updateEvent(block.e, {
                                            start: root.shift(block.e.startDate, days, mins),
                                            end: root.shift(block.e.endDate, days, mins),
                                            allDay: false
                                        });
                                    }
                                }

                                // Le bas : l'étirer change sa fin.
                                MouseArea {
                                    id: resizeMa
                                    property real py: 0
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.bottom: parent.bottom
                                    height: 6
                                    preventStealing: true
                                    cursorShape: Qt.SizeVerCursor
                                    onPressed: (mouse) => resizeMa.py = resizeMa.mapToItem(null, mouse.x, mouse.y).y
                                    onPositionChanged: (mouse) => block.dh = resizeMa.mapToItem(null, mouse.x, mouse.y).y - resizeMa.py
                                    onReleased: {
                                        var mins = Math.round(block.dh / weekPane.hourH * 4) * 15;
                                        block.dh = 0;
                                        if (mins === 0)
                                            return;
                                        var end = root.shift(block.e.endDate, 0, mins);
                                        // Un quart d'heure au moins.
                                        if (end - block.e.startDate < 15 * 60000)
                                            end = new Date(block.e.startDate.getTime() + 15 * 60000);
                                        Agenda.updateEvent(block.e, { end: end, allDay: false });
                                    }
                                }
                            }
                        }

                        // Maintenant : un trait rouge en travers du jour.
                        Rectangle {
                            visible: root.sameDay(col.day, root.today)
                            y: (root.now.getHours() + root.now.getMinutes() / 60) * weekPane.hourH
                            width: parent.width
                            height: 2
                            color: Theme.colorDanger

                            Rectangle {
                                x: -4
                                anchors.verticalCenter: parent.verticalCenter
                                width: 8
                                height: 8
                                radius: 4
                                color: Theme.colorDanger
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Créer, modifier ──────────────────────────────────────────
    AgendaEditor {
        id: editor
        anchors.fill: parent
        z: 20
    }
}
