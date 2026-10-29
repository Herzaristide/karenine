pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// L'onglet « Agenda » : les calendriers du compte Nextcloud (Murena…), lus
// par anna (services/Agenda.qml). À gauche le mois, à droite le jour choisi.
//
//   ╭──────────────────────────────╮ ╭──────────────────────────────╮
//   │ octobre 2026    ‹ › Aujourd'hui │ jeudi 22 octobre              │
//   │  lu ma me je ve sa di        │ ▍ Journée   Toussaint          │
//   │  28 29 30  1  2  3  4        │ ▍ 14:00 – 15:00  Dentiste       │
//   │   5  6  7  8  9 10 11        │     12 rue X                   │
//   │  …        (22)  •            │                                │
//   ╰──────────────────────────────╯ ╰──────────────────────────────╯
//
// Un point sous un jour par calendrier qui y a quelque chose, à sa couleur.
// Sans compte connecté, l'onglet propose de le connecter (CloudAccount).
Item {
    id: root

    // Le mois affiché (0-11) et le jour choisi.
    property int year: new Date().getFullYear()
    property int month: new Date().getMonth()
    property date selected: new Date()
    // Aujourd'hui, à minuit : relu toutes les minutes (passer minuit).
    property date today: root.midnight(new Date())

    function midnight(d) {
        return new Date(d.getFullYear(), d.getMonth(), d.getDate());
    }

    function sameDay(a, b) {
        return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
    }

    function load() {
        if (Cloud.connected)
            Agenda.load(root.year, root.month);
    }

    function step(delta) {
        var d = new Date(root.year, root.month + delta, 1);
        root.year = d.getFullYear();
        root.month = d.getMonth();
        root.load();
    }

    function goToday() {
        root.today = root.midnight(new Date());
        root.selected = root.today;
        root.year = root.today.getFullYear();
        root.month = root.today.getMonth();
        root.load();
    }

    Component.onCompleted: root.load()

    Connections {
        target: Cloud
        function onConnectedChanged() { root.load(); }
    }

    // Les événements changent ailleurs (le téléphone) : relus toutes les
    // cinq minutes tant que l'onglet est affiché.
    Timer {
        interval: 5 * 60 * 1000
        repeat: true
        running: root.visible && Cloud.connected
        onTriggered: root.load()
    }
    Timer {
        interval: 60000
        repeat: true
        running: root.visible
        onTriggered: root.today = root.midnight(new Date())
    }

    // « 14:00 » d'une Date, à la mode de la langue.
    function time(d) {
        return I18n.locale.toString(d, "HH:mm");
    }

    function when(e, day) {
        if (e.allDay)
            return I18n.tr("agenda.allDay");
        // Un événement qui déborde sur ce jour : depuis la veille, ou
        // jusqu'au lendemain.
        var startsBefore = e.startDate < day;
        var next = new Date(day.getFullYear(), day.getMonth(), day.getDate() + 1);
        var endsAfter = e.endDate > next;
        var from = startsBefore ? "…" : root.time(e.startDate);
        if (+e.endDate === +e.startDate)
            return from;
        return from + " – " + (endsAfter ? "…" : root.time(e.endDate));
    }

    // ── Sans compte ──────────────────────────────────────────────
    Column {
        anchors.centerIn: parent
        width: Math.min(460, root.width - 40)
        spacing: 14
        visible: Cloud.known && !Cloud.connected

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

        CloudAccount {
            width: parent.width
        }
    }

    // ── Le mois ──────────────────────────────────────────────────
    Item {
        id: monthPane
        visible: Cloud.connected
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Math.min(320, root.width * 0.45)

        readonly property real cellW: monthPane.width / 7
        readonly property real cellH: (monthPane.height - header.height - weekdays.height - 12) / 6
        readonly property date start: Agenda.gridStart(root.year, root.month)

        RowLayout {
            id: header
            width: parent.width
            height: 30
            spacing: 4

            Text {
                Layout.fillWidth: true
                // « octobre 2026 », la majuscule de la langue en plus.
                text: {
                    var s = I18n.locale.toString(new Date(root.year, root.month, 1), "MMMM yyyy");
                    return s.charAt(0).toUpperCase() + s.slice(1);
                }
                font.family: "Inter"
                font.pixelSize: 14
                font.weight: Font.DemiBold
                color: Theme.textPrimary
                elide: Text.ElideRight
            }
            GlassButton { implicitWidth: 26; implicitHeight: 26; fontSize: 13; text: "‹"; onClicked: root.step(-1) }
            GlassButton { implicitWidth: 26; implicitHeight: 26; fontSize: 13; text: "›"; onClicked: root.step(1) }
            GlassButton { implicitHeight: 26; fontSize: 11; text: I18n.tr("agenda.today"); onClicked: root.goToday() }
        }

        Row {
            id: weekdays
            anchors.top: header.bottom
            anchors.topMargin: 8
            height: 18

            Repeater {
                model: 7
                Text {
                    required property int index
                    width: monthPane.cellW
                    horizontalAlignment: Text.AlignHCenter
                    // La semaine commence au jour de la langue (lundi en français).
                    text: I18n.locale.dayName((I18n.locale.firstDayOfWeek + index) % 7, Locale.ShortFormat)
                    font.family: "Inter"
                    font.pixelSize: 10
                    color: Theme.textDim
                }
            }
        }

        Grid {
            anchors.top: weekdays.bottom
            anchors.topMargin: 4
            columns: 7

            Repeater {
                model: 42

                Item {
                    id: cell
                    required property int index
                    readonly property date day: new Date(monthPane.start.getFullYear(), monthPane.start.getMonth(),
                                                         monthPane.start.getDate() + cell.index)
                    readonly property bool inMonth: cell.day.getMonth() === root.month
                    readonly property bool isToday: root.sameDay(cell.day, root.today)
                    readonly property bool isSelected: root.sameDay(cell.day, root.selected)
                    // Un point par calendrier qui a quelque chose ce jour-là.
                    readonly property var dots: {
                        var seen = [];
                        Agenda.on(cell.day).forEach(e => { if (seen.indexOf(e.calendar) < 0) seen.push(e.calendar); });
                        return seen.slice(0, 3);
                    }

                    width: monthPane.cellW
                    height: monthPane.cellH

                    Rectangle {
                        anchors.centerIn: parent
                        width: Math.min(parent.width, parent.height) - 4
                        height: width
                        radius: width / 2
                        color: cell.isSelected ? Theme.selectedFill
                             : cellMa.containsMouse ? Theme.hoverOverlay : "transparent"
                        border.color: cell.isToday ? Theme.glow(0) : "transparent"
                        border.width: cell.isToday ? 1.5 : 0
                        Behavior on color { ColorAnimation { duration: 140 } }
                    }

                    Text {
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: cell.dots.length > 0 ? -3 : 0
                        text: cell.day.getDate()
                        font.family: "Inter"
                        font.pixelSize: 12
                        font.weight: cell.isToday || cell.isSelected ? Font.DemiBold : Font.Normal
                        color: cell.inMonth ? Theme.textPrimary : Theme.textInactive
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Math.max(3, parent.height * 0.14)
                        spacing: 3

                        Repeater {
                            model: cell.dots
                            Rectangle {
                                required property string modelData
                                width: 4
                                height: 4
                                radius: 2
                                color: Agenda.color(modelData)
                                opacity: cell.inMonth ? 1 : 0.5
                            }
                        }
                    }

                    MouseArea {
                        id: cellMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.selected = cell.day;
                            // Un jour du mois d'à côté : on y va.
                            if (!cell.inMonth)
                                root.step(cell.day < new Date(root.year, root.month, 1) ? -1 : 1);
                        }
                    }
                }
            }
        }
    }

    // Le fil entre le mois et le jour.
    Rectangle {
        visible: Cloud.connected
        x: monthPane.width + 16
        width: 1
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        color: Theme.dividerColor
    }

    // ── Le jour ──────────────────────────────────────────────────
    Item {
        id: dayPane
        visible: Cloud.connected
        anchors.left: monthPane.right
        anchors.leftMargin: 33
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom

        readonly property var events: Agenda.on(root.selected)

        Text {
            id: dayTitle
            width: parent.width
            height: 30
            verticalAlignment: Text.AlignVCenter
            text: {
                var s = I18n.locale.toString(root.selected, "dddd d MMMM");
                return s.charAt(0).toUpperCase() + s.slice(1);
            }
            font.family: "Inter"
            font.pixelSize: 14
            font.weight: Font.DemiBold
            color: Theme.textPrimary
            elide: Text.ElideRight
        }

        ListView {
            id: list
            anchors.top: dayTitle.bottom
            anchors.topMargin: 8
            anchors.bottom: status.top
            anchors.bottomMargin: 4
            width: parent.width
            clip: true
            spacing: 6
            boundsBehavior: Flickable.StopAtBounds
            model: dayPane.events

            delegate: Rectangle {
                id: row
                required property var modelData
                width: list.width
                height: rowText.implicitHeight + 16
                radius: Theme.radiusSmall
                color: Qt.alpha(Theme.textPrimary, 0.05)

                // La couleur de son calendrier.
                Rectangle {
                    x: 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: 3
                    height: parent.height - 14
                    radius: 1.5
                    color: Agenda.color(row.modelData.calendar)
                }

                Column {
                    id: rowText
                    x: 18
                    width: parent.width - 28
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Row {
                        width: parent.width
                        spacing: 10

                        Text {
                            id: whenText
                            text: root.when(row.modelData, root.midnight(root.selected))
                            font.family: "Inter"
                            font.pixelSize: 11
                            font.features: { "tnum": 1 }
                            color: Theme.textSecondary
                        }
                        Text {
                            width: parent.width - whenText.width - 10
                            text: row.modelData.title || I18n.tr("agenda.untitled")
                            font.family: "Inter"
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            color: Theme.textPrimary
                            elide: Text.ElideRight
                        }
                    }
                    Text {
                        width: parent.width
                        visible: row.modelData.location !== ""
                        text: row.modelData.location.replace(/\n/g, ", ")
                        font.family: "Inter"
                        font.pixelSize: 10
                        color: Theme.textDim
                        elide: Text.ElideRight
                    }
                }
            }
        }

        Text {
            anchors.centerIn: list
            visible: dayPane.events.length === 0 && !Agenda.loading && Agenda.error === ""
            text: I18n.tr("agenda.nothing")
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.textDim
        }

        // Ce qui se passe : la lecture, ou ce qui a échoué.
        Text {
            id: status
            anchors.bottom: parent.bottom
            width: parent.width
            height: text === "" ? 0 : implicitHeight
            text: Agenda.error !== "" ? Agenda.error
                : Agenda.loading ? I18n.tr("common.loading")
                : ""
            font.family: "Inter"
            font.pixelSize: 10
            color: Agenda.error !== "" ? Theme.colorDanger : Theme.textDim
            elide: Text.ElideRight
        }
    }
}
