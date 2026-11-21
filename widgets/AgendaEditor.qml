pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// La carte qui crée ou modifie un événement ou une tâche, par-dessus
// l'agenda (CalendarWidget). Un clic dans le vide de la grille l'ouvre sur
// un nouvel événement à cette heure ; dans la bande « Journée », sur une
// nouvelle tâche ce jour-là ; sur un rendez-vous ou une tâche, sur lui.
//
//   ╭ Nouvel événement ────────────────────────╮
//   │ [Événement | Tâche]                       │   (à la création seulement)
//   │ Titre     [Point projet               ]  │
//   │ Jour      [2026-11-20]  ☐ Toute la journée│
//   │ Début     [14:00]   Fin [15:00]           │
//   │ Lieu      [                           ]  │
//   │ Agenda    ( Perso ▸ )                     │   un clic passe au suivant
//   │ Notes     [                           ]  │
//   │ (Supprimer)          (Annuler) (Enregistrer)│
//   ╰──────────────────────────────────────────╯
//
// Les dates s'écrivent AAAA-MM-JJ, les heures HH:MM, en heure locale.
// Entrée enregistre, Échap ferme.
Item {
    id: root

    property bool open: false
    // "event" ou "task".
    property string kind: "event"
    // Ce qu'on modifie ; null : on crée.
    property var event: null
    property var task: null
    readonly property bool creating: root.event === null && root.task === null

    // Les champs.
    property string title: ""
    property string day: ""
    property string startTime: ""
    property string endTime: ""
    property bool allDay: false
    property string location: ""
    property string notes: ""
    property string calendar: ""
    property string list: ""
    property string error: ""
    property bool armed: false

    function two(n) { return n < 10 ? "0" + n : "" + n; }
    function hm(d) { return root.two(d.getHours()) + ":" + root.two(d.getMinutes()); }

    function reset() {
        root.error = "";
        root.armed = false;
        root.location = "";
        root.notes = "";
        root.allDay = false;
        root.event = null;
        root.task = null;
    }

    // L'agenda principal (celui du compte), sinon le premier affiché.
    function defaultCalendar() {
        var c = Agenda.calendars.find(c => c.id === Google.email) || Agenda.calendars[0];
        return c ? c.id : "";
    }

    function openNewEvent(start, end, allDay) {
        root.reset();
        root.kind = "event";
        root.title = "";
        root.day = Agenda.dayKey(start);
        root.startTime = root.hm(start);
        root.endTime = root.hm(end);
        root.allDay = allDay;
        root.calendar = root.defaultCalendar();
        root.list = Agenda.lists.length > 0 ? Agenda.lists[0].id : "";
        root.open = true;
        titleField.focusInput();
    }

    function openNewTask(day) {
        root.openNewEvent(new Date(day.getFullYear(), day.getMonth(), day.getDate(), 9),
                          new Date(day.getFullYear(), day.getMonth(), day.getDate(), 10), true);
        root.kind = "task";
    }

    function openEvent(e) {
        root.reset();
        root.kind = "event";
        root.event = e;
        root.title = e.title;
        root.day = Agenda.dayKey(e.startDate);
        root.startTime = root.hm(e.startDate);
        root.endTime = root.hm(e.endDate);
        root.allDay = e.allDay;
        root.location = e.location || "";
        root.notes = e.notes || "";
        root.calendar = e.calendar;
        root.open = true;
    }

    function openTask(t) {
        root.reset();
        root.kind = "task";
        root.task = t;
        root.title = t.title;
        root.day = t.due;
        root.notes = t.notes || "";
        root.list = t.list;
        root.open = true;
    }

    function close() {
        root.open = false;
        root.reset();
    }

    // "2026-11-20" et "14:00" → la Date locale ; null si l'un ne se lit pas.
    function dateOf(day, time) {
        var d = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day.trim());
        var t = /^(\d{1,2})[:h](\d{2})$/.exec((time || "00:00").trim());
        if (!d || !t)
            return null;
        var out = new Date(+d[1], +d[2] - 1, +d[3], +t[1], +t[2]);
        return isNaN(out.getTime()) ? null : out;
    }

    function save() {
        var title = root.title.trim();
        if (root.kind === "task") {
            var due = root.day.trim();
            if (due !== "" && !root.dateOf(due, "00:00")) {
                root.error = I18n.tr("agenda.badDate");
                return;
            }
            var input = { title: title, notes: root.notes, due: due };
            if (root.creating)
                Agenda.createTask(root.list, input);
            else
                Agenda.updateTask(root.task, input);
            root.close();
            return;
        }
        var start, end;
        if (root.allDay) {
            start = root.dateOf(root.day, "00:00");
            end = start ? new Date(start.getFullYear(), start.getMonth(), start.getDate() + 1) : null;
        } else {
            start = root.dateOf(root.day, root.startTime);
            end = root.dateOf(root.day, root.endTime);
            // Une fin avant le début : le lendemain (une soirée qui déborde).
            if (start && end && end <= start)
                end = new Date(end.getTime() + 24 * 3600 * 1000);
        }
        if (!start || !end) {
            root.error = I18n.tr("agenda.badDate");
            return;
        }
        var ev = { title: title, location: root.location, notes: root.notes,
                   start: start, end: end, allDay: root.allDay };
        if (root.creating)
            Agenda.createEvent(root.calendar, ev);
        else
            Agenda.updateEvent(root.event, ev);
        root.close();
    }

    function remove() {
        if (!root.armed) {
            root.armed = true;
            return;
        }
        if (root.kind === "task")
            Agenda.deleteTask(root.task);
        else
            Agenda.deleteEvent(root.event);
        root.close();
    }

    // Le nom de l'agenda ou de la liste choisis, et le suivant au clic.
    function calendarName(id) {
        var c = Agenda.calendars.find(c => c.id === id);
        return c ? c.name : id;
    }
    function cycle(items, current) {
        if (items.length === 0)
            return current;
        var i = items.findIndex(x => x.id === current);
        return items[(i + 1) % items.length].id;
    }

    visible: root.open
    Keys.onEscapePressed: root.close()

    // Le voile : un clic à côté ferme.
    Rectangle {
        anchors.fill: parent
        color: Qt.alpha(Theme.bgDeep, 0.6)
        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
            onWheel: (wheel) => wheel.accepted = true
        }
    }

    component Label: Text {
        Layout.preferredWidth: 70
        font.family: "Inter"
        font.pixelSize: 12
        color: Theme.textSecondary
    }

    // Une ligne de saisie, du fond des cartes.
    component Field: Rectangle {
        id: field
        // La valeur, reprise dans la saisie quand elle change d'ailleurs
        // (un autre élément ouvert) ; la frappe la renvoie par `edited`.
        property string text: ""
        onTextChanged: if (input.text !== field.text) input.text = field.text
        property string placeholder: ""
        signal edited(string text)
        function focusInput() { input.forceActiveFocus(); }

        Layout.fillWidth: true
        implicitHeight: 32
        radius: Theme.radiusSmall
        color: Theme.bgElevated
        border.width: input.activeFocus ? 1 : 0
        border.color: Qt.alpha(Theme.accentColor, 0.6)

        TextInput {
            id: input
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10
            verticalAlignment: TextInput.AlignVCenter
            clip: true
            font.family: "Inter"
            font.pixelSize: 13
            color: Theme.textPrimary
            selectionColor: Qt.alpha(Theme.accentColor, 0.45)
            Component.onCompleted: input.text = field.text
            onTextEdited: field.edited(input.text)
            Keys.onReturnPressed: root.save()
            Keys.onEnterPressed: root.save()
            Keys.onEscapePressed: root.close()
        }
        Text {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text.length === 0
            text: field.placeholder
            font: input.font
            color: Theme.textDim
        }
    }

    // Un petit bouton, plein pour l'action principale.
    component Button: Rectangle {
        id: btn
        property string label
        property bool primary: false
        property bool danger: false
        signal clicked()
        implicitWidth: btnText.implicitWidth + 24
        implicitHeight: 32
        radius: Theme.radiusSmall
        color: btn.primary ? Theme.accentColor
             : btn.danger ? Qt.alpha(Theme.colorDanger, btnMa.containsMouse ? 0.26 : 0.16)
             : btnMa.containsMouse ? Theme.hoverOverlay : Theme.bgElevated
        Text {
            id: btnText
            anchors.centerIn: parent
            text: btn.label
            font.family: "Inter"
            font.pixelSize: 12
            font.weight: Font.Medium
            color: btn.primary ? Theme.bgDeep : btn.danger ? Theme.colorDanger : Theme.textPrimary
        }
        MouseArea {
            id: btnMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }

    // ── La carte ─────────────────────────────────────────────────
    Rectangle {
        anchors.centerIn: parent
        width: Math.min(400, parent.width - 24)
        height: card.implicitHeight + 32
        radius: Theme.radius
        color: Theme.bgDeep
        border.width: 1
        border.color: Theme.dividerColor

        MouseArea { anchors.fill: parent }

        ColumnLayout {
            id: card
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 16
            spacing: 10

            Text {
                text: I18n.tr(root.creating ? (root.kind === "task" ? "agenda.newTask" : "agenda.newEvent")
                                            : (root.kind === "task" ? "agenda.editTask" : "agenda.editEvent"))
                font.family: "Inter"
                font.pixelSize: 15
                font.weight: Font.DemiBold
                color: Theme.textPrimary
            }

            // Événement ou tâche : à la création seulement.
            Row {
                visible: root.creating
                spacing: 4
                Repeater {
                    model: [{ k: "event", l: "agenda.kind.event" }, { k: "task", l: "agenda.kind.task" }]
                    Button {
                        id: kindBtn
                        required property var modelData
                        label: I18n.tr(kindBtn.modelData.l)
                        primary: root.kind === kindBtn.modelData.k
                        onClicked: root.kind = kindBtn.modelData.k
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Label { text: I18n.tr("agenda.field.title") }
                Field {
                    id: titleField
                    text: root.title
                    onEdited: (t) => root.title = t
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Label { text: I18n.tr(root.kind === "task" ? "agenda.field.due" : "agenda.field.day") }
                Field {
                    Layout.fillWidth: false
                    Layout.preferredWidth: 120
                    text: root.day
                    placeholder: "AAAA-MM-JJ"
                    onEdited: (t) => root.day = t
                }
                // Toute la journée : une case.
                Row {
                    visible: root.kind === "event"
                    spacing: 6
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        height: 16
                        radius: 4
                        color: root.allDay ? Theme.accentColor : "transparent"
                        border.width: root.allDay ? 0 : 1.5
                        border.color: Theme.textDim
                        Text {
                            anchors.centerIn: parent
                            visible: root.allDay
                            text: "✓"
                            font.pixelSize: 11
                            font.weight: Font.Bold
                            color: Theme.bgDeep
                        }
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -4
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.allDay = !root.allDay
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: I18n.tr("agenda.field.allDay")
                        font.family: "Inter"
                        font.pixelSize: 12
                        color: Theme.textSecondary
                    }
                }
                Item { Layout.fillWidth: true }
            }

            RowLayout {
                visible: root.kind === "event" && !root.allDay
                Layout.fillWidth: true
                Label { text: I18n.tr("agenda.field.start") }
                Field {
                    Layout.fillWidth: false
                    Layout.preferredWidth: 70
                    text: root.startTime
                    placeholder: "HH:MM"
                    onEdited: (t) => root.startTime = t
                }
                Text {
                    Layout.leftMargin: 10
                    text: I18n.tr("agenda.field.end")
                    font.family: "Inter"
                    font.pixelSize: 12
                    color: Theme.textSecondary
                }
                Field {
                    Layout.fillWidth: false
                    Layout.preferredWidth: 70
                    text: root.endTime
                    placeholder: "HH:MM"
                    onEdited: (t) => root.endTime = t
                }
                Item { Layout.fillWidth: true }
            }

            RowLayout {
                visible: root.kind === "event"
                Layout.fillWidth: true
                Label { text: I18n.tr("agenda.field.location") }
                Field {
                    text: root.location
                    onEdited: (t) => root.location = t
                }
            }

            // L'agenda (ou la liste) : un clic passe au suivant. Une fois
            // créé, un événement reste dans son agenda.
            RowLayout {
                visible: root.kind === "task" || root.creating
                Layout.fillWidth: true
                Label { text: I18n.tr(root.kind === "task" ? "agenda.field.list" : "agenda.field.calendar") }
                Button {
                    label: (root.kind === "task" ? Agenda.listTitle(root.list) : root.calendarName(root.calendar)) + "  ▸"
                    onClicked: {
                        if (root.kind === "task") {
                            if (root.creating)
                                root.list = root.cycle(Agenda.lists, root.list);
                        } else {
                            root.calendar = root.cycle(Agenda.calendars, root.calendar);
                        }
                    }
                }
                Item { Layout.fillWidth: true }
            }

            RowLayout {
                Layout.fillWidth: true
                Label { text: I18n.tr("agenda.field.notes") }
                Field {
                    text: root.notes
                    onEdited: (t) => root.notes = t
                }
            }

            Text {
                Layout.fillWidth: true
                visible: root.error !== ""
                text: root.error
                wrapMode: Text.Wrap
                font.family: "Inter"
                font.pixelSize: 12
                color: Theme.colorDanger
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 4
                spacing: 6
                Button {
                    visible: !root.creating
                    danger: true
                    label: I18n.tr(root.armed ? "agenda.deleteConfirm" : "agenda.delete")
                    onClicked: root.remove()
                }
                // Une tâche : la confier à Claude Code (son titre et ses
                // notes tels qu'écrits ici).
                Button {
                    visible: root.kind === "task" && root.title.trim() !== ""
                    label: I18n.tr("tasks.openInClaude")
                    onClicked: {
                        Agenda.openInClaude({ title: root.title, notes: root.notes, list: root.list });
                        root.close();
                    }
                }
                Item { Layout.fillWidth: true }
                Button {
                    label: I18n.tr("common.cancel")
                    onClicked: root.close()
                }
                Button {
                    primary: true
                    label: I18n.tr("agenda.save")
                    onClicked: root.save()
                }
            }
        }
    }
}
