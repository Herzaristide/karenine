pragma ComponentBehavior: Bound
import QtQuick
import QtQml
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "../services"

Item {
    id: root

    // ── Persistence ──────────────────────────────────────────────────────────
    // Notes are stored as JSON in Quickshell's per-shell data dir (auto-created).
    // QtCore Settings is avoided on purpose: Quickshell sets no QSettings
    // organization/domain, so QSettings fails to initialize.
    FileView {
        id: notesFile
        path: Quickshell.dataPath("notes.json")
        watchChanges: true
        printErrors: false
        onLoaded: root.loadNotes()
        onFileChanged: reload()
        onAdapterUpdated: writeAdapter()

        JsonAdapter { // qmllint disable unresolved-type
            id: notesAdapter
            property var notes: []
        }
    }

    // ── In-memory data ────────────────────────────────────────────────────────
    property var notesData: []     // source of truth: [{id, content, timestampMs, timestamp}]
    property string searchFilter: ""
    property bool searchVisible: false

    ListModel { id: displayModel }

    // ── Data helpers ──────────────────────────────────────────────────────────
    function loadNotes() {
        var parsed = notesAdapter.notes; // qmllint disable unqualified
        notesData = parsed instanceof Array ? parsed : [];
        refreshView(searchFilter);
    }

    function saveNotes() {
        // Assigning triggers onAdapterUpdated → writeAdapter() (persist to disk).
        notesAdapter.notes = notesData; // qmllint disable unqualified
    }

    function addNote(text) {
        var trimmed = text.trim();
        if (trimmed === "") return;
        var now = new Date();
        var note = {
            id: now.getTime() + Math.random(),
            content: trimmed,
            timestampMs: now.getTime(),
            timestamp: now.toLocaleString(Qt.locale(), "dd MMM yyyy  HH:mm")
        };
        // prepend so most-recent is first in the source array too
        var arr = notesData.slice();
        arr.unshift(note);
        notesData = arr;
        saveNotes();
        refreshView(searchFilter);
        Qt.callLater(function() { noteList.positionViewAtBeginning(); });
    }

    function deleteNote(noteId) {
        var arr = notesData.filter(function(n) { return n.id !== noteId; });
        notesData = arr;
        saveNotes();
        refreshView(searchFilter);
    }

    function clearAllNotes() {
        notesData = [];
        saveNotes();
        refreshView(searchFilter);
    }

    function refreshView(filter) {
        displayModel.clear();
        var f = filter ? filter.toLowerCase() : "";
        for (var i = 0; i < notesData.length; i++) {
            var n = notesData[i];
            if (f === "" || n.content.toLowerCase().indexOf(f) !== -1) {
                displayModel.append({
                    noteId: n.id,
                    noteContent: n.content,
                    noteTimestamp: n.timestamp
                });
            }
        }
    }

    Component.onCompleted: loadNotes()

    // ── Layout ────────────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6

        // Header row ──────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Text {
                text: "NOTES"
                font.family: "JetBrains Mono"
                font.pixelSize: 12
                font.bold: true
                color: Theme.accentColor
            }

            Text {
                text: root.notesData.length + " note" + (root.notesData.length !== 1 ? "s" : "")
                font.family: "JetBrains Mono"
                font.pixelSize: 11
                color: Theme.textInactive
            }

            Item { Layout.fillWidth: true }

            Text {
                text: root.searchVisible ? "[×]" : "[/]"
                font.family: "JetBrains Mono"
                font.pixelSize: 11
                color: searchToggleHover.containsMouse
                    ? Theme.accentColor
                    : (root.searchVisible ? Qt.darker(Theme.accentColor, 1.2) : Theme.textInactive)

                MouseArea {
                    id: searchToggleHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.searchVisible = !root.searchVisible;
                        if (!root.searchVisible) {
                            searchField.text = "";
                            root.searchFilter = "";
                            root.refreshView("");
                        } else {
                            Qt.callLater(function() { searchField.forceActiveFocus(); });
                        }
                    }
                }
            }

            Text {
                id: clearBtn
                text: "[clear all]"
                font.family: "JetBrains Mono"
                font.pixelSize: 11
                color: clearHover.containsMouse ? Theme.colorDanger : Theme.textInactive

                MouseArea {
                    id: clearHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.clearAllNotes()
                }
            }
        }

        // Input area ──────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 4

            Text {
                text: "+"
                font.family: "JetBrains Mono"
                font.pixelSize: 12
                color: Theme.accentColor
                Layout.alignment: Qt.AlignTop
                topPadding: 6
            }

            TextArea {
                id: inputArea
                Layout.fillWidth: true
                implicitHeight: Math.max(Math.min(contentHeight + topPadding + bottomPadding, 300), 1 * font.pixelSize * 1.4)
                topPadding: 6
                bottomPadding: 6
                leftPadding: 0
                wrapMode: TextEdit.Wrap
                placeholderText: "New note… (Enter to save, Shift+Enter for newline)"
                placeholderTextColor: Theme.placeholderColor
                font.family: "JetBrains Mono"
                font.pixelSize: 12
                color: Theme.accentColor
                background: Item {}
                selectByMouse: true

                Keys.onReturnPressed: (event) => {
                    if (event.modifiers & Qt.ShiftModifier) {
                        inputArea.insert(inputArea.cursorPosition, "\n");
                    } else {
                        root.addNote(inputArea.text);
                        inputArea.text = "";
                        event.accepted = true;
                    }
                }
            }
        }

        // Thin separator ──────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.dividerColor
        }

        // Search bar (toggle) ─────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 4
            visible: root.searchVisible

            Text {
                text: "/"
                font.family: "JetBrains Mono"
                font.pixelSize: 12
                color: Theme.accentColor
            }

            TextField {
                id: searchField
                Layout.fillWidth: true
                placeholderText: "search…"
                placeholderTextColor: Theme.placeholderColor
                font.family: "JetBrains Mono"
                font.pixelSize: 12
                color: Theme.accentColor
                background: Item {}
                leftPadding: 0
                onTextChanged: {
                    root.searchFilter = text;
                    root.refreshView(text);
                }
                Keys.onEscapePressed: {
                    root.searchVisible = false;
                    text = "";
                    root.searchFilter = "";
                    root.refreshView("");
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Theme.dividerColor
            visible: root.searchVisible
        }

        // Note list ───────────────────────────────────────────────────────────
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // Empty state
            Text {
                anchors.centerIn: parent
                visible: displayModel.count === 0
                text: root.searchFilter !== "" ? "No matching notes." : "No notes yet…"
                font.family: "JetBrains Mono"
                font.pixelSize: 12
                color: Theme.placeholderColor
            }

            ListView {
                id: noteList
                anchors.fill: parent
                clip: true
                spacing: 4
                model: displayModel

                delegate: Item {
                    id: noteItem
                    required property var noteId
                    required property string noteContent
                    required property string noteTimestamp
                    width: noteList.width
                    height: noteCol.height + 10

                    // Hover highlight
                    Rectangle {
                        anchors.fill: parent
                        color: delHover.containsMouse ? Theme.hoverOverlay : "transparent"
                        radius: 3
                    }

                    Column {
                        id: noteCol
                        anchors {
                            left: parent.left
                            right: parent.right
                            leftMargin: 4
                            rightMargin: 28
                            verticalCenter: parent.verticalCenter
                        }
                        spacing: 2

                        Text {
                            text: noteItem.noteTimestamp
                            font.family: "JetBrains Mono"
                            font.pixelSize: 10
                            color: Theme.textInactive
                            width: parent.width
                            elide: Text.ElideRight
                        }

                        TextEdit {
                            readOnly: true
                            selectByMouse: true
                            wrapMode: TextEdit.Wrap
                            text: noteItem.noteContent
                            font.family: "JetBrains Mono"
                            font.pixelSize: 12
                            color: Theme.textBody
                            width: parent.width
                            selectionColor: Theme.accentColor
                            selectedTextColor: Theme.selectedTextColor
                        }
                    }

                    // Delete button
                    Text {
                        id: delBtn
                        anchors {
                            right: parent.right
                            rightMargin: 4
                            verticalCenter: parent.verticalCenter
                        }
                        text: "×"
                        font.family: "JetBrains Mono"
                        font.pixelSize: 14
                        color: delHover.containsMouse ? Theme.colorDanger : Theme.textSubtle

                        MouseArea {
                            id: delHover
                            anchors.fill: parent
                            anchors.margins: -6
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.deleteNote(noteItem.noteId)
                        }
                    }
                }
            }
        }
    }
}
