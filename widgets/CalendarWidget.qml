pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// L'onglet « Agenda » : les agendas et les tâches du compte Google, lus par
// anna (services/Agenda.qml). Deux vues, comme un agenda en ligne :
//
//   Mois : la grille entière, six semaines, les rendez-vous dans les cases.
//   ╭ novembre 2026            ‹ › Aujourd'hui  [Mois|Semaine] ╮
//   │ lun.     mar.     mer.     jeu.     ven.     sam.   dim. │
//   ├────────┬────────┬────────┬────────┬────────┬──────┬──────┤
//   │ 26     │ 27     │ 28     │ 29     │ 30     │ 31   │  1   │
//   │▇Congés▇│• 14:00 │        │        │        │      │      │
//   │        │ Dentist│        │        │        │      │      │
//   ├────────┼────────┼ …                                      │
//
//   Semaine : sept colonnes, les heures en lignes, chaque rendez-vous à sa
//   place et à sa durée ; les journées entières dans une bande au-dessus.
//
// Les tâches datées s'y mêlent, à leur jour, une case à cocher devant (Google
// ne leur garde pas d'heure) ; à droite, un panneau repliable les liste
// toutes, datées ou non, par liste. Cocher, ici ou là, coche chez Google.
//
// Un clic sur un jour du mois ouvre sa semaine. Sans compte connecté,
// l'onglet propose de le connecter (GoogleAccount).
Item {
    id: root

    // "month" ou "week".
    property string view: "month"
    // Le panneau des tâches, déplié.
    property bool showTasks: true
    // Le jour de référence : son mois en vue Mois, sa semaine en vue Semaine.
    property date anchor: root.midnight(new Date())
    // Aujourd'hui, à minuit : relu toutes les minutes (passer minuit).
    property date today: root.midnight(new Date())
    // L'heure, pour le trait rouge de la vue Semaine.
    property date now: new Date()

    readonly property int year: root.anchor.getFullYear()
    readonly property int month: root.anchor.getMonth()
    readonly property date weekStart: {
        var a = root.anchor;
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

    // La semaine tient toujours dans les six semaines lues pour le mois de
    // son premier jour (Agenda.load).
    function load() {
        if (!Google.connected)
            return;
        if (root.view === "week")
            Agenda.load(root.weekStart.getFullYear(), root.weekStart.getMonth());
        else
            Agenda.load(root.year, root.month);
    }

    function step(delta) {
        if (root.view === "week")
            root.anchor = root.addDays(root.anchor, 7 * delta);
        else
            root.anchor = new Date(root.year, root.month + delta, 1);
    }

    function goToday() {
        root.today = root.midnight(new Date());
        root.anchor = root.today;
    }

    function openWeek(day) {
        root.anchor = day;
        root.view = "week";
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
    // dans la bande du haut en vue Semaine, en aplat en vue Mois.
    function isBand(e) {
        return e.allDay || e.endDate - e.startDate >= 24 * 3600 * 1000;
    }

    // Une tâche (de Google Tasks), pas un rendez-vous.
    function isTask(item) {
        return item.due !== undefined;
    }

    // Ce qu'un jour montre : ses tâches, puis ses rendez-vous.
    function itemsOn(day) {
        return Agenda.tasksOn(day).concat(Agenda.on(day));
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
            // « novembre 2026 », ou « 2 – 8 nov. 2026 » pour une semaine.
            text: {
                if (root.view === "month")
                    return root.capitalize(I18n.locale.toString(new Date(root.year, root.month, 1), "MMMM yyyy"));
                var a = root.weekStart, b = root.addDays(a, 6);
                var from = a.getMonth() === b.getMonth() ? I18n.locale.toString(a, "d")
                         : a.getFullYear() === b.getFullYear() ? I18n.locale.toString(a, "d MMM")
                         : I18n.locale.toString(a, "d MMM yyyy");
                return from + " – " + I18n.locale.toString(b, "d MMM yyyy");
            }
            font.family: "Inter"
            font.pixelSize: 14
            font.weight: Font.DemiBold
            color: Theme.textPrimary
        }

        // Ce qui se passe : la lecture, ou ce qui a échoué.
        Text {
            Layout.fillWidth: true
            Layout.leftMargin: 10
            text: Agenda.error !== "" ? Agenda.error
                : Agenda.tasksError !== "" ? Agenda.tasksError
                : Agenda.loading ? I18n.tr("common.loading")
                : ""
            font.family: "Inter"
            font.pixelSize: 10
            color: Agenda.error !== "" || Agenda.tasksError !== "" ? Theme.colorDanger : Theme.textDim
            elide: Text.ElideRight
        }

        GlassButton { implicitWidth: 26; implicitHeight: 26; fontSize: 13; text: "‹"; onClicked: root.step(-1) }
        GlassButton { implicitWidth: 26; implicitHeight: 26; fontSize: 13; text: "›"; onClicked: root.step(1) }
        GlassButton { implicitHeight: 26; fontSize: 11; text: I18n.tr("agenda.today"); onClicked: root.goToday() }
        Item { implicitWidth: 6 }
        GlassButton {
            implicitHeight: 26; fontSize: 11
            text: I18n.tr("agenda.month")
            accent: root.view === "month"
            onClicked: root.view = "month"
        }
        GlassButton {
            implicitHeight: 26; fontSize: 11
            text: I18n.tr("agenda.week")
            accent: root.view === "week"
            onClicked: root.view = "week"
        }
        Item { implicitWidth: 6 }
        GlassButton {
            implicitHeight: 26; fontSize: 11
            text: I18n.tr("agenda.tasks")
            accent: root.showTasks
            onClicked: root.showTasks = !root.showTasks
        }
    }

    // ── Le mois ──────────────────────────────────────────────────
    Item {
        id: monthPane
        visible: Google.connected && root.view === "month"
        anchors.top: header.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: tasksPane.visible ? tasksPane.left : parent.right
        anchors.rightMargin: tasksPane.visible ? 12 : 0
        anchors.bottom: parent.bottom

        readonly property real cellW: monthPane.width / 7
        readonly property real cellH: (monthPane.height - weekdays.height) / 6
        readonly property date start: Agenda.gridStart(root.year, root.month)
        // Les lignes (tâches et rendez-vous) qui tiennent sous le numéro du jour.
        readonly property int lines: Math.max(1, Math.floor((monthPane.cellH - 22) / 15))

        Row {
            id: weekdays
            height: 18

            Repeater {
                model: 7
                Text {
                    required property int index
                    width: monthPane.cellW
                    leftPadding: 6
                    // La semaine commence au jour de la langue (lundi en français).
                    text: I18n.locale.dayName((I18n.locale.firstDayOfWeek + index) % 7, Locale.ShortFormat)
                    font.family: "Inter"
                    font.pixelSize: 10
                    color: Theme.textDim
                }
            }
        }

        Grid {
            id: grid
            anchors.top: weekdays.bottom
            columns: 7

            Repeater {
                model: 42

                Item {
                    id: cell
                    required property int index
                    readonly property date day: root.addDays(monthPane.start, cell.index)
                    readonly property bool inMonth: cell.day.getMonth() === root.month
                    readonly property bool isToday: root.sameDay(cell.day, root.today)
                    readonly property var events: root.itemsOn(cell.day)
                    // Trop de rendez-vous : le dernier rang dit combien manquent.
                    readonly property int shown: cell.events.length > monthPane.lines ? monthPane.lines - 1
                                                                                      : cell.events.length

                    width: monthPane.cellW
                    height: monthPane.cellH

                    Rectangle {
                        anchors.fill: parent
                        color: cellMa.containsMouse ? Theme.hoverOverlay
                             : cell.inMonth ? "transparent" : Qt.alpha(Theme.textPrimary, 0.02)
                        Behavior on color { ColorAnimation { duration: 140 } }
                    }

                    // Le quadrillage : chaque case trace son haut et sa gauche.
                    Rectangle { width: parent.width; height: 1; color: Theme.dividerColor }
                    Rectangle { visible: cell.index % 7 > 0; width: 1; height: parent.height; color: Theme.dividerColor }

                    MouseArea {
                        id: cellMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openWeek(cell.day)
                    }

                    // Le numéro, dans une pastille d'accent aujourd'hui.
                    Rectangle {
                        id: dayNum
                        x: 4
                        y: 3
                        width: Math.max(18, numText.implicitWidth + 8)
                        height: 18
                        radius: 9
                        color: cell.isToday ? Theme.glow(0) : "transparent"

                        Text {
                            id: numText
                            anchors.centerIn: parent
                            text: cell.day.getDate() === 1
                                  ? I18n.locale.toString(cell.day, "d MMM") : cell.day.getDate()
                            font.family: "Inter"
                            font.pixelSize: 11
                            font.weight: cell.isToday ? Font.DemiBold : Font.Normal
                            font.features: { "tnum": 1 }
                            color: cell.isToday ? Theme.bgDeep
                                 : cell.inMonth ? Theme.textPrimary : Theme.textInactive
                        }
                    }

                    Column {
                        anchors.top: dayNum.bottom
                        anchors.topMargin: 2
                        x: 3
                        width: parent.width - 6
                        spacing: 1

                        Repeater {
                            model: cell.events.slice(0, cell.shown)

                            Rectangle {
                                id: chip
                                required property var modelData
                                readonly property bool task: root.isTask(chip.modelData)
                                readonly property bool band: !chip.task && root.isBand(chip.modelData)
                                readonly property color tint: Agenda.color(chip.modelData.calendar)

                                width: parent.width
                                height: 14
                                radius: 3
                                // Les journées : un aplat ; une tâche : sa case ; le reste :
                                // un point et l'heure.
                                color: chip.band ? Qt.alpha(chip.tint, cell.inMonth ? 0.85 : 0.45) : "transparent"

                                Rectangle {
                                    visible: !chip.band && !chip.task
                                    x: 3
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 6
                                    height: 6
                                    radius: 3
                                    color: chip.tint
                                    opacity: cell.inMonth ? 1 : 0.5
                                }

                                TaskCheck {
                                    visible: chip.task
                                    task: chip.modelData
                                    x: 1
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Text {
                                    x: chip.band ? 4 : 13
                                    width: parent.width - x - 2
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: {
                                        var t = chip.modelData.title || I18n.tr("agenda.untitled");
                                        // Commencé la veille : pas d'heure à donner ici.
                                        if (chip.task || chip.band || chip.modelData.startDate < cell.day)
                                            return t;
                                        return root.time(chip.modelData.startDate) + " " + t;
                                    }
                                    font.family: "Inter"
                                    font.pixelSize: 10
                                    font.weight: chip.band ? Font.Medium : Font.Normal
                                    font.features: { "tnum": 1 }
                                    font.strikeout: chip.task && chip.modelData.done
                                    color: chip.band ? "white"
                                         : !cell.inMonth || (chip.task && chip.modelData.done) ? Theme.textInactive
                                         : Theme.textPrimary
                                    elide: Text.ElideRight
                                }
                            }
                        }

                        Text {
                            visible: cell.shown < cell.events.length
                            x: 3
                            height: 14
                            verticalAlignment: Text.AlignVCenter
                            text: I18n.tr("agenda.more", { n: cell.events.length - cell.shown })
                            font.family: "Inter"
                            font.pixelSize: 10
                            font.weight: Font.Medium
                            color: Theme.textSecondary
                        }
                    }
                }
            }
        }

        // Le bas de la grille.
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.dividerColor }
    }

    // ── La semaine ───────────────────────────────────────────────
    Item {
        id: weekPane
        visible: Google.connected && root.view === "week"
        anchors.top: header.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: tasksPane.visible ? tasksPane.left : parent.right
        anchors.rightMargin: tasksPane.visible ? 12 : 0
        anchors.bottom: parent.bottom

        readonly property int gutter: 44
        readonly property real colW: (weekPane.width - weekPane.gutter) / 7
        readonly property int hourH: 36
        readonly property var days: {
            var out = [];
            for (var i = 0; i < 7; i++)
                out.push(root.addDays(root.weekStart, i));
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

            Repeater {
                model: 7

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
                            width: bandCol.width
                            height: 14
                            radius: 3
                            // Une tâche : sa case et son titre, sans aplat.
                            color: band.task ? "transparent" : Qt.alpha(Agenda.color(band.modelData.calendar), 0.85)

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
                    model: 7

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

                        Repeater {
                            model: weekPane.placed[col.index]

                            Rectangle {
                                id: block
                                required property var modelData
                                readonly property var e: block.modelData.e
                                readonly property real slot: (col.width - 4) / block.modelData.cols
                                readonly property color tint: Agenda.color(block.e.calendar)

                                x: 2 + block.modelData.col * block.slot
                                y: block.modelData.top * weekPane.hourH + 1
                                width: block.slot - 2
                                height: Math.max(14, block.modelData.height * weekPane.hourH - 2)
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

    // ── Les tâches ───────────────────────────────────────────────
    // Toutes, par liste : à faire d'abord (les datées par échéance), puis
    // faites, en retrait. Une échéance passée est en rouge.
    Item {
        id: tasksPane
        visible: Google.connected && root.showTasks
        anchors.top: header.bottom
        anchors.topMargin: 8
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        width: Math.min(240, root.width * 0.28)

        // [{ title, tasks }] par liste, les listes vides laissées de côté.
        readonly property var groups: Agenda.lists.map(l => ({
            title: l.title,
            tasks: Agenda.tasks.filter(t => t.list === l.id).sort((a, b) => {
                if (a.done !== b.done)
                    return a.done - b.done;
                if ((a.due === "") !== (b.due === ""))
                    return a.due === "" ? 1 : -1;
                return a.due < b.due ? -1 : a.due > b.due ? 1
                     : a.position < b.position ? -1 : a.position > b.position ? 1 : 0;
            })
        })).filter(g => g.tasks.length > 0)

        Rectangle { width: 1; height: parent.height; color: Theme.dividerColor }

        ListView {
            id: taskList
            anchors.fill: parent
            anchors.leftMargin: 12
            clip: true
            spacing: 2
            boundsBehavior: Flickable.StopAtBounds
            model: tasksPane.groups

            delegate: Column {
                id: group
                required property var modelData
                width: taskList.width
                spacing: 2

                Text {
                    width: parent.width
                    topPadding: 4
                    bottomPadding: 2
                    text: group.modelData.title
                    font.family: "Inter"
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                    color: Theme.textSecondary
                    elide: Text.ElideRight
                }

                Repeater {
                    model: group.modelData.tasks

                    Item {
                        id: row
                        required property var modelData
                        readonly property bool late: !row.modelData.done && row.modelData.due !== ""
                                                     && row.modelData.due < Agenda.dayKey(root.today)
                        width: group.width
                        height: Math.max(20, rowText.implicitHeight + 6)

                        TaskCheck {
                            x: row.modelData.parent !== "" ? 14 : 2
                            y: 5
                            task: row.modelData
                        }

                        Column {
                            id: rowText
                            x: (row.modelData.parent !== "" ? 14 : 2) + 16
                            y: 3
                            width: parent.width - x - 4

                            Text {
                                width: parent.width
                                text: row.modelData.title || I18n.tr("agenda.untitled")
                                font.family: "Inter"
                                font.pixelSize: 11
                                font.strikeout: row.modelData.done
                                color: row.modelData.done ? Theme.textInactive : Theme.textPrimary
                                wrapMode: Text.Wrap
                                maximumLineCount: 2
                                elide: Text.ElideRight
                            }
                            Text {
                                visible: row.modelData.due !== "" && !row.modelData.done
                                text: {
                                    var p = row.modelData.due.split("-");
                                    return I18n.locale.toString(new Date(+p[0], +p[1] - 1, +p[2]), "ddd d MMM");
                                }
                                font.family: "Inter"
                                font.pixelSize: 9
                                color: row.late ? Theme.colorDanger : Theme.textDim
                            }
                        }
                    }
                }
            }
        }

        Text {
            anchors.centerIn: parent
            width: parent.width - 24
            horizontalAlignment: Text.AlignHCenter
            visible: tasksPane.groups.length === 0 && Agenda.tasksError === ""
            text: I18n.tr("agenda.noTasks")
            font.family: "Inter"
            font.pixelSize: 11
            color: Theme.textDim
            wrapMode: Text.Wrap
        }
    }
}
