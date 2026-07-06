import QtQuick
import QtQuick.Layouts
import "../services"

// AIPanel: hosts the two AI backends behind a small switch. Index 0 is the
// local Ollama chat (with its tools), index 1 is Claude Code. The bar's
// "AI" button opens this panel; the toggle below picks which engine answers.
Item {
    id: aiPanel

    // 0 = Ollama, 1 = Claude Code
    property int backend: 0

    ColumnLayout {
        anchors.fill: parent
        spacing: 6

        // ── Backend switch ───────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 12

            Text {
                text: "ollama"
                font.family: "JetBrains Mono"
                font.pixelSize: 11
                font.bold: aiPanel.backend === 0
                color: aiPanel.backend === 0 ? Theme.accentColor : Theme.textInactive
                opacity: ollamaMa.containsMouse || aiPanel.backend === 0 ? 1.0 : 0.6

                MouseArea {
                    id: ollamaMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: aiPanel.backend = 0
                }
            }

            Text {
                text: "claude"
                font.family: "JetBrains Mono"
                font.pixelSize: 11
                font.bold: aiPanel.backend === 1
                color: aiPanel.backend === 1 ? Theme.accentColor : Theme.textInactive
                opacity: claudeMa.containsMouse || aiPanel.backend === 1 ? 1.0 : 0.6

                MouseArea {
                    id: claudeMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: aiPanel.backend = 1
                }
            }

            Item { Layout.fillWidth: true }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: aiPanel.backend

            OllamaChat {}
            ClaudeChat {}
        }
    }
}
