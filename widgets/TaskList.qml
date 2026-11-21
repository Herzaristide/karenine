pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// Les tâches du compte Google (services/Agenda.qml), toutes listes
// confondues ou celle choisie, et de quoi en créer une d'un mot. Dans le
// volet des tâches de la barre (`compact`) et dans l'onglet Agenda, en mode
// « Tâches ».
//
// Dans la barre, le strict nécessaire : le champ, puis une ligne par tâche
// à faire, sans filtre ni groupe ; chacune a sa case, Claude, et de quoi la
// voir dans l'agenda.
//
//   ╭ + Nouvelle tâche…                                               ╮
//    ☐ Payer le loyer                                           ✦  ▦
//    ☐ Appeler le garage                                        ✦  ▦
//
// Dans l'onglet Agenda :
//
//   [Toutes] [Mes tâches] [Courses]                                      les listes
//   ╭ + Nouvelle tâche…                                               ╮
//   [Sans date | Aujourd'hui | Demain]                  ( Mes tâches ▸ )
//   EN RETARD
//    ☐ Payer le loyer                                         5 nov.
//   AUJOURD'HUI
//    ☐ Appeler le garage
//       ☐ Demander le devis                                           sous-tâche
//   À VENIR · SANS DATE
//   ▸ FAITES 4                                                        dépliable
//
// Entrée crée la tâche, dans la liste montrée (ou celle du bouton quand
// toutes le sont), au jour choisi ; le champ reste prêt pour la suivante.
// Un clic sur une tâche l'ouvre (`openTask`) ; sa case la coche.
Item {
    id: root

    // Dans le volet de la barre : son en-tête, et le champ prend le clavier.
    property bool compact: false
    // La liste montrée (son id) ; vide : toutes.
    property string filter: ""
    property bool showDone: false
    // Le jour d'une tâche créée : "none", "today" ou "tomorrow".
    property string due: "none"

    signal openTask(var task)
    // « Ouvrir l'agenda » (compact).
    signal openAll()

    function focusAdd() {
        addInput.forceActiveFocus();
    }

    // La liste où va une tâche créée.
    readonly property string listForNew: {
        if (root.filter !== "")
            return root.filter;
        if (Agenda.quickList !== "" && Agenda.lists.some(l => l.id === Agenda.quickList))
            return Agenda.quickList;
        return Agenda.lists.length > 0 ? Agenda.lists[0].id : "";
    }

    function dayAfter(key, n) {
        var d = Agenda._parse(key);
        return Agenda.dayKey(new Date(d.getFullYear(), d.getMonth(), d.getDate() + n));
    }

    function add() {
        var title = addInput.text.trim();
        if (title === "")
            return;
        var due = root.due === "today" ? Agenda.todayKey
                : root.due === "tomorrow" ? root.dayAfter(Agenda.todayKey, 1) : "";
        Agenda.createTask(root.listForNew, { title: title, notes: "", due: due });
        addInput.text = "";
    }

    // « Demain », « vendredi », « 5 nov. » ; rien sans échéance.
    function dueLabel(due) {
        if (due === "")
            return "";
        var d = Agenda._parse(due);
        var t = Agenda._parse(Agenda.todayKey);
        var n = Math.round((d - t) / 86400000);
        if (n === 0)
            return I18n.tr("tasks.due.today");
        if (n === 1)
            return I18n.tr("tasks.due.tomorrow");
        if (n === -1)
            return I18n.tr("tasks.due.yesterday");
        if (n > 1 && n < 7)
            return I18n.locale.toString(d, "dddd");
        return I18n.locale.toString(d, d.getFullYear() === t.getFullYear() ? "d MMM" : "d MMM yyyy");
    }

    readonly property var shown: Agenda.tasks.filter(t => root.filter === "" || t.list === root.filter)
    readonly property int todoCount: root.shown.filter(t => !t.done).length

    // Les rangs de la liste : des têtes de groupe ({ head, label, n, danger,
    // fold }) et des tâches ({ task, depth }). À faire : en retard, du jour,
    // à venir, sans date ; chaque sous-tâche sous sa tâche. Puis les faites,
    // repliées.
    readonly property var rows: {
        if (root.compact)
            return root.flatRows;
        var today = Agenda.todayKey;
        function byOrder(a, b) { return a.position < b.position ? -1 : a.position > b.position ? 1 : 0; }
        function byDue(a, b) { return a.due < b.due ? -1 : a.due > b.due ? 1 : byOrder(a, b); }
        var todo = root.shown.filter(t => !t.done);
        var ids = {};
        todo.forEach(t => ids[t.list + "/" + t.id] = true);
        var isChild = t => t.parent !== "" && ids[t.list + "/" + t.parent] === true;
        var tops = todo.filter(t => !isChild(t));
        var kids = p => todo.filter(t => t.parent === p.id && t.list === p.list).sort(byOrder);
        var groups = [
            { label: "tasks.overdue", danger: true, items: tops.filter(t => t.due !== "" && t.due < today).sort(byDue) },
            { label: "tasks.today", items: tops.filter(t => t.due === today).sort(byOrder) },
            { label: "tasks.upcoming", items: tops.filter(t => t.due > today).sort(byDue) },
            { label: "tasks.undated", items: tops.filter(t => t.due === "").sort(byOrder) }
        ];
        var out = [];
        groups.forEach(g => {
            if (g.items.length === 0)
                return;
            var rows = [];
            g.items.forEach(t => {
                rows.push({ head: false, task: t, depth: 0 });
                kids(t).forEach(k => rows.push({ head: false, task: k, depth: 1 }));
            });
            out.push({ head: true, label: I18n.tr(g.label), n: rows.length, danger: g.danger === true, fold: false });
            out = out.concat(rows);
        });
        var done = root.shown.filter(t => t.done).sort(byOrder);
        if (done.length > 0) {
            out.push({ head: true, label: I18n.tr("tasks.done"), n: done.length, danger: false, fold: true });
            if (root.showDone)
                done.forEach(t => out.push({ head: false, task: t, depth: 0 }));
        }
        return out;
    }

    // La barre : les tâches à faire, dans l'ordre de l'onglet (en retard, du
    // jour, à venir, sans date), chaque sous-tâche sous la sienne.
    readonly property var flatRows: {
        function byOrder(a, b) { return a.position < b.position ? -1 : a.position > b.position ? 1 : 0; }
        // Sans date en dernier, les autres par échéance.
        function byDue(a, b) {
            var ka = a.due === "" ? "~" : a.due, kb = b.due === "" ? "~" : b.due;
            return ka < kb ? -1 : ka > kb ? 1 : byOrder(a, b);
        }
        var todo = root.shown.filter(t => !t.done);
        var ids = {};
        todo.forEach(t => ids[t.list + "/" + t.id] = true);
        var isChild = t => t.parent !== "" && ids[t.list + "/" + t.parent] === true;
        var out = [];
        todo.filter(t => !isChild(t)).sort(byDue).forEach(t => {
            out.push({ head: false, task: t, depth: 0 });
            todo.filter(k => k.parent === t.id && k.list === t.list).sort(byOrder)
                .forEach(k => out.push({ head: false, task: k, depth: 1 }));
        });
        return out;
    }

    implicitHeight: Google.connected ? top.implicitHeight + 10 + Math.max(70, list.contentHeight)
                                     : offline.implicitHeight

    Component.onCompleted: {
        if (Google.connected)
            Agenda.loadTasks();
        if (root.compact && Google.connected)
            addInput.forceActiveFocus();
    }

    // Une petite pastille cliquable.
    component Chip: Rectangle {
        id: chip
        property string label
        property bool active: false
        signal clicked()
        implicitWidth: chipText.implicitWidth + 18
        implicitHeight: 24
        radius: 12
        color: chip.active ? Qt.alpha(Theme.accentColor, 0.18)
             : chipMa.containsMouse ? Theme.hoverOverlay : Qt.alpha(Theme.textPrimary, 0.06)
        Text {
            id: chipText
            anchors.centerIn: parent
            text: chip.label
            font.family: "Inter"
            font.pixelSize: 11
            font.weight: Font.Medium
            color: chip.active ? Theme.accentColor : Theme.textSecondary
        }
        MouseArea {
            id: chipMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }
    }

    // ── Sans compte ──────────────────────────────────────────────
    Column {
        id: offline
        visible: !Google.connected
        width: parent.width
        spacing: 10

        Text {
            width: parent.width
            text: I18n.tr("agenda.connectTitle")
            wrapMode: Text.Wrap
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.textSecondary
        }
        GlassButton {
            visible: root.compact
            implicitHeight: 28
            fontSize: 11
            text: I18n.tr("tasks.openAgenda")
            onClicked: root.openAll()
        }
    }

    // ── L'en-tête, les listes, le champ ──────────────────────────
    ColumnLayout {
        id: top
        visible: Google.connected
        width: parent.width
        spacing: 8

        Flow {
            visible: !root.compact && Agenda.lists.length > 1
            Layout.fillWidth: true
            spacing: 4

            Chip {
                label: I18n.tr("tasks.allLists")
                active: root.filter === ""
                onClicked: root.filter = ""
            }
            Repeater {
                model: Agenda.lists
                Chip {
                    id: listChip
                    required property var modelData
                    label: listChip.modelData.title
                    active: root.filter === listChip.modelData.id
                    onClicked: root.filter = listChip.modelData.id
                }
            }
        }

        // Le champ : Entrée crée la tâche.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 34
            radius: Theme.radiusSmall
            color: Theme.bgElevated
            border.width: addInput.activeFocus ? 1 : 0
            border.color: Qt.alpha(Theme.accentColor, 0.6)

            Text {
                id: plus
                x: 10
                anchors.verticalCenter: parent.verticalCenter
                text: "+"
                font.family: "Inter"
                font.pixelSize: 16
                color: addInput.activeFocus ? Theme.accentColor : Theme.textDim
            }
            TextInput {
                id: addInput
                anchors.left: plus.right
                anchors.leftMargin: 8
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                clip: true
                font.family: "Inter"
                font.pixelSize: 13
                color: Theme.textPrimary
                selectionColor: Qt.alpha(Theme.accentColor, 0.45)
                Keys.onReturnPressed: root.add()
                Keys.onEnterPressed: root.add()
                // Échap efface d'abord ; le champ vide, il passe plus loin
                // (le volet se referme).
                Keys.onEscapePressed: (event) => {
                    if (addInput.text !== "")
                        addInput.text = "";
                    else
                        event.accepted = false;
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: addInput.text.length === 0
                    text: I18n.tr("tasks.newPlaceholder")
                    font: addInput.font
                    color: Theme.textDim
                }
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.IBeamCursor
                onPressed: (mouse) => {
                    addInput.forceActiveFocus();
                    mouse.accepted = false;
                }
            }
        }

        // Le jour, et la liste quand toutes sont montrées.
        RowLayout {
            visible: !root.compact
            Layout.fillWidth: true
            spacing: 8

            Segmented {
                Layout.preferredWidth: 240
                options: [{ label: I18n.tr("tasks.due.none"), value: "none" },
                          { label: I18n.tr("tasks.due.today"), value: "today" },
                          { label: I18n.tr("tasks.due.tomorrow"), value: "tomorrow" }]
                current: root.due
                onPicked: (value) => root.due = value
            }
            Item { Layout.fillWidth: true }
            GlassButton {
                visible: root.filter === "" && Agenda.lists.length > 1
                implicitHeight: 28
                fontSize: 11
                text: Agenda.listTitle(root.listForNew) + "  ▸"
                onClicked: {
                    var ls = Agenda.lists;
                    var i = ls.findIndex(l => l.id === root.listForNew);
                    Agenda.quickList = ls[(i + 1) % ls.length].id;
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: Agenda.tasksError !== ""
            text: Agenda.tasksError
            wrapMode: Text.Wrap
            font.family: "Inter"
            font.pixelSize: 11
            color: Theme.colorDanger
        }
    }

    // ── Les tâches ───────────────────────────────────────────────
    ListView {
        id: list
        visible: Google.connected
        anchors.top: top.bottom
        anchors.topMargin: 10
        anchors.bottom: parent.bottom
        width: parent.width
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.rows

        delegate: Item {
            id: row
            required property var modelData
            readonly property bool head: row.modelData.head
            readonly property var task: row.modelData.task || ({})
            width: list.width
            height: row.head ? 26 : 30

            // Une tête de groupe ; celle des faites se déplie.
            Row {
                visible: row.head
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 5
                x: 4
                spacing: 6

                Text {
                    visible: row.modelData.fold === true
                    text: root.showDone ? "▾" : "▸"
                    font.pixelSize: 10
                    color: Theme.textDim
                }
                Text {
                    text: (row.modelData.label || "").toUpperCase()
                    font.family: "Inter"
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.6
                    color: row.modelData.danger ? Theme.colorDanger : Theme.textDim
                }
                Text {
                    text: row.modelData.n || ""
                    font.family: "Inter"
                    font.pixelSize: 10
                    font.features: { "tnum": 1 }
                    color: Theme.textInactive
                }
            }
            MouseArea {
                visible: row.head && row.modelData.fold === true
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showDone = !root.showDone
            }

            // Une tâche.
            Rectangle {
                visible: !row.head
                anchors.fill: parent
                anchors.topMargin: 1
                anchors.bottomMargin: 1
                radius: Theme.radiusSmall
                color: taskMa.containsMouse ? Theme.hoverOverlay : "transparent"
                opacity: row.task.pending ? 0.55 : 1

                MouseArea {
                    id: taskMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: row.task.pending ? Qt.ArrowCursor : Qt.PointingHandCursor
                    onClicked: if (!row.task.pending) root.openTask(row.task)
                }

                TaskCheck {
                    id: box
                    task: row.task
                    size: 14
                    x: 8 + (row.modelData.depth || 0) * 20
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    id: titleText
                    anchors.left: box.right
                    anchors.leftMargin: 10
                    anchors.right: meta.visible ? meta.left : claudeBtn.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.task.title || I18n.tr("agenda.untitled")
                    elide: Text.ElideRight
                    font.family: "Inter"
                    font.pixelSize: 13
                    font.strikeout: row.task.done === true
                    color: row.task.done ? Theme.textInactive : Theme.textPrimary
                }
                // L'échéance (pas celle du jour, que son groupe dit), et la
                // liste quand toutes sont montrées.
                // Claude Code : un terminal, la tâche en première demande.
                // Les étoiles de l'onglet Claude du panneau.
                // La barre : la tâche dans l'onglet Agenda.
                Rectangle {
                    id: calBtn
                    visible: root.compact && !row.task.pending
                    anchors.right: parent.right
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    width: 24
                    height: 24
                    radius: Theme.radiusSmall
                    color: calMa.containsMouse ? Qt.alpha(Theme.accentColor, 0.18) : "transparent"

                    NixIcon {
                        anchors.centerIn: parent
                        iconSize: 15
                        source: "../assets/ui/calendar.svg"
                        color: calMa.containsMouse ? Theme.accentColor : Theme.iconColor
                        opacity: calMa.containsMouse || taskMa.containsMouse ? 1 : 0.7
                    }
                    MouseArea {
                        id: calMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openTask(row.task)
                    }
                }
                Rectangle {
                    id: claudeBtn
                    visible: !row.task.done && !row.task.pending
                    anchors.right: calBtn.visible ? calBtn.left : parent.right
                    anchors.rightMargin: calBtn.visible ? 2 : 4
                    anchors.verticalCenter: parent.verticalCenter
                    width: 24
                    height: 24
                    radius: Theme.radiusSmall
                    color: claudeMa.containsMouse ? Qt.alpha(Theme.accentColor, 0.18) : "transparent"

                    NixIcon {
                        anchors.centerIn: parent
                        iconSize: 15
                        source: "../assets/ui/sparkles.svg"
                        color: claudeMa.containsMouse ? Theme.accentColor : Theme.iconColor
                        opacity: claudeMa.containsMouse || taskMa.containsMouse ? 1 : 0.7
                    }
                    MouseArea {
                        id: claudeMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Agenda.openInClaude(row.task)
                    }
                }
                Text {
                    id: meta
                    visible: !root.compact
                    anchors.right: claudeBtn.visible ? claudeBtn.left : parent.right
                    anchors.rightMargin: claudeBtn.visible ? 6 : 8
                    anchors.verticalCenter: parent.verticalCenter
                    readonly property string when: row.task.due === Agenda.todayKey && !row.task.done
                                                   ? "" : root.dueLabel(row.task.due || "")
                    readonly property string where: root.filter === "" && Agenda.lists.length > 1
                                                    ? Agenda.listTitle(row.task.list) : ""
                    text: [meta.when, meta.where].filter(s => s !== "").join("  ·  ")
                    font.family: "Inter"
                    font.pixelSize: 11
                    font.features: { "tnum": 1 }
                    color: !row.task.done && row.task.due !== "" && row.task.due < Agenda.todayKey
                           ? Theme.colorDanger : Theme.textDim
                }
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            // Sous la tête des faites, s'il y en a.
            y: list.contentHeight + 16
            visible: root.todoCount === 0
            text: I18n.tr("tasks.none")
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.textSecondary
        }
    }
}
