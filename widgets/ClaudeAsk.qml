pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import "../services"

// Ce que Claude demande : une permission, ou ses questions, avec de quoi
// répondre. Sous la conversation (ClaudeConversation) et dans la liste des
// sessions (ClaudeView).
Rectangle {
    id: ask
    // { id, tool, title, text, detail, fields, actions }
    required property var request
    // Les demandes en attente, celle-ci comprise.
    property int count: 1
    // Dans une carte déjà encadrée : ni fond, ni marges.
    property bool flat: false
    readonly property int pad: ask.flat ? 0 : 12
    signal answered(string action, var values)

    // Les choix faits pour ses questions : { clé: option }.
    property var values: {
        var v = {};
        (ask.request.fields || []).forEach((f) => v[f.key] = f.value);
        return v;
    }
    implicitHeight: askCol.implicitHeight + 2 * ask.pad
    radius: Theme.radius
    color: ask.flat ? "transparent" : Theme.bgElevated
    border.width: ask.flat ? 0 : 1
    border.color: Qt.alpha(Theme.accentColor, 0.55)

    // Pas de réponse dans la demi-seconde où la demande apparaît : un double
    // clic sur la précédente ne valide pas la suivante, sans l'avoir lue.
    property bool armed: false
    onVisibleChanged: ask.armed = false
    Timer {
        interval: 500
        running: ask.visible && !ask.armed
        onTriggered: ask.armed = true
    }

    function reply(action) {
        if (!ask.armed)
            return;
        ask.answered(action, ask.values);
    }

    ColumnLayout {
        id: askCol
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: ask.pad
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Rectangle {
                implicitWidth: 8
                implicitHeight: 8
                radius: 4
                color: Theme.accentColor
            }
            Text {
                Layout.fillWidth: true
                text: ask.request.title
                wrapMode: Text.Wrap
                font.family: "Inter"
                font.pixelSize: 13
                font.weight: Font.DemiBold
                color: Theme.textPrimary
            }
            Text {
                visible: ask.count > 1
                text: "1 / " + ask.count
                font.family: "Inter"
                font.pixelSize: 11
                color: Theme.textDim
            }
        }
        Text {
            Layout.fillWidth: true
            visible: text !== ""
            text: ask.request.text
            wrapMode: Text.Wrap
            font.family: "Inter"
            font.pixelSize: 12
            color: Theme.textSecondary
        }
        // La commande, le fichier et ce qui y change.
        Rectangle {
            Layout.fillWidth: true
            visible: ask.request.detail !== ""
            implicitHeight: Math.min(180, askDetail.implicitHeight + 16)
            radius: Theme.radiusSmall
            color: Theme.bgDeep
            clip: true
            Flickable {
                anchors.fill: parent
                anchors.margins: 8
                contentHeight: askDetail.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                Text {
                    id: askDetail
                    width: parent.width
                    text: ask.request.detail
                    wrapMode: Text.WrapAnywhere
                    font.family: "JetBrains Mono"
                    font.pixelSize: 11
                    color: Theme.colorCyan
                }
            }
        }
        // Ses questions : une option à choisir pour chacune.
        Repeater {
            model: ask.request.fields || []
            ColumnLayout {
                id: question
                required property var modelData
                Layout.fillWidth: true
                spacing: 4
                Text {
                    Layout.fillWidth: true
                    text: question.modelData.label
                    wrapMode: Text.Wrap
                    font.family: "Inter"
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    color: Theme.textPrimary
                }
                Repeater {
                    model: question.modelData.options || []
                    Rectangle {
                        id: option
                        required property var modelData
                        readonly property bool picked: ask.values[question.modelData.key] === option.modelData.id
                        Layout.fillWidth: true
                        implicitHeight: optionCol.implicitHeight + 12
                        radius: Theme.radiusSmall
                        color: option.picked ? Theme.selectedFill : optionMa.containsMouse ? Theme.hoverOverlay : "transparent"
                        border.width: option.picked ? 1 : 0
                        border.color: Qt.alpha(Theme.accentColor, 0.5)
                        Column {
                            id: optionCol
                            x: 10
                            y: 6
                            width: parent.width - 20
                            Text {
                                width: parent.width
                                text: option.modelData.label
                                wrapMode: Text.Wrap
                                font.family: "Inter"
                                font.pixelSize: 12
                                color: Theme.textPrimary
                            }
                            Text {
                                width: parent.width
                                visible: (option.modelData.sub || "") !== ""
                                text: option.modelData.sub || ""
                                wrapMode: Text.Wrap
                                font.family: "Inter"
                                font.pixelSize: 11
                                color: Theme.textDim
                            }
                        }
                        MouseArea {
                            id: optionMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                var v = Object.assign({}, ask.values);
                                v[question.modelData.key] = option.modelData.id;
                                ask.values = v;
                            }
                        }
                    }
                }
            }
        }
        // Les boutons : refuser, toujours autoriser, autoriser.
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Item { Layout.fillWidth: true }
            Repeater {
                model: ask.request.actions || []
                Rectangle {
                    id: askBtn
                    required property var modelData
                    implicitWidth: askBtnText.implicitWidth + 22
                    implicitHeight: 30
                    radius: Theme.radiusSmall
                    color: askBtn.modelData.primary ? (askBtnMa.containsMouse ? Qt.lighter(Theme.accentColor, 1.1) : Theme.accentColor)
                         : askBtnMa.containsMouse ? Theme.hoverOverlay : "transparent"
                    border.width: askBtn.modelData.primary ? 0 : 1
                    border.color: askBtn.modelData.danger ? Qt.alpha(Theme.colorDanger, 0.5) : Theme.dividerColor
                    Text {
                        id: askBtnText
                        anchors.centerIn: parent
                        text: askBtn.modelData.label
                        font.family: "Inter"
                        font.pixelSize: 12
                        font.weight: Font.Medium
                        color: askBtn.modelData.primary ? Theme.selectedTextColor
                             : askBtn.modelData.danger ? Theme.colorDanger : Theme.textPrimary
                    }
                    MouseArea {
                        id: askBtnMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: ask.reply(askBtn.modelData.id)
                    }
                }
            }
        }
    }
}
