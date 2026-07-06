import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "../services"

Item {
    id: root

    property bool rainbowActive: false
    property real rainbowHue: 0.0

    // Set to false when rendered inside SettingsWindow (which provides its own title bar)
    property bool showInternalHeader: true

    // ── Palette editor state ──────────────────────────────────────
    property string selectedPaletteKey: ""
    readonly property var paletteKeyLabels: ({
        "base00": "fond sombre",    "base01": "fond élevé",
        "base02": "sélection",      "base03": "commentaires",
        "base04": "bord/statut",    "base05": "texte",
        "base06": "texte clair",    "base07": "fond clair",
        "base08": "erreur",         "base09": "alerte",
        "base0a": "ambre",          "base0b": "succès",
        "base0c": "cyan",           "base0d": "accent",
        "base0e": "mauve",          "base0f": "corail"
    })

    // ── Rainbow cycling timer ─────────────────────────────────────
    Timer {
        id: rainbowTimer
        interval: 100
        repeat: true
        running: root.rainbowActive
        onTriggered: {
            root.rainbowHue = (root.rainbowHue + 0.025) % 1.0
            colorPicker.pickerH = root.rainbowHue
            fieldCanvas.requestPaint()
            colorPicker.updateAccent()
        }
    }

    // ── UI ────────────────────────────────────────────────────────
    Flickable {
        anchors.fill: parent
        contentHeight: mainCol.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
        }

        ColumnLayout {
            id: mainCol
            width: parent.width
            spacing: 0

            // ── Header ───────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                Layout.bottomMargin: 8
                spacing: 8
                visible: root.showInternalHeader

                Text {
                    text: "Paramètres"
                    font.family: "JetBrains Mono"
                    font.pixelSize: 14
                    font.weight: Font.Bold
                    color: Theme.textPrimary
                    Layout.fillWidth: true
                }
            }

            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Theme.accentDark
                Layout.bottomMargin: 16
                visible: root.showInternalHeader
            }

            // ── APPARENCE section ──────────────────────────────
            Text {
                Layout.bottomMargin: 10
                text: "APPARENCE"
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                font.letterSpacing: 1.5
                color: Theme.accentMuted
            }

            // ── Dark / Light mode toggle ───────────────────────
            RowLayout {
                Layout.fillWidth: true
                Layout.bottomMargin: 12
                spacing: 8

                // Toggle pill
                Rectangle {
                    id: themePill
                    width: 44; height: 22; radius: 11
                    color: Theme.darkMode ? Theme.accentDark : Theme.accentColor
                    Behavior on color { ColorAnimation { duration: 200 } }

                    // Knob
                    Rectangle {
                        width: 16; height: 16; radius: 8
                        anchors.verticalCenter: parent.verticalCenter
                        x: Theme.darkMode ? 24 : 4
                        color: Theme.iconColor
                        Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Theme.toggleTheme()
                    }
                }

                Item { Layout.fillWidth: true }

                Text {
                    text: Theme.darkMode ? "Sombre" : "Clair"
                    font.family: "JetBrains Mono"
                    font.pixelSize: 11
                    color: Theme.textSecondary
                }
            }

            // Color preview chip + hex input
            RowLayout {
                Layout.fillWidth: true
                Layout.bottomMargin: 8
                spacing: 8

                Rectangle {
                    width: 24; height: 24; radius: 5
                    color: Theme.accentColor
                    border.color: Theme.dividerColor
                    border.width: 1
                }

                TextField {
                    id: hexField
                    Layout.fillWidth: true
                    text: Theme.accentColor.toString().toUpperCase()
                    font.family: "JetBrains Mono"
                    font.pixelSize: 12
                    color: Theme.textPrimary
                    leftPadding: 8; rightPadding: 8
                    selectByMouse: true
                    background: Rectangle {
                        color: Theme.bgInput
                        radius: 4
                        border.color: Theme.accentDark
                        border.width: 1
                    }
                    Connections {
                        target: Theme
                        function onAccentColorChanged() {
                            if (!hexField.activeFocus)
                                hexField.text = Theme.accentColor.toString().toUpperCase()
                        }
                    }
                    onEditingFinished: {
                        var t = text.trim()
                        if (!t.startsWith("#")) t = "#" + t
                        if (/^#[0-9a-fA-F]{6}$/.test(t) || /^#[0-9a-fA-F]{3}$/.test(t)) {
                            colorPicker.initFromColor(Qt.color(t))
                            Theme.setAccentColor(t.toLowerCase())
                        } else {
                            text = Theme.accentColor.toString().toUpperCase()
                        }
                    }
                }
            }

            // ── Color picker ─────────────────────────────────────
            Item {
                id: colorPicker
                Layout.fillWidth: true
                Layout.preferredHeight: 144  // 120 field + 8 gap + 14 hue + 2 padding
                Layout.bottomMargin: 16

                // Internal HSV state (0.0 – 1.0 each)
                property real pickerH: 0.667
                property real pickerS: 0.5
                property real pickerV: 0.56

                Component.onCompleted: initFromColor(Theme.accentColor)

                function initFromColor(c) {
                    var hsv = rgbToHsv(c.r, c.g, c.b)
                    pickerH = hsv.h
                    pickerS = hsv.s
                    pickerV = hsv.v
                }

                function rgbToHsv(r, g, b) {
                    var max = Math.max(r, g, b), min = Math.min(r, g, b)
                    var delta = max - min
                    var h = 0, s = 0, v = max
                    if (max > 0) s = delta / max
                    if (delta > 0) {
                        if (max === r)      h = ((g - b) / delta) % 6
                        else if (max === g) h = (b - r) / delta + 2
                        else               h = (r - g) / delta + 4
                        h /= 6
                        if (h < 0) h += 1
                    }
                    return { h: h, s: s, v: v }
                }

                function hsvToHex(h, s, v) {
                    var i = Math.floor(h * 6), f = h * 6 - i
                    var p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
                    var r, g, b
                    switch (i % 6) {
                        case 0: r = v; g = t; b = p; break
                        case 1: r = q; g = v; b = p; break
                        case 2: r = p; g = v; b = t; break
                        case 3: r = p; g = q; b = v; break
                        case 4: r = t; g = p; b = v; break
                        case 5: r = v; g = p; b = q; break
                    }
                    function x2h(n) { var s = Math.round(n * 255).toString(16); return s.length === 1 ? "0"+s : s }
                    return "#" + x2h(r) + x2h(g) + x2h(b)
                }

                function updateAccent() {
                    Theme.setAccentColor(hsvToHex(pickerH, pickerS, pickerV))
                }

                // Re-sync HSV when accent.hex is loaded (or changed externally),
                // but not while the user is actively dragging the picker.
                property bool userInteracting: false
                Connections {
                    target: Theme
                    function onAccentColorChanged() {
                        if (!colorPicker.userInteracting)
                            colorPicker.initFromColor(Theme.accentColor)
                    }
                }

                // ── Saturation / brightness field ─────────────────
                Canvas {
                    id: fieldCanvas
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 120

                    Connections {
                        target: colorPicker
                        function onPickerHChanged() { fieldCanvas.requestPaint() }
                    }

                    onPaint: {
                        var ctx = getContext("2d"), w = width, h = height
                        // Base: pure hue at full saturation + value
                        ctx.fillStyle = colorPicker.hsvToHex(colorPicker.pickerH, 1.0, 1.0)
                        ctx.fillRect(0, 0, w, h)
                        // White → transparent (left = white, right = saturated)
                        var wg = ctx.createLinearGradient(0, 0, w, 0)
                        wg.addColorStop(0.0, "rgba(255,255,255,1)")
                        wg.addColorStop(1.0, "rgba(255,255,255,0)")
                        ctx.fillStyle = wg; ctx.fillRect(0, 0, w, h)
                        // Transparent → black (top = bright, bottom = dark)
                        var bg = ctx.createLinearGradient(0, 0, 0, h)
                        bg.addColorStop(0.0, "rgba(0,0,0,0)")
                        bg.addColorStop(1.0, "rgba(0,0,0,1)")
                        ctx.fillStyle = bg; ctx.fillRect(0, 0, w, h)
                    }

                    // Crosshair cursor
                    Rectangle {
                        x: colorPicker.pickerS * fieldCanvas.width  - width  / 2
                        y: (1 - colorPicker.pickerV) * fieldCanvas.height - height / 2
                        width: 14; height: 14; radius: 7
                        color: "transparent"
                        border.color: Theme.iconColor; border.width: 2
                        antialiasing: true
                        Rectangle {
                            anchors.centerIn: parent
                            width: 6; height: 6; radius: 3
                            color: "transparent"
                            border.color: Qt.rgba(0, 0, 0, 0.55); border.width: 1
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.CrossCursor
                        function pick(mouse) {
                            colorPicker.pickerS = Math.max(0, Math.min(1, mouse.x / width))
                            colorPicker.pickerV = Math.max(0, Math.min(1, 1 - mouse.y / height))
                            colorPicker.updateAccent()
                        }
                        onPressed:         (mouse) => { colorPicker.userInteracting = true; pick(mouse) }
                        onReleased:        colorPicker.userInteracting = false
                        onPositionChanged: (mouse) => { if (pressed) pick(mouse) }
                    }
                }

                // ── Hue strip ─────────────────────────────────────
                Item {
                    id: hueRow
                    anchors.top: fieldCanvas.bottom
                    anchors.topMargin: 8
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 14

                    Canvas {
                        id: hueCanvas
                        anchors.fill: parent
                        onPaint: {
                            var ctx = getContext("2d")
                            var grad = ctx.createLinearGradient(0, 0, width, 0)
                            for (var i = 0; i <= 12; i++) {
                                var stop = i / 12
                                grad.addColorStop(stop, "hsl(" + Math.round(stop * 360) + ",100%,50%)")
                            }
                            var r = 4
                            ctx.beginPath()
                            ctx.moveTo(r, 0); ctx.lineTo(width - r, 0)
                            ctx.arcTo(width, 0,      width,      r,          r)
                            ctx.lineTo(width, height - r)
                            ctx.arcTo(width, height, width - r,  height,     r)
                            ctx.lineTo(r, height)
                            ctx.arcTo(0, height,     0,          height - r, r)
                            ctx.lineTo(0, r)
                            ctx.arcTo(0, 0,          r,          0,          r)
                            ctx.closePath()
                            ctx.fillStyle = grad; ctx.fill()
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            function pick(mouse) {
                                colorPicker.pickerH = Math.max(0, Math.min(0.9999, mouse.x / width))
                                fieldCanvas.requestPaint()
                                colorPicker.updateAccent()
                            }
                            onPressed:         (mouse) => { colorPicker.userInteracting = true; pick(mouse) }
                            onReleased:        colorPicker.userInteracting = false
                            onPositionChanged: (mouse) => { if (pressed) pick(mouse) }
                        }
                    }

                    // Thumb indicator
                    Rectangle {
                        x: colorPicker.pickerH * hueRow.width - width / 2
                        y: -2
                        width: 5; height: hueRow.height + 4; radius: 2.5
                        color: Theme.iconColor
                        border.color: Qt.rgba(0, 0, 0, 0.45); border.width: 1
                        antialiasing: true
                    }
                }
            }

            // ── Rainbow + Reset row ───────────────────────────
            RowLayout {
                Layout.fillWidth: true
                Layout.bottomMargin: 16
                spacing: 8

            // ── Rainbow cycling button ─────────────────────────
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 32

                // Rainbow gradient background
                Canvas {
                    id: rainbowBtnBg
                    anchors.fill: parent
                    onPaint: {
                        var ctx = getContext("2d")
                        var grad = ctx.createLinearGradient(0, 0, width, 0)
                        for (var i = 0; i <= 12; i++) {
                            grad.addColorStop(i / 12, "hsl(" + Math.round(i / 12 * 360) + ",90%,55%)")
                        }
                        var r = 8
                        ctx.beginPath()
                        ctx.moveTo(r, 0); ctx.lineTo(width - r, 0)
                        ctx.arcTo(width, 0,      width,      r,          r)
                        ctx.lineTo(width, height - r)
                        ctx.arcTo(width, height, width - r,  height,     r)
                        ctx.lineTo(r, height)
                        ctx.arcTo(0, height,     0,          height - r, r)
                        ctx.lineTo(0, r)
                        ctx.arcTo(0, 0,          r,          0,          r)
                        ctx.closePath()
                        ctx.fillStyle = grad
                        ctx.fill()
                    }
                }

                // Dimming overlay — lighter when active
                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    color: Theme.bgDeep
                    opacity: root.rainbowActive ? 0.10 : 0.50
                    Behavior on opacity { NumberAnimation { duration: 250 } }
                }

                // Active border glow
                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    color: "transparent"
                    border.color: Theme.iconColor
                    border.width: 1
                    opacity: root.rainbowActive ? 0.8 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 250 } }
                }

                // Icon + label
                Row {
                    anchors.centerIn: parent
                    spacing: 6

                    Text {
                        text: root.rainbowActive ? "Arrêter" : "Arc-en-ciel"
                        font.family: "JetBrains Mono"
                        font.pixelSize: 11
                        font.weight: Font.Medium
                        color: Theme.iconColor
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (!root.rainbowActive) {
                            // Start from current hue so it doesn't jump
                            root.rainbowHue = colorPicker.pickerH
                        }
                        root.rainbowActive = !root.rainbowActive
                    }
                }
            }

            // ── Reset to default button ───────────────────────
            Item {
                Layout.preferredWidth: 110
                Layout.preferredHeight: 32

                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    color: Theme.bgElevated
                    border.color: Theme.dividerColor
                    border.width: 1
                }

                Text {
                    anchors.centerIn: parent
                    text: "↺ Défaut"
                    font.family: "JetBrains Mono"
                    font.pixelSize: 11
                    font.weight: Font.Medium
                    color: Theme.textSecondary
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.rainbowActive = false
                        Theme.resetToDefaults()
                    }
                }
            }

            } // end RowLayout

            Item { Layout.preferredHeight: 8 }

            // ── Separator ─────────────────────────────────────────────────
            Rectangle {
                Layout.fillWidth: true
                height: 1
                color: Theme.dividerColor
                Layout.topMargin: 4
                Layout.bottomMargin: 16
            }

            // ── PALETTE BASE16 section ─────────────────────────────────────
            Text {
                Layout.bottomMargin: 10
                text: "PALETTE BASE16"
                font.family: "JetBrains Mono"
                font.pixelSize: 10
                font.letterSpacing: 1.5
                color: Theme.accentMuted
            }

            // ── 4×4 swatch grid ──────────────────────────────────────────
            GridLayout {
                Layout.fillWidth: true
                Layout.bottomMargin: 4
                columns: 4
                columnSpacing: 6
                rowSpacing: 4

                Repeater {
                    model: ["base00","base01","base02","base03",
                            "base04","base05","base06","base07",
                            "base08","base09","base0a","base0b",
                            "base0c","base0d","base0e","base0f"]
                    delegate: Item {
                        Layout.fillWidth: true
                        implicitHeight: paletteSwatchRect.height + paletteSwatchLabel.implicitHeight + 4

                        Rectangle {
                            id: paletteSwatchRect
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: 30
                            radius: 4
                            color: Theme.palette[modelData] || "#666666"
                            border.color: root.selectedPaletteKey === modelData
                                          ? Theme.iconColor : "transparent"
                            border.width: root.selectedPaletteKey === modelData ? 2 : 0

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (root.selectedPaletteKey === modelData) {
                                        root.selectedPaletteKey = ""
                                    } else {
                                        root.selectedPaletteKey = modelData
                                        // Initialise the inline picker from this swatch's color
                                        var c = Qt.color(Theme.palette[modelData] || "#666666")
                                        var max = Math.max(c.r, c.g, c.b)
                                        var min = Math.min(c.r, c.g, c.b)
                                        var delta = max - min
                                        var h = 0, s = 0, v = max
                                        if (max > 0) s = delta / max
                                        if (delta > 0) {
                                            if (max === c.r)      h = ((c.g - c.b) / delta) % 6
                                            else if (max === c.g) h = (c.b - c.r) / delta + 2
                                            else                   h = (c.r - c.g) / delta + 4
                                            h /= 6
                                            if (h < 0) h += 1
                                        }
                                        paletteColorPicker.pickerH = h
                                        paletteColorPicker.pickerS = s
                                        paletteColorPicker.pickerV = v
                                        paletteFieldCanvas.requestPaint()
                                    }
                                }
                            }
                        }

                        Text {
                            id: paletteSwatchLabel
                            anchors.top: paletteSwatchRect.bottom
                            anchors.topMargin: 3
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: modelData
                            font.family: "JetBrains Mono"
                            font.pixelSize: 8
                            color: root.selectedPaletteKey === modelData
                                   ? Theme.textPrimary : Theme.textDim
                        }
                    }
                }
            }

            // ── Inline palette color picker (collapses when nothing selected) ──
            Item {
                id: palettePickerWrapper
                Layout.fillWidth: true
                Layout.preferredHeight: root.selectedPaletteKey !== "" ? 168 : 0
                Layout.bottomMargin:    root.selectedPaletteKey !== "" ? 8   : 0
                clip: true
                opacity: root.selectedPaletteKey !== "" ? 1.0 : 0.0

                Behavior on Layout.preferredHeight {
                    NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                }
                Behavior on opacity { NumberAnimation { duration: 150 } }

                Item {
                    id: paletteColorPicker
                    anchors.fill: parent

                    property real pickerH: 0.0
                    property real pickerS: 0.5
                    property real pickerV: 0.5

                    function hsvToHex(h, s, v) {
                        var i = Math.floor(h * 6), f = h * 6 - i
                        var p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
                        var r, g, b
                        switch (i % 6) {
                            case 0: r = v; g = t; b = p; break
                            case 1: r = q; g = v; b = p; break
                            case 2: r = p; g = v; b = t; break
                            case 3: r = p; g = q; b = v; break
                            case 4: r = t; g = p; b = v; break
                            case 5: r = v; g = p; b = q; break
                        }
                        function x2h(n) { var s = Math.round(n * 255).toString(16); return s.length === 1 ? "0"+s : s }
                        return "#" + x2h(r) + x2h(g) + x2h(b)
                    }

                    function updateColor() {
                        Theme.setPaletteColor(root.selectedPaletteKey,
                                              hsvToHex(pickerH, pickerS, pickerV))
                    }

                    // Header: preview chip + key name + role + hex input
                    RowLayout {
                        id: palettePickerHeader
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 24
                        spacing: 6

                        Rectangle {
                            width: 16; height: 16; radius: 3
                            color: paletteColorPicker.hsvToHex(
                                       paletteColorPicker.pickerH,
                                       paletteColorPicker.pickerS,
                                       paletteColorPicker.pickerV)
                            border.color: Theme.dividerColor; border.width: 1
                        }

                        Text {
                            text: root.selectedPaletteKey
                            font.family: "JetBrains Mono"
                            font.pixelSize: 11
                            font.weight: Font.Medium
                            color: Theme.textPrimary
                        }

                        Text {
                            text: root.paletteKeyLabels[root.selectedPaletteKey] || ""
                            font.family: "JetBrains Mono"
                            font.pixelSize: 10
                            color: Theme.textSecondary
                        }

                        Item { Layout.fillWidth: true }

                        TextField {
                            id: paletteHexField
                            implicitWidth: 84
                            text: paletteColorPicker.hsvToHex(
                                      paletteColorPicker.pickerH,
                                      paletteColorPicker.pickerS,
                                      paletteColorPicker.pickerV).toUpperCase()
                            font.family: "JetBrains Mono"
                            font.pixelSize: 11
                            color: Theme.textPrimary
                            leftPadding: 6; rightPadding: 6
                            selectByMouse: true
                            background: Rectangle {
                                color: Theme.bgInput
                                radius: 4
                                border.color: Theme.accentDark
                                border.width: 1
                            }
                            Connections {
                                target: paletteColorPicker
                                function onPickerHChanged() { syncField() }
                                function onPickerSChanged() { syncField() }
                                function onPickerVChanged() { syncField() }
                                function syncField() {
                                    if (!paletteHexField.activeFocus)
                                        paletteHexField.text = paletteColorPicker.hsvToHex(
                                            paletteColorPicker.pickerH,
                                            paletteColorPicker.pickerS,
                                            paletteColorPicker.pickerV).toUpperCase()
                                }
                            }
                            onEditingFinished: {
                                var t = text.trim()
                                if (!t.startsWith("#")) t = "#" + t
                                if (/^#[0-9a-fA-F]{6}$/.test(t)) {
                                    var c = Qt.color(t)
                                    var max = Math.max(c.r, c.g, c.b)
                                    var min = Math.min(c.r, c.g, c.b)
                                    var delta = max - min
                                    var h = 0, s = 0, v = max
                                    if (max > 0) s = delta / max
                                    if (delta > 0) {
                                        if (max === c.r)      h = ((c.g - c.b) / delta) % 6
                                        else if (max === c.g) h = (c.b - c.r) / delta + 2
                                        else                   h = (c.r - c.g) / delta + 4
                                        h /= 6; if (h < 0) h += 1
                                    }
                                    paletteColorPicker.pickerH = h
                                    paletteColorPicker.pickerS = s
                                    paletteColorPicker.pickerV = v
                                    paletteFieldCanvas.requestPaint()
                                    Theme.setPaletteColor(root.selectedPaletteKey, t.toLowerCase())
                                } else {
                                    text = paletteColorPicker.hsvToHex(
                                               paletteColorPicker.pickerH,
                                               paletteColorPicker.pickerS,
                                               paletteColorPicker.pickerV).toUpperCase()
                                }
                            }
                        }
                    }

                    // Saturation / brightness field
                    Canvas {
                        id: paletteFieldCanvas
                        anchors.top: palettePickerHeader.bottom
                        anchors.topMargin: 8
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 96

                        Connections {
                            target: paletteColorPicker
                            function onPickerHChanged() { paletteFieldCanvas.requestPaint() }
                        }

                        onPaint: {
                            var ctx = getContext("2d"), w = width, h = height
                            ctx.fillStyle = paletteColorPicker.hsvToHex(paletteColorPicker.pickerH, 1.0, 1.0)
                            ctx.fillRect(0, 0, w, h)
                            var wg = ctx.createLinearGradient(0, 0, w, 0)
                            wg.addColorStop(0.0, "rgba(255,255,255,1)")
                            wg.addColorStop(1.0, "rgba(255,255,255,0)")
                            ctx.fillStyle = wg; ctx.fillRect(0, 0, w, h)
                            var bg = ctx.createLinearGradient(0, 0, 0, h)
                            bg.addColorStop(0.0, "rgba(0,0,0,0)")
                            bg.addColorStop(1.0, "rgba(0,0,0,1)")
                            ctx.fillStyle = bg; ctx.fillRect(0, 0, w, h)
                        }

                        Rectangle {
                            x: paletteColorPicker.pickerS * paletteFieldCanvas.width  - width  / 2
                            y: (1 - paletteColorPicker.pickerV) * paletteFieldCanvas.height - height / 2
                            width: 14; height: 14; radius: 7
                            color: "transparent"
                            border.color: Theme.iconColor; border.width: 2
                            antialiasing: true
                            Rectangle {
                                anchors.centerIn: parent
                                width: 6; height: 6; radius: 3
                                color: "transparent"
                                border.color: Qt.rgba(0, 0, 0, 0.55); border.width: 1
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.CrossCursor
                            function pick(mouse) {
                                paletteColorPicker.pickerS = Math.max(0, Math.min(1, mouse.x / width))
                                paletteColorPicker.pickerV = Math.max(0, Math.min(1, 1 - mouse.y / height))
                                paletteColorPicker.updateColor()
                            }
                            onPressed:         (mouse) => { pick(mouse) }
                            onPositionChanged: (mouse) => { if (pressed) pick(mouse) }
                        }
                    }

                    // Hue strip
                    Item {
                        id: paletteHueRow
                        anchors.top: paletteFieldCanvas.bottom
                        anchors.topMargin: 8
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 14

                        Canvas {
                            id: paletteHueCanvas
                            anchors.fill: parent
                            onPaint: {
                                var ctx = getContext("2d")
                                var grad = ctx.createLinearGradient(0, 0, width, 0)
                                for (var i = 0; i <= 12; i++) {
                                    var stop = i / 12
                                    grad.addColorStop(stop, "hsl(" + Math.round(stop * 360) + ",100%,50%)")
                                }
                                var r = 4
                                ctx.beginPath()
                                ctx.moveTo(r, 0); ctx.lineTo(width - r, 0)
                                ctx.arcTo(width, 0,      width,      r,          r)
                                ctx.lineTo(width, height - r)
                                ctx.arcTo(width, height, width - r,  height,     r)
                                ctx.lineTo(r, height)
                                ctx.arcTo(0, height,     0,          height - r, r)
                                ctx.lineTo(0, r)
                                ctx.arcTo(0, 0,          r,          0,          r)
                                ctx.closePath()
                                ctx.fillStyle = grad; ctx.fill()
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                function pick(mouse) {
                                    paletteColorPicker.pickerH = Math.max(0, Math.min(0.9999, mouse.x / width))
                                    paletteFieldCanvas.requestPaint()
                                    paletteColorPicker.updateColor()
                                }
                                onPressed:         (mouse) => { pick(mouse) }
                                onPositionChanged: (mouse) => { if (pressed) pick(mouse) }
                            }
                        }

                        Rectangle {
                            x: paletteColorPicker.pickerH * paletteHueRow.width - width / 2
                            y: -2
                            width: 5; height: paletteHueRow.height + 4; radius: 2.5
                            color: Theme.iconColor
                            border.color: Qt.rgba(0, 0, 0, 0.45); border.width: 1
                            antialiasing: true
                        }
                    }
                }
            }

            Item { Layout.preferredHeight: 8 }
        }
    }

}
