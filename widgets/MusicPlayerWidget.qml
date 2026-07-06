pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell.Io
import Quickshell.Services.Mpris
import "../services"

Item {
    id: root

    // ── Active player selection ──────────────────────────────────────────
    // Prefer the first player that is currently Playing, otherwise the first
    // available player. Re-evaluated reactively whenever the list or any
    // player's playbackState changes.
    property var player: {
        var list = Mpris.players ? Mpris.players.values : [];
        if (!list || list.length === 0) return null;
        for (var i = 0; i < list.length; ++i) {
            if (list[i].playbackState === MprisPlaybackState.Playing) return list[i];
        }
        return list[0];
    }

    readonly property bool hasPlayer: player !== null && player !== undefined
    readonly property bool isPlaying: hasPlayer && player.playbackState === MprisPlaybackState.Playing

    // ── Real-time audio spectrum from cava (9 bars, 0–100) ─────────────
    property var eqLevels: [0,0,0,0,0,0,0,0,0]

    Process {
        id: cavaProc
        running: root.isPlaying
        command: [
            "sh", "-c",
            "mkdir -p /tmp/qs-music && cat > /tmp/qs-music/cava.conf <<'EOF'\n" +
            "[general]\nbars = 9\nframerate = 60\n" +
            "[input]\nmethod = pulse\nsource = auto\n" +
            "[output]\nmethod = raw\ndata_format = ascii\nascii_max_range = 100\nchannels = mono\n" +
            "[smoothing]\nnoise_reduction = 35\n" +
            "EOF\nexec cava -p /tmp/qs-music/cava.conf"
        ]
        stdout: SplitParser {
            onRead: (line) => {
                var parts = line.trim().split(';');
                var arr = [];
                for (var i = 0; i < 9; i++) {
                    var v = parseInt(parts[i]);
                    arr.push(isNaN(v) ? 0 : v);
                }
                root.eqLevels = arr;
            }
        }
        // Reset bars when audio stops streaming
        onRunningChanged: if (!running) root.eqLevels = [0,0,0,0,0,0,0,0,0]
    }

    // ── Vinyl disc rotation (25 fps) ──────────────────────────────────
    property real vinylRotation: 0

    Timer {
        running: root.isPlaying
        interval: 40
        repeat: true
        onTriggered: root.vinylRotation = (root.vinylRotation + 0.8) % 360
    }

    // ── Track-change accent flash ──────────────────────────────────────
    property string currentTrackId: hasPlayer
        ? ((player.trackTitle || "") + "|" + (player.trackArtist || ""))
        : ""
    onCurrentTrackIdChanged: flashAnim.restart()

    SequentialAnimation {
        id: flashAnim
        NumberAnimation { target: trackFlash; property: "opacity"; to: 0.25; duration: 100 }
        NumberAnimation { target: trackFlash; property: "opacity"; to: 0.0; duration: 600; easing.type: Easing.OutCubic }
    }

    // ── Lyrics ───────────────────────────────────────────────────────────
    property bool   showLyrics:    false
    property string lyricsText:    ""    // plain-text fallback
    property bool   lyricsLoading: false
    property bool   isSynced:      false  // true when LRC timestamps available
    property var    lyricLines:    []     // [{t: seconds, text: string}] sorted

    // Active line index — re-evaluates on every position tick
    readonly property int currentLyricIndex: {
        if (!isSynced || !hasPlayer || lyricLines.length === 0) return -1;
        var pos = player.position;
        var idx = 0;
        for (var i = 0; i < lyricLines.length; i++) {
            if (lyricLines[i].t <= pos) idx = i; else break;
        }
        return idx;
    }

    // Resets state and fires a fresh LRCLIB fetch
    function startLyricsFetch() {
        lyricsText    = "";
        lyricLines    = [];
        isSynced      = false;
        lyricsLoading = true;
        lyricsFetcher.pendingArtist = player.trackArtist;
        lyricsFetcher.pendingTitle  = player.trackTitle;
        Qt.callLater(function() { lyricsFetcher.running = true; });
    }

    onShowLyricsChanged: {
        if (showLyrics && !lyricsLoading
                && hasPlayer && player.trackTitle && player.trackArtist
                && lyricsText.length === 0 && lyricLines.length === 0) {
            startLyricsFetch();
        }
    }

    // Re-fetch when the track changes (only if the panel is open)
    property string trackId: hasPlayer && player.trackTitle
                             ? (player.trackArtist + "|||" + player.trackTitle) : ""
    onTrackIdChanged: {
        lyricsText    = "";
        lyricLines    = [];
        isSynced      = false;
        lyricsLoading = false;
        lyricsFetcher.running = false;
        if (showLyrics && hasPlayer && player.trackTitle && player.trackArtist)
            startLyricsFetch();
    }

    // Parses LRC lines into [{t: seconds, text}] sorted by time
    function parseLrc(lines) {
        var result = [];
        for (var i = 0; i < lines.length; i++) {
            var m = lines[i].match(/^\[(\d{2}):(\d{2}[.,]\d{2,3})\]\s*(.*)/);
            if (m) {
                var secs = parseInt(m[1]) * 60 + parseFloat(m[2].replace(',', '.'));
                result.push({ t: secs, text: m[3] });
            }
        }
        result.sort(function(a, b) { return a.t - b.t; });
        return result;
    }

    // Fetches from LRCLIB (synced LRC preferred, plain fallback).
    // First stdout line is a mode tag: "SYNCED", "PLAIN", or "NOTFOUND".
    Process {
        id: lyricsFetcher
        property string pendingArtist: ""
        property string pendingTitle:  ""
        property string rawOutput:     ""
        command: [
            "sh", "-c",
            `jq -rn --arg a "$1" --arg t "$2" '"https://lrclib.net/api/get?artist_name=\\($a | @uri)&track_name=\\($t | @uri)"' | xargs curl -sf --connect-timeout 6 --max-time 10 | jq -r 'if ((.syncedLyrics // "") | length) > 0 then "SYNCED\\n" + .syncedLyrics elif ((.plainLyrics // "") | length) > 0 then "PLAIN\\n" + .plainLyrics else "NOTFOUND" end' || echo "NOTFOUND"`,
            "--", pendingArtist, pendingTitle
        ]
        stdout: SplitParser {
            onRead: (line) => {
                lyricsFetcher.rawOutput += (lyricsFetcher.rawOutput.length > 0 ? "\n" : "") + line;
            }
        }
        onRunningChanged: {
            if (running) { rawOutput = ""; return; }
            var lines = rawOutput.length > 0 ? rawOutput.split("\n") : [];
            rawOutput = "";
            if (lines.length === 0 || lines[0] === "NOTFOUND") {
                root.lyricsText = "No lyrics found.";
            } else if (lines[0] === "SYNCED") {
                var parsed = root.parseLrc(lines.slice(1));
                if (parsed.length > 0) {
                    root.lyricLines = parsed;
                    root.isSynced   = true;
                } else {
                    root.lyricsText = lines.slice(1).join("\n") || "No lyrics found.";
                }
            } else if (lines[0] === "PLAIN") {
                root.lyricsText = lines.slice(1).join("\n") || "No lyrics found.";
            } else {
                root.lyricsText = lines.join("\n") || "No lyrics found.";
            }
            root.lyricsLoading = false;
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────
    function fmtTime(seconds) {
        if (!seconds || seconds < 0 || !isFinite(seconds)) return "0:00";
        var s = Math.floor(seconds);
        var m = Math.floor(s / 60);
        var r = s % 60;
        return m + ":" + (r < 10 ? "0" : "") + r;
    }

    // Local position ticker — Mpris.position only updates on demand, so we
    // poll it gently while playing for a smooth progress bar.
    Timer {
        running: root.isPlaying
        interval: 500
        repeat: true
        onTriggered: if (root.hasPlayer) root.player.positionChanged()
    }



    Rectangle {
        id: trackFlash
        anchors.fill: parent
        color: Theme.accentColor
        opacity: 0.0
    }

    // ══════════════════════════════════════════════════════════════════════
    // MAIN CONTENT
    // ══════════════════════════════════════════════════════════════════════
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 16

        // Top spacer — keeps the widget vertically centered in the panel
        Item { Layout.fillHeight: true }

        // ── Vinyl disc ───────────────────────────────────────────────
        Item {
            id: vinylContainer
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: Math.min(parent.width - 16, 186)
            Layout.preferredHeight: width

            // Gesture state for click/drag interactions on the disc
            property real pressX: 0
            property real dragDx: 0
            property bool dragging: false
            readonly property real dragThreshold: 12
            // Animated horizontal offset applied to the vinyl disc via Translate
            property real discOffset: 0

            // Single wrapper so rings + disc all move with one Translate
            Item {
                id: vinylCarousel
                anchors.fill: parent
                transform: Translate { x: vinylContainer.discOffset }
                opacity: root.showLyrics ? 0 : 1
                visible: opacity > 0.001
                scale: vinylContainer.dragging ? 0.94 : 1.0
                Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                Behavior on scale   { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                // Outer counter-rotating ring
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width + 22; height: parent.height + 22; radius: width / 2
                    color: "transparent"
                    border.width: 1; border.color: Theme.accentColor
                    opacity: root.isPlaying ? 0.45 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

                    RotationAnimator on rotation {
                        running: root.isPlaying && !root.showLyrics
                        from: 0; to: -360; duration: 14000; loops: Animation.Infinite
                    }
                }

                // Inner pulsing ring
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width + 8; height: parent.height + 8; radius: width / 2
                    color: "transparent"
                    border.width: 2; border.color: Theme.accentColor
                    opacity: root.isPlaying ? 0.30 : 0.0
                    Behavior on opacity { NumberAnimation { duration: 320 } }

                    SequentialAnimation on scale {
                        running: root.isPlaying && !root.showLyrics; loops: Animation.Infinite
                        NumberAnimation { from: 1.0; to: 1.04; duration: 860; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 1.04; to: 1.0; duration: 860; easing.type: Easing.InOutSine }
                    }
                }

                // Disc body (rotates with the art)
                Item {
                    id: vinylDisc
                    anchors.fill: parent
                    rotation: root.vinylRotation
                }
            }

            // Snap back to center after a short (non-skip) drag
            NumberAnimation {
                id: snapBackAnim
                target: vinylContainer
                property: "discOffset"
                to: 0
                duration: 220
                easing.type: Easing.OutCubic
            }

            // Slide-out + slide-in animation for track skips. Mirrors the swipe
            // direction so the listener sees one record leaving and the next
            // arriving from the opposite side.
            SequentialAnimation {
                id: skipAnim
                property int direction: 1   // +1 = drag right, -1 = drag left
                property bool isPrev: false

                NumberAnimation {
                    target: vinylContainer
                    property: "discOffset"
                    to: skipAnim.direction * vinylContainer.width
                    duration: 220
                    easing.type: Easing.InCubic
                }
                ScriptAction {
                    script: {
                        if (root.hasPlayer) {
                            if (skipAnim.isPrev) {
                                if (root.player.canGoPrevious) root.player.previous();
                            } else {
                                if (root.player.canGoNext) root.player.next();
                            }
                        }
                        // Reposition off the opposite edge so the new disc can
                        // glide in from the side the swipe came from.
                        vinylContainer.discOffset = -skipAnim.direction * vinylContainer.width;
                    }
                }
                NumberAnimation {
                    target: vinylContainer
                    property: "discOffset"
                    to: 0
                    duration: 320
                    easing.type: Easing.OutCubic
                }
            }

            // Original disc content lives inside vinylDisc — keep wrapping it.
            Item {
                id: vinylDiscContent
                parent: vinylDisc
                anchors.fill: parent

                // Black circular base (vinyl)
                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: Theme.bgDeep
                }

                // Decorative groove rings (no-art state)
                Repeater {
                    model: 5
                    Rectangle {
                        required property int index
                        anchors.centerIn: parent
                        width: parent.width * (0.28 + index * 0.14); height: width; radius: width / 2
                        color: "transparent"
                        border.width: 0.5
                        border.color: Qt.rgba(1, 1, 1, 0.04 + index * 0.025)
                        visible: discArt.status !== Image.Ready
                    }
                }

                // High-resolution album art — source for the masked render.
                // Use opacity:0 (not visible:false) so the scene graph keeps the
                // layer texture alive; visible:false lets Qt cull the node and
                // the cached layer texture gets dropped after a while.
                Image {
                    id: discArt
                    anchors.fill: parent
                    source: root.hasPlayer && root.player.trackArtUrl ? root.player.trackArtUrl : ""
                    sourceSize.width: 1024
                    sourceSize.height: 1024
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    smooth: true
                    mipmap: true
                    cache: true
                    opacity: 0
                    layer.enabled: true
                    layer.smooth: true
                    layer.mipmap: true
                    layer.textureSize: Qt.size(1024, 1024)

                    onSourceChanged: { artScale.scale = 1.07; artScaleAnim.restart(); }
                }

                // Circular mask source
                Item {
                    id: discMask
                    anchors.fill: parent
                    opacity: 0
                    layer.enabled: true
                    layer.smooth: true
                    layer.textureSize: Qt.size(1024, 1024)
                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: "white"
                        antialiasing: true
                    }
                }

                // Wrapper providing the entrance scale animation
                Item {
                    id: artScale
                    anchors.fill: parent

                    MultiEffect {
                        anchors.fill: parent
                        source: discArt
                        maskEnabled: true
                        maskSource: discMask
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                        opacity: discArt.status === Image.Ready ? 1.0 : 0.0
                        Behavior on opacity { NumberAnimation { duration: 350; easing.type: Easing.OutCubic } }
                    }

                    NumberAnimation on scale {
                        id: artScaleAnim
                        from: 1.07; to: 1.0
                        duration: 380; easing.type: Easing.OutCubic
                        running: false
                    }
                }

                // Radial vignette over art (clipped to circle naturally)
                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    visible: discArt.status === Image.Ready
                    color: "transparent"
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.06) }
                        GradientStop { position: 0.6; color: "transparent"          }
                        GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.45) }
                    }
                }

                // Placeholder note icon (no art)
                Text {
                    anchors.centerIn: parent
                    visible: discArt.status !== Image.Ready
                    text: "♪"; font.pixelSize: parent.width * 0.35
                    color: Theme.iconColor; opacity: 0.22
                }

                // Center spindle hole
                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width * 0.10; height: width; radius: width / 2
                    color: Theme.bgDeep
                    border.width: 2
                    border.color: Qt.rgba(Theme.accentColor.r, Theme.accentColor.g, Theme.accentColor.b, 0.80)
                    z: 10
                }
            }

            // Pause indicator overlay (fades in when halted)
            Rectangle {
                anchors.centerIn: parent
                width: 52; height: 52; radius: 26
                color: Qt.rgba(0, 0, 0, 0.58)
                opacity: !root.showLyrics && root.hasPlayer && !root.isPlaying && !vinylContainer.dragging ? 0.92 : 0.0
                Behavior on opacity { NumberAnimation { duration: 260 } }

                Text {
                    anchors.centerIn: parent
                    text: root.hasPlayer ? "⏸" : "♪"
                    font.pixelSize: 20; color: "white"
                }
            }

            // Drag direction hint (◮ previous / ◭ next — swipe right pulls in
            // the previous track from the left, swipe left brings the next one)
            Rectangle {
                anchors.centerIn: parent
                width: 52; height: 52; radius: 26
                color: Qt.rgba(0, 0, 0, 0.58)
                readonly property bool show:
                    vinylContainer.dragging
                    && Math.abs(vinylContainer.dragDx) > vinylContainer.dragThreshold
                opacity: show ? 0.92 : 0.0
                Behavior on opacity { NumberAnimation { duration: 160 } }

                Text {
                    anchors.centerIn: parent
                    text: vinylContainer.dragDx > 0 ? "⏮" : "⏭"
                    font.pixelSize: 22; color: "white"
                }
            }

            // Gesture surface: click toggles play/pause, horizontal drag skips
            // tracks (drag right → previous, drag left → next).
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                enabled: root.hasPlayer && !skipAnim.running
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                preventStealing: true

                onPressed: (mouse) => {
                    snapBackAnim.stop();
                    vinylContainer.discOffset = 0;
                    vinylContainer.pressX = mouse.x;
                    vinylContainer.dragDx = 0;
                    vinylContainer.dragging = true;
                }
                onPositionChanged: (mouse) => {
                    if (vinylContainer.dragging) {
                        vinylContainer.dragDx = mouse.x - vinylContainer.pressX;
                        vinylContainer.discOffset = vinylContainer.dragDx * 0.6;
                    }
                }
                onReleased: (mouse) => {
                    var dx = vinylContainer.dragDx;
                    var t = vinylContainer.dragThreshold;
                    vinylContainer.dragging = false;
                    vinylContainer.dragDx = 0;
                    if (!root.hasPlayer) {
                        snapBackAnim.restart();
                        return;
                    }
                    if (Math.abs(dx) < t) {
                        snapBackAnim.restart();
                        root.player.togglePlaying();
                    } else {
                        // dx > 0 (swipe right) → previous, dx < 0 → next
                        skipAnim.direction = dx > 0 ? 1 : -1;
                        skipAnim.isPrev = dx > 0;
                        skipAnim.start();
                    }
                }
                onCanceled: {
                    vinylContainer.dragging = false;
                    vinylContainer.dragDx = 0;
                    snapBackAnim.restart();
                }
            }
        }

        // ── Animated EQ bars ─────────────────────────────────────────
        Row {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredHeight: 36
            spacing: 4
            opacity: root.showLyrics ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

            Repeater {
                model: 9
                delegate: Item {
                    required property int index
                    width: 6; height: 36

                    // 0..1 normalized level for this bar from cava
                    readonly property real level: Math.max(0, Math.min(1,
                        (root.eqLevels[index] || 0) / 100))

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        // 3 px floor + audio-driven amplitude up to bar height
                        height: 3 + parent.level * (parent.height - 3)
                        radius: 3
                        color: Theme.accentColor
                        opacity: root.isPlaying ? (0.55 + parent.level * 0.45) : 0.22
                        Behavior on height { NumberAnimation { duration: 80; easing.type: Easing.OutCubic } }
                        Behavior on opacity { NumberAnimation { duration: 220 } }
                    }
                }
            }
        }

        // ── Chromagram (12 pitch classes of currently playing audio) ──
        ChromaGraph {
            Layout.fillWidth: true
            Layout.preferredHeight: 70
            active: root.isPlaying
            opacity: root.showLyrics ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        }

        // ── Title + Artist ───────────────────────────────────────────
        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignHCenter
            spacing: 4
            opacity: root.showLyrics ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

            // Marquee title
            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: titleText.implicitHeight
                clip: true

                Text {
                    id: titleText
                    text: root.hasPlayer && root.player.trackTitle ? root.player.trackTitle : "Nothing playing"
                    font.family: "JetBrains Mono"
                    font.pixelSize: 16
                    font.weight: Font.Medium
                    color: Theme.textPrimary
                    elide: Text.ElideNone
                    wrapMode: Text.NoWrap

                    property bool overflows: paintedWidth > parent.width

                    x: overflows ? marqueeX : (parent.width - paintedWidth) / 2
                    property real marqueeX: 0

                    SequentialAnimation on marqueeX {
                        running: titleText.overflows
                        loops: Animation.Infinite
                        PauseAnimation { duration: 1500 }
                        NumberAnimation {
                            from: 0
                            to: -(titleText.paintedWidth - titleText.parent.width + 8)
                            duration: Math.max(2000, titleText.paintedWidth * 18)
                            easing.type: Easing.InOutQuad
                        }
                        PauseAnimation { duration: 1500 }
                        NumberAnimation {
                            from: -(titleText.paintedWidth - titleText.parent.width + 8)
                            to: 0
                            duration: Math.max(2000, titleText.paintedWidth * 18)
                            easing.type: Easing.InOutQuad
                        }
                    }

                    Behavior on opacity { NumberAnimation { duration: 250 } }
                }
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: root.hasPlayer && root.player.trackArtist ? root.player.trackArtist : "—"
                font.family: "JetBrains Mono"
                font.pixelSize: 12
                color: Theme.textSecondary
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: root.hasPlayer && root.player.trackAlbum ? root.player.trackAlbum : ""
                visible: text !== ""
                font.family: "JetBrains Mono"
                font.pixelSize: 11
                color: Theme.textDim
                elide: Text.ElideRight
            }
        }

        // ── Progress bar ─────────────────────────────────────────────
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4
            opacity: root.showLyrics ? 0 : (root.hasPlayer ? 1.0 : 0.4)
            Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

            Rectangle {
                id: progressTrack
                Layout.fillWidth: true
                Layout.preferredHeight: 4
                radius: 2
                color: Theme.bgInput

                readonly property real ratio: {
                    if (!root.hasPlayer || !root.player.length || root.player.length <= 0) return 0;
                    return Math.max(0, Math.min(1, root.player.position / root.player.length));
                }

                Rectangle {
                    height: parent.height
                    radius: parent.radius
                    width: parent.width * progressTrack.ratio
                    color: Theme.accentColor
                    Behavior on width { SmoothedAnimation { velocity: 200 } }
                }

                Rectangle {
                    width: 10; height: 10; radius: 5
                    color: Theme.accentColor
                    border.width: 2
                    border.color: Theme.bgDeep
                    x: parent.width * progressTrack.ratio - width / 2
                    y: (parent.height - height) / 2
                    visible: seekArea.containsMouse || seekArea.pressed
                    Behavior on x { SmoothedAnimation { velocity: 200 } }
                }

                MouseArea {
                    id: seekArea
                    anchors.fill: parent
                    anchors.topMargin: -8
                    anchors.bottomMargin: -8
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: root.hasPlayer && root.player && root.player.canSeek
                    onClicked: (mouse) => {
                        if (!enabled) return;
                        var ratio = Math.max(0, Math.min(1, mouse.x / width));
                        root.player.position = ratio * root.player.length;
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: root.hasPlayer ? root.fmtTime(root.player.position) : "0:00"
                    font.family: "JetBrains Mono"
                    font.pixelSize: 10
                    color: Theme.textDim
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: root.hasPlayer ? root.fmtTime(root.player.length) : "0:00"
                    font.family: "JetBrains Mono"
                    font.pixelSize: 10
                    color: Theme.textDim
                }
            }
        }

        // ── Lyrics toggle (transport controls live on the vinyl itself) ──
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 14

            TransportButton {
                glyph: "♪"
                size: 30
                accent: root.showLyrics
                enabled: root.hasPlayer
                onActivated: root.showLyrics = !root.showLyrics
            }
        }

        // Bottom spacer — paired with the top spacer to vertically center content
        Item { Layout.fillHeight: true }
    }

    // ── Lyrics overlay (full panel width) ────────────────────────────────
    // Shows the active sentence centered, plus 1–2 sibling lines fading out
    // above and below. No scrolling — lines just rotate through this fixed
    // 5-slot column as the position advances. Spans the entire widget width
    // with a small padding so long lines wrap rather than getting cropped.
    Item {
        id: lyricsOverlay
        anchors.fill: parent
        anchors.margins: 12
        opacity: root.showLyrics ? 1 : 0
        visible: opacity > 0.001
        Behavior on opacity { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }

        // Loading state
        Text {
            anchors.centerIn: parent
            width: parent.width - 16
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: root.lyricsLoading
            text: "Fetching lyrics…"
            font.family: "JetBrains Mono"
            font.pixelSize: 11
            color: Theme.textDim
            SequentialAnimation on opacity {
                running: root.lyricsLoading && root.showLyrics
                loops: Animation.Infinite
                NumberAnimation { from: 0.3; to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
                NumberAnimation { from: 1.0; to: 0.3; duration: 700; easing.type: Easing.InOutQuad }
            }
        }

        // Empty / not-found / not-synced states
        Text {
            anchors.centerIn: parent
            visible: !root.lyricsLoading && (!root.isSynced || root.lyricLines.length === 0)
            text: root.lyricsText && root.lyricsText.length > 0 && !root.isSynced
                  ? "Synced lyrics unavailable"
                  : "No lyrics found"
            horizontalAlignment: Text.AlignHCenter
            width: parent.width - 16
            wrapMode: Text.WordWrap
            font.family: "JetBrains Mono"
            font.pixelSize: 11
            color: Theme.textDim
        }

        // Synced lyrics: 5 fixed slots (−2 −1 0 +1 +2)
        Column {
            anchors.centerIn: parent
            width: parent.width - 16
            spacing: 8
            visible: !root.lyricsLoading && root.isSynced && root.lyricLines.length > 0

            Repeater {
                model: 5  // offsets: -2, -1, 0, +1, +2
                delegate: Text {
                    required property int index
                    readonly property int offset: index - 2
                    readonly property int targetIdx: root.currentLyricIndex + offset
                    readonly property bool isCurrent: offset === 0
                    readonly property bool inRange:
                        targetIdx >= 0 && targetIdx < root.lyricLines.length

                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    elide: Text.ElideNone

                    text: inRange
                          ? (root.lyricLines[targetIdx].text === ""
                             ? "·" : root.lyricLines[targetIdx].text)
                          : ""
                    font.family: "JetBrains Mono"
                    font.pixelSize: isCurrent ? 20 : 15
                    font.weight: isCurrent ? Font.DemiBold : Font.Normal
                    color: isCurrent ? Theme.accentColor : Theme.textSecondary
                    opacity: !inRange ? 0
                             : isCurrent ? 1.0
                             : Math.abs(offset) === 1 ? 0.55
                             : 0.28
                    Behavior on opacity { NumberAnimation { duration: 280 } }
                    Behavior on color   { ColorAnimation  { duration: 280 } }
                }
            }
        }
    }

    // ── Empty-state overlay (subtle) ─────────────────────────────────────
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 12
        visible: !root.hasPlayer
        text: "No active media player"
        font.family: "JetBrains Mono"
        font.pixelSize: 11
        color: Theme.textDim
        opacity: 0.6
        SequentialAnimation on opacity {
            running: !root.hasPlayer
            loops: Animation.Infinite
            NumberAnimation { from: 0.4; to: 0.8; duration: 1400; easing.type: Easing.InOutQuad }
            NumberAnimation { from: 0.8; to: 0.4; duration: 1400; easing.type: Easing.InOutQuad }
        }
    }

    // ── Reusable transport button ────────────────────────────────────────
    component TransportButton: Item {
        id: btn
        property string glyph: ""
        property real size: 36
        property bool accent: false
        signal activated()

        implicitWidth: size
        implicitHeight: size

        Rectangle {
            id: bg
            anchors.fill: parent
            radius: width / 2
            color: btn.accent
                   ? Theme.accentColor
                   : (ma.containsMouse ? Theme.hoverOverlay : Theme.bgElevated)
            opacity: btn.enabled ? 1.0 : 0.35
            border.width: btn.accent ? 0 : 1
            border.color: Theme.dividerColor

            scale: ma.pressed ? 0.92 : (ma.containsMouse ? 1.08 : 1.0)
            Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 160 } }
            Behavior on opacity { NumberAnimation { duration: 160 } }

            Text {
                anchors.centerIn: parent
                text: btn.glyph
                font.pixelSize: btn.size * 0.42
                color: btn.accent ? Theme.selectedTextColor : Theme.iconColor
            }
        }

        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: btn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: if (btn.enabled) btn.activated()
        }
    }
}
