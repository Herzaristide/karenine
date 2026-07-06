import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell.Io
import "../services"

Item {
    id: root

    implicitHeight: controlsCol.implicitHeight + 16

    // ── Accent color picker state ──────────────────────────────────────────
    property bool colorPickerOpen: false
    property bool rainbowActive:   false
    property real rainbowHue:      0.0

    Timer {
        id: rainbowTimer
        interval: 100
        repeat:   true
        running:  root.rainbowActive
        onTriggered: {
            root.rainbowHue = (root.rainbowHue + 0.025) % 1.0
            accentPicker.pickerH = root.rainbowHue
            accentFieldCanvas.requestPaint()
            accentPicker.updateAccent()
        }
    }

    // ── State ──────────────────────────────────────────────────────────────
    property real  volumeLevel: 0.0
    property bool  isMuted:     false
    property string volString:   "vol  --"

    // ── wpctl get-volume ───────────────────────────────────────────────────
    Process {
        id: getVolProc
        command: ["sh", "-c", "wpctl get-volume @DEFAULT_AUDIO_SINK@"]
        stdout: StdioCollector { id: getVolOut }
        onRunningChanged: {
            if (!running) {
                var line = getVolOut.text.trim(); // e.g. "Volume: 0.75" or "Volume: 0.75 [MUTED]"
                var m = line.match(/Volume:\s*([\d.]+)(\s*\[MUTED\])?/);
                if (m) {
                    root.volumeLevel = parseFloat(m[1]);
                    root.isMuted     = m[2] !== undefined;
                    var pct = Math.round(root.volumeLevel * 100);
                    root.volString = root.isMuted
                        ? "vol  -- MUTED"
                        : "vol  " + pct + "%";
                }
            }
        }
    }

    // ── wpctl set-volume ───────────────────────────────────────────────────
    Process {
        id: setVolProc
        property string pendingCmd: ""
        command: ["sh", "-c", pendingCmd]
        onRunningChanged: {
            if (!running && !getVolProc.running) getVolProc.running = true;
        }
    }

    function volumeUp()   { setVolProc.pendingCmd = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+";    setVolProc.running = true; }
    function volumeDown() { setVolProc.pendingCmd = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-";    setVolProc.running = true; }
    function toggleMute() { setVolProc.pendingCmd = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";   setVolProc.running = true; }

    // ── grimblast screenshot ───────────────────────────────────────────────
    Process {
        id: shotProc
        property string pendingCmd: ""
        command: ["sh", "-c", pendingCmd]
        onRunningChanged: {
            if (!running) notifyProc.running = true;
        }
    }

    Process {
        id: notifyProc
        command: ["notify-send", "-i", "camera-photo", "Screenshot", "Saved to /tmp/"]
    }

    function takeScreenshot(region) {
        var ts   = Qt.formatDateTime(new Date(), "yyyyMMdd_HHmmss");
        var path = "/tmp/screenshot-" + ts + ".png";
        shotProc.pendingCmd = "grimblast copysave " + region + " '" + path + "'";
        shotProc.running    = true;
    }

    // ── wpctl status → parse sinks + sources ──────────────────────────────
    property var    sinks:           []
    property var    sources:         []
    property string pendingDeviceId: ""

    Process {
        id: statusProc
        command: [
            "sh", "-c",
            "wpctl status | awk '" +
            "/Sinks:/{sec=\"sink\"} /Sources:/{sec=\"source\"} /Filters:|Streams:|Video/{sec=\"\"} " +
            "sec&&/[0-9]+\\./{act=(index($0,\"*\")>0)?\"true\":\"false\"; line=$0; gsub(/^[^0-9]*/,\"\",line); id=line+0; " +
            "desc=line; sub(/^[0-9]+\\. */,\"\",desc); gsub(/ *\\[.*/,\"\",desc); gsub(/ *$/,\"\",desc); " +
            "print sec\"|\"id\"|\"act\"|\"desc}'" ]
        stdout: StdioCollector { id: statusOut }
        onRunningChanged: {
            if (!running) {
                const newSinks = [];
                const newSources = [];
                const lines = statusOut.text.trim().split('\n');
                for (const line of lines) {
                    if (!line) continue;
                    const parts = line.split('|');
                    if (parts.length < 4) continue;
                    const entry = { id: parts[1], active: parts[2] === "true", desc: parts.slice(3).join('|') };
                    if (parts[0] === "sink")   newSinks.push(entry);
                    if (parts[0] === "source") newSources.push(entry);
                }
                root.sinks   = newSinks;
                root.sources = newSources;
            }
        }
    }

    Process {
        id: setDefaultProc
        command: ["sh", "-c", "wpctl set-default \"$1\"", "--", root.pendingDeviceId]
        onRunningChanged: {
            if (!running && !statusProc.running) statusProc.running = true;
        }
    }

    function activeSinkName() {
        var a = sinks.find(function(s) { return s.active; });
        return a ? a.desc : (sinks.length ? sinks[0].desc : "—");
    }
    function activeSourceName() {
        var a = sources.find(function(s) { return s.active; });
        return a ? a.desc : (sources.length ? sources[0].desc : "—");
    }
    function cycleDevice(list, dir) {
        if (list.length === 0) return;
        var cur = list.findIndex(function(s) { return s.active; });
        var next = (cur + dir + list.length) % list.length;
        root.pendingDeviceId = list[next].id;
        setDefaultProc.running = true;
    }

    // ── Battery state ──────────────────────────────────────────────────────
    property bool   batteryPresent: false
    property int    batteryPercent: 0
    property string batteryStatus:  ""

    Process {
        id: batteryProc
        command: [
            "sh", "-c",
            "bat=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -n1); " +
            "if [ -n \"$bat\" ]; then " +
            "  cap=$(cat \"$bat/capacity\" 2>/dev/null); " +
            "  st=$(cat \"$bat/status\" 2>/dev/null); " +
            "  echo \"$cap|$st\"; " +
            "fi"
        ]
        stdout: StdioCollector { id: batteryOut }
        onRunningChanged: {
            if (!running) {
                var line = batteryOut.text.trim();
                if (line.length > 0) {
                    var parts = line.split('|');
                    root.batteryPercent = parseInt(parts[0]);
                    root.batteryStatus  = parts.length > 1 ? parts[1] : "";
                    root.batteryPresent = !isNaN(root.batteryPercent);
                } else {
                    root.batteryPresent = false;
                }
            }
        }
    }

    function batteryString() {
        if (!batteryPresent) return "";
        var sym = "";
        switch (batteryStatus) {
            case "Charging":     sym = "+"; break;
            case "Discharging":  sym = "-"; break;
            case "Full":         sym = "="; break;
            case "Not charging": sym = "~"; break;
            default:             sym = "?"; break;
        }
        return "bat  " + sym + " " + batteryPercent + "%";
    }

    // ── Refresh timer ──────────────────────────────────────────────────────
    Timer {
        interval: 3000
        repeat:   true
        running:  true
        onTriggered: {
            if (!getVolProc.running)  getVolProc.running  = true;
            if (!statusProc.running)  statusProc.running  = true;
            if (!batteryProc.running) batteryProc.running = true;
        }
    }

    Component.onCompleted: { getVolProc.running = true; statusProc.running = true; batteryProc.running = true; }

    // ── UI ─────────────────────────────────────────────────────────────────
    ColumnLayout {
        id: controlsCol
        anchors {
            left:   parent.left
            right:  parent.right
            top:    parent.top
            margins: 8
        }
        spacing: 6

        // Header row ─────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Text {
                text:            "CONTRÔLES"
                font.family:     "JetBrains Mono"
                font.pixelSize:  12
                font.bold:       true
                color:           Theme.accentColor
            }

            Item { Layout.fillWidth: true }

            // Dark / Light mode toggle pill
            Rectangle {
                id: themePill
                width: 32; height: 16; radius: 8
                color: Theme.darkMode ? Theme.accentDark : Theme.accentColor
                Behavior on color { ColorAnimation { duration: 200 } }
                Rectangle {
                    width: 10; height: 10; radius: 5
                    anchors.verticalCenter: parent.verticalCenter
                    x: Theme.darkMode ? 18 : 4
                    color: Theme.iconColor
                    Behavior on x { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
                }
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Theme.toggleTheme()
                }
            }

            // Accent color square
            Rectangle {
                id: accentSquare
                width: 16; height: 16; radius: 3
                color: Theme.accentColor
                border.color: accentSquareHover.containsMouse
                              ? Qt.rgba(Theme.iconColor.r, Theme.iconColor.g, Theme.iconColor.b, 0.6)
                              : Qt.rgba(Theme.iconColor.r, Theme.iconColor.g, Theme.iconColor.b, 0.25)
                border.width: 1
                Behavior on border.color { ColorAnimation { duration: 100 } }
                MouseArea {
                    id:           accentSquareHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape:  Qt.PointingHandCursor
                    onClicked: {
                        root.colorPickerOpen = !root.colorPickerOpen
                        if (root.colorPickerOpen)
                            accentPicker.initFromColor(Theme.accentColor)
                    }
                }
            }

            // Volume buttons
            Repeater {
                model: [
                    { label: "[−]",    action: function() { root.volumeDown(); } },
                    { label: "[+]",    action: function() { root.volumeUp();   } },
                    { label: root.isMuted ? "[unmute]" : "[mute]", action: function() { root.toggleMute(); } }
                ]

                delegate: Text {
                    required property var modelData
                    text:            modelData.label
                    font.family:     "JetBrains Mono"
                    font.pixelSize:  11
                    color:           btnHover.containsMouse ? Theme.accentColor : Theme.textInactive
                    Behavior on color { ColorAnimation { duration: 100 } }
                    MouseArea {
                        id:           btnHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape:  Qt.PointingHandCursor
                        onClicked:    modelData.action()
                    }
                }
            }

            // Settings button
            Text {
                text:        "[⚙]"
                font.family: "JetBrains Mono"
                font.pixelSize: 11
                color: Theme.settingsOpen
                       ? Theme.accentColor
                       : (settingsBtnHover.containsMouse ? Theme.accentColor : Theme.textInactive)
                Behavior on color { ColorAnimation { duration: 100 } }
                MouseArea {
                    id:           settingsBtnHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape:  Qt.PointingHandCursor
                    onClicked:    Theme.settingsOpen = !Theme.settingsOpen
                }
            }
        }

        // ── Accent color picker (collapsible) ────────────────────────────
        Item {
            id: accentPicker
            Layout.fillWidth: true
            Layout.preferredHeight: root.colorPickerOpen ? 162 : 0
            clip: true
            visible: root.colorPickerOpen

            Behavior on Layout.preferredHeight { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

            // ── Internal HSV state ─────────────────────────────────────
            property real pickerH: 0.667
            property real pickerS: 0.5
            property real pickerV: 0.56

            Component.onCompleted: initFromColor(Theme.accentColor)

            function initFromColor(c) {
                var hsv = rgbToHsv(c.r, c.g, c.b)
                pickerH = hsv.h; pickerS = hsv.s; pickerV = hsv.v
            }
            function rgbToHsv(r, g, b) {
                var max = Math.max(r, g, b), min = Math.min(r, g, b)
                var delta = max - min, h = 0, s = 0, v = max
                if (max > 0) s = delta / max
                if (delta > 0) {
                    if (max === r)      h = ((g - b) / delta) % 6
                    else if (max === g) h = (b - r) / delta + 2
                    else               h = (r - g) / delta + 4
                    h /= 6; if (h < 0) h += 1
                }
                return { h: h, s: s, v: v }
            }
            function hsvToHex(h, s, v) {
                var i = Math.floor(h * 6), f = h * 6 - i
                var p = v*(1-s), q = v*(1-f*s), t = v*(1-(1-f)*s)
                var r, g, b
                switch (i % 6) {
                    case 0: r=v; g=t; b=p; break; case 1: r=q; g=v; b=p; break
                    case 2: r=p; g=v; b=t; break; case 3: r=p; g=q; b=v; break
                    case 4: r=t; g=p; b=v; break; case 5: r=v; g=p; b=q; break
                }
                function x2h(n) { var s = Math.round(n*255).toString(16); return s.length===1?"0"+s:s }
                return "#" + x2h(r) + x2h(g) + x2h(b)
            }
            function updateAccent() {
                Theme.setAccentColor(hsvToHex(pickerH, pickerS, pickerV))
            }

            property bool userInteracting: false
            Connections {
                target: Theme
                function onAccentColorChanged() {
                    if (!accentPicker.userInteracting && !root.rainbowActive)
                        accentPicker.initFromColor(Theme.accentColor)
                }
            }

            ColumnLayout {
                anchors.fill: parent
                spacing: 4

                // Saturation / brightness field ──────────────────────────
                Canvas {
                    id: accentFieldCanvas
                    Layout.fillWidth: true
                    height: 100

                    Connections {
                        target: accentPicker
                        function onPickerHChanged() { accentFieldCanvas.requestPaint() }
                    }
                    onPaint: {
                        var ctx = getContext("2d"), w = width, h = height
                        ctx.fillStyle = accentPicker.hsvToHex(accentPicker.pickerH, 1.0, 1.0)
                        ctx.fillRect(0, 0, w, h)
                        var wg = ctx.createLinearGradient(0,0,w,0)
                        wg.addColorStop(0.0,"rgba(255,255,255,1)"); wg.addColorStop(1.0,"rgba(255,255,255,0)")
                        ctx.fillStyle=wg; ctx.fillRect(0,0,w,h)
                        var bg = ctx.createLinearGradient(0,0,0,h)
                        bg.addColorStop(0.0,"rgba(0,0,0,0)"); bg.addColorStop(1.0,"rgba(0,0,0,1)")
                        ctx.fillStyle=bg; ctx.fillRect(0,0,w,h)
                    }
                    // Crosshair
                    Rectangle {
                        x: accentPicker.pickerS * accentFieldCanvas.width  - width/2
                        y: (1-accentPicker.pickerV) * accentFieldCanvas.height - height/2
                        width:14; height:14; radius:7; color:"transparent"
                        border.color:Theme.iconColor; border.width:2; antialiasing:true
                        Rectangle { anchors.centerIn:parent; width:6; height:6; radius:3
                            color:"transparent"; border.color:Qt.rgba(0,0,0,0.55); border.width:1 }
                    }
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.CrossCursor
                        function pick(m) {
                            accentPicker.pickerS = Math.max(0, Math.min(1, m.x/width))
                            accentPicker.pickerV = Math.max(0, Math.min(1, 1-m.y/height))
                            accentPicker.updateAccent()
                        }
                        onPressed:  (m) => { accentPicker.userInteracting=true; pick(m) }
                        onReleased: accentPicker.userInteracting=false
                        onPositionChanged: (m) => { if(pressed) pick(m) }
                    }
                }

                // Hue strip ──────────────────────────────────────────────
                Item {
                    id: accentHueRow
                    Layout.fillWidth: true; height: 12
                    Canvas {
                        id: accentHueCanvas
                        anchors.fill: parent
                        onPaint: {
                            var ctx=getContext("2d"), grad=ctx.createLinearGradient(0,0,width,0)
                            for(var i=0;i<=12;i++) grad.addColorStop(i/12,"hsl("+Math.round(i/12*360)+",100%,50%)")
                            var r=4
                            ctx.beginPath(); ctx.moveTo(r,0); ctx.lineTo(width-r,0)
                            ctx.arcTo(width,0,width,r,r); ctx.lineTo(width,height-r)
                            ctx.arcTo(width,height,width-r,height,r); ctx.lineTo(r,height)
                            ctx.arcTo(0,height,0,height-r,r); ctx.lineTo(0,r)
                            ctx.arcTo(0,0,r,0,r); ctx.closePath()
                            ctx.fillStyle=grad; ctx.fill()
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            function pick(m) {
                                accentPicker.pickerH=Math.max(0,Math.min(0.9999,m.x/width))
                                accentFieldCanvas.requestPaint(); accentPicker.updateAccent()
                            }
                            onPressed:  (m)=>{ accentPicker.userInteracting=true; pick(m) }
                            onReleased: accentPicker.userInteracting=false
                            onPositionChanged: (m)=>{ if(pressed) pick(m) }
                        }
                    }
                    // Thumb
                    Rectangle {
                        x: accentPicker.pickerH * accentHueRow.width - width/2; y: -2
                        width:5; height:accentHueRow.height+4; radius:2.5
                        color:Theme.iconColor; border.color:Qt.rgba(0,0,0,0.45); border.width:1; antialiasing:true
                    }
                }

                // Hex input + rainbow row ────────────────────────────────
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    TextField {
                        id: accentHexField
                        Layout.fillWidth: true
                        text: Theme.accentColor.toString().toUpperCase()
                        font.family: "JetBrains Mono"; font.pixelSize: 11
                        color: Theme.textPrimary
                        leftPadding: 6; rightPadding: 6; topPadding: 3; bottomPadding: 3
                        selectByMouse: true
                        background: Rectangle {
                            color: Theme.bgInput; radius: 4
                            border.color: Theme.accentDark; border.width: 1
                        }
                        Connections {
                            target: Theme
                            function onAccentColorChanged() {
                                if (!accentHexField.activeFocus)
                                    accentHexField.text = Theme.accentColor.toString().toUpperCase()
                            }
                        }
                        onEditingFinished: {
                            var t = text.trim()
                            if (!t.startsWith("#")) t = "#" + t
                            if (/^#[0-9a-fA-F]{6}$/.test(t) || /^#[0-9a-fA-F]{3}$/.test(t)) {
                                accentPicker.initFromColor(Qt.color(t))
                                Theme.setAccentColor(t.toLowerCase())
                            } else {
                                text = Theme.accentColor.toString().toUpperCase()
                            }
                        }
                    }

                    // Rainbow toggle button
                    Item {
                        width: 72; height: 22
                        Canvas {
                            anchors.fill: parent
                            onPaint: {
                                var ctx=getContext("2d"), grad=ctx.createLinearGradient(0,0,width,0)
                                for(var i=0;i<=12;i++) grad.addColorStop(i/12,"hsl("+Math.round(i/12*360)+",90%,55%)")
                                var r=5
                                ctx.beginPath(); ctx.moveTo(r,0); ctx.lineTo(width-r,0)
                                ctx.arcTo(width,0,width,r,r); ctx.lineTo(width,height-r)
                                ctx.arcTo(width,height,width-r,height,r); ctx.lineTo(r,height)
                                ctx.arcTo(0,height,0,height-r,r); ctx.lineTo(0,r)
                                ctx.arcTo(0,0,r,0,r); ctx.closePath()
                                ctx.fillStyle=grad; ctx.fill()
                            }
                        }
                        Rectangle {
                            anchors.fill: parent; radius: 5; color: Theme.bgDeep
                            opacity: root.rainbowActive ? 0.10 : 0.45
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                        Rectangle {
                            anchors.fill: parent; radius: 5; color: "transparent"
                            border.color: Theme.iconColor; border.width: 1
                            opacity: root.rainbowActive ? 0.8 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 200 } }
                        }
                        Text {
                            anchors.centerIn: parent
                            text: root.rainbowActive ? "stop" : "rainbow"
                            font.family: "JetBrains Mono"; font.pixelSize: 10
                            color: Theme.iconColor
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                if (!root.rainbowActive) root.rainbowHue = accentPicker.pickerH
                                root.rainbowActive = !root.rainbowActive
                            }
                        }
                    }
                }
            }
        }

        // Volume readout ─────────────────────────────────────────────────
        Text {
            text:           root.volString
            font.family:    "JetBrains Mono"
            font.pixelSize: 11
            color:          root.isMuted ? Theme.textDim : Theme.textInactive
        }

        // Battery readout ────────────────────────────────────────────────
        Text {
            visible:        root.batteryPresent
            text:           root.batteryString()
            font.family:    "JetBrains Mono"
            font.pixelSize: 11
            color: {
                if (!root.batteryPresent) return Theme.textInactive;
                if (root.batteryStatus === "Charging" || root.batteryStatus === "Full")
                    return Theme.accentColor;
                if (root.batteryPercent <= 15) return Theme.colorDanger;
                if (root.batteryPercent <= 30) return Theme.textDim;
                return Theme.textInactive;
            }
        }

        // Screenshot row ─────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Text {
                text:           "CAPTURE"
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                font.bold:      true
                color:          Theme.textInactive
            }

            Item { Layout.fillWidth: true }

            Repeater {
                model: [
                    { label: "[screenshot]", region: "screen" },
                    { label: "[zone]",       region: "area"   }
                ]

                delegate: Text {
                    required property var modelData
                    text:           modelData.label
                    font.family:    "JetBrains Mono"
                    font.pixelSize: 11
                    color:          shotBtnHover.containsMouse ? Theme.accentColor : Theme.textInactive
                    Behavior on color { ColorAnimation { duration: 100 } }
                    MouseArea {
                        id:           shotBtnHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape:  Qt.PointingHandCursor
                        onClicked:    root.takeScreenshot(modelData.region)
                    }
                }
            }
        }

        // Output device row ────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Text {
                text:           "SORTIE"
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                font.bold:      true
                color:          Theme.textInactive
            }

            Text {
                Layout.fillWidth: true
                text:           root.activeSinkName()
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                color:          Theme.textBody
                elide:          Text.ElideRight
            }

            Text {
                text:           "[<]"
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                color:          sinkPrevHover.containsMouse ? Theme.accentColor : Theme.textInactive
                Behavior on color { ColorAnimation { duration: 100 } }
                MouseArea {
                    id:           sinkPrevHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape:  Qt.PointingHandCursor
                    onClicked:    root.cycleDevice(root.sinks, -1)
                }
            }

            Text {
                text:           "[>]"
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                color:          sinkNextHover.containsMouse ? Theme.accentColor : Theme.textInactive
                Behavior on color { ColorAnimation { duration: 100 } }
                MouseArea {
                    id:           sinkNextHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape:  Qt.PointingHandCursor
                    onClicked:    root.cycleDevice(root.sinks, 1)
                }
            }
        }

        // Input device row ─────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            spacing: 6

            Text {
                text:           "ENTRÉE"
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                font.bold:      true
                color:          Theme.textInactive
            }

            Text {
                Layout.fillWidth: true
                text:           root.activeSourceName()
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                color:          Theme.textBody
                elide:          Text.ElideRight
            }

            Text {
                text:           "[<]"
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                color:          srcPrevHover.containsMouse ? Theme.accentColor : Theme.textInactive
                Behavior on color { ColorAnimation { duration: 100 } }
                MouseArea {
                    id:           srcPrevHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape:  Qt.PointingHandCursor
                    onClicked:    root.cycleDevice(root.sources, -1)
                }
            }

            Text {
                text:           "[>]"
                font.family:    "JetBrains Mono"
                font.pixelSize: 11
                color:          srcNextHover.containsMouse ? Theme.accentColor : Theme.textInactive
                Behavior on color { ColorAnimation { duration: 100 } }
                MouseArea {
                    id:           srcNextHover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape:  Qt.PointingHandCursor
                    onClicked:    root.cycleDevice(root.sources, 1)
                }
            }
        }

        // Bottom separator ───────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height:           1
            color:            Theme.dividerColor
            Layout.topMargin: 2
        }
    }
}
