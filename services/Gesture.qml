pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Webcam gesture control, as run by the anna daemon (anna/src/gesture/).
//
// One long-lived socket follows the engine's status (`gesture_watch`); short
// requests (on/off, camera list, camera switch) go through a second socket,
// one command per connection, since the daemon answers a single line and
// closes. Everything goes through the socket rather than the `anna` CLI: the
// daemon is the one that owns the camera.
Singleton {
    id: gesture

    // The daemon speaks gesture_* (an older anna answers with an error).
    property bool available: false
    property bool enabled: false
    // Camera open, LED on.
    property bool active: false
    property string mode: "idle"
    property string camera: ""
    property string error: ""
    // [{ path: "/dev/video0", name: "HD Webcam" }, …]
    property var cameras: []

    function setEnabled(on) {
        gesture._send({ cmd: "gesture_set", enabled: on });
    }

    function toggle() {
        gesture._send({ cmd: "gesture_toggle" });
    }

    function setCamera(path) {
        gesture.camera = path;
        gesture._send({ cmd: "gesture_set_camera", device: path });
    }

    function refreshCameras() {
        gesture._send({ cmd: "gesture_cameras" });
    }

    function _applyStatus(s) {
        gesture.available = true;
        gesture.enabled = !!s.enabled;
        gesture.active = !!s.active;
        gesture.mode = s.mode || "idle";
        gesture.camera = s.camera || "";
        gesture.error = s.error || "";
    }

    // ── Status stream ────────────────────────────────────────────────
    Socket {
        id: watchSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var s = JSON.parse(line);
                    if (s && s.enabled !== undefined)
                        gesture._applyStatus(s);
                } catch (e) { /* partial line */ }
            }
        }
        onConnectedChanged: {
            if (connected)
                write('{"cmd":"gesture_watch"}\n');
            else
                gesture.available = false;
        }
    }

    // (Re)connect while the daemon is away — it restarts with the session.
    Timer {
        interval: 3000
        running: !watchSock.connected
        repeat: true
        triggeredOnStart: true
        onTriggered: watchSock.connected = true
    }

    // ── Requests ─────────────────────────────────────────────────────
    property var _queue: []

    function _send(obj) {
        gesture._queue = gesture._queue.concat([JSON.stringify(obj)]);
        if (!reqSock.connected)
            reqSock.connected = true;
    }

    function _next() {
        gesture._queue = gesture._queue.slice(1);
        reqSock.connected = false;
        if (gesture._queue.length > 0)
            Qt.callLater(function () { reqSock.connected = true; });
    }

    Socket {
        id: reqSock
        path: Anna.socketPath
        parser: SplitParser {
            onRead: (line) => {
                try {
                    var r = JSON.parse(line);
                    if (Array.isArray(r))
                        gesture.cameras = r;
                    else if (r && r.enabled !== undefined)
                        gesture._applyStatus(r);
                } catch (e) { /* ignore */ }
                gesture._next();
            }
        }
        onConnectedChanged: {
            if (connected && gesture._queue.length > 0)
                write(gesture._queue[0] + "\n");
        }
    }
}
